/* ------------------------------------------------------------------
 * jet_triangle - a minimal "shape object" for the jet_win render
 * chain: on a bang (sent by jet_head), records a triangle in the chain
 * color (see jet_color) as a draw command for whichever jet_win is
 * currently mid-frame (jet_shared.h's jet_win_submit_draw, resolved
 * across bundles at load time - same trick as pix_* objects reaching
 * into Gem); the window draws it at the end of the frame. Always flat-colored and unlit (unlike jet_rectangle, it
 * doesn't sample a bound texture). Like jet_rectangle it is real 3D
 * geometry in the XY plane: it follows the chain's model transform
 * (including Z) and is depth-tested (see jet_depth).
 *
 * [jet_triangle <size>]
 *   size   HALF the base width and the height-above-center: the
 *          apex is at (0, size), the base corners at (+-size, -size).
 *          Default 1.
 * Inlets, Gem-style: left = the chain (bang, plus "size s"), right =
 * size (stores only). Centered on the origin - move it with
 * jet_translateXYZ. The bang is forwarded out of the outlet after
 * drawing.
 * ------------------------------------------------------------------
 */

#import <Metal/Metal.h>

#include "m_pd.h"
#include "jet_shared.h"

#include <string.h>

static t_class *jet_triangle_class;

typedef struct _jet_triangle {
  t_object  x_obj;
  t_outlet *x_outlet;
  t_float   x_size;        // Gem units
} t_jet_triangle;

static void jet_triangle_bang(t_jet_triangle *x)
{
  if(!jet_win_frame_active()) {
    return;  // no jet_win mid-frame right now - just skip quietly
  }

  JetDrawDesc d;
  memset(&d, 0, sizeof(d));
  jet_fill_uniforms3d(&d.uniforms, true);  // flat shapes are unlit

  const float s = x->x_size;
  const float rawX[3] = { 0.f,  -s, s };
  const float rawY[3] = { s,    -s, -s };
  JetVertex3D verts[3];
  for(int i = 0; i < 3; i++) {
    verts[i].pos[0] = rawX[i]; verts[i].pos[1] = rawY[i]; verts[i].pos[2] = 0.f;
    verts[i].normal[0] = 0.f; verts[i].normal[1] = 0.f; verts[i].normal[2] = 1.f;
    memcpy(verts[i].color, d.uniforms.tint, 3 * sizeof(float));
  }

  d.pipeline = JET_PIPE_FLAT3D;
  d.vertices = verts;
  d.vertexBytes = sizeof(verts);
  d.vertexCount = 3;
  jet_win_submit_draw(&d);
  outlet_bang(x->x_outlet);
}

static void jet_triangle_size(t_jet_triangle *x, t_floatarg s)
{
  x->x_size = s;
}

static void *jet_triangle_new(t_symbol *s, int argc, t_atom *argv)
{
  t_jet_triangle *x = (t_jet_triangle *)pd_new(jet_triangle_class);
  (void)s;

  x->x_size = (argc >= 1) ? atom_getfloatarg(0, argc, argv) : 1.f;
  x->x_outlet = outlet_new(&x->x_obj, &s_bang);
  floatinlet_new(&x->x_obj, &x->x_size);

  return (void *)x;
}

extern "C" void jet_triangle_setup(void)
{
  jet_triangle_class = class_new(gensym("jet_triangle"),
                                   (t_newmethod)jet_triangle_new, 0,
                                   sizeof(t_jet_triangle), CLASS_DEFAULT,
                                   A_GIMME, 0);
  class_addbang(jet_triangle_class, jet_triangle_bang);
  class_addmethod(jet_triangle_class, (t_method)jet_triangle_size,
                  gensym("size"), A_FLOAT, 0);
}
