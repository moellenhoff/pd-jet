/* ------------------------------------------------------------------
 * jet_shader - runs a Metal fragment shader on the chain's current
 * texture (or, for generator effects, on nothing) and hands the result
 * on as the new current texture - the equivalent of a TouchDesigner
 * GLSL TOP. It replaces special-purpose objects: the effect lives in a
 * plain text file next to the patch, and the parameters the file
 * declares become inlets of the object.
 *
 *   [jet_shader kaleidoscope.metal]
 *
 * An effect file is MSL plus @-comments (the full format is described
 * at the top of jet_shader_core.h, with examples in shaders/):
 *
 *   // @input src
 *   // @param float amount = 0.5
 *   float4 effect(float2 uv, constant JetParams &p, JetTex t) { ... }
 *
 * Inlets, left to right: the chain (bang), then one per @param (a float
 * for float, a list for float2/3/4/color) and one symbol inlet per
 * @input after the first (the name of a texture published with
 * jet_share). The value inlets only store - the next bang uses them -
 * like everywhere else in jet. The same values can be sent to the left
 * inlet by name: "amount 0.3", "tint 1 0.5 0 1". "info" prints the
 * list of inlets to the Pd window.
 *
 * With "// @history N" the object also keeps the last N frames of its
 * first input in a ring buffer (a GPU texture array) and the effect can
 * read any of them with jet_history(t, p, uv, framesAgo) - that is all a
 * slit-scan needs; see shaders/slitscan.metal. "freeze 1" stops recording.
 *
 * Messages: reload (read + recompile the file now), autoreload 0/1
 * (default 1: the file's modification time is checked every few
 * frames, so saving it in a text editor updates the picture live),
 * resolution w h (output size; default = @size, else the size of the
 * first input, else 512x512), input n name.
 *
 * Inlets are fixed when the object is created: if you add or remove
 * @param/@input lines, retype the object ("reload" still recompiles the
 * code and keeps your values by name, and tells you when the inlets no
 * longer match the file).
 * ------------------------------------------------------------------
 */

#import <Metal/Metal.h>

#include "m_pd.h"
#include "jet_shared.h"
#include "jet_shader_core.h"

#include <string>
#include <vector>
#include <sys/stat.h>
#include <unistd.h>

static t_class *jet_shader_class;

struct ShaderState {
  std::string fileName;                       // as typed in the box
  std::string path;                           // resolved absolute path
  std::string baseName;                       // for error messages
  double      mtime;
  std::string userSrc;
  jetsh::Spec spec;
  std::string signature;                      // inlet layout the object was created with
  std::vector<std::vector<float> > vals;      // current value of every param
  std::vector<t_symbol *> inputNames;         // [0] unused: input 0 is the chain
  std::vector<unsigned char> buf;
  id<MTLRenderPipelineState> pipeline;
  id<MTLTexture> texA, texB, black;
  id<MTLTexture> histTex;                     // @history ring buffer (texture array)
  id<MTLRenderPipelineState> copyPipeline;    // input -> history slice
  int    histNext, histValid, histW, histH, histLen;
  int    freeze;
  int    writeIsA;
  int    resW, resH;                          // from "resolution", 0 = unset
  double t0;
  float  frame;
  int    bangCount;
  int    autoreload;
  int    needCompile;
  int    warnedNoInput;
};

typedef struct _jet_shader {
  t_object     x_obj;
  t_outlet    *x_outlet;
  t_canvas    *x_canvas;
  ShaderState *s;
} t_jet_shader;

// ---------------------------------------------------------------- file

static std::string jet_shader_signature(const jetsh::Spec &sp)
{
  std::string sig;
  for(const jetsh::Item &it : sp.items) {
    if(it.isParam) sig += "p:" + sp.params[it.index].name + ":" + sp.params[it.index].type + ";";
    else           sig += "i:" + sp.inputs[it.index].name + ";";
  }
  return sig;
}

static double jet_shader_mtime(const std::string &path)
{
  struct stat st;
  if(stat(path.c_str(), &st) != 0) return 0;
  return (double)st.st_mtimespec.tv_sec + st.st_mtimespec.tv_nsec * 1e-9;
}

// reads + parses the file. On the initial load an unusable file leaves
// the object without parameters (it still exists, the patch still opens);
// on a reload the previous working state is kept.
static bool jet_shader_load(t_jet_shader *x, bool initial)
{
  ShaderState *s = x->s;
  if(s->path.empty()) {
    char dir[MAXPDSTRING], *name = NULL;
    int fd = canvas_open(x->x_canvas, s->fileName.c_str(), "", dir, &name, MAXPDSTRING, 0);
    if(fd < 0) {
      pd_error(x, "jet_shader: can't find '%s' (next to the patch or in the Pd path)",
               s->fileName.c_str());
      return false;
    }
    sys_close(fd);
    s->path = std::string(dir) + "/" + name;
    s->baseName = name;
  }
  NSString *text = [NSString stringWithContentsOfFile:[NSString stringWithUTF8String:s->path.c_str()]
                                             encoding:NSUTF8StringEncoding error:nil];
  if(!text) {
    pd_error(x, "jet_shader: can't read '%s'", s->path.c_str());
    return false;
  }
  s->mtime = jet_shader_mtime(s->path);
  std::string src = [text UTF8String];
  jetsh::Spec sp = jetsh::parse(src);
  if(!sp.error.empty()) {
    pd_error(x, "jet_shader: %s: %s", s->baseName.c_str(), sp.error.c_str());
    return false;
  }

  // keep the values of parameters that still exist (same name and size)
  std::vector<std::vector<float> > vals;
  for(const jetsh::Param &np : sp.params) {
    std::vector<float> v = np.def;
    for(size_t i = 0; i < s->spec.params.size(); i++) {
      if(s->spec.params[i].name == np.name && s->spec.params[i].comps == np.comps &&
         i < s->vals.size()) {
        v = s->vals[i];
        break;
      }
    }
    vals.push_back(v);
  }
  std::string sig = jet_shader_signature(sp);
  if(!initial && sig != s->signature) {
    pd_error(x, "jet_shader: the @param/@input lines of %s changed - the code is "
             "updated, but retype the object to get matching inlets",
             s->baseName.c_str());
  }
  s->spec = sp;
  s->userSrc = src;
  s->vals = vals;
  s->needCompile = 1;
  if(initial) s->signature = sig;
  return true;
}

static void jet_shader_ensurePipeline(t_jet_shader *x)
{
  ShaderState *s = x->s;
  if(!s->needCompile) return;
  id<MTLDevice> device = jet_win_device();
  if(!device) return;                 // jet_win not created yet
  s->needCompile = 0;

  std::string src = jetsh::buildSource(s->spec, s->userSrc, s->baseName);
  NSError *err = nil;
  id<MTLLibrary> lib = [device newLibraryWithSource:[NSString stringWithUTF8String:src.c_str()]
                                            options:nil error:&err];
  if(!lib) {
    pd_error(x, "jet_shader: %s", [[err localizedDescription] UTF8String]);
    return;
  }
  MTLRenderPipelineDescriptor *d = [[MTLRenderPipelineDescriptor alloc] init];
  id<MTLFunction> vf = [lib newFunctionWithName:@"jet_vertex"];
  id<MTLFunction> ff = [lib newFunctionWithName:@"jet_fragment"];
  d.vertexFunction = vf;
  d.fragmentFunction = ff;
  d.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
  id<MTLRenderPipelineState> ps = [device newRenderPipelineStateWithDescriptor:d error:&err];
  [d release];
  [vf release];
  [ff release];
  [lib release];
  if(!ps) {
    pd_error(x, "jet_shader: pipeline build failed: %s", [[err localizedDescription] UTF8String]);
    return;
  }
  [s->pipeline release];
  s->pipeline = ps;
}

// ------------------------------------------------------------ textures

// input texture -> one slice of the history array (a render pass rather
// than a blit, so differing sizes and pixel formats just work)
static NSString *const kHistoryCopySrc = @""
  "#include <metal_stdlib>\n"
  "using namespace metal;\n"
  "struct CopyVOut { float4 position [[position]]; float2 uv; };\n"
  "vertex CopyVOut copyVertex(uint vid [[vertex_id]]) {\n"
  "  float2 q = float2((vid == 2 || vid == 4 || vid == 5) ? 1.0 : -1.0,\n"
  "                    (vid == 0 || vid == 3 || vid == 5) ? 1.0 : -1.0);\n"
  "  CopyVOut o;\n"
  "  o.position = float4(q, 0.0, 1.0);\n"
  "  o.uv = float2(q.x * 0.5 + 0.5, 0.5 - q.y * 0.5);\n"
  "  return o;\n"
  "}\n"
  "fragment float4 copyFragment(CopyVOut in [[stage_in]],\n"
  "    texture2d<float> src [[texture(0)]], sampler smp [[sampler(0)]]) {\n"
  "  return src.sample(smp, in.uv);\n"
  "}\n";

static id<MTLTexture> jet_shader_makeTexture(id<MTLDevice> device, int w, int h)
{
  MTLTextureDescriptor *desc =
    [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                        width:w height:h mipmapped:NO];
  desc.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
  return [device newTextureWithDescriptor:desc];
}

// freshly allocated textures hold garbage; clear them (matters for the
// first read of "prev" in feedback effects)
static void jet_shader_clear(id<MTLTexture> tex)
{
  id<MTLCommandBuffer> cb = [jet_win_queue() commandBuffer];
  MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
  pass.colorAttachments[0].texture = tex;
  pass.colorAttachments[0].loadAction = MTLLoadActionClear;
  pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
  pass.colorAttachments[0].storeAction = MTLStoreActionStore;
  id<MTLRenderCommandEncoder> e = [cb renderCommandEncoderWithDescriptor:pass];
  [e endEncoding];
  [cb commit];
}

static bool jet_shader_ensureTextures(ShaderState *s, int w, int h)
{
  id<MTLDevice> device = jet_win_device();
  if(!device) return false;
  if(!s->black) {
    s->black = jet_shader_makeTexture(device, 1, 1);
    jet_shader_clear(s->black);
  }
  if(s->texA && s->texB && (int)s->texA.width == w && (int)s->texA.height == h) return true;
  [s->texA release];
  [s->texB release];
  s->texA = jet_shader_makeTexture(device, w, h);
  s->texB = jet_shader_makeTexture(device, w, h);
  jet_shader_clear(s->texA);
  jet_shader_clear(s->texB);
  return true;
}

// (re)creates the ring buffer when the length or the input size changed;
// every slice starts out black
static bool jet_shader_ensureHistory(ShaderState *s, int w, int h)
{
  id<MTLDevice> device = jet_win_device();
  if(!device) return false;
  if(!s->copyPipeline) {
    NSError *err = nil;
    id<MTLLibrary> lib = [device newLibraryWithSource:kHistoryCopySrc options:nil error:&err];
    if(!lib) return false;
    MTLRenderPipelineDescriptor *d = [[MTLRenderPipelineDescriptor alloc] init];
    id<MTLFunction> vf = [lib newFunctionWithName:@"copyVertex"];
    id<MTLFunction> ff = [lib newFunctionWithName:@"copyFragment"];
    d.vertexFunction = vf;
    d.fragmentFunction = ff;
    d.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
    s->copyPipeline = [device newRenderPipelineStateWithDescriptor:d error:&err];
    [d release]; [vf release]; [ff release]; [lib release];
    if(!s->copyPipeline) return false;
  }
  const int n = s->spec.history;
  if(s->histTex && s->histW == w && s->histH == h && s->histLen == n) return true;

  [s->histTex release];
  MTLTextureDescriptor *desc = [[MTLTextureDescriptor alloc] init];
  desc.textureType = MTLTextureType2DArray;
  desc.pixelFormat = MTLPixelFormatRGBA8Unorm;
  desc.width = w;
  desc.height = h;
  desc.arrayLength = n;
  desc.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
  s->histTex = [device newTextureWithDescriptor:desc];
  [desc release];
  if(!s->histTex) return false;
  s->histW = w; s->histH = h; s->histLen = n;
  s->histNext = 0; s->histValid = 0;

  id<MTLCommandBuffer> cb = [jet_win_queue() commandBuffer];
  for(int i = 0; i < n; i++) {
    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = s->histTex;
    pass.colorAttachments[0].slice = i;
    pass.colorAttachments[0].loadAction = MTLLoadActionClear;
    pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLRenderCommandEncoder> e = [cb renderCommandEncoderWithDescriptor:pass];
    [e endEncoding];
  }
  [cb commit];
  return true;
}

// ---------------------------------------------------------------- bang

static void jet_shader_bang(t_jet_shader *x)
{
  if(!jet_win_frame_active()) return;
  ShaderState *s = x->s;

  if(s->autoreload && !s->path.empty() && (++s->bangCount % 20) == 0) {
    if(jet_shader_mtime(s->path) != s->mtime) jet_shader_load(x, false);
  }
  jet_shader_ensurePipeline(x);
  if(!s->pipeline) return;

  const size_t nIn = s->spec.inputs.size();
  id<MTLTexture> in0 = nil;
  if(nIn >= 1) {
    in0 = jet_win_current_texture();
    if(!in0) {
      if(!s->warnedNoInput) {
        pd_error(x, "jet_shader: %s needs an input texture (put a texture-producing "
                 "object before this in the chain)", s->baseName.c_str());
        s->warnedNoInput = 1;
      }
      return;
    }
    s->warnedNoInput = 0;
  }

  int w = s->resW, h = s->resH;
  if(w < 1 || h < 1) { w = s->spec.sizeW; h = s->spec.sizeH; }
  if((w < 1 || h < 1) && in0) { w = (int)in0.width; h = (int)in0.height; }
  if(w < 1 || h < 1) { w = 512; h = 512; }
  if(!jet_shader_ensureTextures(s, w, h)) return;

  id<MTLTexture> out  = s->writeIsA ? s->texA : s->texB;
  id<MTLTexture> prev = s->writeIsA ? s->texB : s->texA;

  // @history: record this frame's first input, then tell the shader
  // which slot is the current one and how many are valid
  int histIndex = 0, histCount = 0;
  if(s->spec.history > 0) {
    if(!jet_shader_ensureHistory(s, (int)in0.width, (int)in0.height)) return;
    if(!s->freeze) {
      id<MTLCommandBuffer> hc = [jet_win_queue() commandBuffer];
      MTLRenderPassDescriptor *hp = [MTLRenderPassDescriptor renderPassDescriptor];
      hp.colorAttachments[0].texture = s->histTex;
      hp.colorAttachments[0].slice = s->histNext;
      hp.colorAttachments[0].loadAction = MTLLoadActionDontCare;
      hp.colorAttachments[0].storeAction = MTLStoreActionStore;
      id<MTLRenderCommandEncoder> he = [hc renderCommandEncoderWithDescriptor:hp];
      [he setRenderPipelineState:s->copyPipeline];
      [he setFragmentTexture:in0 atIndex:0];
      [he setFragmentSamplerState:jet_win_sampler() atIndex:0];
      [he drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
      [he endEncoding];
      [hc commit];
      histIndex = s->histNext;
      s->histNext = (s->histNext + 1) % s->histLen;
      if(s->histValid < s->histLen) s->histValid++;
    } else {
      histIndex = (s->histNext - 1 + s->histLen) % s->histLen;
    }
    histCount = s->histValid;
  }

  jetsh::fillBuffer(s->spec, s->vals, (float)(clock_gettimesince(s->t0) / 1000.0),
                    s->frame, (float)w, (float)h, histIndex, histCount, s->buf);
  s->frame += 1.f;

  id<MTLCommandBuffer> cb = [jet_win_queue() commandBuffer];
  MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
  pass.colorAttachments[0].texture = out;
  pass.colorAttachments[0].loadAction = MTLLoadActionDontCare;
  pass.colorAttachments[0].storeAction = MTLStoreActionStore;
  id<MTLRenderCommandEncoder> e = [cb renderCommandEncoderWithDescriptor:pass];
  [e setRenderPipelineState:s->pipeline];
  [e setFragmentBytes:s->buf.data() length:s->buf.size() atIndex:0];
  for(size_t k = 0; k < nIn; k++) {
    id<MTLTexture> t = (k == 0) ? in0 : nil;
    if(k > 0 && k < s->inputNames.size() && s->inputNames[k] && s->inputNames[k] != &s_) {
      t = jet_win_named_texture(s->inputNames[k]);
    }
    [e setFragmentTexture:(t ? t : s->black) atIndex:k];
  }
  if(s->spec.feedback) [e setFragmentTexture:prev atIndex:nIn];
  if(s->spec.history > 0) [e setFragmentTexture:s->histTex atIndex:nIn + (s->spec.feedback ? 1 : 0)];
  [e setFragmentSamplerState:jet_win_sampler() atIndex:0];
  [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
  [e endEncoding];
  [cb commit];
  // not waiting: same-queue commit order is enough (see jet_perlin.mm)

  s->writeIsA = !s->writeIsA;
  jet_win_set_current_texture(out);
  outlet_bang(x->x_outlet);
}

// ------------------------------------------------------------ messages

static void jet_shader_setParam(t_jet_shader *x, int idx, int argc, t_atom *argv)
{
  ShaderState *s = x->s;
  if(idx < 0 || idx >= (int)s->vals.size()) return;
  const int comps = s->spec.params[idx].comps;
  for(int c = 0; c < comps && c < argc; c++) {
    s->vals[idx][c] = atom_getfloat(argv + c);
  }
}

// every parameter inlet is created with its own selector "__p<N>"
static void jet_shader_pinlet(t_jet_shader *x, t_symbol *sel, int argc, t_atom *argv)
{
  jet_shader_setParam(x, atoi(sel->s_name + 3), argc, argv);
}

// ... and every extra input inlet with "__i<N>" carrying a symbol
static void jet_shader_iinlet(t_jet_shader *x, t_symbol *sel, int argc, t_atom *argv)
{
  const int k = atoi(sel->s_name + 3);
  ShaderState *s = x->s;
  if(k >= 1 && k < (int)s->inputNames.size() && argc >= 1) {
    s->inputNames[k] = atom_getsymbol(argv);
  }
}

// "<param name> v1 v2 ..." to the left inlet
static void jet_shader_anything(t_jet_shader *x, t_symbol *sel, int argc, t_atom *argv)
{
  ShaderState *s = x->s;
  for(size_t i = 0; i < s->spec.params.size(); i++) {
    if(s->spec.params[i].name == sel->s_name) {
      jet_shader_setParam(x, (int)i, argc, argv);
      return;
    }
  }
  pd_error(x, "jet_shader: no parameter or message '%s' (send \"info\" to list them)",
           sel->s_name);
}

static void jet_shader_reload(t_jet_shader *x)
{
  jet_shader_load(x, false);
}

static void jet_shader_autoreload(t_jet_shader *x, t_floatarg f)
{
  x->s->autoreload = f != 0;
}

static void jet_shader_freeze(t_jet_shader *x, t_floatarg f)
{
  x->s->freeze = f != 0;
}

static void jet_shader_resolution(t_jet_shader *x, t_floatarg w, t_floatarg h)
{
  x->s->resW = w < 1 ? 0 : (int)w;
  x->s->resH = h < 1 ? 0 : (int)h;
}

static void jet_shader_input(t_jet_shader *x, t_floatarg n, t_symbol *name)
{
  const int k = (int)n;
  if(k >= 1 && k < (int)x->s->inputNames.size()) x->s->inputNames[k] = name;
  else pd_error(x, "jet_shader: input %d doesn't exist (input 0 is the chain)", k);
}

static void jet_shader_info(t_jet_shader *x)
{
  ShaderState *s = x->s;
  post("jet_shader %s:", s->fileName.c_str());
  int inlet = 1;
  post("  inlet 0: the chain (bang)  [input %s]",
       s->spec.inputs.empty() ? "- none, generator" : s->spec.inputs[0].name.c_str());
  for(const jetsh::Item &it : s->spec.items) {
    if(it.isParam) {
      const jetsh::Param &p = s->spec.params[it.index];
      std::string v;
      for(int c = 0; c < p.comps; c++) v += " " + std::to_string(s->vals[it.index][c]);
      post("  inlet %d: %s (%s) =%s", inlet++, p.name.c_str(), p.type.c_str(), v.c_str());
    } else {
      post("  inlet %d: texture name for input '%s'", inlet++,
           s->spec.inputs[it.index].name.c_str());
    }
  }
  if(s->spec.history > 0) {
    post("  history: the last %d frames of '%s' (freeze 0/1 stops recording)",
         s->spec.history, s->spec.inputs[0].name.c_str());
  }
  post("  size: %s", s->spec.sizeW ? "from @size" : "that of the first input (512x512 without one)");
}

// ----------------------------------------------------------- lifecycle

static void *jet_shader_new(t_symbol *sel, int argc, t_atom *argv)
{
  t_jet_shader *x = (t_jet_shader *)pd_new(jet_shader_class);
  (void)sel;
  x->x_outlet = outlet_new(&x->x_obj, &s_bang);
  x->x_canvas = canvas_getcurrent();

  ShaderState *s = new ShaderState();
  x->s = s;
  s->mtime = 0;
  s->pipeline = nil;
  s->texA = s->texB = s->black = nil;
  s->histTex = nil;
  s->copyPipeline = nil;
  s->histNext = s->histValid = s->histW = s->histH = s->histLen = 0;
  s->freeze = 0;
  s->writeIsA = 1;
  s->resW = s->resH = 0;
  s->t0 = clock_getlogicaltime();
  s->frame = 0;
  s->bangCount = 0;
  s->autoreload = 1;
  s->needCompile = 0;
  s->warnedNoInput = 0;
  s->inputNames.assign(jetsh::kMaxInputs, nullptr);

  if(argc >= 1 && argv[0].a_type == A_SYMBOL) {
    s->fileName = atom_getsymbol(argv)->s_name;
    jet_shader_load(x, true);
  } else {
    pd_error(x, "jet_shader: needs an effect file ([jet_shader effect.metal])");
  }

  // one inlet per declared parameter / extra input, in file order
  for(const jetsh::Item &it : s->spec.items) {
    if(it.isParam) {
      std::string sel2 = "__p" + std::to_string(it.index);
      // Pd only forwards a float to an inlet declared as float, and a
      // list to one declared as list
      inlet_new(&x->x_obj, &x->x_obj.ob_pd,
                s->spec.params[it.index].comps == 1 ? &s_float : &s_list,
                gensym(sel2.c_str()));
    } else {
      std::string sel2 = "__i" + std::to_string(it.index);
      inlet_new(&x->x_obj, &x->x_obj.ob_pd, &s_symbol, gensym(sel2.c_str()));
      if(s->spec.inputs[it.index].defaultName.size())
        s->inputNames[it.index] = gensym(s->spec.inputs[it.index].defaultName.c_str());
    }
  }
  return (void *)x;
}

static void jet_shader_free(t_jet_shader *x)
{
  ShaderState *s = x->s;
  [s->pipeline release];
  [s->texA release];
  [s->texB release];
  [s->black release];
  [s->histTex release];
  [s->copyPipeline release];
  delete s;
  x->s = nullptr;
}

extern "C" void jet_shader_setup(void)
{
  jet_shader_class = class_new(gensym("jet_shader"),
                               (t_newmethod)jet_shader_new, (t_method)jet_shader_free,
                               sizeof(t_jet_shader), CLASS_DEFAULT,
                               A_GIMME, 0);
  class_addbang(jet_shader_class, jet_shader_bang);
  class_addanything(jet_shader_class, jet_shader_anything);
  class_addmethod(jet_shader_class, (t_method)jet_shader_reload, gensym("reload"), A_NULL);
  class_addmethod(jet_shader_class, (t_method)jet_shader_autoreload, gensym("autoreload"), A_FLOAT, 0);
  class_addmethod(jet_shader_class, (t_method)jet_shader_freeze, gensym("freeze"), A_FLOAT, 0);
  class_addmethod(jet_shader_class, (t_method)jet_shader_resolution, gensym("resolution"), A_FLOAT, A_FLOAT, 0);
  class_addmethod(jet_shader_class, (t_method)jet_shader_input, gensym("input"), A_FLOAT, A_SYMBOL, 0);
  class_addmethod(jet_shader_class, (t_method)jet_shader_info, gensym("info"), A_NULL);
  for(int i = 0; i < jetsh::kMaxParams; i++) {
    std::string n = "__p" + std::to_string(i);
    class_addmethod(jet_shader_class, (t_method)jet_shader_pinlet, gensym(n.c_str()), A_GIMME, 0);
  }
  for(int i = 1; i < jetsh::kMaxInputs; i++) {
    std::string n = "__i" + std::to_string(i);
    class_addmethod(jet_shader_class, (t_method)jet_shader_iinlet, gensym(n.c_str()), A_GIMME, 0);
  }
}
