/* ------------------------------------------------------------------
 * jet_win - a Pd external that opens its own native macOS window
 * (like gemwin) and renders with Metal instead of OpenGL/Gem.
 *
 * Window/context owner only - same split as Gem's gemwin vs gemhead,
 * and for the same reasons: multiple independent chains can render
 * into one window, each with its own on/off and priority ordering,
 * without jet_head needing to know anything about windowing. See
 * jet_head.mm for the chain-entry-point half of this.
 *
 * Every tick, jet_win begins a Metal render pass, then bangs every
 * currently-registered jet_head (in ascending priority order - see
 * jet_win_register_head() in jet_shared.h) so their chains draw
 * into the pass via the other jet_win_* accessors, then
 * ends/presents the pass once all of them (synchronous, depth-first
 * Pd message dispatch) have run to completion.
 *
 * Modeled on how Gem's own gemcocoawindow.mm opens its window (see
 * ../Gem/src/Output/gemcocoawindow.mm): a real NSWindow, and instead
 * of Cocoa's own blocking run loop, pending events are pumped
 * manually via -nextEventMatchingMask: on every tick of a repeating
 * Pd clock - that's what lets a native Cocoa window coexist with
 * Pd's own (Tk/Cocoa-based) event loop in the same process.
 * ------------------------------------------------------------------
 */

#import <Cocoa/Cocoa.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>

#include "m_pd.h"
#include "jet_shared.h"

#include <algorithm>
#include <map>
#include <string>
#include <vector>

static const int kDefaultFps = 60;

@class JetWinView;

// ---------------------------------------------------------------
// the Pd object type - moved up front so the cross-bundle accessor
// functions below (see jet_shared.h) can each address a specific
// window's own state. Every jet_win now owns its own head list,
// current-texture, current-pixels and transform - these used to be
// single process-wide globals, which is exactly why two jet_wins
// used to render identical content: one shared scene, whichever
// window last touched it.
// ---------------------------------------------------------------

struct HeadEntry { int priority; t_outlet *outlet; };

static t_class *jet_win_class;

typedef struct _jet_win {
  t_object   x_obj;
  t_clock   *x_clock;
  t_outlet  *x_fpsOutlet;
  NSWindow  *x_window;
  JetWinView *x_view;
  id         x_escMonitor;  // local NSEvent monitor for ESC-exits-fullscreen
  int        x_open;
  int        x_rendering;  // render on/off via a float, see jet_win_float

  // identity so jet_head can target this specific window (see
  // jet_win_register_head below) - both default to "default", so
  // a single unnamed window/head pair needs no naming at all.
  t_symbol   *x_name;

  // gemwin-style configurable state - stored so "dimen"/"offset"/
  // etc. work whether sent before or after "create". x_title is a
  // pointer (heap-allocated in jet_win_new, freed in
  // jet_win_free): pd_new() only allocates raw memory, it never
  // runs a std::string's constructor for an embedded member.
  std::string *x_title;
  int         x_dimenW, x_dimenH;
  int         x_offsetX, x_offsetY;
  int         x_border;
  int         x_fullscreen;

  int         x_profiling;
  float       x_fps;
  double      x_lastFrameSysTime;

  // target render interval, like Gem's [gemwin <fps>] creation arg:
  // 0 means "as fast as possible" (reschedule with 0ms delay)
  double      x_tickMs;

  // this window's own render-chain state (see jet_shared.h) -
  // registered jet_head chains, kept sorted by ascending priority,
  // plus the CPU/GPU "current" slots and 2D transform they draw with
  std::vector<HeadEntry> x_heads;
  id<MTLTexture> x_currentTexture;
  std::vector<unsigned char> x_currentPixels;
  int         x_currentPixelsW, x_currentPixelsH;
  float       x_transform[9];

  // 3D: additive to the 2D state above (see jet_shared.h). model
  // transform works exactly like x_transform (reset to identity per
  // chain, jet_translate3d/rotate3d/scale3d accumulate onto it);
  // view/projection are recomputed once per FRAME (not per chain,
  // see jet_win_tick) from this window's own camera state below.
  float       x_transform3d[16];
  float       x_viewMatrix[16];
  float       x_projMatrix[16];
  float       x_camPos[3];
  float       x_camLookAt[3];
  float       x_fovDeg;
  float       x_nearZ, x_farZ;
  float       x_aspect;  // width/height of the actual drawable, set per frame
  float       x_lightDir[3];
  float       x_lightColor[3];
} t_jet_win;

// ---------------------------------------------------------------
// cross-bundle shared state (see jet_shared.h)
// ---------------------------------------------------------------

// device/queue/pipelines/sampler stay process-wide: on this hardware
// there's a single GPU, so every window's MTLCreateSystemDefaultDevice()
// call returns the same device and sharing compiled pipeline state
// across windows is both valid and cheaper than rebuilding it per
// window. the render encoder is also fine as a single slot: only one
// window is ever mid-frame at a time, since jet_win_tick dispatches
// synchronously on Pd's single main thread.
static id<MTLRenderCommandEncoder>  g_currentEncoder = nil;
static id<MTLRenderPipelineState>   g_flatPipeline = nil;
static id<MTLRenderPipelineState>   g_texturedPipeline = nil;
static id<MTLSamplerState>          g_sampler = nil;
static id<MTLDevice>                g_device = nil;
static id<MTLCommandQueue>          g_queue = nil;
static id<MTLRenderPipelineState>   g_flat3dPipeline = nil;
static id<MTLRenderPipelineState>   g_textured3dPipeline = nil;
static id<MTLDepthStencilState>     g_depthState = nil;
static id<MTLDepthStencilState>     g_noDepthState = nil;

// name -> window registry, so jet_head can bind to a specific
// jet_win at construction time (see jet_win_register_head).
static std::map<t_symbol *, t_jet_win *> g_windowsByName;

// whichever window is currently dispatching its head chain - the
// "get/set current X" accessors below resolve against this, so chain
// objects (jet_triangle, jet_texture, jet_image, ...) stay
// completely window-agnostic. jet_win_tick sets this right before
// banging its own heads and clears it right after.
static t_jet_win *g_activeWindow = nullptr;

id<MTLRenderCommandEncoder> jet_win_current_encoder(void) { return g_currentEncoder; }
id<MTLRenderPipelineState> jet_win_flat_pipeline(void) { return g_flatPipeline; }
id<MTLRenderPipelineState> jet_win_textured_pipeline(void) { return g_texturedPipeline; }
id<MTLSamplerState> jet_win_sampler(void) { return g_sampler; }
id<MTLDevice> jet_win_device(void) { return g_device; }
id<MTLCommandQueue> jet_win_queue(void) { return g_queue; }

void jet_win_set_current_pixels(const unsigned char *rgba, int width, int height)
{
  if(!g_activeWindow) {
    return;
  }
  const size_t n = (size_t)width * height * 4;
  g_activeWindow->x_currentPixels.assign(rgba, rgba + n);
  g_activeWindow->x_currentPixelsW = width;
  g_activeWindow->x_currentPixelsH = height;
}
int jet_win_get_current_pixels(const unsigned char **outRgba, int *outWidth,
                                 int *outHeight)
{
  if(!g_activeWindow || g_activeWindow->x_currentPixels.empty()) {
    return 0;
  }
  *outRgba = g_activeWindow->x_currentPixels.data();
  *outWidth = g_activeWindow->x_currentPixelsW;
  *outHeight = g_activeWindow->x_currentPixelsH;
  return 1;
}

void jet_win_set_current_texture(id<MTLTexture> tex)
{
  if(!g_activeWindow) {
    return;
  }
  g_activeWindow->x_currentTexture = tex;
}
id<MTLTexture> jet_win_current_texture(void)
{
  return g_activeWindow ? g_activeWindow->x_currentTexture : nil;
}

void jet_win_get_transform(float outMat9[9])
{
  if(!g_activeWindow) {
    jet_mat3_identity(outMat9);
    return;
  }
  for(int i = 0; i < 9; i++) {
    outMat9[i] = g_activeWindow->x_transform[i];
  }
}
void jet_win_set_transform(const float mat9[9])
{
  if(!g_activeWindow) {
    return;
  }
  for(int i = 0; i < 9; i++) {
    g_activeWindow->x_transform[i] = mat9[i];
  }
}

float jet_win_get_aspect(void)
{
  return (g_activeWindow && g_activeWindow->x_aspect > 0.f) ? g_activeWindow->x_aspect : 1.f;
}

void jet_win_get_transform3d(float outMat16[16])
{
  if(!g_activeWindow) {
    jet_mat4_identity(outMat16);
    return;
  }
  for(int i = 0; i < 16; i++) {
    outMat16[i] = g_activeWindow->x_transform3d[i];
  }
}
void jet_win_set_transform3d(const float mat16[16])
{
  if(!g_activeWindow) {
    return;
  }
  for(int i = 0; i < 16; i++) {
    g_activeWindow->x_transform3d[i] = mat16[i];
  }
}
void jet_win_get_view(float outMat16[16])
{
  if(!g_activeWindow) {
    jet_mat4_identity(outMat16);
    return;
  }
  for(int i = 0; i < 16; i++) {
    outMat16[i] = g_activeWindow->x_viewMatrix[i];
  }
}
void jet_win_get_projection(float outMat16[16])
{
  if(!g_activeWindow) {
    jet_mat4_identity(outMat16);
    return;
  }
  for(int i = 0; i < 16; i++) {
    outMat16[i] = g_activeWindow->x_projMatrix[i];
  }
}
void jet_win_get_light(float outDir3[3], float outColor3[3])
{
  if(!g_activeWindow) {
    outDir3[0] = 0.f; outDir3[1] = 1.f; outDir3[2] = 0.f;
    outColor3[0] = outColor3[1] = outColor3[2] = 1.f;
    return;
  }
  for(int i = 0; i < 3; i++) {
    outDir3[i] = g_activeWindow->x_lightDir[i];
    outColor3[i] = g_activeWindow->x_lightColor[i];
  }
}

id<MTLRenderPipelineState> jet_win_flat3d_pipeline(void) { return g_flat3dPipeline; }
id<MTLRenderPipelineState> jet_win_textured3d_pipeline(void) { return g_textured3dPipeline; }
id<MTLDepthStencilState> jet_win_depth_state(void) { return g_depthState; }
id<MTLDepthStencilState> jet_win_no_depth_state(void) { return g_noDepthState; }

void jet_win_register_head(t_symbol *windowName, void *x, t_outlet *outlet,
                             int priority)
{
  auto it = g_windowsByName.find(windowName);
  if(it == g_windowsByName.end()) {
    pd_error(x, "jet_head: no jet_win named '%s' (create it above this "
             "jet_head)", windowName->s_name);
    return;
  }
  t_jet_win *win = it->second;
  win->x_heads.push_back({priority, outlet});
  std::stable_sort(win->x_heads.begin(), win->x_heads.end(),
                   [](const HeadEntry &a, const HeadEntry &b) {
    return a.priority < b.priority;
  });
}

void jet_win_unregister_head(t_outlet *outlet)
{
  for(auto &kv : g_windowsByName) {
    t_jet_win *win = kv.second;
    win->x_heads.erase(std::remove_if(win->x_heads.begin(), win->x_heads.end(),
                                      [outlet](const HeadEntry &h) {
      return h.outlet == outlet;
    }), win->x_heads.end());
  }
}

// ---------------------------------------------------------------
// the Metal-backed view
// ---------------------------------------------------------------

@interface JetWinView : NSView
@property(nonatomic, strong) id<MTLDevice> device;
@property(nonatomic, strong) id<MTLCommandQueue> queue;
@property(nonatomic, strong) CAMetalLayer *metalLayer;
@property(nonatomic, strong) id<CAMetalDrawable> currentDrawable;
@property(nonatomic, strong) id<MTLCommandBuffer> currentCmdBuf;
@property(nonatomic, strong) id<MTLTexture> depthTexture;  // 3D depth testing, see ensureDepthTexture
- (void)beginFrame;
- (void)endFrame;
@end

@implementation JetWinView

- (BOOL)wantsUpdateLayer { return YES; }

- (CALayer *)makeBackingLayer
{
  CAMetalLayer *layer = [CAMetalLayer layer];
  self.metalLayer = layer;
  return layer;
}

- (instancetype)initWithFrame:(NSRect)frame
{
  self = [super initWithFrame:frame];
  if(self) {
    self.wantsLayer = YES;
    self.device = MTLCreateSystemDefaultDevice();
    g_device = self.device;
    self.metalLayer.device = self.device;
    self.metalLayer.pixelFormat = MTLPixelFormatBGRA8Unorm;
    self.queue = [self.device newCommandQueue];
    g_queue = self.queue;
    [self setupPipelines];
  }
  return self;
}

- (void)setupPipelines
{
  NSString *src = @""
    "#include <metal_stdlib>\n"
    "using namespace metal;\n"
    // packed_float2/packed_float4, NOT float2/float4, for a struct
    // crossing the CPU->GPU boundary via a raw byte buffer
    // (setVertexBytes) - same bug class as jet_cube's Vertex3D (see
    // its comment further down): plain float4 as a struct field needs
    // 16-byte alignment, but only gets 8 bytes after a plain float2,
    // so the compiler pads 4 bytes in between - the C++-side FlatVertex
    // (jet_triangle.mm/jet_rectangle.mm) is tightly packed at 24
    // bytes/vertex with no such gap, so every vertex after the first
    // read back at the wrong offset. This is the ORIGINAL 2D pipeline,
    // present since the very first jet_triangle test - it just never
    // got caught because every jet_rectangle in this whole project
    // so far happened to go through the (correctly-aligned, no bug)
    // TEXTURED path instead of this flat-color one.
    "struct VertexData { packed_float2 pos; packed_float4 color; };\n"
    "struct VertexOut { float4 position [[position]]; float4 color; };\n"
    "vertex VertexOut vertexMain(uint vid [[vertex_id]],\n"
    "    constant VertexData *verts [[buffer(0)]]) {\n"
    "  VertexOut out;\n"
    "  out.position = float4(verts[vid].pos, 0.0, 1.0);\n"
    "  out.color = verts[vid].color;\n"
    "  return out;\n"
    "}\n"
    "fragment float4 fragmentMain(VertexOut in [[stage_in]]) {\n"
    "  return in.color;\n"
    "}\n"
    // packed_float2 here too, purely for consistency/robustness - its
    // alignment (8) already happened to match a tightly-packed float2
    // pos followed by float2 uv (both 8-byte quantities), so this
    // particular struct was never actually broken, unlike VertexData
    // above.
    "struct TexVertexData { packed_float2 pos; float2 uv; };\n"
    "struct TexVertexOut { float4 position [[position]]; float2 uv; };\n"
    "vertex TexVertexOut texVertexMain(uint vid [[vertex_id]],\n"
    "    constant TexVertexData *verts [[buffer(0)]]) {\n"
    "  TexVertexOut out;\n"
    "  out.position = float4(verts[vid].pos, 0.0, 1.0);\n"
    "  out.uv = verts[vid].uv;\n"
    "  return out;\n"
    "}\n"
    "fragment float4 texFragmentMain(TexVertexOut in [[stage_in]],\n"
    "    texture2d<float> tex [[texture(0)]], sampler s [[sampler(0)]]) {\n"
    "  return tex.sample(s, in.uv);\n"
    "}\n"
    // --- 3D: additive, see jet_shared.h's comment on the 3D
    // accessors for the overall design. Uniforms3D's layout must
    // match the C++-side Uniforms3D struct byte-for-byte - lightDir/
    // lightColor are float4 (not float3) specifically so there's no
    // float3-padding-rule question to get right on either side at
    // all: float4 is unambiguously 16 bytes, 16-byte aligned, in both
    // MSL and a plain C++ float[4]. w is unused (xyz only).
    "struct Uniforms3D {\n"
    "  float4x4 model; float4x4 view; float4x4 projection;\n"
    "  float4 lightDir;\n"
    "  float4 lightColor;\n"
    "};\n"
    // packed_float3, NOT float3, for a struct crossing the CPU->GPU
    // boundary via a raw byte buffer (setVertexBytes): plain float3
    // as a STRUCT FIELD has 16-byte alignment in MSL, so the compiler
    // silently pads 4 bytes after each one - pos/normal/color would
    // read back as 48 bytes/vertex here despite the C++-side
    // Vertex3D being a tightly-packed 36 bytes, so every vertex after
    // the first would be read from the wrong offset entirely (this
    // was the cause of the "wild glitch" cube - VOut3D below is
    // unaffected since it's GPU-internal only, never uploaded raw).
    "struct Vertex3D { packed_float3 pos; packed_float3 normal; packed_float3 color; };\n"
    "struct VOut3D { float4 position [[position]]; float3 normal; float3 color; };\n"
    "vertex VOut3D vertex3DFlatMain(uint vid [[vertex_id]],\n"
    "    constant Vertex3D *verts [[buffer(0)]],\n"
    "    constant Uniforms3D &u [[buffer(1)]]) {\n"
    "  VOut3D out;\n"
    "  float4 worldPos = u.model * float4(verts[vid].pos, 1.0);\n"
    "  out.position = u.projection * u.view * worldPos;\n"
    "  out.normal = (u.model * float4(verts[vid].normal, 0.0)).xyz;\n"
    "  out.color = verts[vid].color;\n"
    "  return out;\n"
    "}\n"
    "fragment float4 fragment3DFlatMain(VOut3D in [[stage_in]],\n"
    "    constant Uniforms3D &u [[buffer(1)]]) {\n"
    "  float3 n = normalize(in.normal);\n"
    "  float ndotl = max(dot(n, normalize(u.lightDir.xyz)), 0.0);\n"
    "  float3 lit = in.color * (0.15 + ndotl * u.lightColor.xyz);\n"
    "  return float4(lit, 1.0);\n"
    "}\n"
    // packed_float3 here too - see Vertex3D's comment above
    "struct Vertex3DTex { packed_float3 pos; packed_float3 normal; float2 uv; };\n"
    "struct VOut3DTex { float4 position [[position]]; float3 normal; float2 uv; };\n"
    "vertex VOut3DTex vertex3DTexMain(uint vid [[vertex_id]],\n"
    "    constant Vertex3DTex *verts [[buffer(0)]],\n"
    "    constant Uniforms3D &u [[buffer(1)]]) {\n"
    "  VOut3DTex out;\n"
    "  float4 worldPos = u.model * float4(verts[vid].pos, 1.0);\n"
    "  out.position = u.projection * u.view * worldPos;\n"
    "  out.normal = (u.model * float4(verts[vid].normal, 0.0)).xyz;\n"
    "  out.uv = verts[vid].uv;\n"
    "  return out;\n"
    "}\n"
    "fragment float4 fragment3DTexMain(VOut3DTex in [[stage_in]],\n"
    "    texture2d<float> tex [[texture(0)]], sampler s [[sampler(0)]],\n"
    "    constant Uniforms3D &u [[buffer(1)]]) {\n"
    "  float3 n = normalize(in.normal);\n"
    "  float ndotl = max(dot(n, normalize(u.lightDir.xyz)), 0.0);\n"
    "  float4 albedo = tex.sample(s, in.uv);\n"
    "  float3 lit = albedo.rgb * (0.15 + ndotl * u.lightColor.xyz);\n"
    "  return float4(lit, albedo.a);\n"
    "}\n";

  NSError *err = nil;
  id<MTLLibrary> lib = [self.device newLibraryWithSource:src options:nil error:&err];
  if(!lib) {
    post("jet_win: shader compile failed: %s", [[err localizedDescription] UTF8String]);
    return;
  }

  MTLRenderPipelineDescriptor *flatDesc = [[MTLRenderPipelineDescriptor alloc] init];
  flatDesc.vertexFunction = [lib newFunctionWithName:@"vertexMain"];
  flatDesc.fragmentFunction = [lib newFunctionWithName:@"fragmentMain"];
  flatDesc.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
  g_flatPipeline = [self.device newRenderPipelineStateWithDescriptor:flatDesc error:&err];
  if(!g_flatPipeline) {
    post("jet_win: flat pipeline build failed: %s", [[err localizedDescription] UTF8String]);
  }

  MTLRenderPipelineDescriptor *texDesc = [[MTLRenderPipelineDescriptor alloc] init];
  texDesc.vertexFunction = [lib newFunctionWithName:@"texVertexMain"];
  texDesc.fragmentFunction = [lib newFunctionWithName:@"texFragmentMain"];
  texDesc.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
  g_texturedPipeline = [self.device newRenderPipelineStateWithDescriptor:texDesc error:&err];
  if(!g_texturedPipeline) {
    post("jet_win: textured pipeline build failed: %s", [[err localizedDescription] UTF8String]);
  }

  MTLSamplerDescriptor *sampDesc = [[MTLSamplerDescriptor alloc] init];
  sampDesc.minFilter = MTLSamplerMinMagFilterLinear;
  sampDesc.magFilter = MTLSamplerMinMagFilterLinear;
  sampDesc.sAddressMode = MTLSamplerAddressModeClampToEdge;
  sampDesc.tAddressMode = MTLSamplerAddressModeClampToEdge;
  g_sampler = [self.device newSamplerStateWithDescriptor:sampDesc];

  // 3D: depth-tested pipelines, otherwise built the same way as the
  // two 2D ones above - see jet_shared.h for why 2D stays untouched
  MTLRenderPipelineDescriptor *flat3dDesc = [[MTLRenderPipelineDescriptor alloc] init];
  flat3dDesc.vertexFunction = [lib newFunctionWithName:@"vertex3DFlatMain"];
  flat3dDesc.fragmentFunction = [lib newFunctionWithName:@"fragment3DFlatMain"];
  flat3dDesc.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
  flat3dDesc.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;
  g_flat3dPipeline = [self.device newRenderPipelineStateWithDescriptor:flat3dDesc error:&err];
  if(!g_flat3dPipeline) {
    post("jet_win: flat3d pipeline build failed: %s", [[err localizedDescription] UTF8String]);
  }

  MTLRenderPipelineDescriptor *tex3dDesc = [[MTLRenderPipelineDescriptor alloc] init];
  tex3dDesc.vertexFunction = [lib newFunctionWithName:@"vertex3DTexMain"];
  tex3dDesc.fragmentFunction = [lib newFunctionWithName:@"fragment3DTexMain"];
  tex3dDesc.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
  tex3dDesc.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;
  g_textured3dPipeline = [self.device newRenderPipelineStateWithDescriptor:tex3dDesc error:&err];
  if(!g_textured3dPipeline) {
    post("jet_win: textured3d pipeline build failed: %s", [[err localizedDescription] UTF8String]);
  }

  MTLDepthStencilDescriptor *depthDesc = [[MTLDepthStencilDescriptor alloc] init];
  depthDesc.depthCompareFunction = MTLCompareFunctionLess;
  depthDesc.depthWriteEnabled = YES;
  g_depthState = [self.device newDepthStencilStateWithDescriptor:depthDesc];

  MTLDepthStencilDescriptor *noDepthDesc = [[MTLDepthStencilDescriptor alloc] init];
  noDepthDesc.depthCompareFunction = MTLCompareFunctionAlways;
  noDepthDesc.depthWriteEnabled = NO;
  g_noDepthState = [self.device newDepthStencilStateWithDescriptor:noDepthDesc];
}

// (re)creates the depth buffer to match the drawable's current size -
// called from beginFrame, so it stays in sync with resizes without
// needing its own hook into setFrameSize:
- (void)ensureDepthTexture
{
  const NSSize size = self.metalLayer.drawableSize;
  const int w = (int)size.width, h = (int)size.height;
  if(w < 1 || h < 1) {
    return;
  }
  if(self.depthTexture && (int)self.depthTexture.width == w &&
     (int)self.depthTexture.height == h) {
    return;
  }
  MTLTextureDescriptor *desc =
    [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float
                                                        width:w height:h mipmapped:NO];
  desc.usage = MTLTextureUsageRenderTarget;
  desc.storageMode = MTLStorageModePrivate;
  self.depthTexture = [self.device newTextureWithDescriptor:desc];
}

- (void)setFrameSize:(NSSize)newSize
{
  [super setFrameSize:newSize];
  self.metalLayer.drawableSize = CGSizeMake(newSize.width, newSize.height);
}

// must accept first responder to receive key events at all (NSView's
// default is NO)
- (BOOL)acceptsFirstResponder { return YES; }

// ESC exits native fullscreen - not a stock macOS behavior for
// -toggleFullScreen:, so we bind it ourselves. while fullscreen,
// jet_win's window is the only reachable one (its own Space), so
// this is the quickest way back to the Pd patch.
- (void)keyDown:(NSEvent *)event
{
  static const unsigned short kEscKeyCode = 53;
  const BOOL isFullscreen =
    (self.window.styleMask & NSWindowStyleMaskFullScreen) != 0;
  if(event.keyCode == kEscKeyCode && isFullscreen) {
    [self.window toggleFullScreen:nil];
    return;
  }
  [super keyDown:event];
}

- (void)beginFrame
{
  if(!g_flatPipeline) {
    return;
  }
  self.currentDrawable = [self.metalLayer nextDrawable];
  if(!self.currentDrawable) {
    return;
  }

  MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
  pass.colorAttachments[0].texture = self.currentDrawable.texture;
  pass.colorAttachments[0].loadAction = MTLLoadActionClear;
  pass.colorAttachments[0].clearColor = MTLClearColorMake(0.07, 0.07, 0.10, 1.0);
  pass.colorAttachments[0].storeAction = MTLStoreActionStore;

  // 3D: shared by every jet_head this frame - the same window-wide
  // "one on-screen pass for the whole frame" the 2D pipeline already
  // uses (see the file header comment). 2D shape draws simply never
  // set a depth-stencil state, so they're unaffected by this being
  // present.
  [self ensureDepthTexture];
  if(self.depthTexture) {
    pass.depthAttachment.texture = self.depthTexture;
    pass.depthAttachment.loadAction = MTLLoadActionClear;
    pass.depthAttachment.clearDepth = 1.0;
    pass.depthAttachment.storeAction = MTLStoreActionDontCare;
  }

  self.currentCmdBuf = [self.queue commandBuffer];
  g_currentEncoder = [self.currentCmdBuf renderCommandEncoderWithDescriptor:pass];
}

- (void)endFrame
{
  if(!g_currentEncoder) {
    return;
  }
  [g_currentEncoder endEncoding];
  [self.currentCmdBuf presentDrawable:self.currentDrawable];
  [self.currentCmdBuf commit];

  g_currentEncoder = nil;
  // NOTE: the owning window's x_currentTexture is cleared by
  // jet_win_tick right after this call, not here - this view has
  // no reference back to its t_jet_win.
  self.currentCmdBuf = nil;
  self.currentDrawable = nil;
}

@end

// ---------------------------------------------------------------
// the Pd object (t_jet_win itself is declared further up, next to
// the cross-bundle accessor functions that need its full definition)
// ---------------------------------------------------------------

static NSUInteger jet_win_styleMask(const t_jet_win *x)
{
  if(!x->x_border) {
    return NSWindowStyleMaskBorderless | NSWindowStyleMaskResizable;
  }
  return NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
        NSWindowStyleMaskResizable | NSWindowStyleMaskMiniaturizable;
}

static void jet_win_tick(t_jet_win *x);

static void jet_win_create(t_jet_win *x)
{
  if(x->x_open) {
    post("jet_win: already open");
    return;
  }

  [NSApplication sharedApplication];

  const NSRect frame = NSMakeRect(x->x_offsetX, x->x_offsetY, x->x_dimenW, x->x_dimenH);
  NSWindow *win = [[NSWindow alloc] initWithContentRect:frame
                                              styleMask:jet_win_styleMask(x)
                                                backing:NSBackingStoreBuffered
                                                  defer:NO];
  [win setTitle:[NSString stringWithUTF8String:x->x_title->c_str()]];
  [win setReleasedWhenClosed:NO];
  // a plain programmatically-created NSWindow doesn't get native
  // fullscreen support for free - only windows that come from the
  // standard app-lifecycle/NIB setup do. without this,
  // -toggleFullScreen: silently does nothing.
  win.collectionBehavior = NSWindowCollectionBehaviorFullScreenPrimary;

  JetWinView *view = [[JetWinView alloc] initWithFrame:frame];
  [win setContentView:view];
  [win makeKeyAndOrderFront:nil];
  [win makeFirstResponder:view];  // so keyDown: (ESC-exits-fullscreen) reaches it
  [NSApp activateIgnoringOtherApps:YES];

  // belt-and-suspenders ESC handling: keyDown: above depends on this
  // view staying first responder, which native fullscreen's
  // transition doesn't reliably preserve. a local event monitor
  // intercepts key events at the app level before normal dispatch,
  // regardless of focus/responder-chain state.
  x->x_escMonitor = [NSEvent
    addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown
    handler:^NSEvent *(NSEvent *event) {
    static const unsigned short kEscKeyCode = 53;
    if(event.window == win && event.keyCode == kEscKeyCode &&
       (win.styleMask & NSWindowStyleMaskFullScreen)) {
      [win toggleFullScreen:nil];
      return nil;  // consume it, don't let it propagate further
    }
    return event;
  }];

  x->x_window = win;
  x->x_view = view;
  x->x_open = 1;
  x->x_lastFrameSysTime = clock_getlogicaltime();

  post("jet_win: window created");
  clock_delay(x->x_clock, x->x_tickMs);
}

static void jet_win_destroy(t_jet_win *x)
{
  if(!x->x_open) {
    return;
  }
  [x->x_window close];

  // we drive AppKit's event loop ourselves (see jet_win_tick) -
  // -close only marks the window closed internally, the screen isn't
  // actually redrawn to reflect that until events get pumped again.
  // pump once more here, with the window still alive, before we stop
  // ticking for good below - otherwise the (now invisible-to-Cocoa
  // but not yet erased on screen) window just sits there looking
  // like it never closed.
  NSEvent *e;
  while((e = [NSApp nextEventMatchingMask:NSEventMaskAny
                                 untilDate:[NSDate distantPast]
                                    inMode:NSDefaultRunLoopMode
                                   dequeue:YES])) {
    [NSApp sendEvent:e];
  }

  clock_unset(x->x_clock);
  if(x->x_escMonitor) {
    [NSEvent removeMonitor:x->x_escMonitor];
    x->x_escMonitor = nil;
  }
  [x->x_window release];
  [x->x_view release];
  x->x_window = nil;
  x->x_view = nil;
  x->x_open = 0;
  post("jet_win: window destroyed");
}

// ---------------------------------------------------------------
// gemwin-style configuration messages
// ---------------------------------------------------------------

static void jet_win_dimen(t_jet_win *x, t_floatarg w, t_floatarg h)
{
  x->x_dimenW = (w < 1) ? 1 : (int)w;
  x->x_dimenH = (h < 1) ? 1 : (int)h;
  if(x->x_open) {
    [x->x_window setContentSize:NSMakeSize(x->x_dimenW, x->x_dimenH)];
  }
}

static void jet_win_offset(t_jet_win *x, t_floatarg ox, t_floatarg oy)
{
  x->x_offsetX = (int)ox;
  x->x_offsetY = (int)oy;
  if(x->x_open) {
    // match Gem/Pd's screen-space convention (origin top-left, y
    // down) rather than Cocoa's native bottom-left/y-up
    NSScreen *screen = [NSScreen mainScreen];
    const CGFloat screenH = screen ? screen.frame.size.height : 0;
    [x->x_window setFrameTopLeftPoint:NSMakePoint(x->x_offsetX, screenH - x->x_offsetY)];
  }
}

static void jet_win_title(t_jet_win *x, t_symbol *s)
{
  *x->x_title = s->s_name;
  if(x->x_open) {
    [x->x_window setTitle:[NSString stringWithUTF8String:x->x_title->c_str()]];
  }
}

static void jet_win_border(t_jet_win *x, t_floatarg f)
{
  x->x_border = (f != 0.f);
  if(x->x_open) {
    x->x_window.styleMask = jet_win_styleMask(x);
  }
}

static void jet_win_cursor(t_jet_win *x, t_floatarg f)
{
  (void)x;
  if(f != 0.f) {
    [NSCursor unhide];
  } else {
    [NSCursor hide];
  }
}

static void jet_win_fullscreen(t_jet_win *x, t_floatarg f)
{
  const int want = (f != 0.f);
  if(want == x->x_fullscreen) {
    return;
  }
  x->x_fullscreen = want;
  if(x->x_open) {
    [x->x_window toggleFullScreen:nil];
  }
}

static void jet_win_profile(t_jet_win *x, t_floatarg f)
{
  x->x_profiling = (f != 0.f);
  if(!x->x_profiling) {
    x->x_fps = 0.f;
  }
}

// a float to the window turns rendering on (non-zero) or off (0), like
// Gem's gemwin - the window itself stays open either way
static void jet_win_float(t_jet_win *x, t_floatarg f)
{
  x->x_rendering = (f != 0.f);
}

static void jet_win_fpsMess(t_jet_win *x)
{
  outlet_float(x->x_fpsOutlet, x->x_fps);
}

// ---------------------------------------------------------------
// 3D camera/light messages - see jet_shared.h's comment on the 3D
// accessors. Unlike dimen/offset/etc above these have no "before
// create" special case to worry about: view/projection are recomputed
// fresh every tick in jet_win_tick from whatever this state
// currently is, so there's nothing to (re)apply on create.
// ---------------------------------------------------------------

static void jet_win_camera(t_jet_win *x, t_floatarg cx, t_floatarg cy, t_floatarg cz)
{
  x->x_camPos[0] = cx;
  x->x_camPos[1] = cy;
  x->x_camPos[2] = cz;
}

static void jet_win_lookat(t_jet_win *x, t_floatarg lx, t_floatarg ly, t_floatarg lz)
{
  x->x_camLookAt[0] = lx;
  x->x_camLookAt[1] = ly;
  x->x_camLookAt[2] = lz;
}

static void jet_win_fov(t_jet_win *x, t_floatarg f)
{
  if(f < 1.f) {
    f = 1.f;
  } else if(f > 179.f) {
    f = 179.f;
  }
  x->x_fovDeg = f;
}

static void jet_win_light(t_jet_win *x, t_floatarg dx, t_floatarg dy, t_floatarg dz)
{
  x->x_lightDir[0] = dx;
  x->x_lightDir[1] = dy;
  x->x_lightDir[2] = dz;
}

static void jet_win_lightcolor(t_jet_win *x, t_floatarg r, t_floatarg g, t_floatarg b)
{
  x->x_lightColor[0] = r;
  x->x_lightColor[1] = g;
  x->x_lightColor[2] = b;
}

// resets every piece of CHAIN-scoped state (see jet_shared.h's note on
// state scopes) right before one jet_head's chain runs. Draw objects
// still set the encoder state they need explicitly - this is the
// backstop for state they don't know about, so a stale value from an
// earlier chain can never silently decide how a later one looks.
static void jet_win_beginChain(t_jet_win *x)
{
  float identity2d[9];
  jet_mat3_identity(identity2d);
  for(int i = 0; i < 9; i++) {
    x->x_transform[i] = identity2d[i];
  }
  jet_mat4_identity(x->x_transform3d);

  // a texture one chain bound (or rendered) isn't this chain's input
  x->x_currentTexture = nil;

  // encoder state: back to the 2D default (no depth test, no depth
  // write); 3D shapes switch it on for themselves when they draw
  if(g_currentEncoder && g_noDepthState) {
    [g_currentEncoder setDepthStencilState:g_noDepthState];
  }
}

static void jet_win_tick(t_jet_win *x)
{
  if(!x->x_open) {
    return;
  }

  // this whole tick runs from a Pd clock callback, not from AppKit's
  // own main run loop - so none of the usual per-iteration autorelease
  // pool draining that a normal Cocoa app gets for free happens here
  // on its own. every temporary Objective-C object created below
  // (NSError/NSString conversions, NSDictionary literals passed to
  // AVFoundation, AVFoundation's own internal temporaries during
  // decode - jet_movie's nextFrameRGBA chain in particular) would
  // otherwise just accumulate for the lifetime of the process. this
  // is almost certainly what crashed a synced video+audio patch after
  // a while: the audio-sync catch-up path can call into AVFoundation
  // several times per tick, generating garbage much faster than plain
  // solo video playback does.
  @autoreleasepool {

  NSEvent *e;
  while((e = [NSApp nextEventMatchingMask:NSEventMaskAny
                                 untilDate:[NSDate distantPast]
                                    inMode:NSDefaultRunLoopMode
                                   dequeue:YES])) {
    [NSApp sendEvent:e];
  }

  // render on/off (a float to the window, like Gem's gemwin): while
  // off, the window stays open and keeps pumping events (so it stays
  // responsive - resize, border, ...) but no frame is drawn and the
  // heads aren't banged
  if(x->x_rendering) {

  double frameStart = 0.0;
  if(x->x_profiling) {
    frameStart = clock_getlogicaltime();
  }

  g_activeWindow = x;

  // 3D: view/projection are camera properties, not per-chain, so
  // they're computed once here per FRAME (not inside the per-head
  // loop below, unlike the 2D/3D model transform) from this window's
  // own camera state - see the "camera"/"lookat"/"fov" messages.
  // aspect from the actual drawable, not the last "dimen" message -
  // the user can drag-resize the window, and a stale ratio stretches
  // every 3D and 2D shape
  const CGSize drawable = x->x_view.metalLayer.drawableSize;
  if(drawable.width >= 1.0 && drawable.height >= 1.0) {
    x->x_aspect = (float)(drawable.width / drawable.height);
  }
  const float aspect = x->x_aspect;
  jet_mat4_lookAt(x->x_camPos[0], x->x_camPos[1], x->x_camPos[2],
                    x->x_camLookAt[0], x->x_camLookAt[1], x->x_camLookAt[2],
                    x->x_viewMatrix);
  jet_mat4_perspective(x->x_fovDeg * (float)M_PI / 180.f, aspect,
                         x->x_nearZ, x->x_farZ, x->x_projMatrix);

  [x->x_view beginFrame];
  // dispatch to every jet_head registered to THIS window, in
  // priority order - each one's chain draws into the frame we just
  // began. every chain starts from a clean slate (jet_win_beginChain),
  // so nothing one chain does to chain-scoped state can leak into the
  // next - same idea as Gem pushing/popping the modelview matrix per
  // gemhead branch, extended to everything chain-scoped.
  for(const HeadEntry &h : x->x_heads) {
    jet_win_beginChain(x);
    outlet_bang(h.outlet);
  }
  [x->x_view endFrame];
  x->x_currentTexture = nil;  // texture binding only lasts one frame
  g_activeWindow = nullptr;

  if(x->x_profiling) {
    const double ms = clock_gettimesince(frameStart);
    if(ms > 0.0) {
      x->x_fps = (float)(1000.0 / ms);
    }
  }

  }  // if(x->x_rendering)

  }  // @autoreleasepool

  clock_delay(x->x_clock, x->x_tickMs);
}

// creation args, like Gem's [gemwin <fps>] plus an optional window
// name (a symbol, in either position/order) for jet_head to target
// - see jet_win_register_head in jet_shared.h. Omitted name
// defaults to "default"; omitted fps defaults to kDefaultFps; 0 means
// "as fast as possible" (0ms reschedule delay); negative is invalid
// (matches GemMan::frameRate's own fallback behavior).
static void *jet_win_new(t_symbol *s, int argc, t_atom *argv)
{
  t_jet_win *x = (t_jet_win *)pd_new(jet_win_class);
  (void)s;
  x->x_clock = clock_new(x, (t_method)jet_win_tick);
  x->x_fpsOutlet = outlet_new(&x->x_obj, &s_float);
  x->x_window = nil;
  x->x_view = nil;
  x->x_escMonitor = nil;
  x->x_open = 0;
  // on by default (unlike Gem, where a freshly created gemwin stays
  // dark until it gets a 1): plain "create" renders right away, and
  // Gem-style "create, 1" works too since 1 just sets it to on again
  x->x_rendering = 1;

  x->x_title = new std::string("jet_win");
  x->x_dimenW = 640;
  x->x_dimenH = 480;
  x->x_offsetX = 100;
  x->x_offsetY = 100;
  x->x_border = 1;
  x->x_fullscreen = 0;
  x->x_profiling = 0;
  x->x_fps = 0.f;
  x->x_lastFrameSysTime = 0.0;

  x->x_currentTexture = nil;
  x->x_currentPixelsW = 0;
  x->x_currentPixelsH = 0;
  jet_mat3_identity(x->x_transform);

  // 3D defaults: Gem's own default view - camera 4 units back on +Z
  // looking at the origin (right-handed, Y-up) with a 90 degree
  // vertical fov, which makes the z=0 plane exactly 8 units tall
  // (2 * 4 * tan(45)). That's the same 8 units the 2D shapes use (see
  // jet_shared.h), so 2D and 3D content share one scale.
  jet_mat4_identity(x->x_transform3d);
  jet_mat4_identity(x->x_viewMatrix);
  jet_mat4_identity(x->x_projMatrix);
  x->x_camPos[0] = 0.f;  x->x_camPos[1] = 0.f;    x->x_camPos[2] = 4.f;
  x->x_camLookAt[0] = 0.f; x->x_camLookAt[1] = 0.f; x->x_camLookAt[2] = 0.f;
  x->x_fovDeg = 90.f;
  x->x_nearZ = 0.1f;
  x->x_aspect = 4.f / 3.f;
  x->x_farZ = 100.f;
  // light direction points FROM a lit surface TOWARD the light - this
  // default comes from up/front/right of the origin
  x->x_lightDir[0] = 0.4f; x->x_lightDir[1] = 0.8f; x->x_lightDir[2] = 0.4f;
  x->x_lightColor[0] = x->x_lightColor[1] = x->x_lightColor[2] = 1.f;

  t_symbol *name = gensym("default");
  float fps = 0.f;
  for(int i = 0; i < argc; i++) {
    if(argv[i].a_type == A_SYMBOL) {
      name = atom_getsymbol(argv + i);
    } else if(argv[i].a_type == A_FLOAT) {
      fps = atom_getfloat(argv + i);
    }
  }

  if(g_windowsByName.count(name)) {
    pd_error(x, "jet_win: a window named '%s' already exists - jet_heads "
             "targeting that name will bind to whichever one was created "
             "last", name->s_name);
  }
  x->x_name = name;
  g_windowsByName[name] = x;

  if(fps < 0.f) {
    pd_error(x, "jet_win: invalid frame rate %f, using %d", fps, kDefaultFps);
    fps = (float)kDefaultFps;
  } else if(fps == 0.f) {
    // no fps arg at all also lands here - treat that as "use the
    // default", not "as fast as possible", so plain [jet_win]
    // behaves sanely out of the box
    fps = (float)kDefaultFps;
  }
  x->x_tickMs = 1000.0 / fps;

  return (void *)x;
}

static void jet_win_free(t_jet_win *x)
{
  jet_win_destroy(x);
  clock_free(x->x_clock);
  delete x->x_title;

  auto it = g_windowsByName.find(x->x_name);
  if(it != g_windowsByName.end() && it->second == x) {
    g_windowsByName.erase(it);
  }
}

extern "C" void jet_win_setup(void)
{
  jet_win_class = class_new(gensym("jet_win"),
                              (t_newmethod)jet_win_new,
                              (t_method)jet_win_free,
                              sizeof(t_jet_win), CLASS_DEFAULT, A_GIMME, 0);
  class_addfloat(jet_win_class, jet_win_float);
  class_addmethod(jet_win_class, (t_method)jet_win_create,
                  gensym("create"), A_NULL);
  class_addmethod(jet_win_class, (t_method)jet_win_destroy,
                  gensym("destroy"), A_NULL);
  class_addmethod(jet_win_class, (t_method)jet_win_dimen,
                  gensym("dimen"), A_FLOAT, A_FLOAT, 0);
  class_addmethod(jet_win_class, (t_method)jet_win_offset,
                  gensym("offset"), A_FLOAT, A_FLOAT, 0);
  class_addmethod(jet_win_class, (t_method)jet_win_title,
                  gensym("title"), A_SYMBOL, 0);
  class_addmethod(jet_win_class, (t_method)jet_win_border,
                  gensym("border"), A_FLOAT, 0);
  class_addmethod(jet_win_class, (t_method)jet_win_cursor,
                  gensym("cursor"), A_FLOAT, 0);
  class_addmethod(jet_win_class, (t_method)jet_win_fullscreen,
                  gensym("fullscreen"), A_FLOAT, 0);
  class_addmethod(jet_win_class, (t_method)jet_win_profile,
                  gensym("profile"), A_FLOAT, 0);
  class_addmethod(jet_win_class, (t_method)jet_win_fpsMess,
                  gensym("fps"), A_NULL);
  class_addmethod(jet_win_class, (t_method)jet_win_camera,
                  gensym("camera"), A_FLOAT, A_FLOAT, A_FLOAT, 0);
  class_addmethod(jet_win_class, (t_method)jet_win_lookat,
                  gensym("lookat"), A_FLOAT, A_FLOAT, A_FLOAT, 0);
  class_addmethod(jet_win_class, (t_method)jet_win_fov,
                  gensym("fov"), A_FLOAT, 0);
  class_addmethod(jet_win_class, (t_method)jet_win_light,
                  gensym("light"), A_FLOAT, A_FLOAT, A_FLOAT, 0);
  class_addmethod(jet_win_class, (t_method)jet_win_lightcolor,
                  gensym("lightcolor"), A_FLOAT, A_FLOAT, A_FLOAT, 0);
}
