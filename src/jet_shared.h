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
 *    jet_win_beginChain): the 2D and 3D model transforms, the current
 *    texture, and the encoder's depth-stencil state. Nothing a chain
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
 * Rule for anything that draws: set every piece of encoder state you
 * depend on explicitly (pipeline, depth-stencil, textures, buffers)
 * instead of assuming what an earlier draw left behind - a chain can
 * contain 2D and 3D shapes in any order.
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

// the render encoder for the frame currently being built, or nil if
// no jet_win is mid-frame right now. only meaningful while handling
// a "render" bang sent from jet_win's per-frame chain trigger.
id<MTLRenderCommandEncoder> jet_win_current_encoder(void);

// the two shared pipelines (flat per-vertex color / texture-sampled)
// every shape object picks between, rather than building its own.
id<MTLRenderPipelineState> jet_win_flat_pipeline(void);
id<MTLRenderPipelineState> jet_win_textured_pipeline(void);
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

// the current 2D affine transform (row-major 3x3, homogeneous
// coords), like Gem's modelview matrix - jet_win resets it to
// identity right before banging each jet_head, so it only
// accumulates within a single chain, never leaks into the next one.
// jet_translateXYZ/jet_rotateXYZ/jet_scaleXYZ multiply their own
// operation onto it; jet_triangle/jet_rectangle apply it (on the
// CPU, before building their vertex buffers) to their own positions.
void jet_win_get_transform(float outMat9[9]);
void jet_win_set_transform(const float mat9[9]);

// --- 2D units: Gem units. The window is 8 units tall (y runs -4..+4)
// and as wide as its aspect ratio makes it (x runs -4*aspect..
// +4*aspect), so on an 800x600 window [jet_rectangle 0 0 5.33 4 ...]
// fills the whole picture, exactly as [rectangle 5.33 4] does in Gem.
// 2D shape objects work in these units; the 2D transform above is in
// them too. The default 3D camera (z=4, fov 90) is chosen so the z=0
// plane is also 8 units tall - 2D and 3D share one scale.
//
// width/height of the window's actual drawable (not the last "dimen"
// message - the user can drag-resize it), so shapes stay undistorted.
float jet_win_get_aspect(void);

static const float JET_UNITS_HALF_HEIGHT = 4.f;

// converts a point in 2D Gem units (after the 2D transform) to the
// normalized device coordinates the 2D pipelines expect
static inline void jet_units_to_ndc(float x, float y, float *nx, float *ny)
{
  *nx = x / (JET_UNITS_HALF_HEIGHT * jet_win_get_aspect());
  *ny = y / JET_UNITS_HALF_HEIGHT;
}

// --- 3D: additive to everything above, existing 2D objects/pipelines
// are completely untouched. Right-handed, Y-up world space, column-
// major 4x4 matrices (Metal's own native convention, so these upload
// straight into an MSL float4x4 with no transpose). Model transform
// works exactly like the 2D one: jet_win resets it to identity
// before each jet_head chain, jet_translate3d/rotate3d/scale3d
// multiply their own op onto it, 3D shape objects (jet_cube, later
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

// the two 3D pipelines (flat per-vertex color / texture-sampled),
// mirroring jet_win_flat_pipeline/textured_pipeline above but with
// depth testing and a position+normal(+uv) vertex layout - see
// jet_cube.mm for the exact vertex structs each expects.
id<MTLRenderPipelineState> jet_win_flat3d_pipeline(void);
id<MTLRenderPipelineState> jet_win_textured3d_pipeline(void);
id<MTLDepthStencilState>   jet_win_depth_state(void);

// depth-stencil state that always passes and never writes - the 2D
// pipelines share ONE on-screen encoder with any 3D content this
// frame (see the file header comment on multi-chain rendering), and
// setDepthStencilState: persists on an encoder across draw calls
// until changed again. Without explicitly setting THIS before every
// 2D draw, a 2D shape drawn after a 3D one earlier in the same frame
// would silently inherit the 3D depth test and could vanish behind
// it. jet_triangle/jet_rectangle set this immediately before
// their own draw calls; 3D shape objects use jet_win_depth_state()
// above instead.
id<MTLDepthStencilState>   jet_win_no_depth_state(void);

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

// small 3x3 (row-major) matrix helpers for the 2D transform above -
// header-only, no cross-bundle symbol needed for plain math.
static inline void jet_mat3_identity(float m[9])
{
  m[0] = 1; m[1] = 0; m[2] = 0;
  m[3] = 0; m[4] = 1; m[5] = 0;
  m[6] = 0; m[7] = 0; m[8] = 1;
}

// out = a * b (row-major); safe to alias out with a or b
static inline void jet_mat3_mul(const float a[9], const float b[9], float out[9])
{
  float r[9];
  for(int row = 0; row < 3; row++) {
    for(int col = 0; col < 3; col++) {
      r[row * 3 + col] = a[row * 3 + 0] * b[0 * 3 + col] +
                         a[row * 3 + 1] * b[1 * 3 + col] +
                         a[row * 3 + 2] * b[2 * 3 + col];
    }
  }
  for(int i = 0; i < 9; i++) {
    out[i] = r[i];
  }
}

// applies m to the 2D point (x,y) (homogeneous z=1)
static inline void jet_mat3_apply(const float m[9], float x, float y,
                                    float *outX, float *outY)
{
  *outX = m[0] * x + m[1] * y + m[2];
  *outY = m[3] * x + m[4] * y + m[5];
}

#endif  // for header file
