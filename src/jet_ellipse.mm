/* ------------------------------------------------------------------
 * jet_ellipse - a filled ellipse with a smooth edge (see jet_circle for
 * how). Texture-aware, flat in the chain colour otherwise; unlit, centred
 * on the chain's origin, in the XY plane.
 *
 * [jet_ellipse <radiusx> <radiusy>]
 *   The two half axes, default 1 1. One argument makes a circle.
 * Inlets: the chain (bang, plus "size rx ry" / "size r"), radius x and
 * radius y (both store only). The bang is forwarded.
 * ------------------------------------------------------------------
 */

#import <Metal/Metal.h>

#include "m_pd.h"
#include "jet_shared.h"
#include "jet_quad.h"

static t_class *jet_ellipse_class;

typedef struct _jet_ellipse {
  t_object  x_obj;
  t_outlet *x_outlet;
  t_float   x_rx, x_ry;
} t_jet_ellipse;

static void jet_ellipse_bang(t_jet_ellipse *x)
{
  jet_quad_draw(x->x_rx, x->x_ry, true);
  outlet_bang(x->x_outlet);
}

static void jet_ellipse_size(t_jet_ellipse *x, t_symbol *s, int argc, t_atom *argv)
{
  (void)s;
  if(argc >= 1) {
    x->x_rx = x->x_ry = atom_getfloat(argv);   // one value = a circle
  }
  if(argc >= 2) {
    x->x_ry = atom_getfloat(argv + 1);
  }
}

static void *jet_ellipse_new(t_symbol *s, int argc, t_atom *argv)
{
  t_jet_ellipse *x = (t_jet_ellipse *)pd_new(jet_ellipse_class);
  x->x_rx = x->x_ry = 1.f;
  jet_ellipse_size(x, s, argc, argv);
  x->x_outlet = outlet_new(&x->x_obj, &s_bang);
  floatinlet_new(&x->x_obj, &x->x_rx);
  floatinlet_new(&x->x_obj, &x->x_ry);
  return (void *)x;
}

extern "C" void jet_ellipse_setup(void)
{
  jet_ellipse_class = class_new(gensym("jet_ellipse"),
                                (t_newmethod)jet_ellipse_new, 0,
                                sizeof(t_jet_ellipse), CLASS_DEFAULT,
                                A_GIMME, 0);
  class_addbang(jet_ellipse_class, jet_ellipse_bang);
  class_addlist(jet_ellipse_class, (t_method)jet_ellipse_size);
  class_addmethod(jet_ellipse_class, (t_method)jet_ellipse_size, gensym("size"), A_GIMME, 0);
}
