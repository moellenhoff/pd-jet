/* ------------------------------------------------------------------
 * jet_rectangle - a "shape object" for the jet_win render chain,
 * like jet_triangle but with independently settable width/height,
 * and - unlike jet_triangle - texture-aware: if jet_texture has
 * bound a texture this frame (jet_win_current_texture()), draws a
 * textured quad sampling it; otherwise falls back to a flat-colored
 * quad. Mirrors how Gem's [square] renders textured or flat
 * depending on whether a [pix_texture] preceded it in the chain.
 *
 * [jet_rectangle <x> <y> <halfwidth> <halfheight> <r> <g> <b>]
 *   x y           center of the rectangle
 *   halfwidth/    HALF the size - the rectangle reaches halfwidth to
 *   halfheight    the left AND right of its center (same convention
 *                 as Gem), so [jet_rectangle 0 0 5.33 4] is 10.67 x 8
 *   r g b         flat color, 0..1; ignored while a texture is bound
 * Units are Gem units: the window is 8 units tall (y = -4..+4) and
 * 8*aspect wide, so on an 800x600 window [jet_rectangle 0 0 5.33 4]
 * fills the whole picture. Messages: "pos x y", "size halfw halfh",
 * "color r g b". Position and size go through the chain's 2D
 * transform (jet_translateXYZ/rotateXYZ/scaleXYZ) first.
 * ------------------------------------------------------------------
 */

#import <Metal/Metal.h>

#include "m_pd.h"
#include "jet_shared.h"

static t_class *jet_rectangle_class;

typedef struct { float pos[2]; float color[4]; } FlatVertex;
typedef struct { float pos[2]; float uv[2]; }    TexVertex;

typedef struct _jet_rectangle {
  t_object x_obj;
  float    x_cx, x_cy;     // center, in Gem units (window is 8 units tall, see jet_shared.h)
  float    x_w, x_h;       // half-width / half-height, same units
  float    x_r, x_g, x_b;
} t_jet_rectangle;

static void jet_rectangle_bang(t_jet_rectangle *x)
{
  id<MTLRenderCommandEncoder> enc = jet_win_current_encoder();
  if(!enc) {
    return;  // no jet_win mid-frame right now - just skip quietly
  }
  // this frame's shared on-screen encoder may have already had a 3D
  // depth-stencil state set by an earlier chain this same frame (see
  // jet_shared.h's comment on jet_win_no_depth_state) - reset it
  // explicitly so this 2D draw is never accidentally depth-tested
  id<MTLDepthStencilState> noDepth = jet_win_no_depth_state();
  if(noDepth) {
    [enc setDepthStencilState:noDepth];
  }

  const float cx = x->x_cx, cy = x->x_cy, w = x->x_w, h = x->x_h;
  id<MTLTexture> tex = jet_win_current_texture();

  float mat[9];
  jet_win_get_transform(mat);
  // 4 corners, transformed once, reused for either vertex layout
  // below: [0]=top-left [1]=bottom-left [2]=bottom-right [3]=top-right
  float cxr[4], cyr[4];
  const float rawX[4] = { cx - w, cx - w, cx + w, cx + w };
  const float rawY[4] = { cy + h, cy - h, cy - h, cy + h };
  for(int i = 0; i < 4; i++) {
    float ux, uy;
    jet_mat3_apply(mat, rawX[i], rawY[i], &ux, &uy);
    jet_units_to_ndc(ux, uy, &cxr[i], &cyr[i]);
  }

  if(tex) {
    id<MTLRenderPipelineState> pipeline = jet_win_textured_pipeline();
    if(!pipeline) {
      return;
    }
    TexVertex verts[6] = {
      { { cxr[0], cyr[0] }, { 0.f, 0.f } },
      { { cxr[1], cyr[1] }, { 0.f, 1.f } },
      { { cxr[2], cyr[2] }, { 1.f, 1.f } },
      { { cxr[0], cyr[0] }, { 0.f, 0.f } },
      { { cxr[2], cyr[2] }, { 1.f, 1.f } },
      { { cxr[3], cyr[3] }, { 1.f, 0.f } },
    };
    [enc setRenderPipelineState:pipeline];
    [enc setVertexBytes:verts length:sizeof(verts) atIndex:0];
    [enc setFragmentTexture:tex atIndex:0];
    [enc setFragmentSamplerState:jet_win_sampler() atIndex:0];
    [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
  } else {
    id<MTLRenderPipelineState> pipeline = jet_win_flat_pipeline();
    if(!pipeline) {
      return;
    }
    const float col[4] = { x->x_r, x->x_g, x->x_b, 1.0f };
    FlatVertex verts[6] = {
      { { cxr[0], cyr[0] }, { col[0], col[1], col[2], col[3] } },
      { { cxr[1], cyr[1] }, { col[0], col[1], col[2], col[3] } },
      { { cxr[2], cyr[2] }, { col[0], col[1], col[2], col[3] } },
      { { cxr[0], cyr[0] }, { col[0], col[1], col[2], col[3] } },
      { { cxr[2], cyr[2] }, { col[0], col[1], col[2], col[3] } },
      { { cxr[3], cyr[3] }, { col[0], col[1], col[2], col[3] } },
    };
    [enc setRenderPipelineState:pipeline];
    [enc setVertexBytes:verts length:sizeof(verts) atIndex:0];
    [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
  }
}

static void jet_rectangle_pos(t_jet_rectangle *x, t_floatarg cx, t_floatarg cy)
{
  x->x_cx = cx;
  x->x_cy = cy;
}
static void jet_rectangle_size(t_jet_rectangle *x, t_floatarg w, t_floatarg h)
{
  x->x_w = w;
  x->x_h = h;
}
static void jet_rectangle_color(t_jet_rectangle *x, t_floatarg r,
                                  t_floatarg g, t_floatarg b)
{
  x->x_r = r;
  x->x_g = g;
  x->x_b = b;
}

static void *jet_rectangle_new(t_symbol *s, int argc, t_atom *argv)
{
  t_jet_rectangle *x = (t_jet_rectangle *)pd_new(jet_rectangle_class);
  (void)s;

  x->x_cx = (argc >= 1) ? atom_getfloatarg(0, argc, argv) : 0.f;
  x->x_cy = (argc >= 2) ? atom_getfloatarg(1, argc, argv) : 0.f;
  x->x_w = (argc >= 3) ? atom_getfloatarg(2, argc, argv) : 1.6f;
  x->x_h = (argc >= 4) ? atom_getfloatarg(3, argc, argv) : 1.6f;
  x->x_r = (argc >= 5) ? atom_getfloatarg(4, argc, argv) : 0.85f;
  x->x_g = (argc >= 6) ? atom_getfloatarg(5, argc, argv) : 0.47f;
  x->x_b = (argc >= 7) ? atom_getfloatarg(6, argc, argv) : 0.34f;

  return (void *)x;
}

extern "C" void jet_rectangle_setup(void)
{
  jet_rectangle_class = class_new(gensym("jet_rectangle"),
                                    (t_newmethod)jet_rectangle_new, 0,
                                    sizeof(t_jet_rectangle), CLASS_DEFAULT,
                                    A_GIMME, 0);
  class_addbang(jet_rectangle_class, jet_rectangle_bang);
  class_addmethod(jet_rectangle_class, (t_method)jet_rectangle_pos,
                  gensym("pos"), A_FLOAT, A_FLOAT, 0);
  class_addmethod(jet_rectangle_class, (t_method)jet_rectangle_size,
                  gensym("size"), A_FLOAT, A_FLOAT, 0);
  class_addmethod(jet_rectangle_class, (t_method)jet_rectangle_color,
                  gensym("color"), A_FLOAT, A_FLOAT, A_FLOAT, 0);
}
