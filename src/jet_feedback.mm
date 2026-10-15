/* ------------------------------------------------------------------
 * jet_feedback - real-time video feedback/trail effect, the same
 * idea as TouchDesigner's Feedback TOP: each frame blends the CURRENT
 * texture (whatever's "current texture" when this bangs - jet_video,
 * jet_perlin, jet_image+jet_texture, anything) with a rotated/
 * zoomed copy of its OWN previous output. Classic spiraling video-
 * feedback trails, entirely on the GPU.
 *
 * This is deliberately the kind of thing that's awkward on Gem: it
 * needs a persistent, GPU-resident buffer that survives across
 * frames and gets sampled with a per-frame transform while also being
 * written to - a ping-pong pair of render targets, alternating which
 * one is "read from" (last frame's result) and which is "written to"
 * (this frame's result) each tick. Gem's pix_* objects operate on
 * CPU buffers per-chain, per-frame; there's no standing GPU-side
 * feedback-buffer concept to build this on without effectively
 * reimplementing a chunk of what this whole jet_* family already
 * gives us for free.
 *
 * Same render-to-texture pattern as jet_perlin.mm (see the comment
 * there for why a second command buffer on the shared queue is safe
 * mid-frame) - the only new piece is sampling TWO textures in one
 * fragment shader instead of generating color from scratch.
 * ------------------------------------------------------------------
 */

#import <Metal/Metal.h>

#include "m_pd.h"
#include "jet_shared.h"

#include <cmath>

static t_class *jet_feedback_class;

typedef struct { float pos[2]; float uv[2]; } QuadVertex;

// must match the MSL FeedbackParams struct field-for-field
typedef struct {
  float decay;
  float rotSin, rotCos;
  float zoom;
  float offsetX, offsetY;
} FeedbackParams;

typedef struct _jet_feedback {
  t_object  x_obj;
  t_outlet *x_outlet;
  int       x_texW, x_texH;
  FeedbackParams x_params;
  float     x_rotateDeg;  // degrees per iteration (per bang), not per second
  int       x_warnedNoInput;
  id<MTLRenderPipelineState> x_pipeline;
  id<MTLTexture> x_texA;
  id<MTLTexture> x_texB;
  int       x_writeIsA;  // which of A/B this tick renders INTO; the other is "previous"
} t_jet_feedback;

static NSString *const kFeedbackShaderSrc = @""
  "#include <metal_stdlib>\n"
  "using namespace metal;\n"
  "struct QuadVertex { float2 pos; float2 uv; };\n"
  "struct VOut { float4 position [[position]]; float2 uv; };\n"
  "struct FeedbackParams {\n"
  "  float decay; float rotSin; float rotCos; float zoom;\n"
  "  float offsetX; float offsetY;\n"
  "};\n"
  "vertex VOut feedbackVertexMain(uint vid [[vertex_id]],\n"
  "    constant QuadVertex *verts [[buffer(0)]]) {\n"
  "  VOut out;\n"
  "  out.position = float4(verts[vid].pos, 0.0, 1.0);\n"
  "  out.uv = verts[vid].uv;\n"
  "  return out;\n"
  "}\n"
  "fragment float4 feedbackFragmentMain(VOut in [[stage_in]],\n"
  "    texture2d<float> currentTex [[texture(0)]],\n"
  "    texture2d<float> prevTex [[texture(1)]],\n"
  "    sampler s [[sampler(0)]],\n"
  "    constant FeedbackParams &params [[buffer(0)]]) {\n"
  "  float2 centered = in.uv - float2(0.5, 0.5);\n"
  "  float2 rotated = float2(centered.x * params.rotCos - centered.y * params.rotSin,\n"
  "                          centered.x * params.rotSin + centered.y * params.rotCos);\n"
  "  rotated *= params.zoom;\n"
  "  rotated += float2(params.offsetX, params.offsetY);\n"
  "  float2 prevUv = rotated + float2(0.5, 0.5);\n"
  "  float4 cur = currentTex.sample(s, in.uv);\n"
  "  float4 prev = float4(0.0, 0.0, 0.0, 1.0);\n"
  "  if(prevUv.x >= 0.0 && prevUv.x <= 1.0 && prevUv.y >= 0.0 && prevUv.y <= 1.0) {\n"
  "    prev = prevTex.sample(s, prevUv);\n"
  "  }\n"
  "  return mix(cur, prev, params.decay);\n"
  "}\n";

static void jet_feedback_ensurePipeline(t_jet_feedback *x)
{
  if(x->x_pipeline) {
    return;
  }
  id<MTLDevice> device = jet_win_device();
  if(!device) {
    return;  // jet_win not created yet
  }

  NSError *err = nil;
  id<MTLLibrary> lib = [device newLibraryWithSource:kFeedbackShaderSrc options:nil error:&err];
  if(!lib) {
    pd_error(x, "jet_feedback: shader compile failed: %s",
             [[err localizedDescription] UTF8String]);
    return;
  }
  MTLRenderPipelineDescriptor *desc = [[MTLRenderPipelineDescriptor alloc] init];
  desc.vertexFunction = [lib newFunctionWithName:@"feedbackVertexMain"];
  desc.fragmentFunction = [lib newFunctionWithName:@"feedbackFragmentMain"];
  desc.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;

  x->x_pipeline = [device newRenderPipelineStateWithDescriptor:desc error:&err];
  if(!x->x_pipeline) {
    pd_error(x, "jet_feedback: pipeline build failed: %s",
             [[err localizedDescription] UTF8String]);
  }
}

static id<MTLTexture> jet_feedback_makeTexture(id<MTLDevice> device, int w, int h)
{
  MTLTextureDescriptor *desc =
    [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                        width:w
                                                       height:h
                                                    mipmapped:NO];
  desc.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
  return [device newTextureWithDescriptor:desc];
}

// clears a freshly-(re)allocated texture to black - otherwise its
// first use as "previous frame" would sample uninitialized GPU
// memory for one tick before the feedback loop overwrites it
static void jet_feedback_clearTexture(id<MTLTexture> tex)
{
  id<MTLCommandQueue> queue = jet_win_queue();
  id<MTLCommandBuffer> cmdBuf = [queue commandBuffer];
  MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
  pass.colorAttachments[0].texture = tex;
  pass.colorAttachments[0].loadAction = MTLLoadActionClear;
  pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
  pass.colorAttachments[0].storeAction = MTLStoreActionStore;
  id<MTLRenderCommandEncoder> enc = [cmdBuf renderCommandEncoderWithDescriptor:pass];
  [enc endEncoding];
  [cmdBuf commit];
}

static void jet_feedback_ensureTextures(t_jet_feedback *x)
{
  if(x->x_texA && x->x_texB &&
     (int)x->x_texA.width == x->x_texW && (int)x->x_texA.height == x->x_texH) {
    return;
  }
  id<MTLDevice> device = jet_win_device();
  if(!device) {
    return;
  }
  x->x_texA = jet_feedback_makeTexture(device, x->x_texW, x->x_texH);
  x->x_texB = jet_feedback_makeTexture(device, x->x_texW, x->x_texH);
  jet_feedback_clearTexture(x->x_texA);
  jet_feedback_clearTexture(x->x_texB);
  x->x_writeIsA = 1;
}

static void jet_feedback_bang(t_jet_feedback *x)
{
  // only meaningful while some jet_win frame is in progress (also
  // our cue that the device/queue are ready) - same convention as
  // jet_perlin
  if(!jet_win_frame_active()) {
    return;
  }

  id<MTLTexture> inputTex = jet_win_current_texture();
  if(!inputTex) {
    if(!x->x_warnedNoInput) {
      pd_error(x, "jet_feedback: no current texture to feed back (put a "
               "texture-producing object before this in the chain)");
      x->x_warnedNoInput = 1;
    }
    return;
  }
  x->x_warnedNoInput = 0;

  jet_feedback_ensurePipeline(x);
  jet_feedback_ensureTextures(x);
  if(!x->x_pipeline || !x->x_texA || !x->x_texB) {
    return;
  }

  id<MTLTexture> writeTex = x->x_writeIsA ? x->x_texA : x->x_texB;
  id<MTLTexture> prevTex = x->x_writeIsA ? x->x_texB : x->x_texA;

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
  pass.colorAttachments[0].texture = writeTex;
  pass.colorAttachments[0].loadAction = MTLLoadActionClear;
  pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
  pass.colorAttachments[0].storeAction = MTLStoreActionStore;

  id<MTLRenderCommandEncoder> enc = [cmdBuf renderCommandEncoderWithDescriptor:pass];
  [enc setRenderPipelineState:x->x_pipeline];
  [enc setVertexBytes:verts length:sizeof(verts) atIndex:0];
  [enc setFragmentTexture:inputTex atIndex:0];
  [enc setFragmentTexture:prevTex atIndex:1];
  [enc setFragmentSamplerState:jet_win_sampler() atIndex:0];
  [enc setFragmentBytes:&x->x_params length:sizeof(FeedbackParams) atIndex:0];
  [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
  [enc endEncoding];
  [cmdBuf commit];
  // deliberately NOT waiting - same-queue commit order is enough, see
  // jet_perlin.mm's comment for why

  jet_win_set_current_texture(writeTex);
  x->x_writeIsA = !x->x_writeIsA;
  outlet_bang(x->x_outlet);
}

static void jet_feedback_resolution(t_jet_feedback *x, t_floatarg w, t_floatarg h)
{
  x->x_texW = (w < 1) ? 1 : (int)w;
  x->x_texH = (h < 1) ? 1 : (int)h;
  x->x_texA = nil;
  x->x_texB = nil;  // force jet_feedback_ensureTextures() to rebuild both
}

static void jet_feedback_decay(t_jet_feedback *x, t_floatarg f)
{
  if(f < 0.f) f = 0.f;
  if(f > 0.999f) f = 0.999f;  // 1.0 would never fade at all - a frozen-forever trail
  x->x_params.decay = f;
}

static void jet_feedback_rotate(t_jet_feedback *x, t_floatarg f)
{
  x->x_rotateDeg = f;
  const float rad = f * (float)M_PI / 180.f;
  x->x_params.rotSin = sinf(rad);
  x->x_params.rotCos = cosf(rad);
}

static void jet_feedback_zoom(t_jet_feedback *x, t_floatarg f)
{
  x->x_params.zoom = f;
}

static void jet_feedback_offset(t_jet_feedback *x, t_floatarg ox, t_floatarg oy)
{
  x->x_params.offsetX = ox;
  x->x_params.offsetY = oy;
}

static void *jet_feedback_new(t_symbol *s, int argc, t_atom *argv)
{
  t_jet_feedback *x = (t_jet_feedback *)pd_new(jet_feedback_class);
  (void)s;

  x->x_outlet = outlet_new(&x->x_obj, &s_bang);
  x->x_texW = (argc >= 1) ? (int)atom_getfloatarg(0, argc, argv) : 512;
  x->x_texH = (argc >= 2) ? (int)atom_getfloatarg(1, argc, argv) : 512;

  x->x_params.decay = 0.9f;
  x->x_rotateDeg = 1.5f;
  const float rad = x->x_rotateDeg * (float)M_PI / 180.f;
  x->x_params.rotSin = sinf(rad);
  x->x_params.rotCos = cosf(rad);
  x->x_params.zoom = 1.0f;
  x->x_params.offsetX = 0.f;
  x->x_params.offsetY = 0.f;

  x->x_warnedNoInput = 0;
  x->x_pipeline = nil;
  x->x_texA = nil;
  x->x_texB = nil;
  x->x_writeIsA = 1;

  return (void *)x;
}

extern "C" void jet_feedback_setup(void)
{
  jet_feedback_class = class_new(gensym("jet_feedback"),
                                   (t_newmethod)jet_feedback_new, 0,
                                   sizeof(t_jet_feedback), CLASS_DEFAULT,
                                   A_GIMME, 0);
  class_addbang(jet_feedback_class, jet_feedback_bang);
  class_addmethod(jet_feedback_class, (t_method)jet_feedback_resolution,
                  gensym("resolution"), A_FLOAT, A_FLOAT, 0);
  class_addmethod(jet_feedback_class, (t_method)jet_feedback_decay,
                  gensym("decay"), A_FLOAT, 0);
  class_addmethod(jet_feedback_class, (t_method)jet_feedback_rotate,
                  gensym("rotate"), A_FLOAT, 0);
  class_addmethod(jet_feedback_class, (t_method)jet_feedback_zoom,
                  gensym("zoom"), A_FLOAT, 0);
  class_addmethod(jet_feedback_class, (t_method)jet_feedback_offset,
                  gensym("offset"), A_FLOAT, A_FLOAT, 0);
}
