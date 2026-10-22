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
 * Every tick, jet_win bangs every currently-registered jet_head (in
 * ascending priority order - see jet_win_register_head() in
 * jet_shared.h). The chains don't draw anything themselves: shapes
 * RECORD draw commands (jet_win_submit_draw) while the heads run
 * (synchronous, depth-first Pd message dispatch), and once all of
 * them have completed the window orders the list, opens ONE on-screen
 * render pass, executes the commands and presents.
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

// one recorded draw (see jet_win_submit_draw). The vertex bytes live in
// the window's per-frame arena (vertexOffset) unless the shape passed
// its own persistent MTLBuffer. Metal objects are NOT retained: a
// command only lives from its bang to the end of the same tick.
enum DepthMode { kDepthOff = 0, kDepthTestWrite = 1, kDepthTestOnly = 2 };
struct RecordedDraw {
  JetPipeline    pipeline;
  DepthMode      depth;
  size_t         vertexOffset, vertexBytes;
  id<MTLBuffer>  vertexBuffer;
  size_t         vertexBufferOffset;
  unsigned int   vertexCount;
  id<MTLTexture> texture;
  JetUniforms3D  uniforms;
  float          sortZ;      // view-space z of the model origin, translucent sorting
  bool           translucent;
};

// a separate recording with its own camera (jet_render); the saved
// chain state is put back when it ends
struct SceneScope {
  std::vector<RecordedDraw>  draws;
  std::vector<unsigned char> arena;
  float view[16], proj[16], lightDir[3], lightColor[3], aspect;
  float savedTransform[16], savedColor[4];
  int   savedDepth;
  id<MTLTexture> savedTexture;
};


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
  void       *x_keyProxy;   // bound to #key, see jet_win_keyproxy_float

  // gemwin-style configurable state - stored so "dimen"/"offset"/
  // etc. work whether sent before or after "create". x_title is a
  // pointer (heap-allocated in jet_win_new, freed in
  // jet_win_free): pd_new() only allocates raw memory, it never
  // runs a std::string's constructor for an embedded member.
  std::string *x_title;
  int         x_dimenW, x_dimenH;
  int         x_offsetX, x_offsetY;
  int         x_border;
  int         x_fullscreen;   // the REQUESTED state ("fullscreen" message); applied whenever a window exists
  int         x_isFs;         // the window currently is in our fullscreen mode
  int         x_display;      // 0 = the display the window is on, N = NSScreen number N (1 = primary)
  int         x_frameDirty;   // dimen/offset arrived while fullscreen: use them when leaving it
  NSRect      x_savedFrame;   // windowed frame to return to

  int         x_profiling;
  float       x_fps;
  double      x_lastFrameSysTime;

  // target render interval, like Gem's [gemwin <fps>] creation arg:
  // 0 means "as fast as possible" (reschedule with 0ms delay)
  double      x_tickMs;

  // this window's own render-chain state (see jet_shared.h) -
  // registered jet_head chains, kept sorted by ascending priority,
  // plus the CPU/GPU "current" slots they draw with
  std::vector<HeadEntry> x_heads;
  id<MTLTexture> x_currentTexture;
  std::vector<unsigned char> x_currentPixels;
  int         x_currentPixelsW, x_currentPixelsH;

  // model transform (reset to identity per chain, jet_translateXYZ/
  // rotateXYZ/scaleXYZ accumulate onto it); x_depth = depth test flag
  // (chain-scoped, jet_depth);
  // view/projection are recomputed once per FRAME (not per chain,
  // see jet_win_tick) from this window's own camera state below.
  float       x_transform3d[16];
  int         x_depth;
  float       x_viewMatrix[16];
  float       x_projMatrix[16];
  float       x_camPos[3];
  float       x_camLookAt[3];
  float       x_fovDeg;
  float       x_nearZ, x_farZ;
  float       x_aspect;  // width/height of the actual drawable, set per frame
  float       x_lightDir[3];
  float       x_lightColor[3];
  float       x_color[4];  // chain-scoped current color, see jet_shared.h

  // this frame's recorded draws and their vertex data, cleared at the
  // start of every frame (see jet_win_tick)
  int         x_frameActive;
  std::vector<RecordedDraw>   x_draws;
  std::vector<unsigned char>  x_arena;
  std::vector<SceneScope *> x_scopes;        // open jet_render scenes, innermost last
  std::vector<id<MTLTexture> > x_framePins;  // pooled textures sampled by this frame's draws

  // named textures (jet_share/jet_use), see jet_shared.h. A pointer
  // because std::map isn't valid when zero-filled like the vectors are;
  // made in jet_win_new. The map retains its textures.
  std::map<t_symbol *, id<MTLTexture>> *x_named;
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
static id<MTLSamplerState>          g_sampler = nil;
static id<MTLDevice>                g_device = nil;
static id<MTLCommandQueue>          g_queue = nil;
static id<MTLRenderPipelineState>   g_flat3dPipeline = nil;
static id<MTLRenderPipelineState>   g_textured3dPipeline = nil;
static id<MTLRenderPipelineState>   g_discFlatPipeline = nil;      // smooth ellipse in a quad
static id<MTLRenderPipelineState>   g_discTexPipeline = nil;
static id<MTLDepthStencilState>     g_depthState = nil;
static id<MTLDepthStencilState>     g_noDepthState = nil;
static id<MTLDepthStencilState>     g_depthTestOnlyState = nil;  // translucent shapes: test, don't write

// name -> window registry, so jet_head can bind to a specific
// jet_win at construction time (see jet_win_register_head).
static std::map<t_symbol *, t_jet_win *> g_windowsByName;

// whichever window is currently dispatching its head chain - the
// "get/set current X" accessors below resolve against this, so chain
// objects (jet_triangle, jet_texture, jet_image, ...) stay
// completely window-agnostic. jet_win_tick sets this right before
// banging its own heads and clears it right after.
static t_jet_win *g_activeWindow = nullptr;

// texture pool pins, defined further down (see "texture pool")
static void jet_pool_pin(id<MTLTexture> tex);
static void jet_pool_unpin(id<MTLTexture> tex);

void jet_win_publish_texture(t_symbol *name, id<MTLTexture> tex)
{
  if(!g_activeWindow || !g_activeWindow->x_named || !name) {
    return;
  }
  auto &m = *g_activeWindow->x_named;
  auto it = m.find(name);
  id<MTLTexture> old = (it != m.end()) ? it->second : nil;
  if(old == tex) {
    return;
  }
  if(tex) {
    m[name] = [tex retain];
    jet_pool_pin(tex);
  } else {
    m.erase(name);
  }
  if(old) jet_pool_unpin(old);
  [old release];
}

// ---------------------------------------------------------------
// texture pool (see jet_shared.h). A texture is reusable when it is
// released by its producer AND not pinned. Pins come from recorded
// draws (until the end of the frame) and from published names (until
// replaced). Everything runs on the Pd thread, so no locking.
// ---------------------------------------------------------------
struct PoolEntry {
  id<MTLTexture> tex;
  int  w, h;
  bool bgra;
  bool inUse;
  int  pins;
  long lastUsed;
};
static std::vector<PoolEntry> g_pool;
static long g_poolFrame = 0;

static PoolEntry *jet_pool_find(id<MTLTexture> tex)
{
  for(PoolEntry &e : g_pool) {
    if(e.tex == tex) return &e;
  }
  return nullptr;
}

static id<MTLTexture> jet_pool_acquire(int w, int h, bool bgra)
{
  if(!g_device || w < 1 || h < 1) return nil;
  for(PoolEntry &e : g_pool) {
    if(!e.inUse && e.pins == 0 && e.w == w && e.h == h && e.bgra == bgra) {
      e.inUse = true;
      e.lastUsed = g_poolFrame;
      return e.tex;
    }
  }
  MTLTextureDescriptor *desc =
    [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:(bgra ? MTLPixelFormatBGRA8Unorm
                                                                    : MTLPixelFormatRGBA8Unorm)
                                                        width:w height:h mipmapped:NO];
  desc.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
  desc.storageMode = MTLStorageModePrivate;
  id<MTLTexture> tex = [g_device newTextureWithDescriptor:desc];  // +1, owned by the pool
  if(!tex) return nil;
  g_pool.push_back({ tex, w, h, bgra, true, 0, g_poolFrame });
  return tex;
}

id<MTLTexture> jet_win_pool_acquire(int w, int h) { return jet_pool_acquire(w, h, false); }
id<MTLTexture> jet_win_pool_acquire_bgra(int w, int h) { return jet_pool_acquire(w, h, true); }

void jet_win_pool_release(id<MTLTexture> tex)
{
  PoolEntry *e = jet_pool_find(tex);
  if(e) e->inUse = false;
}

static void jet_pool_pin(id<MTLTexture> tex)
{
  PoolEntry *e = jet_pool_find(tex);
  if(e) e->pins++;
}

static void jet_pool_unpin(id<MTLTexture> tex)
{
  PoolEntry *e = jet_pool_find(tex);
  if(e && e->pins > 0) e->pins--;
}

// once per window frame: free textures nobody has wanted for a while
static void jet_pool_endFrame(void)
{
  g_poolFrame++;
  for(size_t i = 0; i < g_pool.size(); ) {
    PoolEntry &e = g_pool[i];
    if(!e.inUse && e.pins == 0 && g_poolFrame - e.lastUsed > 300) {
      [e.tex release];
      g_pool.erase(g_pool.begin() + i);
    } else {
      i++;
    }
  }
}

id<MTLTexture> jet_win_named_texture(t_symbol *name)
{
  if(!g_activeWindow || !g_activeWindow->x_named) {
    return nil;
  }
  auto it = g_activeWindow->x_named->find(name);
  return (it != g_activeWindow->x_named->end()) ? it->second : nil;
}

int jet_win_frame_active(void) { return g_activeWindow && g_activeWindow->x_frameActive; }
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

float jet_win_get_aspect(void)
{
  if(g_activeWindow && !g_activeWindow->x_scopes.empty()) return g_activeWindow->x_scopes.back()->aspect;
  return (g_activeWindow && g_activeWindow->x_aspect > 0.f) ? g_activeWindow->x_aspect : 1.f;
}

int jet_win_get_depth(void)
{
  return g_activeWindow ? g_activeWindow->x_depth : 1;
}
void jet_win_set_depth(int on)
{
  if(g_activeWindow) {
    g_activeWindow->x_depth = on ? 1 : 0;
  }
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
  const float *src = g_activeWindow->x_scopes.empty() ? g_activeWindow->x_viewMatrix
                                                      : g_activeWindow->x_scopes.back()->view;
  for(int i = 0; i < 16; i++) {
    outMat16[i] = src[i];
  }
}
void jet_win_get_projection(float outMat16[16])
{
  if(!g_activeWindow) {
    jet_mat4_identity(outMat16);
    return;
  }
  const float *src = g_activeWindow->x_scopes.empty() ? g_activeWindow->x_projMatrix
                                                      : g_activeWindow->x_scopes.back()->proj;
  for(int i = 0; i < 16; i++) {
    outMat16[i] = src[i];
  }
}
void jet_win_get_light(float outDir3[3], float outColor3[3])
{
  if(!g_activeWindow) {
    outDir3[0] = 0.f; outDir3[1] = 1.f; outDir3[2] = 0.f;
    outColor3[0] = outColor3[1] = outColor3[2] = 1.f;
    return;
  }
  const bool scoped = !g_activeWindow->x_scopes.empty();
  for(int i = 0; i < 3; i++) {
    outDir3[i] = scoped ? g_activeWindow->x_scopes.back()->lightDir[i] : g_activeWindow->x_lightDir[i];
    outColor3[i] = scoped ? g_activeWindow->x_scopes.back()->lightColor[i] : g_activeWindow->x_lightColor[i];
  }
}

void jet_win_get_color(float outRGBA[4])
{
  for(int i = 0; i < 4; i++) {
    outRGBA[i] = g_activeWindow ? g_activeWindow->x_color[i] : 1.f;
  }
}
void jet_win_set_color(const float rgba[4])
{
  if(!g_activeWindow) {
    return;
  }
  for(int i = 0; i < 4; i++) {
    g_activeWindow->x_color[i] = rgba[i];
  }
}


// records one draw into the active window's frame - see jet_shared.h.
// Translucent (alpha < 1) shapes with depth testing on are flagged
// here and run after everything else, sorted back to front.
extern "C" int jet_win_submit_draw(const JetDrawDesc *d)
{
  t_jet_win *w = g_activeWindow;
  if(!w || !w->x_frameActive || !d || d->vertexCount == 0) {
    return 0;
  }
  RecordedDraw r;
  r.pipeline = d->pipeline;
  r.vertexCount = d->vertexCount;
  r.vertexBuffer = d->vertexBuffer;
  r.vertexBufferOffset = d->vertexBufferOffset;
  r.vertexOffset = 0;
  r.vertexBytes = 0;
  if(!d->vertexBuffer) {
    // setVertexBytes is limited to 4 KB - bigger meshes need an MTLBuffer
    if(!d->vertices || d->vertexBytes == 0 || d->vertexBytes > 4096) {
      return 0;
    }
    std::vector<unsigned char> &arena = w->x_scopes.empty() ? w->x_arena : w->x_scopes.back()->arena;
    r.vertexOffset = arena.size();
    r.vertexBytes = d->vertexBytes;
    const unsigned char *src = (const unsigned char *)d->vertices;
    arena.insert(arena.end(), src, src + d->vertexBytes);
  }
  if((d->pipeline == JET_PIPE_TEXTURED3D || d->pipeline == JET_PIPE_DISC_TEXTURED) && !d->texture) {
    return 0;
  }
  r.texture = d->texture;
  if(d->texture) {
    // the draw runs at the end of the frame - keep a pooled texture's
    // content until then
    jet_pool_pin(d->texture);
    w->x_framePins.push_back(d->texture);
  }
  r.uniforms = d->uniforms;
  r.translucent = d->uniforms.tint[3] < 0.999f;
  if(!w->x_depth) {
    r.depth = kDepthOff;
  } else {
    r.depth = r.translucent ? kDepthTestOnly : kDepthTestWrite;
  }
  // view-space z of the model origin: camera looks down -z, so more
  // negative = farther away
  const float *v = d->uniforms.view, *m = d->uniforms.model;
  const float ox = m[12], oy = m[13], oz = m[14];
  r.sortZ = v[2] * ox + v[6] * oy + v[10] * oz + v[14];
  (w->x_scopes.empty() ? w->x_draws : w->x_scopes.back()->draws).push_back(r);
  return 1;
}

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

// draws a recorded list into an open render pass: everything except
// depth-tested translucent shapes in submission order, then the
// translucent ones back to front
static void jet_encode_draws(id<MTLRenderCommandEncoder> enc,
                             const std::vector<RecordedDraw> &draws,
                             const std::vector<unsigned char> &arena)
{
  std::vector<const RecordedDraw *> order;
  std::vector<const RecordedDraw *> translucent;
  order.reserve(draws.size());
  for(const RecordedDraw &d : draws) {
    if(d.depth == kDepthTestOnly) {
      translucent.push_back(&d);
    } else {
      order.push_back(&d);
    }
  }
  std::stable_sort(translucent.begin(), translucent.end(),
                   [](const RecordedDraw *a, const RecordedDraw *b) {
    return a->sortZ < b->sortZ;
  });
  order.insert(order.end(), translucent.begin(), translucent.end());

  int lastPipeline = -1, lastDepth = -1;
  for(const RecordedDraw *d : order) {
    id<MTLRenderPipelineState> pso =
      d->pipeline == JET_PIPE_TEXTURED3D ? g_textured3dPipeline :
      d->pipeline == JET_PIPE_DISC_FLAT ? g_discFlatPipeline :
      d->pipeline == JET_PIPE_DISC_TEXTURED ? g_discTexPipeline : g_flat3dPipeline;
    if(!pso) continue;
    if((int)d->pipeline != lastPipeline) {
      [enc setRenderPipelineState:pso];
      lastPipeline = (int)d->pipeline;
    }
    if((int)d->depth != lastDepth) {
      id<MTLDepthStencilState> st =
        (d->depth == kDepthOff) ? g_noDepthState :
        (d->depth == kDepthTestOnly) ? g_depthTestOnlyState : g_depthState;
      [enc setDepthStencilState:st];
      lastDepth = (int)d->depth;
    }
    if(d->vertexBuffer) {
      [enc setVertexBuffer:d->vertexBuffer offset:d->vertexBufferOffset atIndex:0];
    } else {
      [enc setVertexBytes:arena.data() + d->vertexOffset length:d->vertexBytes atIndex:0];
    }
    [enc setVertexBytes:&d->uniforms length:sizeof(JetUniforms3D) atIndex:1];
    [enc setFragmentBytes:&d->uniforms length:sizeof(JetUniforms3D) atIndex:1];
    if(d->pipeline == JET_PIPE_TEXTURED3D || d->pipeline == JET_PIPE_DISC_TEXTURED) {
      [enc setFragmentTexture:d->texture atIndex:0];
      [enc setFragmentSamplerState:g_sampler atIndex:0];
    }
    [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:d->vertexCount];
  }
}

// ---- scenes (jet_render), see jet_shared.h ----
extern "C" int jet_win_scene_begin(const JetSceneCamera *cam)
{
  t_jet_win *w = g_activeWindow;
  if(!w || !w->x_frameActive || !cam || w->x_scopes.size() >= 4) return 0;
  SceneScope *sc = new SceneScope();
  memcpy(sc->view, cam->view, sizeof(sc->view));
  memcpy(sc->proj, cam->projection, sizeof(sc->proj));
  memcpy(sc->lightDir, cam->lightDir, sizeof(sc->lightDir));
  memcpy(sc->lightColor, cam->lightColor, sizeof(sc->lightColor));
  sc->aspect = cam->aspect;
  // save the chain state and start the scene with a clean one
  memcpy(sc->savedTransform, w->x_transform3d, sizeof(sc->savedTransform));
  memcpy(sc->savedColor, w->x_color, sizeof(sc->savedColor));
  sc->savedDepth = w->x_depth;
  sc->savedTexture = w->x_currentTexture;
  jet_mat4_identity(w->x_transform3d);
  w->x_color[0] = w->x_color[1] = w->x_color[2] = w->x_color[3] = 1.f;
  w->x_depth = 1;
  w->x_currentTexture = nil;
  w->x_scopes.push_back(sc);
  return 1;
}

extern "C" void jet_win_scene_end(id<MTLTexture> color, id<MTLTexture> depth, const float clear[4])
{
  t_jet_win *w = g_activeWindow;
  if(!w || w->x_scopes.empty()) return;
  SceneScope *sc = w->x_scopes.back();
  w->x_scopes.pop_back();

  if(color && depth && g_flat3dPipeline && g_textured3dPipeline) {
    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = color;
    pass.colorAttachments[0].loadAction = MTLLoadActionClear;
    pass.colorAttachments[0].clearColor = MTLClearColorMake(clear[0], clear[1], clear[2], clear[3]);
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    pass.depthAttachment.texture = depth;
    pass.depthAttachment.loadAction = MTLLoadActionClear;
    pass.depthAttachment.clearDepth = 1.0;
    pass.depthAttachment.storeAction = MTLStoreActionDontCare;
    id<MTLCommandBuffer> cb = [g_queue commandBuffer];
    id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:pass];
    if(enc) {
      jet_encode_draws(enc, sc->draws, sc->arena);
      [enc endEncoding];
      [cb commit];   // before the window's own pass is committed: it samples this
    }
  }

  memcpy(w->x_transform3d, sc->savedTransform, sizeof(sc->savedTransform));
  memcpy(w->x_color, sc->savedColor, sizeof(sc->savedColor));
  w->x_depth = sc->savedDepth;
  w->x_currentTexture = sc->savedTexture;
  delete sc;
}

@interface JetWinView : NSView
@property(nonatomic, strong) id<MTLDevice> device;
@property(nonatomic, strong) id<MTLCommandQueue> queue;
@property(nonatomic, strong) CAMetalLayer *metalLayer;
@property(nonatomic, strong) id<MTLTexture> depthTexture;  // 3D depth testing, see ensureDepthTexture
// executes a frame's recorded draws in one on-screen render pass and
// presents it - see jet_win_submit_draw
- (void)renderDraws:(const std::vector<RecordedDraw> *)draws
              arena:(const std::vector<unsigned char> *)arena;
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

// classic source-over blending: chain alpha 1 draws opaque exactly as
// before, anything lower mixes with what is already in the frame
- (void)enableAlphaBlending:(MTLRenderPipelineDescriptor *)desc
{
  MTLRenderPipelineColorAttachmentDescriptor *ca = desc.colorAttachments[0];
  ca.blendingEnabled = YES;
  ca.rgbBlendOperation = MTLBlendOperationAdd;
  ca.alphaBlendOperation = MTLBlendOperationAdd;
  ca.sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
  ca.sourceAlphaBlendFactor = MTLBlendFactorSourceAlpha;
  ca.destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
  ca.destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
}

- (void)setupPipelines
{
  NSString *src = @""
    "#include <metal_stdlib>\n"
    "using namespace metal;\n"
    // --- shapes: see jet_shared.h's comment on the 3D accessors and
    // draw commands for the overall design. Uniforms3D's layout must
    // match the C++-side Uniforms3D struct byte-for-byte - lightDir/
    // lightColor are float4 (not float3) specifically so there's no
    // float3-padding-rule question to get right on either side at
    // all: float4 is unambiguously 16 bytes, 16-byte aligned, in both
    // MSL and a plain C++ float[4]. w is unused except lightDir.w: 1 = unlit (flat shapes).
    "struct Uniforms3D {\n"
    "  float4x4 model; float4x4 view; float4x4 projection;\n"
    "  float4 lightDir;\n"
    "  float4 lightColor;\n"
    "  float4 tint;\n"
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
    "  float3 shade = (u.lightDir.w > 0.5) ? float3(1.0) : (0.15 + ndotl * u.lightColor.xyz);\n"
    "  float3 lit = in.color * shade;\n"
    "  return float4(lit, u.tint.a);\n"
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
    // the texture's own alpha is ignored on purpose: only the chain alpha counts
    "fragment float4 fragment3DTexMain(VOut3DTex in [[stage_in]],\n"
    "    texture2d<float> tex [[texture(0)]], sampler s [[sampler(0)]],\n"
    "    constant Uniforms3D &u [[buffer(1)]]) {\n"
    "  float3 n = normalize(in.normal);\n"
    "  float ndotl = max(dot(n, normalize(u.lightDir.xyz)), 0.0);\n"
    "  float4 albedo = tex.sample(s, in.uv);\n"
    "  float3 shade = (u.lightDir.w > 0.5) ? float3(1.0) : (0.15 + ndotl * u.lightColor.xyz);\n"
    "  float3 lit = albedo.rgb * u.tint.rgb * shade;\n"
    "  return float4(lit, u.tint.a);\n"
    "}\n"
    // ellipse inscribed in a quad whose uv runs 0..1: coverage ramps from 1
    // to 0 over the last pixel inside the edge (fwidth of the normalised
    // radius is one pixel), which gives a smooth edge at any size, scale
    // and tilt. the edge pixels get partial alpha (blending is on)
    "float jetDiscCover(float2 uv) {\n"
    "  float r = length(uv * 2.0 - 1.0);\n"
    "  float aa = max(fwidth(r), 0.0001);\n"
    "  return clamp((1.0 - r) / aa, 0.0, 1.0);\n"
    "}\n"
    "fragment float4 fragment3DDiscFlatMain(VOut3DTex in [[stage_in]],\n"
    "    constant Uniforms3D &u [[buffer(1)]]) {\n"
    "  float cover = jetDiscCover(in.uv);\n"
    "  if(cover <= 0.0) { discard_fragment(); }\n"
    "  return float4(u.tint.rgb, u.tint.a * cover);\n"
    "}\n"
    "fragment float4 fragment3DDiscTexMain(VOut3DTex in [[stage_in]],\n"
    "    texture2d<float> tex [[texture(0)]], sampler s [[sampler(0)]],\n"
    "    constant Uniforms3D &u [[buffer(1)]]) {\n"
    "  float cover = jetDiscCover(in.uv);\n"
    "  if(cover <= 0.0) { discard_fragment(); }\n"
    "  float3 c = tex.sample(s, in.uv).rgb * u.tint.rgb;\n"
    "  return float4(c, u.tint.a * cover);\n"
    "}\n";

  NSError *err = nil;
  id<MTLLibrary> lib = [self.device newLibraryWithSource:src options:nil error:&err];
  if(!lib) {
    post("jet_win: shader compile failed: %s", [[err localizedDescription] UTF8String]);
    return;
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
  [self enableAlphaBlending:flat3dDesc];
  g_flat3dPipeline = [self.device newRenderPipelineStateWithDescriptor:flat3dDesc error:&err];
  if(!g_flat3dPipeline) {
    post("jet_win: flat3d pipeline build failed: %s", [[err localizedDescription] UTF8String]);
  }

  MTLRenderPipelineDescriptor *tex3dDesc = [[MTLRenderPipelineDescriptor alloc] init];
  tex3dDesc.vertexFunction = [lib newFunctionWithName:@"vertex3DTexMain"];
  tex3dDesc.fragmentFunction = [lib newFunctionWithName:@"fragment3DTexMain"];
  tex3dDesc.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
  tex3dDesc.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;
  [self enableAlphaBlending:tex3dDesc];
  g_textured3dPipeline = [self.device newRenderPipelineStateWithDescriptor:tex3dDesc error:&err];
  if(!g_textured3dPipeline) {
    post("jet_win: textured3d pipeline build failed: %s", [[err localizedDescription] UTF8String]);
  }

  // smooth-edged ellipse pipelines: same vertex stage as the textured one
  MTLRenderPipelineDescriptor *discDesc = [[MTLRenderPipelineDescriptor alloc] init];
  discDesc.vertexFunction = [lib newFunctionWithName:@"vertex3DTexMain"];
  discDesc.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
  discDesc.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;
  [self enableAlphaBlending:discDesc];
  discDesc.fragmentFunction = [lib newFunctionWithName:@"fragment3DDiscFlatMain"];
  g_discFlatPipeline = [self.device newRenderPipelineStateWithDescriptor:discDesc error:&err];
  if(!g_discFlatPipeline) {
    post("jet_win: disc pipeline build failed: %s", [[err localizedDescription] UTF8String]);
  }
  discDesc.fragmentFunction = [lib newFunctionWithName:@"fragment3DDiscTexMain"];
  g_discTexPipeline = [self.device newRenderPipelineStateWithDescriptor:discDesc error:&err];
  if(!g_discTexPipeline) {
    post("jet_win: textured disc pipeline build failed: %s", [[err localizedDescription] UTF8String]);
  }

  MTLDepthStencilDescriptor *depthDesc = [[MTLDepthStencilDescriptor alloc] init];
  depthDesc.depthCompareFunction = MTLCompareFunctionLessEqual;  // coplanar redraws still pass
  depthDesc.depthWriteEnabled = YES;
  g_depthState = [self.device newDepthStencilStateWithDescriptor:depthDesc];

  MTLDepthStencilDescriptor *noDepthDesc = [[MTLDepthStencilDescriptor alloc] init];
  noDepthDesc.depthCompareFunction = MTLCompareFunctionAlways;
  noDepthDesc.depthWriteEnabled = NO;
  g_noDepthState = [self.device newDepthStencilStateWithDescriptor:noDepthDesc];

  MTLDepthStencilDescriptor *testOnlyDesc = [[MTLDepthStencilDescriptor alloc] init];
  testOnlyDesc.depthCompareFunction = MTLCompareFunctionLessEqual;
  testOnlyDesc.depthWriteEnabled = NO;
  g_depthTestOnlyState = [self.device newDepthStencilStateWithDescriptor:testOnlyDesc];
}

// (re)creates the depth buffer to match the drawable's current size -
// called from renderDraws, so it stays in sync with resizes without
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

// ESC leaving fullscreen is handled by the window's event monitor (see
// jet_win_create); everything else goes up the responder chain
- (void)keyDown:(NSEvent *)event
{
  [super keyDown:event];
}

- (void)renderDraws:(const std::vector<RecordedDraw> *)draws
              arena:(const std::vector<unsigned char> *)arena
{
  if(!g_flat3dPipeline || !g_textured3dPipeline) {
    return;
  }
  // acquired late on purpose: the drawable is only held from here to
  // present, not while the chains run
  [self ensureDepthTexture];
  if(!self.depthTexture) {
    return;
  }
  id<CAMetalDrawable> drawable = [self.metalLayer nextDrawable];
  if(!drawable) {
    return;
  }

  MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
  pass.colorAttachments[0].texture = drawable.texture;
  pass.colorAttachments[0].loadAction = MTLLoadActionClear;
  pass.colorAttachments[0].clearColor = MTLClearColorMake(0.07, 0.07, 0.10, 1.0);
  pass.colorAttachments[0].storeAction = MTLStoreActionStore;
  pass.depthAttachment.texture = self.depthTexture;
  pass.depthAttachment.loadAction = MTLLoadActionClear;
  pass.depthAttachment.clearDepth = 1.0;
  pass.depthAttachment.storeAction = MTLStoreActionDontCare;

  id<MTLCommandBuffer> cmdBuf = [self.queue commandBuffer];
  id<MTLRenderCommandEncoder> enc = [cmdBuf renderCommandEncoderWithDescriptor:pass];
  if(!enc) {
    return;
  }

  jet_encode_draws(enc, *draws, *arena);

  [enc endEncoding];
  [cmdBuf presentDrawable:drawable];
  [cmdBuf commit];
}

@end

// ---------------------------------------------------------------
// the Pd object (t_jet_win itself is declared further up, next to
// the cross-bundle accessor functions that need its full definition)
// ---------------------------------------------------------------

// a borderless NSWindow refuses to become key by default, which would
// leave ESC (and any other key) with nowhere to go in fullscreen
@interface JetNSWindow : NSWindow
@end
@implementation JetNSWindow
- (BOOL)canBecomeKeyWindow { return YES; }
- (BOOL)canBecomeMainWindow { return YES; }
@end

static NSUInteger jet_win_styleMask(const t_jet_win *x)
{
  if(!x->x_border) {
    return NSWindowStyleMaskBorderless | NSWindowStyleMaskResizable;
  }
  return NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
        NSWindowStyleMaskResizable | NSWindowStyleMaskMiniaturizable;
}

static void jet_win_tick(t_jet_win *x);

// Cocoa's global screen coordinates have their origin at the bottom left
// of the PRIMARY display, y up. jet_win's "offset" works like Pd/Gem
// screen coordinates instead: origin at the top left of the primary
// display, y down, other displays continuing beyond it (a display to the
// right of a 1920 wide primary starts at x = 1920).
static CGFloat jet_win_primaryHeight(void)
{
  NSArray<NSScreen *> *screens = [NSScreen screens];
  return screens.count ? screens[0].frame.size.height : 0;
}

static void jet_win_applyOffset(t_jet_win *x)
{
  [x->x_window setFrameTopLeftPoint:NSMakePoint(x->x_offsetX,
                                                jet_win_primaryHeight() - x->x_offsetY)];
}

static NSScreen *jet_win_targetScreen(t_jet_win *x)
{
  NSArray<NSScreen *> *screens = [NSScreen screens];
  if(x->x_display >= 1 && x->x_display <= (int)screens.count) {
    return screens[x->x_display - 1];
  }
  NSScreen *s = x->x_window.screen;
  return s ? s : (screens.count ? screens[0] : nil);
}

// Makes the window match x_fullscreen. Idempotent, instant and
// synchronous (no macOS fullscreen Space and no animation, so two windows
// on two displays behave the same no matter how the "Displays have
// separate Spaces" setting is): a borderless window covering the target
// display, above the menu bar and the Dock.
static void jet_win_applyFullscreen(t_jet_win *x)
{
  if(!x->x_open) {
    return;   // applied when the window is created
  }
  NSWindow *win = x->x_window;
  if(x->x_fullscreen) {
    NSScreen *screen = jet_win_targetScreen(x);
    if(!screen) {
      return;
    }
    if(!x->x_isFs) {
      x->x_savedFrame = win.frame;
    }
    win.styleMask = NSWindowStyleMaskBorderless;
    win.level = NSMainMenuWindowLevel + 1;
    [win setFrame:screen.frame display:YES];
    x->x_isFs = 1;
    const NSRect f = screen.frame;
    post("jet_win: fullscreen on display %d (%d x %d)",
         (int)[[NSScreen screens] indexOfObject:screen] + 1, (int)f.size.width, (int)f.size.height);
  } else if(x->x_isFs) {
    win.level = NSNormalWindowLevel;
    win.styleMask = jet_win_styleMask(x);
    if(x->x_frameDirty) {
      [win setContentSize:NSMakeSize(x->x_dimenW, x->x_dimenH)];
      jet_win_applyOffset(x);
      x->x_frameDirty = 0;
    } else {
      [win setFrame:x->x_savedFrame display:YES];
    }
    x->x_isFs = 0;
    post("jet_win: fullscreen off");
  }
  [win makeKeyAndOrderFront:nil];
  [win makeFirstResponder:x->x_view];
}

// ESC, the Pd way. Pd forwards every key press that reaches one of its own
// windows to whatever is bound to the symbol "#key" (that is how [key]
// works). A fullscreen jet window usually does not have the keyboard -
// macOS no longer lets a background process take the focus by itself - so
// the keys land in Pd's GUI instead; listening on "#key" catches ESC there
// too. (The window's own key handling covers the case where the jet window
// has the focus, e.g. after a click.) A small proxy object is bound
// because jet_win's own float method already means "render on/off".
typedef struct _jet_win_keyproxy {
  t_pd       kp_pd;
  t_jet_win *kp_owner;
} t_jet_win_keyproxy;

static t_class *jet_win_keyproxy_class;

static void jet_win_keyproxy_float(t_jet_win_keyproxy *p, t_floatarg f)
{
  if((int)f == 27 && p->kp_owner->x_isFs) {
    p->kp_owner->x_fullscreen = 0;
    jet_win_applyFullscreen(p->kp_owner);
  }
}

static void jet_win_create(t_jet_win *x)
{
  if(x->x_open) {
    post("jet_win: already open");
    return;
  }

  [NSApplication sharedApplication];
  // Pd's core is a plain command-line process, which macOS treats as
  // "prohibited": it can show windows, but is never the active app and
  // its windows never get the keyboard (so ESC in fullscreen went to
  // Pd's GUI instead). "Accessory" lifts that without a Dock icon or a
  // menu bar of its own. A host that is already a regular app keeps its
  // policy.
  if([NSApp activationPolicy] == NSApplicationActivationPolicyProhibited) {
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
  }

  const NSRect frame = NSMakeRect(0, 0, x->x_dimenW, x->x_dimenH);
  NSWindow *win = [[JetNSWindow alloc] initWithContentRect:frame
                                              styleMask:jet_win_styleMask(x)
                                                backing:NSBackingStoreBuffered
                                                  defer:NO];
  [win setTitle:[NSString stringWithUTF8String:x->x_title->c_str()]];
  [win setReleasedWhenClosed:NO];
  // fullscreen is our own borderless mode (jet_win_applyFullscreen), so
  // the green zoom button must not start macOS's Space-based one
  win.collectionBehavior = NSWindowCollectionBehaviorFullScreenNone;

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
    if(event.window == win && event.keyCode == kEscKeyCode && x->x_isFs) {
      x->x_fullscreen = 0;
      jet_win_applyFullscreen(x);
      return nil;  // consume it, don't let it propagate further
    }
    return event;
  }];

  x->x_window = win;
  x->x_view = view;
  x->x_open = 1;
  x->x_isFs = 0;
  jet_win_applyOffset(x);
  jet_win_applyFullscreen(x);   // a "fullscreen 1" sent before "create" takes effect now
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
  x->x_isFs = 0;
  post("jet_win: window destroyed");
}

// ---------------------------------------------------------------
// gemwin-style configuration messages
// ---------------------------------------------------------------

static void jet_win_dimen(t_jet_win *x, t_floatarg w, t_floatarg h)
{
  x->x_dimenW = (w < 1) ? 1 : (int)w;
  x->x_dimenH = (h < 1) ? 1 : (int)h;
  if(x->x_isFs) {
    x->x_frameDirty = 1;       // used when fullscreen ends
  } else if(x->x_open) {
    [x->x_window setContentSize:NSMakeSize(x->x_dimenW, x->x_dimenH)];
  }
}

static void jet_win_offset(t_jet_win *x, t_floatarg ox, t_floatarg oy)
{
  x->x_offsetX = (int)ox;
  x->x_offsetY = (int)oy;
  if(x->x_isFs) {
    x->x_frameDirty = 1;
  } else if(x->x_open) {
    jet_win_applyOffset(x);
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
  if(x->x_open && !x->x_isFs) {
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
  x->x_fullscreen = (f != 0.f);
  jet_win_applyFullscreen(x);
}

// "display N": which display "fullscreen" covers (1 = primary, see
// "displays"); 0 = the one the window is on
static void jet_win_display(t_jet_win *x, t_floatarg f)
{
  x->x_display = (f < 0.f) ? 0 : (int)f;
  if(x->x_isFs) {
    jet_win_applyFullscreen(x);   // move to the other display
  }
}

static void jet_win_displays(t_jet_win *x)
{
  (void)x;
  NSArray<NSScreen *> *screens = [NSScreen screens];
  const CGFloat ph = jet_win_primaryHeight();
  for(NSUInteger i = 0; i < screens.count; i++) {
    const NSRect f = screens[i].frame;
    post("jet_win: display %d: %d x %d at offset %d %d%s", (int)i + 1,
         (int)f.size.width, (int)f.size.height,
         (int)f.origin.x, (int)(ph - (f.origin.y + f.size.height)),
         i == 0 ? " (primary)" : "");
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
  jet_mat4_identity(x->x_transform3d);
  x->x_depth = 1;
  x->x_color[0] = x->x_color[1] = x->x_color[2] = x->x_color[3] = 1.f;

  // a texture one chain bound (or rendered) isn't this chain's input
  x->x_currentTexture = nil;
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

  x->x_draws.clear();
  x->x_arena.clear();
  x->x_frameActive = (g_flat3dPipeline && g_textured3dPipeline) ? 1 : 0;
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
  x->x_frameActive = 0;
  [x->x_view renderDraws:&x->x_draws arena:&x->x_arena];
  for(id<MTLTexture> t : x->x_framePins) jet_pool_unpin(t);
  x->x_framePins.clear();
  jet_pool_endFrame();
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
  {
    t_jet_win_keyproxy *kp = (t_jet_win_keyproxy *)pd_new(jet_win_keyproxy_class);
    kp->kp_owner = x;
    pd_bind(&kp->kp_pd, gensym("#key"));
    x->x_keyProxy = kp;
  }
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
  x->x_named = new std::map<t_symbol *, id<MTLTexture>>();
  x->x_dimenW = 640;
  x->x_dimenH = 480;
  x->x_offsetX = 100;
  x->x_offsetY = 100;
  x->x_border = 1;
  x->x_fullscreen = 0;
  x->x_isFs = 0;
  x->x_display = 0;
  x->x_frameDirty = 0;
  x->x_savedFrame = NSMakeRect(0, 0, 0, 0);
  x->x_profiling = 0;
  x->x_fps = 0.f;
  x->x_lastFrameSysTime = 0.0;

  x->x_currentTexture = nil;
  x->x_currentPixelsW = 0;
  x->x_currentPixelsH = 0;
  x->x_depth = 1;

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
  x->x_color[0] = x->x_color[1] = x->x_color[2] = x->x_color[3] = 1.f;

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
  if(x->x_keyProxy) {
    t_jet_win_keyproxy *kp = (t_jet_win_keyproxy *)x->x_keyProxy;
    pd_unbind(&kp->kp_pd, gensym("#key"));
    pd_free(&kp->kp_pd);
    x->x_keyProxy = nullptr;
  }
  jet_win_destroy(x);
  clock_free(x->x_clock);
  delete x->x_title;
  for(auto &kv : *x->x_named) {
    jet_pool_unpin(kv.second);
    [kv.second release];
  }
  delete x->x_named;
  x->x_named = nullptr;
  std::vector<RecordedDraw>().swap(x->x_draws);
  std::vector<unsigned char>().swap(x->x_arena);
  std::vector<id<MTLTexture> >().swap(x->x_framePins);
  for(SceneScope *sc : x->x_scopes) delete sc;
  x->x_scopes.clear();

  auto it = g_windowsByName.find(x->x_name);
  if(it != g_windowsByName.end() && it->second == x) {
    g_windowsByName.erase(it);
  }
}

extern "C" void jet_win_setup(void)
{
  jet_win_keyproxy_class = class_new(gensym("jet_win_keyproxy"), 0, 0,
                                     sizeof(t_jet_win_keyproxy), CLASS_PD | CLASS_NOINLET, A_NULL);
  class_addfloat(jet_win_keyproxy_class, (t_method)jet_win_keyproxy_float);

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
  class_addmethod(jet_win_class, (t_method)jet_win_display,
                  gensym("display"), A_FLOAT, 0);
  class_addmethod(jet_win_class, (t_method)jet_win_displays,
                  gensym("displays"), A_NULL);
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
