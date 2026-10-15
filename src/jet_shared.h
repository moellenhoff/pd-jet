/* ------------------------------------------------------------------
 * jet_shared.h - the tiny cross-bundle interface that lets chain
 * objects (jet_triangle, jet_rectangle, jet_texture,
 * jet_image, ...) reach into whichever jet_win currently has an
 * active render pass - exactly the way pix_* objects reach into Gem:
 * jet_win.pd_darwin exports these functions, other .pd_darwin
 * bundles call them and they resolve at load time via
 * -undefined dynamic_lookup, because all these bundles end up loaded
 * in the same Pd process.
 *
 * Mirrors Gem's actual split: jet_image loads pixels (CPU side,
 * "current pixels"), jet_texture uploads whatever's current to the
 * GPU ("current texture"), shape objects (jet_triangle,
 * jet_rectangle) sample it if one is bound, else fall back to flat
 * per-vertex color.
 *
 * Multi-window: each jet_win owns its own head list/current-
 * texture/current-pixels/transform (no longer one shared global set
 * of "current" slots). jet_win.mm tracks which window is currently
 * mid-frame and routes every "get/set current X" call below to that
 * window's own state, so chain objects (jet_triangle, jet_image,
 * jet_texture, ...) stay completely window-agnostic - only
 * jet_head needs to know which window it belongs to, via an
 * optional window-name creation arg matched against jet_win's own
 * (also optional, defaults to "default" on both sides, so a single
 * unnamed window behaves exactly as before).
 *
 * State has three scopes - know which one a piece of state lives in:
 *
 *  - CHAIN-scoped (reset by jet_win before every jet_head bang, see
 *    jet_win_beginChain): the model transform, the current color,
 *    the depth test on/off flag and the current texture. jet_separator saves and restores all of these around its
 *    own branch. Nothing a chain
 *    does to these can reach the next chain.
 *  - FRAME-scoped (set once per frame by jet_win): camera view/
 *    projection, the light, the aspect ratio. Chain objects only read.
 *  - OBJECT-scoped (lives in the object, survives across frames):
 *    textures an object renders into or owns, retained pixel data.
 *    "Current pixels" is the one exception that is window-wide and
 *    persists across chains and frames - producers that need to
 *    survive on ticks without new data must re-publish what they
 *    hold every bang rather than rely on it still being there.
 *
 * Drawing: shapes never touch the on-screen encoder. They record draw
 * commands (jet_win_submit_draw, below) while the chains run; the
 * window sorts them and draws everything in ONE on-screen pass after
 * the last chain, setting pipeline, depth and blend state itself, so
 * nothing one shape does can affect another. Objects that render into
 * a texture (jet_perlin, jet_feedback, ...) still encode their own
 * offscreen pass on jet_win_queue() immediately - same-queue commit
 * order guarantees it is finished before the on-screen pass reads it.
 * ------------------------------------------------------------------
 */
#ifndef _INCLUDE__JET_SHARED_H_
#define _INCLUDE__JET_SHARED_H_

#import <Metal/Metal.h>
#include "m_pd.h"
#include <math.h>

#ifdef __cplusplus
extern "C" {
#endif

// non-zero while a jet_win is dispatching its chains for the current
// frame (i.e. while a jet_head bang is being handled). Objects that
// only make sense mid-frame (producers, shapes) check this and skip
// quietly otherwise.
int jet_win_frame_active(void);

// shared resources. Producers (jet_perlin, jet_feedback, ...) encode
// their own OFFSCREEN passes on jet_win_queue() right away; shapes do
// not touch an encoder at all, they submit draw commands (see
// jet_win_submit_draw below).
id<MTLSamplerState>        jet_win_sampler(void);
id<MTLDevice>               jet_win_device(void);
id<MTLCommandQueue>         jet_win_queue(void);

// CPU-side "current pixels", set by jet_image (or, in the future,
// any CPU pixel-processing object), read by jet_texture. rgba must
// be width*height*4 bytes, interleaved, top-to-bottom.
void jet_win_set_current_pixels(const unsigned char *rgba, int width,
                                  int height);
int  jet_win_get_current_pixels(const unsigned char **outRgba,
                                  int *outWidth, int *outHeight);

// GPU "current texture", set by jet_texture, sampled by shape
// objects when non-nil.
void jet_win_set_current_texture(id<MTLTexture> tex);
id<MTLTexture> jet_win_current_texture(void);

// jet_head calls these in its constructor/destructor to join/leave
// a specific jet_win's set of chains that get banged once per
// frame, in ascending priority order (same convention as Gem's
// [gemhead priority]). windowName matches a jet_win's own (also
// optional) name argument - both default to "default" when omitted,
// so a single unnamed window/head pair needs no naming at all. x is
// the calling jet_head, only used for pd_error() if windowName
// doesn't match any existing jet_win.
void jet_win_register_head(t_symbol *windowName, void *x, t_outlet *outlet,
                             int priority);
void jet_win_unregister_head(t_outlet *outlet);

// --- Units: Gem units. All shapes are real 3D geometry drawn through
// the camera. The default camera (z=4, fov 90) makes the z=0 plane
// 8 units tall (y runs -4..+4) and 8*aspect wide, so on an 800x600
// window [jet_rectangle 5.33 4] fills the whole picture, exactly as
// [rectangle 5.33 4] does in Gem - and a shape moved back in Z gets
// smaller by perspective, like in Gem.
//
// width/height of the window's actual drawable (not the last "dimen"
// message - the user can drag-resize it).
float jet_win_get_aspect(void);

// --- 3D: Right-handed, Y-up world space, column-
// major 4x4 matrices (Metal's own native convention, so these upload
// straight into an MSL float4x4 with no transpose). Model transform:
// jet_win resets it to identity before each jet_head chain,
// jet_translateXYZ/rotateXYZ/scaleXYZ multiply their own op onto it,
// shape objects (jet_rectangle, jet_triangle, jet_cube, later
// jet_obj) read it once per vertex-buffer build. View/projection
// are NOT per-chain - jet_win computes them once per FRAME from its
// own camera state ("camera"/"lookat"/"fov" messages) and shape
// objects only ever read them.
void jet_win_get_transform3d(float outMat16[16]);
void jet_win_set_transform3d(const float mat16[16]);
void jet_win_get_view(float outMat16[16]);
void jet_win_get_projection(float outMat16[16]);

// the one directional light every 3D shader uses. dir points FROM the
// lit surface TOWARD the light (so fragment shaders do
// max(dot(normal, lightDir), 0) directly, no extra negation).
void jet_win_get_light(float outDir3[3], float outColor3[3]);

// the chain's current color (RGBA, 0..1), set by jet_color and read by
// every shape: it is the flat color of a shape without a texture and a
// multiplicative tint on one with a texture, like Gem's [color].
// Chain-scoped: jet_win resets it to opaque white before every chain
// (jet_separator saves/restores it). Alpha blends the shape (source-
// over); it applies to flat and textured shapes alike, and a
// texture's own alpha channel is ignored.
void jet_win_get_color(float outRGBA[4]);
void jet_win_set_color(const float rgba[4]);

// depth testing on/off for the chain's shapes, set by jet_depth.
// Chain-scoped, ON by default (like Gem). Shapes call
// jet_win_apply_depth() right before drawing.
int  jet_win_get_depth(void);
void jet_win_set_depth(int on);

// --- draw commands. Shapes don't draw into a live encoder: they
// RECORD what they want drawn (a vertex block, a pipeline kind, a
// texture, the uniforms) with jet_win_submit_draw(), and the window
// executes the whole list in one on-screen render pass at the end of
// the frame, after every chain has run. This keeps encoder state out
// of the objects' hands (nothing can leak between shapes), lets the
// window decide ordering and depth/blend state, and is the basis for
// layers, multiple passes and moving rendering off the Pd thread.
//
// The window reads the chain's depth flag (jet_depth) and the alpha of
// uniforms.tint when a command is submitted, and orders execution:
//   - everything that is NOT (depth-tested AND alpha < 1) runs in
//     submission order, so depth-off layering keeps painter's order;
//   - depth-tested translucent shapes run afterwards, sorted back to
//     front, testing depth but not writing it.
// Pipelines: FLAT3D takes JetVertex3D, TEXTURED3D takes JetVertex3DTex
// (+ a texture); both take the JetUniforms3D block defined below.
typedef enum { JET_PIPE_FLAT3D = 0, JET_PIPE_TEXTURED3D = 1 } JetPipeline;



#ifdef __cplusplus
}
#endif

// column-major 4x4 matrix helpers (Metal/OpenGL native layout: column
// c, row r lives at m[c*4+r]) - header-only, no cross-bundle symbol
// needed for plain math. Right-handed throughout.
static inline void jet_mat4_identity(float m[16])
{
  for(int i = 0; i < 16; i++) {
    m[i] = 0.f;
  }
  m[0] = m[5] = m[10] = m[15] = 1.f;
}

// out = a * b (column-major); safe to alias out with a or b
static inline void jet_mat4_mul(const float a[16], const float b[16], float out[16])
{
  float r[16];
  for(int col = 0; col < 4; col++) {
    for(int row = 0; row < 4; row++) {
      float sum = 0.f;
      for(int k = 0; k < 4; k++) {
        sum += a[k * 4 + row] * b[col * 4 + k];
      }
      r[col * 4 + row] = sum;
    }
  }
  for(int i = 0; i < 16; i++) {
    out[i] = r[i];
  }
}

static inline void jet_mat4_translation(float tx, float ty, float tz, float m[16])
{
  jet_mat4_identity(m);
  m[12] = tx;
  m[13] = ty;
  m[14] = tz;
}

static inline void jet_mat4_scale(float sx, float sy, float sz, float m[16])
{
  jet_mat4_identity(m);
  m[0] = sx;
  m[5] = sy;
  m[10] = sz;
}

// angles in radians, right-handed (counterclockwise looking down the
// positive axis toward the origin)
static inline void jet_mat4_rotationX(float a, float m[16])
{
  jet_mat4_identity(m);
  const float c = cosf(a), s = sinf(a);
  m[5] = c;  m[6] = s;
  m[9] = -s; m[10] = c;
}
static inline void jet_mat4_rotationY(float a, float m[16])
{
  jet_mat4_identity(m);
  const float c = cosf(a), s = sinf(a);
  m[0] = c;  m[2] = -s;
  m[8] = s;  m[10] = c;
}
static inline void jet_mat4_rotationZ(float a, float m[16])
{
  jet_mat4_identity(m);
  const float c = cosf(a), s = sinf(a);
  m[0] = c;  m[1] = s;
  m[4] = -s; m[5] = c;
}

// right-handed perspective projection targeting Metal's [0,1] clip-
// space depth range (NOT OpenGL's [-1,1]) - fovYRadians is the full
// vertical field of view, aspect is width/height.
static inline void jet_mat4_perspective(float fovYRadians, float aspect,
                                          float nearZ, float farZ, float m[16])
{
  for(int i = 0; i < 16; i++) {
    m[i] = 0.f;
  }
  const float f = 1.f / tanf(fovYRadians * 0.5f);
  m[0] = f / aspect;
  m[5] = f;
  m[10] = farZ / (nearZ - farZ);
  m[11] = -1.f;
  m[14] = (nearZ * farZ) / (nearZ - farZ);
}

// right-handed look-at view matrix
static inline void jet_mat4_lookAt(float eyeX, float eyeY, float eyeZ,
                                     float targetX, float targetY, float targetZ,
                                     float m[16])
{
  float zx = eyeX - targetX, zy = eyeY - targetY, zz = eyeZ - targetZ;
  float zlen = sqrtf(zx * zx + zy * zy + zz * zz);
  if(zlen < 1e-6f) {
    zlen = 1e-6f;
  }
  zx /= zlen; zy /= zlen; zz /= zlen;

  // up = (0,1,0); xaxis = normalize(cross(up, zaxis))
  float xx = zz, xy = 0.f, xz = -zx;  // cross((0,1,0),(zx,zy,zz))
  float xlen = sqrtf(xx * xx + xy * xy + xz * xz);
  if(xlen < 1e-6f) {
    // camera looking straight up/down - up vector degenerates, fall
    // back to a fixed world-X axis so we don't divide by ~0
    xx = 1.f; xy = 0.f; xz = 0.f;
  } else {
    xx /= xlen; xy /= xlen; xz /= xlen;
  }

  // yaxis = cross(zaxis, xaxis)
  const float yx = zy * xz - zz * xy;
  const float yy = zz * xx - zx * xz;
  const float yz = zx * xy - zy * xx;

  m[0] = xx; m[4] = xy; m[8]  = xz; m[12] = -(xx * eyeX + xy * eyeY + xz * eyeZ);
  m[1] = yx; m[5] = yy; m[9]  = yz; m[13] = -(yx * eyeX + yy * eyeY + yz * eyeZ);
  m[2] = zx; m[6] = zy; m[10] = zz; m[14] = -(zx * eyeX + zy * eyeY + zz * eyeZ);
  m[3] = 0.f; m[7] = 0.f; m[11] = 0.f; m[15] = 1.f;
}

// --- what every shape needs to draw through the 3D pipelines: the
// vertex layouts and uniform block (must match the MSL structs in
// jet_win.mm byte-for-byte - plain float arrays are tightly packed,
// matching the MSL side's packed_float2/3), plus one call that fills
// the uniforms from the window's current chain state.
typedef struct { float pos[3]; float normal[3]; float color[3]; } JetVertex3D;
typedef struct { float pos[3]; float normal[3]; float uv[2]; }    JetVertex3DTex;
typedef struct {
  float model[16], view[16], projection[16];
  float lightDir[4];    // w: 1 = unlit (flat shapes), 0 = lit by the window light
  float lightColor[4];  // w unused
  float tint[4];        // chain color (jet_color); modulates the texture
} JetUniforms3D;

static inline void jet_fill_uniforms3d(JetUniforms3D *u, bool unlit)
{
  jet_win_get_transform3d(u->model);
  jet_win_get_view(u->view);
  jet_win_get_projection(u->projection);
  jet_win_get_light(u->lightDir, u->lightColor);
  u->lightDir[3] = unlit ? 1.f : 0.f;
  u->lightColor[3] = 0.f;
  jet_win_get_color(u->tint);
}

typedef struct {
  JetPipeline    pipeline;
  const void    *vertices;      // copied by the window (max 4096 bytes), or...
  size_t         vertexBytes;
  id<MTLBuffer>  vertexBuffer;   // ...a persistent buffer the window only references
  size_t         vertexBufferOffset;
  unsigned int   vertexCount;
  id<MTLTexture> texture;        // TEXTURED3D only
  JetUniforms3D  uniforms;
} JetDrawDesc;

// records one draw into the active window's frame. Returns 0 (and
// draws nothing) if no frame is in progress or the desc is invalid.
extern "C" int jet_win_submit_draw(const JetDrawDesc *desc);

#endif  // for header file
