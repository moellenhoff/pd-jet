/* ------------------------------------------------------------------
 * jet_triangle - a minimal "shape object" for the jet_win render
 * chain: on a bang (sent by jet_head), draws a solid-color triangle
 * into whichever jet_win is currently mid-frame, via
 * jet_shared.h's jet_win_current_encoder() - resolved across
 * bundles at load time, same trick as pix_* objects reaching into
 * Gem. Always flat-colored (unlike jet_rectangle, it doesn't
 * sample a bound texture) - it has no device/pipeline of its own,
 * it just uses jet_win's shared flat pipeline.
 * ------------------------------------------------------------------
 */

#import <Metal/Metal.h>

#include "m_pd.h"
#include "jet_shared.h"

static t_class *jet_triangle_class;

typedef struct { float pos[2]; float color[4]; } JetVertex;

typedef struct _jet_triangle {
  t_object x_obj;
  float    x_cx, x_cy;     // center, in Gem units (window is 8 units tall, see jet_shared.h)
  float    x_size;
  float    x_r, x_g, x_b;
} t_jet_triangle;

static void jet_triangle_bang(t_jet_triangle *x)
{
  id<MTLRenderCommandEncoder> enc = jet_win_current_encoder();
  id<MTLRenderPipelineState> pipeline = jet_win_flat_pipeline();
  if(!enc || !pipeline) {
    return;  // no jet_win mid-frame right now - just skip quietly
  }

  const float cx = x->x_cx, cy = x->x_cy, s = x->x_size;
  float mat[9];
  jet_win_get_transform(mat);

  JetVertex verts[3];
  const float rawX[3] = { cx,     cx - s, cx + s };
  const float rawY[3] = { cy + s, cy - s, cy - s };
  for(int i = 0; i < 3; i++) {
    float ux, uy;
    jet_mat3_apply(mat, rawX[i], rawY[i], &ux, &uy);
    jet_units_to_ndc(ux, uy, &verts[i].pos[0], &verts[i].pos[1]);
    verts[i].color[0] = x->x_r;
    verts[i].color[1] = x->x_g;
    verts[i].color[2] = x->x_b;
    verts[i].color[3] = 1.0f;
  }

  [enc setRenderPipelineState:pipeline];
  // this frame's shared on-screen encoder may have already had a 3D
  // depth-stencil state set by an earlier chain this same frame (see
  // jet_shared.h's comment on jet_win_no_depth_state) - reset it
  // explicitly so this 2D draw is never accidentally depth-tested
  id<MTLDepthStencilState> noDepth = jet_win_no_depth_state();
  if(noDepth) {
    [enc setDepthStencilState:noDepth];
  }
  [enc setVertexBytes:verts length:sizeof(verts) atIndex:0];
  [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
}

static void jet_triangle_pos(t_jet_triangle *x, t_floatarg cx, t_floatarg cy)
{
  x->x_cx = cx;
  x->x_cy = cy;
}
static void jet_triangle_size(t_jet_triangle *x, t_floatarg s)
{
  x->x_size = s;
}
static void jet_triangle_color(t_jet_triangle *x, t_floatarg r,
                                 t_floatarg g, t_floatarg b)
{
  x->x_r = r;
  x->x_g = g;
  x->x_b = b;
}

static void *jet_triangle_new(t_symbol *s, int argc, t_atom *argv)
{
  t_jet_triangle *x = (t_jet_triangle *)pd_new(jet_triangle_class);
  (void)s;

  x->x_cx = (argc >= 1) ? atom_getfloatarg(0, argc, argv) : 0.f;
  x->x_cy = (argc >= 2) ? atom_getfloatarg(1, argc, argv) : 0.f;
  x->x_size = (argc >= 3) ? atom_getfloatarg(2, argc, argv) : 1.6f;
  x->x_r = (argc >= 4) ? atom_getfloatarg(3, argc, argv) : 0.85f;
  x->x_g = (argc >= 5) ? atom_getfloatarg(4, argc, argv) : 0.47f;
  x->x_b = (argc >= 6) ? atom_getfloatarg(5, argc, argv) : 0.34f;

  return (void *)x;
}

extern "C" void jet_triangle_setup(void)
{
  jet_triangle_class = class_new(gensym("jet_triangle"),
                                   (t_newmethod)jet_triangle_new, 0,
                                   sizeof(t_jet_triangle), CLASS_DEFAULT,
                                   A_GIMME, 0);
  class_addbang(jet_triangle_class, jet_triangle_bang);
  class_addmethod(jet_triangle_class, (t_method)jet_triangle_pos,
                  gensym("pos"), A_FLOAT, A_FLOAT, 0);
  class_addmethod(jet_triangle_class, (t_method)jet_triangle_size,
                  gensym("size"), A_FLOAT, 0);
  class_addmethod(jet_triangle_class, (t_method)jet_triangle_color,
                  gensym("color"), A_FLOAT, A_FLOAT, A_FLOAT, 0);
}
