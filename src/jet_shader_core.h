/* ------------------------------------------------------------------
 * jet_shader_core.h - the Pd-free half of jet_shader: reads the
 * @-annotations out of an effect file, lays out the parameter block the
 * same way Metal does, and wraps the user's code into a complete
 * shader source. Header-only so tools/effecttest.mm can run exactly
 * the code the object runs (make shadertest).
 *
 * An effect file is plain MSL plus comment directives:
 *
 *   // @input  src              first input = the chain's current texture
 *   // @input  mask  mymask     further inputs = named textures (jet_share),
 *                               optional default name
 *   // @param  float amount = 0.5
 *   // @param  float2 center = 0.5 0.5
 *   // @param  color  tint = 1 0.6 0.3 1       (a float4)
 *   // @feedback                gives t.prev = this object's previous output
 *   // @size   512 512          output size (default: size of the first input)
 *   // @history 30              keeps the last 30 frames of the first input;
 *                               jet_history(t, p, uv, framesAgo) reads one
 *
 *   float4 effect(float2 uv, constant JetParams &p, JetTex t)
 *   {
 *     return t.src.sample(t.smp, uv) * p.amount;
 *   }
 *
 * uv runs 0..1 with (0,0) at the top left, like texture coordinates.
 * p.time (seconds), p.frame and p.resolution (output size in pixels)
 * are always there, and with @history p.historyIndex / p.historyCount
 * (the raw ring buffer is t.hist, a texture2d_array). Parameter types: float, float2, float3, float4,
 * color (= float4, default white).
 * ------------------------------------------------------------------
 */
#ifndef _INCLUDE__JET_SHADER_CORE_H_
#define _INCLUDE__JET_SHADER_CORE_H_

#include <cctype>
#include <cstdlib>
#include <cstring>
#include <sstream>
#include <string>
#include <vector>

namespace jetsh {

static const int kMaxParams = 32;
static const int kMaxInputs = 8;
static const int kMaxHistory = 256;

struct Param {
  std::string name, type;   // type as written: float, float2, float3, float4, color
  int comps;                // 1..4
  std::vector<float> def;   // comps values
  size_t offset;            // byte offset inside JetParams
};

struct Input { std::string name, defaultName; };

// one entry per generated inlet, in file order (input 0 has none: it is
// the chain)
struct Item { bool isParam; int index; };

struct Spec {
  std::vector<Param> params;
  std::vector<Input> inputs;
  std::vector<Item>  items;
  bool   feedback;
  int    history;           // ring buffer length, 0 = none
  int    sizeW, sizeH;      // 0 = not given
  size_t structSize;
  std::string error;        // non-empty: the file is unusable
  Spec() : feedback(false), history(0), sizeW(0), sizeH(0), structSize(0) {}
};

// builtin members at the front of JetParams: float time; float frame;
// float2 resolution; int historyIndex; int historyCount;
// -> offsets 0, 4, 8, 16, 20; user members start at 24
static const size_t kTimeOff = 0, kFrameOff = 4, kResOff = 8,
                    kHistIdxOff = 16, kHistCntOff = 20, kUserStart = 24;

inline std::string trim(const std::string &s)
{
  size_t a = 0, b = s.size();
  while(a < b && isspace((unsigned char)s[a])) a++;
  while(b > a && isspace((unsigned char)s[b - 1])) b--;
  return s.substr(a, b - a);
}

inline bool isIdent(const std::string &s)
{
  if(s.empty() || !(isalpha((unsigned char)s[0]) || s[0] == '_')) return false;
  for(char c : s) if(!(isalnum((unsigned char)c) || c == '_')) return false;
  return true;
}

inline bool reserved(const std::string &s)
{
  return s == "time" || s == "frame" || s == "resolution";
}

// MSL alignment/size of the member types we allow (float3 occupies 16)
inline void typeLayout(int comps, size_t *align, size_t *size)
{
  switch(comps) {
    case 1:  *align = 4;  *size = 4;  break;
    case 2:  *align = 8;  *size = 8;  break;
    default: *align = 16; *size = 16; break;  // float3 and float4
  }
}

inline void layout(Spec &sp)
{
  size_t off = kUserStart, maxAlign = 16;
  for(Param &p : sp.params) {
    size_t a, sz;
    typeLayout(p.comps, &a, &sz);
    off = (off + a - 1) / a * a;
    p.offset = off;
    off += sz;
  }
  sp.structSize = (off + maxAlign - 1) / maxAlign * maxAlign;
}

inline std::string mslType(const Param &p)
{
  return p.comps == 1 ? "float" : "float" + std::to_string(p.comps);
}

inline Spec parse(const std::string &src)
{
  Spec sp;
  std::istringstream in(src);
  std::string line;
  int lineNo = 0;
  while(std::getline(in, line)) {
    lineNo++;
    std::string t = trim(line);
    if(t.compare(0, 2, "//") != 0) continue;
    t = trim(t.substr(2));
    if(t.empty() || t[0] != '@') continue;

    std::istringstream ts(t);
    std::vector<std::string> tok;
    std::string w;
    while(ts >> w) tok.push_back(w);
    const std::string &dir = tok[0];
    auto fail = [&](const std::string &m) {
      if(sp.error.empty()) sp.error = "line " + std::to_string(lineNo) + ": " + m;
    };

    if(dir == "@param") {
      if(tok.size() < 3) { fail("@param needs a type and a name"); continue; }
      Param p;
      p.type = tok[1];
      p.name = tok[2];
      p.offset = 0;
      if(p.type == "float") p.comps = 1;
      else if(p.type == "float2") p.comps = 2;
      else if(p.type == "float3") p.comps = 3;
      else if(p.type == "float4" || p.type == "color") p.comps = 4;
      else { fail("unknown parameter type '" + p.type + "' (float, float2, float3, float4, color)"); continue; }
      if(!isIdent(p.name) || reserved(p.name)) { fail("bad parameter name '" + p.name + "'"); continue; }
      for(const Param &q : sp.params) if(q.name == p.name) { fail("duplicate parameter '" + p.name + "'"); }
      // defaults after '='
      std::vector<float> vals;
      size_t i = 3;
      if(i < tok.size() && tok[i] == "=") i++;
      for(; i < tok.size() && (int)vals.size() < p.comps; i++) vals.push_back((float)atof(tok[i].c_str()));
      float fill = (p.type == "color") ? 1.f : 0.f;
      if(vals.empty()) {
        vals.assign(p.comps, fill);
      } else {
        // a single value fills a vector; otherwise pad with the last
        float last = vals.back();
        while((int)vals.size() < p.comps) vals.push_back(vals.size() == 1 ? vals[0] : last);
      }
      p.def = vals;
      if((int)sp.params.size() >= kMaxParams) { fail("too many parameters"); continue; }
      sp.items.push_back({true, (int)sp.params.size()});
      sp.params.push_back(p);
    } else if(dir == "@input") {
      if(tok.size() < 2 || !isIdent(tok[1])) { fail("@input needs a name"); continue; }
      Input in2;
      in2.name = tok[1];
      if(tok.size() >= 3) in2.defaultName = tok[2];
      for(const Input &q : sp.inputs) if(q.name == in2.name) { fail("duplicate input '" + in2.name + "'"); }
      if(in2.name == "prev" || in2.name == "smp") { fail("'" + in2.name + "' is reserved"); continue; }
      if((int)sp.inputs.size() >= kMaxInputs) { fail("too many inputs"); continue; }
      if(!sp.inputs.empty()) sp.items.push_back({false, (int)sp.inputs.size()});
      sp.inputs.push_back(in2);
    } else if(dir == "@feedback") {
      sp.feedback = true;
    } else if(dir == "@history") {
      sp.history = tok.size() >= 2 ? atoi(tok[1].c_str()) : 0;
      if(sp.history < 1 || sp.history > kMaxHistory)
        fail("@history needs a frame count between 1 and " + std::to_string(kMaxHistory));
    } else if(dir == "@size") {
      if(tok.size() < 3) { fail("@size needs width and height"); continue; }
      sp.sizeW = atoi(tok[1].c_str());
      sp.sizeH = atoi(tok[2].c_str());
      if(sp.sizeW < 1 || sp.sizeH < 1) fail("bad @size");
    } else {
      fail("unknown directive '" + dir + "'");
    }
  }
  if(sp.history > 0 && sp.inputs.empty() && sp.error.empty()) {
    sp.error = "@history records the first @input, so there has to be one";
  }
  if(src.find("effect") == std::string::npos && sp.error.empty()) {
    sp.error = "no effect() function found - define: "
               "float4 effect(float2 uv, constant JetParams &p, JetTex t)";
  }
  layout(sp);
  return sp;
}

// the complete shader source: generated prelude, the user's code
// (with #line so errors point into the user's file), generated entry
// points. Entry points are jet_vertex / jet_fragment.
inline std::string buildSource(const Spec &sp, const std::string &user, const std::string &fileName)
{
  std::string s;
  s += "#include <metal_stdlib>\nusing namespace metal;\n";
  s += "struct JetParams {\n  float time;\n  float frame;\n  float2 resolution;\n"
       "  int historyIndex;\n  int historyCount;\n";
  for(const Param &p : sp.params) s += "  " + mslType(p) + " " + p.name + ";\n";
  s += "};\n";
  s += "struct JetTex {\n";
  for(const Input &i : sp.inputs) s += "  texture2d<float> " + i.name + ";\n";
  if(sp.feedback) s += "  texture2d<float> prev;\n";
  if(sp.history > 0) s += "  texture2d_array<float> hist;\n";
  s += "  sampler smp;\n};\n";
  if(sp.history > 0) {
    s += "constant int JET_HISTORY_SIZE = " + std::to_string(sp.history) + ";\n";
    // the frame `framesAgo` back (0 = the current one), limited to the
    // frames recorded so far
    s += "float4 jet_history(JetTex t, constant JetParams &p, float2 uv, int framesAgo) {\n"
         "  framesAgo = clamp(framesAgo, 0, max(p.historyCount - 1, 0));\n"
         "  int slot = (p.historyIndex - framesAgo + JET_HISTORY_SIZE) % JET_HISTORY_SIZE;\n"
         "  return t.hist.sample(t.smp, uv, slot);\n}\n";
  }
  s += "struct JetVOut { float4 position [[position]]; float2 uv; };\n";
  s += "constant float2 jet_quad[6] = { float2(-1, 1), float2(-1, -1), float2(1, -1),\n"
       "                                float2(-1, 1), float2(1, -1), float2(1, 1) };\n";
  s += "vertex JetVOut jet_vertex(uint vid [[vertex_id]]) {\n"
       "  JetVOut o;\n  float2 q = jet_quad[vid];\n"
       "  o.position = float4(q, 0.0, 1.0);\n"
       "  o.uv = float2(q.x * 0.5 + 0.5, 0.5 - q.y * 0.5);\n  return o;\n}\n";
  s += "#line 1 \"" + fileName + "\"\n";
  s += user;
  s += "\n";
  s += "fragment float4 jet_fragment(JetVOut in [[stage_in]],\n    constant JetParams &p [[buffer(0)]]";
  int n = 0;
  std::string init;
  for(size_t k = 0; k < sp.inputs.size(); k++) {
    s += ",\n    texture2d<float> tex" + std::to_string(n) + " [[texture(" + std::to_string(n) + ")]]";
    init += "tex" + std::to_string(n) + ", ";
    n++;
  }
  if(sp.feedback) {
    s += ",\n    texture2d<float> texPrev [[texture(" + std::to_string(n) + ")]]";
    init += "texPrev, ";
    n++;
  }
  if(sp.history > 0) {
    s += ",\n    texture2d_array<float> texHist [[texture(" + std::to_string(n) + ")]]";
    init += "texHist, ";
  }
  s += ",\n    sampler smp [[sampler(0)]]) {\n";
  s += "  JetTex t = { " + init + "smp };\n";
  s += "  return effect(in.uv, p, t);\n}\n";
  return s;
}

// writes the current values into the byte block that gets bound at
// buffer(0). values[i] holds up to 4 floats for params[i].
inline void fillBuffer(const Spec &sp, const std::vector<std::vector<float> > &values,
                       float time, float frame, float resW, float resH,
                       int histIndex, int histCount,
                       std::vector<unsigned char> &buf)
{
  buf.assign(sp.structSize, 0);
  memcpy(&buf[kTimeOff], &time, 4);
  memcpy(&buf[kFrameOff], &frame, 4);
  float res[2] = { resW, resH };
  memcpy(&buf[kResOff], res, 8);
  memcpy(&buf[kHistIdxOff], &histIndex, 4);
  memcpy(&buf[kHistCntOff], &histCount, 4);
  for(size_t i = 0; i < sp.params.size() && i < values.size(); i++) {
    const Param &p = sp.params[i];
    for(int c = 0; c < p.comps && c < (int)values[i].size(); c++)
      memcpy(&buf[p.offset + 4 * c], &values[i][c], 4);
  }
}

}  // namespace jetsh

#endif
