/* ------------------------------------------------------------------
 * jet_slitscan - GPU port of pix_slitscan: reads each PIXEL from a
 * per-pixel-delayed point in a short history of recent frames, the
 * delay picked by the red channel of a second "delay map" texture
 * (0=now, 255=maximum delay) - an organic, animated result if the
 * delay map is something like jet_perlin, or a classic scanline
 * slit-scan look with a gradient/ramp texture.
 *
 * Same texture2d_array ring buffer as jet_slitscan_line.mm (see
 * its header comment for why); the difference is entirely in the
 * read shader, which samples a SECOND texture (the delay map) to
 * pick each pixel's own array slice, instead of computing it from
 * row position alone.
 *
 * This is the first jet_* object with a genuine SECOND texture
 * input, mirroring Gem's own "gem_right" convention for dual-image
 * pix_* objects (see GemPixDualObj): inlet 0 is the normal chain -
 * bangs decode/composite as usual, reading "current texture" as the
 * live input. Inlet 1 is fed by a SEPARATE chain (its own jet_head,
 * at a lower priority number so it runs first - see the help patch)
 * that produces the delay map; banging inlet 1 just captures whatever
 * "current texture" is AT THAT MOMENT into this object's own
 * x_delayMapTex, the same way GemPixDualObj's gem_right grabs the
 * right-hand chain's image. Capturing an id<MTLTexture> reference
 * this way is safe because everything here runs synchronously on one
 * thread (jet_win_tick) within a single frame - no different from
 * how "current texture" itself is handed off between chain objects.
 * ------------------------------------------------------------------
 */

#import <Metal/Metal.h>

#include "m_pd.h"
#include "jet_shared.h"

static t_class *jet_slitscan_class;

typedef struct { float pos[2]; float uv[2]; } QuadVertex;

// must match the MSL SlitscanParams struct field-for-field
typedef struct {
  int maxDelay;
  int writeIndex;
  int _pad0, _pad1;
} SlitscanParams;

typedef struct _jet_slitscan {
  t_object  x_obj;
  t_inlet  *x_delayMapInlet;
  t_outlet *x_outlet;
  int       x_maxDelay;
  int       x_freeze;
  int       x_writeIndex;
  int       x_bufW, x_bufH;
  int       x_warnedNoInput;
  int       x_warnedNoDelayMap;
  id<MTLTexture> x_delayMapTex;  // captured from "current texture" when inlet 1 bangs
  id<MTLRenderPipelineState> x_copyPipeline;  // writes input -> history[slice]
  id<MTLRenderPipelineState> x_readPipeline;  // composites history -> output, using delay map
  id<MTLTexture> x_historyArray;
  id<MTLTexture> x_outputTex;
} t_jet_slitscan;

static NSString *const kSlitscanShaderSrc = @""
  "#include <metal_stdlib>\n"
  "using namespace metal;\n"
  "struct QuadVertex { float2 pos; float2 uv; };\n"
  "struct VOut { float4 position [[position]]; float2 uv; };\n"
  "struct SlitscanParams { int maxDelay; int writeIndex; int _pad0; int _pad1; };\n"
  "vertex VOut slitscanVertexMain(uint vid [[vertex_id]],\n"
  "    constant QuadVertex *verts [[buffer(0)]]) {\n"
  "  VOut out;\n"
  "  out.position = float4(verts[vid].pos, 0.0, 1.0);\n"
  "  out.uv = verts[vid].uv;\n"
  "  return out;\n"
  "}\n"
  "fragment float4 slitscanCopyFragmentMain(VOut in [[stage_in]],\n"
  "    texture2d<float> currentTex [[texture(0)]], sampler s [[sampler(0)]]) {\n"
  "  return currentTex.sample(s, in.uv);\n"
  "}\n"
  "fragment float4 slitscanReadFragmentMain(VOut in [[stage_in]],\n"
  "    texture2d_array<float> history [[texture(0)]],\n"
  "    texture2d<float> delayMap [[texture(1)]],\n"
  "    sampler s [[sampler(0)]],\n"
  "    constant SlitscanParams &params [[buffer(0)]]) {\n"
  "  float db = delayMap.sample(s, in.uv).r;\n"
  "  int delay = int(db * float(params.maxDelay - 1) + 0.5);\n"
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

static void jet_slitscan_ensurePipelines(t_jet_slitscan *x)
{
  if(x->x_copyPipeline && x->x_readPipeline) {
    return;
  }
  id<MTLDevice> device = jet_win_device();
  if(!device) {
    return;
  }

  NSError *err = nil;
  id<MTLLibrary> lib = [device newLibraryWithSource:kSlitscanShaderSrc options:nil error:&err];
  if(!lib) {
    pd_error(x, "jet_slitscan: shader compile failed: %s",
             [[err localizedDescription] UTF8String]);
    return;
  }

  id<MTLFunction> vfn = [lib newFunctionWithName:@"slitscanVertexMain"];

  MTLRenderPipelineDescriptor *copyDesc = [[MTLRenderPipelineDescriptor alloc] init];
  copyDesc.vertexFunction = vfn;
  copyDesc.fragmentFunction = [lib newFunctionWithName:@"slitscanCopyFragmentMain"];
  copyDesc.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
  x->x_copyPipeline = [device newRenderPipelineStateWithDescriptor:copyDesc error:&err];
  if(!x->x_copyPipeline) {
    pd_error(x, "jet_slitscan: copy pipeline build failed: %s",
             [[err localizedDescription] UTF8String]);
  }

  MTLRenderPipelineDescriptor *readDesc = [[MTLRenderPipelineDescriptor alloc] init];
  readDesc.vertexFunction = vfn;
  readDesc.fragmentFunction = [lib newFunctionWithName:@"slitscanReadFragmentMain"];
  readDesc.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
  x->x_readPipeline = [device newRenderPipelineStateWithDescriptor:readDesc error:&err];
  if(!x->x_readPipeline) {
    pd_error(x, "jet_slitscan: read pipeline build failed: %s",
             [[err localizedDescription] UTF8String]);
  }
}

// see jet_slitscan_line.mm's jet_slitscan_line_clearSlice for why
static void jet_slitscan_clearSlice(id<MTLTexture> array, int slice)
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

static void jet_slitscan_ensureBuffers(t_jet_slitscan *x, int w, int h)
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
    jet_slitscan_clearSlice(x->x_historyArray, i);
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

// inlet 1 ("gem_right"-equivalent): just remembers whatever texture
// is current right now - see the file header comment for why this is
// safe. wired from a separate, lower-priority jet_head branch so it
// runs before the main chain each frame (see the help patch).
static void jet_slitscan_delayMapBang(t_jet_slitscan *x)
{
  id<MTLTexture> tex = jet_win_current_texture();
  if(tex) {
    x->x_delayMapTex = tex;
  }
}

static void jet_slitscan_bang(t_jet_slitscan *x)
{
  if(!jet_win_current_encoder()) {
    return;
  }

  id<MTLTexture> inputTex = jet_win_current_texture();
  if(!inputTex) {
    if(!x->x_warnedNoInput) {
      pd_error(x, "jet_slitscan: no current texture (put a texture-producing "
               "object before this in the chain)");
      x->x_warnedNoInput = 1;
    }
    return;
  }
  x->x_warnedNoInput = 0;

  if(!x->x_delayMapTex) {
    if(!x->x_warnedNoDelayMap) {
      pd_error(x, "jet_slitscan: no delay map yet (bang inlet 1 from a "
               "separate texture-producing chain first)");
      x->x_warnedNoDelayMap = 1;
    }
    return;
  }
  x->x_warnedNoDelayMap = 0;

  jet_slitscan_ensurePipelines(x);
  jet_slitscan_ensureBuffers(x, (int)inputTex.width, (int)inputTex.height);
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

  SlitscanParams params = { x->x_maxDelay, x->x_writeIndex, 0, 0 };
  id<MTLCommandBuffer> cmdBuf2 = [queue commandBuffer];
  MTLRenderPassDescriptor *pass2 = [MTLRenderPassDescriptor renderPassDescriptor];
  pass2.colorAttachments[0].texture = x->x_outputTex;
  pass2.colorAttachments[0].loadAction = MTLLoadActionDontCare;
  pass2.colorAttachments[0].storeAction = MTLStoreActionStore;
  id<MTLRenderCommandEncoder> enc2 = [cmdBuf2 renderCommandEncoderWithDescriptor:pass2];
  [enc2 setRenderPipelineState:x->x_readPipeline];
  [enc2 setVertexBytes:kFullScreenQuad length:sizeof(kFullScreenQuad) atIndex:0];
  [enc2 setFragmentTexture:x->x_historyArray atIndex:0];
  [enc2 setFragmentTexture:x->x_delayMapTex atIndex:1];
  [enc2 setFragmentSamplerState:jet_win_sampler() atIndex:0];
  [enc2 setFragmentBytes:&params length:sizeof(params) atIndex:0];
  [enc2 drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
  [enc2 endEncoding];
  [cmdBuf2 commit];
  // deliberately NOT waiting - same-queue commit order guarantees the
  // later passes/frame see these writes, see jet_perlin.mm's
  // comment for why

  jet_win_set_current_texture(x->x_outputTex);

  if(!x->x_freeze) {
    x->x_writeIndex = (x->x_writeIndex + 1) % x->x_maxDelay;
  }

  outlet_bang(x->x_outlet);
}

static void jet_slitscan_delay(t_jet_slitscan *x, t_floatarg f)
{
  int d = (int)f;
  if(d < 1) {
    d = 1;
  }
  x->x_maxDelay = d;
  x->x_historyArray = nil;
  x->x_outputTex = nil;
}

static void jet_slitscan_freeze(t_jet_slitscan *x, t_floatarg f)
{
  x->x_freeze = (f != 0.f);
}

static void *jet_slitscan_new(t_symbol *s, int argc, t_atom *argv)
{
  t_jet_slitscan *x = (t_jet_slitscan *)pd_new(jet_slitscan_class);
  (void)s;

  // retarget inlet 1's "bang" to our own "delaymapbang" selector, NOT
  // plain "bang" - otherwise it would just re-trigger the main chain
  // handler (class_addbang binds "bang" already, for inlet 0)
  x->x_delayMapInlet = inlet_new(&x->x_obj, &x->x_obj.ob_pd, &s_bang,
                                 gensym("delaymapbang"));
  x->x_outlet = outlet_new(&x->x_obj, &s_bang);
  x->x_maxDelay = (argc >= 1) ? (int)atom_getfloatarg(0, argc, argv) : 30;
  if(x->x_maxDelay < 1) {
    x->x_maxDelay = 1;
  }
  x->x_freeze = 0;
  x->x_writeIndex = 0;
  x->x_bufW = 0;
  x->x_bufH = 0;
  x->x_warnedNoInput = 0;
  x->x_warnedNoDelayMap = 0;
  x->x_delayMapTex = nil;
  x->x_copyPipeline = nil;
  x->x_readPipeline = nil;
  x->x_historyArray = nil;
  x->x_outputTex = nil;

  return (void *)x;
}

extern "C" void jet_slitscan_setup(void)
{
  jet_slitscan_class = class_new(gensym("jet_slitscan"),
                                   (t_newmethod)jet_slitscan_new, 0,
                                   sizeof(t_jet_slitscan), CLASS_DEFAULT,
                                   A_GIMME, 0);
  class_addbang(jet_slitscan_class, jet_slitscan_bang);
  class_addmethod(jet_slitscan_class, (t_method)jet_slitscan_delayMapBang,
                  gensym("delaymapbang"), A_NULL, 0);
  class_addmethod(jet_slitscan_class, (t_method)jet_slitscan_delay,
                  gensym("delay"), A_FLOAT, 0);
  class_addmethod(jet_slitscan_class, (t_method)jet_slitscan_freeze,
                  gensym("freeze"), A_FLOAT, 0);
}
