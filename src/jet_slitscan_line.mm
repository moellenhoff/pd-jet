/* ------------------------------------------------------------------
 * jet_slitscan_line - GPU port of pix_slitscan_line: the classic
 * row-based slit-scan, each horizontal line of the output read from
 * a different point in time, delay increasing linearly from top to
 * bottom (or reversed) - like a mechanical slit-scan camera or a
 * rolling shutter through time.
 *
 * The CPU version keeps a ring buffer of raw RGBA frames and, per
 * row, memcpy's from whichever ring-buffer slot that row's delay
 * picks. Here the ring buffer is a single Metal texture2d_array (one
 * array slice per delay step, up to "delay" slices deep): writing a
 * new frame is one render pass into slice writeIndex, and reading is
 * a single fragment shader where each pixel picks its own array
 * slice with texture2d_array::sample(sampler, uv, index) - the
 * per-row "which past frame" lookup that was a CPU loop happens once
 * per pixel, in parallel, on the GPU.
 *
 * Two render passes per bang, same queue, same synchronization
 * argument as jet_perlin.mm: pass 1 writes the current frame into
 * this tick's array slice, pass 2 (committed after, so guaranteed to
 * see it) composites the output by sampling the array. Both target
 * offscreen textures and publish the result via "current texture"
 * (see jet_shared.h), same as jet_perlin/jet_feedback.
 * ------------------------------------------------------------------
 */

#import <Metal/Metal.h>

#include "m_pd.h"
#include "jet_shared.h"

static t_class *jet_slitscan_line_class;

typedef struct { float pos[2]; float uv[2]; } QuadVertex;

// must match the MSL SlitscanLineParams struct field-for-field
typedef struct {
  int maxDelay;
  int writeIndex;
  int reverse;
  int _pad;
} SlitscanLineParams;

typedef struct _jet_slitscan_line {
  t_object  x_obj;
  t_outlet *x_outlet;
  int       x_maxDelay;
  int       x_reverse;
  int       x_freeze;
  int       x_writeIndex;
  int       x_bufW, x_bufH;  // resolution the history array/output were built at
  int       x_warnedNoInput;
  id<MTLRenderPipelineState> x_copyPipeline;  // writes input -> history[slice]
  id<MTLRenderPipelineState> x_readPipeline;  // composites history -> output
  id<MTLTexture> x_historyArray;
  id<MTLTexture> x_outputTex;
} t_jet_slitscan_line;

static NSString *const kSlitscanLineShaderSrc = @""
  "#include <metal_stdlib>\n"
  "using namespace metal;\n"
  "struct QuadVertex { float2 pos; float2 uv; };\n"
  "struct VOut { float4 position [[position]]; float2 uv; };\n"
  "struct SlitscanLineParams { int maxDelay; int writeIndex; int reverse; int _pad; };\n"
  "vertex VOut slitscanLineVertexMain(uint vid [[vertex_id]],\n"
  "    constant QuadVertex *verts [[buffer(0)]]) {\n"
  "  VOut out;\n"
  "  out.position = float4(verts[vid].pos, 0.0, 1.0);\n"
  "  out.uv = verts[vid].uv;\n"
  "  return out;\n"
  "}\n"
  "fragment float4 slitscanLineCopyFragmentMain(VOut in [[stage_in]],\n"
  "    texture2d<float> currentTex [[texture(0)]], sampler s [[sampler(0)]]) {\n"
  "  return currentTex.sample(s, in.uv);\n"
  "}\n"
  "fragment float4 slitscanLineReadFragmentMain(VOut in [[stage_in]],\n"
  "    texture2d_array<float> history [[texture(0)]], sampler s [[sampler(0)]],\n"
  "    constant SlitscanLineParams &params [[buffer(0)]]) {\n"
  "  float t = in.uv.y;\n"
  "  if(params.reverse != 0) { t = 1.0 - t; }\n"
  "  int delay = int(t * float(params.maxDelay - 1) + 0.5);\n"
  "  delay = clamp(delay, 0, params.maxDelay - 1);\n"
  "  int slot = ((params.writeIndex - delay) % params.maxDelay + params.maxDelay) % params.maxDelay;\n"
  "  return history.sample(s, in.uv, slot);\n"
  "}\n";

static const QuadVertex kFullScreenQuad[6] = {
  { { -1.f,  1.f }, { 0.f, 0.f } },
  { { -1.f, -1.f }, { 0.f, 1.f } },
  { {  1.f, -1.f }, { 1.f, 1.f } },
  { { -1.f,  1.f }, { 0.f, 0.f } },
  { {  1.f, -1.f }, { 1.f, 1.f } },
  { {  1.f,  1.f }, { 1.f, 0.f } },
};

static void jet_slitscan_line_ensurePipelines(t_jet_slitscan_line *x)
{
  if(x->x_copyPipeline && x->x_readPipeline) {
    return;
  }
  id<MTLDevice> device = jet_win_device();
  if(!device) {
    return;  // jet_win not created yet
  }

  NSError *err = nil;
  id<MTLLibrary> lib = [device newLibraryWithSource:kSlitscanLineShaderSrc options:nil error:&err];
  if(!lib) {
    pd_error(x, "jet_slitscan_line: shader compile failed: %s",
             [[err localizedDescription] UTF8String]);
    return;
  }

  id<MTLFunction> vfn = [lib newFunctionWithName:@"slitscanLineVertexMain"];

  MTLRenderPipelineDescriptor *copyDesc = [[MTLRenderPipelineDescriptor alloc] init];
  copyDesc.vertexFunction = vfn;
  copyDesc.fragmentFunction = [lib newFunctionWithName:@"slitscanLineCopyFragmentMain"];
  copyDesc.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
  x->x_copyPipeline = [device newRenderPipelineStateWithDescriptor:copyDesc error:&err];
  if(!x->x_copyPipeline) {
    pd_error(x, "jet_slitscan_line: copy pipeline build failed: %s",
             [[err localizedDescription] UTF8String]);
  }

  MTLRenderPipelineDescriptor *readDesc = [[MTLRenderPipelineDescriptor alloc] init];
  readDesc.vertexFunction = vfn;
  readDesc.fragmentFunction = [lib newFunctionWithName:@"slitscanLineReadFragmentMain"];
  readDesc.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
  x->x_readPipeline = [device newRenderPipelineStateWithDescriptor:readDesc error:&err];
  if(!x->x_readPipeline) {
    pd_error(x, "jet_slitscan_line: read pipeline build failed: %s",
             [[err localizedDescription] UTF8String]);
  }
}

// clears one array slice to black via a no-draw clear-only pass - see
// jet_feedback.mm's jet_feedback_clearTexture for why: a freshly
// allocated slice holds undefined GPU memory, and until the ring
// buffer "warms up" (every slice written at least once), rows whose
// delay reaches into not-yet-written slices would sample that
// garbage instead of the black the CPU version starts with
// (m_history.assign(needed, 0)).
static void jet_slitscan_line_clearSlice(id<MTLTexture> array, int slice)
{
  id<MTLCommandQueue> queue = jet_win_queue();
  id<MTLCommandBuffer> cmdBuf = [queue commandBuffer];
  MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
  pass.colorAttachments[0].texture = array;
  pass.colorAttachments[0].slice = slice;
  pass.colorAttachments[0].loadAction = MTLLoadActionClear;
  pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
  pass.colorAttachments[0].storeAction = MTLStoreActionStore;
  id<MTLRenderCommandEncoder> enc = [cmdBuf renderCommandEncoderWithDescriptor:pass];
  [enc endEncoding];
  [cmdBuf commit];
}

static void jet_slitscan_line_ensureBuffers(t_jet_slitscan_line *x, int w, int h)
{
  if(x->x_historyArray && x->x_outputTex && x->x_bufW == w && x->x_bufH == h &&
     (int)x->x_historyArray.arrayLength == x->x_maxDelay) {
    return;
  }
  id<MTLDevice> device = jet_win_device();
  if(!device) {
    return;
  }

  MTLTextureDescriptor *arrDesc =
    [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                        width:w height:h mipmapped:NO];
  arrDesc.textureType = MTLTextureType2DArray;
  arrDesc.arrayLength = x->x_maxDelay;
  arrDesc.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
  x->x_historyArray = [device newTextureWithDescriptor:arrDesc];
  for(int i = 0; i < x->x_maxDelay; i++) {
    jet_slitscan_line_clearSlice(x->x_historyArray, i);
  }

  MTLTextureDescriptor *outDesc =
    [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                        width:w height:h mipmapped:NO];
  outDesc.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
  x->x_outputTex = [device newTextureWithDescriptor:outDesc];

  x->x_bufW = w;
  x->x_bufH = h;
  x->x_writeIndex = 0;
}

static void jet_slitscan_line_bang(t_jet_slitscan_line *x)
{
  if(!jet_win_current_encoder()) {
    return;
  }

  id<MTLTexture> inputTex = jet_win_current_texture();
  if(!inputTex) {
    if(!x->x_warnedNoInput) {
      pd_error(x, "jet_slitscan_line: no current texture (put a "
               "texture-producing object before this in the chain)");
      x->x_warnedNoInput = 1;
    }
    return;
  }
  x->x_warnedNoInput = 0;

  jet_slitscan_line_ensurePipelines(x);
  jet_slitscan_line_ensureBuffers(x, (int)inputTex.width, (int)inputTex.height);
  if(!x->x_copyPipeline || !x->x_readPipeline || !x->x_historyArray || !x->x_outputTex) {
    return;
  }

  id<MTLCommandQueue> queue = jet_win_queue();

  if(!x->x_freeze) {
    id<MTLCommandBuffer> cmdBuf1 = [queue commandBuffer];
    MTLRenderPassDescriptor *pass1 = [MTLRenderPassDescriptor renderPassDescriptor];
    pass1.colorAttachments[0].texture = x->x_historyArray;
    pass1.colorAttachments[0].slice = x->x_writeIndex;
    pass1.colorAttachments[0].loadAction = MTLLoadActionDontCare;
    pass1.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLRenderCommandEncoder> enc1 = [cmdBuf1 renderCommandEncoderWithDescriptor:pass1];
    [enc1 setRenderPipelineState:x->x_copyPipeline];
    [enc1 setVertexBytes:kFullScreenQuad length:sizeof(kFullScreenQuad) atIndex:0];
    [enc1 setFragmentTexture:inputTex atIndex:0];
    [enc1 setFragmentSamplerState:jet_win_sampler() atIndex:0];
    [enc1 drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
    [enc1 endEncoding];
    [cmdBuf1 commit];
  }

  SlitscanLineParams params = { x->x_maxDelay, x->x_writeIndex, x->x_reverse, 0 };
  id<MTLCommandBuffer> cmdBuf2 = [queue commandBuffer];
  MTLRenderPassDescriptor *pass2 = [MTLRenderPassDescriptor renderPassDescriptor];
  pass2.colorAttachments[0].texture = x->x_outputTex;
  pass2.colorAttachments[0].loadAction = MTLLoadActionDontCare;
  pass2.colorAttachments[0].storeAction = MTLStoreActionStore;
  id<MTLRenderCommandEncoder> enc2 = [cmdBuf2 renderCommandEncoderWithDescriptor:pass2];
  [enc2 setRenderPipelineState:x->x_readPipeline];
  [enc2 setVertexBytes:kFullScreenQuad length:sizeof(kFullScreenQuad) atIndex:0];
  [enc2 setFragmentTexture:x->x_historyArray atIndex:0];
  [enc2 setFragmentSamplerState:jet_win_sampler() atIndex:0];
  [enc2 setFragmentBytes:&params length:sizeof(params) atIndex:0];
  [enc2 drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
  [enc2 endEncoding];
  [cmdBuf2 commit];
  // deliberately NOT waiting - same-queue commit order guarantees
  // pass2 sees pass1's write and jet_win's later on-screen pass
  // sees this texture, see jet_perlin.mm's comment for why

  jet_win_set_current_texture(x->x_outputTex);

  if(!x->x_freeze) {
    x->x_writeIndex = (x->x_writeIndex + 1) % x->x_maxDelay;
  }

  outlet_bang(x->x_outlet);
}

static void jet_slitscan_line_delay(t_jet_slitscan_line *x, t_floatarg f)
{
  int d = (int)f;
  if(d < 1) {
    d = 1;
  }
  x->x_maxDelay = d;
  x->x_historyArray = nil;
  x->x_outputTex = nil;  // force ensureBuffers() to reallocate + reclear
}

static void jet_slitscan_line_reverse(t_jet_slitscan_line *x, t_floatarg f)
{
  x->x_reverse = (f != 0.f);
}

static void jet_slitscan_line_freeze(t_jet_slitscan_line *x, t_floatarg f)
{
  x->x_freeze = (f != 0.f);
}

static void *jet_slitscan_line_new(t_symbol *s, int argc, t_atom *argv)
{
  t_jet_slitscan_line *x = (t_jet_slitscan_line *)pd_new(jet_slitscan_line_class);
  (void)s;

  x->x_outlet = outlet_new(&x->x_obj, &s_bang);
  x->x_maxDelay = (argc >= 1) ? (int)atom_getfloatarg(0, argc, argv) : 30;
  if(x->x_maxDelay < 1) {
    x->x_maxDelay = 1;
  }
  x->x_reverse = 0;
  x->x_freeze = 0;
  x->x_writeIndex = 0;
  x->x_bufW = 0;
  x->x_bufH = 0;
  x->x_warnedNoInput = 0;
  x->x_copyPipeline = nil;
  x->x_readPipeline = nil;
  x->x_historyArray = nil;
  x->x_outputTex = nil;

  return (void *)x;
}

extern "C" void jet_slitscan_line_setup(void)
{
  jet_slitscan_line_class = class_new(gensym("jet_slitscan_line"),
                                        (t_newmethod)jet_slitscan_line_new, 0,
                                        sizeof(t_jet_slitscan_line), CLASS_DEFAULT,
                                        A_GIMME, 0);
  class_addbang(jet_slitscan_line_class, jet_slitscan_line_bang);
  class_addmethod(jet_slitscan_line_class, (t_method)jet_slitscan_line_delay,
                  gensym("delay"), A_FLOAT, 0);
  class_addmethod(jet_slitscan_line_class, (t_method)jet_slitscan_line_reverse,
                  gensym("reverse"), A_FLOAT, 0);
  class_addmethod(jet_slitscan_line_class, (t_method)jet_slitscan_line_freeze,
                  gensym("freeze"), A_FLOAT, 0);
}
