/* ------------------------------------------------------------------
 * jet_perlin - GPU fragment-shader version of pix_perlin: the same
 * animated, spatially-coherent gradient noise, but computed per
 * pixel in parallel on the GPU instead of in a CPU loop. Same
 * parameter set as pix_perlin (period/amp/offset/rate/harmonics/
 * roughness/seed) for a direct apples-to-apples comparison.
 *
 * True render-to-texture: unlike the first version (which drew
 * straight into jet_win's on-screen pass), this renders into its
 * OWN offscreen texture via a SEPARATE command buffer pulled from
 * jet_win's shared queue (jet_win_queue()), then publishes that
 * texture as the chain's "current texture" - the same slot
 * jet_texture uses - so it can feed jet_texture/jet_rectangle
 * (or, later, several consumers at once) like a real TOP, instead of
 * being a dead end on screen.
 *
 * Why a separate command buffer: jet_win's on-screen encoder stays
 * open for the whole frame (every jet_head chain draws into it in
 * turn), and Metal only allows one open encoder per command buffer
 * at a time. A second, independent command buffer submitted to the
 * SAME queue is the normal way to do an extra render pass mid-frame;
 * Metal guarantees same-queue command buffers execute in commit
 * order, so this offscreen pass is guaranteed done before the later-
 * committed on-screen pass samples its texture - no manual
 * wait/fence needed.
 *
 * Builds its own pipeline (lazily, once jet_win has a device) -
 * doesn't touch jet_win's shared flat/textured pipelines, showing
 * that any object can bring its own custom shader, GLSL-TOP-style.
 * Hash-based noise (no permutation table / texture lookups needed,
 * unlike the CPU version).
 * ------------------------------------------------------------------
 */

#import <Metal/Metal.h>

#include "m_pd.h"
#include "jet_shared.h"

static t_class *jet_perlin_class;

typedef struct { float pos[2]; float uv[2]; } QuadVertex;

// must match the MSL PerlinParams struct field-for-field
typedef struct {
  float period;
  float amp;
  float offset;
  float time;
  int   harmonics;
  float roughness;
  float seedX;
  float seedY;
} PerlinParams;

typedef struct _jet_perlin {
  t_object  x_obj;
  t_outlet *x_outlet;
  int       x_texW, x_texH;
  PerlinParams x_params;
  float     x_rate;  // how fast params.time advances, Hz (not sent to the GPU)
  double    x_lastSysTime;
  id<MTLRenderPipelineState> x_pipeline;   // built lazily, on first bang
  id<MTLTexture>             x_tex;        // offscreen render target, rebuilt on resize
} t_jet_perlin;

static NSString *const kPerlinShaderSrc = @""
  "#include <metal_stdlib>\n"
  "using namespace metal;\n"
  "struct QuadVertex { float2 pos; float2 uv; };\n"
  "struct VOut { float4 position [[position]]; float2 uv; };\n"
  "struct PerlinParams {\n"
  "  float period; float amp; float offset; float time;\n"
  "  int harmonics; float roughness; float seedX; float seedY;\n"
  "};\n"
  "vertex VOut perlinVertexMain(uint vid [[vertex_id]],\n"
  "    constant QuadVertex *verts [[buffer(0)]]) {\n"
  "  VOut out;\n"
  "  out.position = float4(verts[vid].pos, 0.0, 1.0);\n"
  "  out.uv = verts[vid].uv;\n"
  "  return out;\n"
  "}\n"
  "static float2 hash22(float2 p, float2 seed) {\n"
  "  p = p + seed;\n"
  "  float3 p3 = fract(float3(p.x, p.y, p.x) * float3(0.1031, 0.1030, 0.0973));\n"
  "  p3 += dot(p3, p3.yzx + 33.33);\n"
  "  return fract((p3.xx + p3.yz) * p3.zy) * 2.0 - 1.0;\n"
  "}\n"
  "static float fadeCurve(float t) { return t*t*t*(t*(t*6.0-15.0)+10.0); }\n"
  "static float perlin2(float2 p, float2 seed) {\n"
  "  float2 pi = floor(p);\n"
  "  float2 pf = fract(p);\n"
  "  float d00 = dot(hash22(pi + float2(0,0), seed), pf - float2(0,0));\n"
  "  float d10 = dot(hash22(pi + float2(1,0), seed), pf - float2(1,0));\n"
  "  float d01 = dot(hash22(pi + float2(0,1), seed), pf - float2(0,1));\n"
  "  float d11 = dot(hash22(pi + float2(1,1), seed), pf - float2(1,1));\n"
  "  float2 u = float2(fadeCurve(pf.x), fadeCurve(pf.y));\n"
  "  float x1 = mix(d00, d10, u.x);\n"
  "  float x2 = mix(d01, d11, u.x);\n"
  "  return mix(x1, x2, u.y);\n"
  "}\n"
  "static float fbm2(float2 p, float2 seed, int harmonics, float roughness) {\n"
  "  float total = 0.0, amp = 1.0, freq = 1.0, maxAmp = 0.0;\n"
  "  for (int i = 0; i < harmonics; i++) {\n"
  "    total += perlin2(p * freq, seed) * amp;\n"
  "    maxAmp += amp;\n"
  "    amp *= roughness;\n"
  "    freq *= 2.0;\n"
  "  }\n"
  "  return maxAmp > 0.0 ? total / maxAmp : 0.0;\n"
  "}\n"
  "fragment float4 perlinFragmentMain(VOut in [[stage_in]],\n"
  "    constant PerlinParams &params [[buffer(0)]]) {\n"
  "  float2 p = in.uv * (16.0 / max(params.period, 0.001));\n"
  "  float2 seed = float2(params.seedX, params.seedY);\n"
  "  float rRaw = fbm2(p + float2(params.time, 0.0), seed,\n"
  "                    params.harmonics, params.roughness);\n"
  "  float gRaw = fbm2(p + float2(1000.0, 1000.0 + params.time), seed,\n"
  "                    params.harmonics, params.roughness);\n"
  "  float r = params.offset + params.amp * rRaw;\n"
  "  float g = params.offset + params.amp * gRaw;\n"
  "  return float4(saturate(r), saturate(g), 0.5, 1.0);\n"
  "}\n";

static void jet_perlin_ensurePipeline(t_jet_perlin *x)
{
  if(x->x_pipeline) {
    return;
  }
  id<MTLDevice> device = jet_win_device();
  if(!device) {
    return;  // jet_win not created yet
  }

  NSError *err = nil;
  id<MTLLibrary> lib = [device newLibraryWithSource:kPerlinShaderSrc options:nil error:&err];
  if(!lib) {
    pd_error(x, "jet_perlin: shader compile failed: %s",
             [[err localizedDescription] UTF8String]);
    return;
  }
  MTLRenderPipelineDescriptor *desc = [[MTLRenderPipelineDescriptor alloc] init];
  desc.vertexFunction = [lib newFunctionWithName:@"perlinVertexMain"];
  desc.fragmentFunction = [lib newFunctionWithName:@"perlinFragmentMain"];
  // we always render into our OWN offscreen texture now, never
  // straight to the screen drawable, so this must match that
  // texture's format (see jet_perlin_ensureTexture), not the
  // window's BGRA8Unorm
  desc.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;

  x->x_pipeline = [device newRenderPipelineStateWithDescriptor:desc error:&err];
  if(!x->x_pipeline) {
    pd_error(x, "jet_perlin: pipeline build failed: %s",
             [[err localizedDescription] UTF8String]);
  }
}

static void jet_perlin_ensureTexture(t_jet_perlin *x)
{
  if(x->x_tex && (int)x->x_tex.width == x->x_texW && (int)x->x_tex.height == x->x_texH) {
    return;
  }
  id<MTLDevice> device = jet_win_device();
  if(!device) {
    return;
  }
  MTLTextureDescriptor *desc =
    [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                        width:x->x_texW
                                                       height:x->x_texH
                                                    mipmapped:NO];
  desc.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
  x->x_tex = [device newTextureWithDescriptor:desc];
}

static void jet_perlin_bang(t_jet_perlin *x)
{
  // only meaningful while some jet_win frame is in progress (this
  // is also our cue that the device/queue are ready)
  if(!jet_win_current_encoder()) {
    return;
  }
  jet_perlin_ensurePipeline(x);
  jet_perlin_ensureTexture(x);
  if(!x->x_pipeline || !x->x_tex) {
    return;
  }

  const double dtMs = clock_gettimesince(x->x_lastSysTime);
  x->x_lastSysTime = clock_getlogicaltime();
  x->x_params.time += (float)(x->x_rate * (dtMs / 1000.0));

  // a quad filling the whole offscreen texture (-1..1 covers it
  // entirely in clip space, regardless of the texture's own pixel
  // size) - where/how big it ends up on screen is jet_rectangle's
  // job now, not ours
  static const QuadVertex verts[6] = {
    { { -1.f,  1.f }, { 0.f, 0.f } },
    { { -1.f, -1.f }, { 0.f, 1.f } },
    { {  1.f, -1.f }, { 1.f, 1.f } },
    { { -1.f,  1.f }, { 0.f, 0.f } },
    { {  1.f, -1.f }, { 1.f, 1.f } },
    { {  1.f,  1.f }, { 1.f, 0.f } },
  };

  id<MTLCommandQueue> queue = jet_win_queue();
  id<MTLCommandBuffer> cmdBuf = [queue commandBuffer];

  MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
  pass.colorAttachments[0].texture = x->x_tex;
  pass.colorAttachments[0].loadAction = MTLLoadActionClear;
  pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
  pass.colorAttachments[0].storeAction = MTLStoreActionStore;

  id<MTLRenderCommandEncoder> enc = [cmdBuf renderCommandEncoderWithDescriptor:pass];
  [enc setRenderPipelineState:x->x_pipeline];
  [enc setVertexBytes:verts length:sizeof(verts) atIndex:0];
  [enc setFragmentBytes:&x->x_params length:sizeof(PerlinParams) atIndex:0];
  [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
  [enc endEncoding];
  [cmdBuf commit];
  // deliberately NOT waiting here - same-queue commit order is
  // enough for jet_win's later, still-open on-screen pass to see
  // this texture correctly once it commits its own command buffer

  jet_win_set_current_texture(x->x_tex);
  outlet_bang(x->x_outlet);
}

static void jet_perlin_resolution(t_jet_perlin *x, t_floatarg w, t_floatarg h)
{
  x->x_texW = (w < 1) ? 1 : (int)w;
  x->x_texH = (h < 1) ? 1 : (int)h;
  x->x_tex = nil;  // force jet_perlin_ensureTexture() to rebuild it
}
static void jet_perlin_period(t_jet_perlin *x, t_floatarg f) { x->x_params.period = f; }
static void jet_perlin_amp(t_jet_perlin *x, t_floatarg f)    { x->x_params.amp = f; }
static void jet_perlin_offset(t_jet_perlin *x, t_floatarg f) { x->x_params.offset = f; }
static void jet_perlin_harmonics(t_jet_perlin *x, t_floatarg f)
{
  int h = (int)f;
  x->x_params.harmonics = (h < 1) ? 1 : h;
}
static void jet_perlin_roughness(t_jet_perlin *x, t_floatarg f) { x->x_params.roughness = f; }
static void jet_perlin_seed(t_jet_perlin *x, t_floatarg f)
{
  x->x_params.seedX = f * 12.9898f;
  x->x_params.seedY = f * 78.233f;
}

// advances params.time each tick by rate*dt - rate itself is just
// another settable parameter (0 = frozen), per-object
static void jet_perlin_rate(t_jet_perlin *x, t_floatarg f) { x->x_rate = f; }

static void *jet_perlin_new(t_symbol *s, int argc, t_atom *argv)
{
  t_jet_perlin *x = (t_jet_perlin *)pd_new(jet_perlin_class);
  (void)s;

  x->x_outlet = outlet_new(&x->x_obj, &s_bang);
  x->x_texW = (argc >= 1) ? (int)atom_getfloatarg(0, argc, argv) : 512;
  x->x_texH = (argc >= 2) ? (int)atom_getfloatarg(1, argc, argv) : 512;

  x->x_params.period = 4.f;
  x->x_params.amp = 0.5f;
  x->x_params.offset = 0.5f;
  x->x_params.time = 0.f;
  x->x_params.harmonics = 3;
  x->x_params.roughness = 0.5f;
  x->x_params.seedX = 12.9898f;
  x->x_params.seedY = 78.233f;
  x->x_rate = 0.15f;
  x->x_pipeline = nil;
  x->x_tex = nil;
  x->x_lastSysTime = clock_getlogicaltime();

  return (void *)x;
}

extern "C" void jet_perlin_setup(void)
{
  jet_perlin_class = class_new(gensym("jet_perlin"),
                                 (t_newmethod)jet_perlin_new, 0,
                                 sizeof(t_jet_perlin), CLASS_DEFAULT,
                                 A_GIMME, 0);
  class_addbang(jet_perlin_class, jet_perlin_bang);
  class_addmethod(jet_perlin_class, (t_method)jet_perlin_resolution,
                  gensym("resolution"), A_FLOAT, A_FLOAT, 0);
  class_addmethod(jet_perlin_class, (t_method)jet_perlin_period,
                  gensym("period"), A_FLOAT, 0);
  class_addmethod(jet_perlin_class, (t_method)jet_perlin_amp,
                  gensym("amp"), A_FLOAT, 0);
  class_addmethod(jet_perlin_class, (t_method)jet_perlin_offset,
                  gensym("offset"), A_FLOAT, 0);
  class_addmethod(jet_perlin_class, (t_method)jet_perlin_rate,
                  gensym("rate"), A_FLOAT, 0);
  class_addmethod(jet_perlin_class, (t_method)jet_perlin_harmonics,
                  gensym("harmonics"), A_FLOAT, 0);
  class_addmethod(jet_perlin_class, (t_method)jet_perlin_roughness,
                  gensym("roughness"), A_FLOAT, 0);
  class_addmethod(jet_perlin_class, (t_method)jet_perlin_seed,
                  gensym("seed"), A_FLOAT, 0);
}
