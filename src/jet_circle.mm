/* ------------------------------------------------------------------
 * jet_circle - a filled circle, like Gem's [circle], but with a smooth
 * edge at any size: it is a quad whose pixel shader cuts out the disc and
 * fades the last pixel (no polygon corners). Texture-aware (a current
 * texture fills the disc, tinted by the chain colour), otherwise flat in
 * the chain colour (jet_color); unlit, centred on the chain's origin, in
 * the XY plane - so it can be moved, turned and scaled with the XYZ
 * objects like every shape (scaling x and y differently makes an ellipse).
 *
 * [jet_circle <radius>]   default 1.
 * Inlets: the chain (bang, plus "size r"), and the radius (stores only).
 * The bang is forwarded.
 * ------------------------------------------------------------------
 */

#import <Metal/Metal.h>

#include "m_pd.h"
#include "jet_shared.h"
#include "jet_quad.h"

static t_class *jet_circle_class;

typedef struct _jet_circle {
  t_object  x_obj;
  t_outlet *x_outlet;
  t_float   x_radius;
} t_jet_circle;

static void jet_circle_bang(t_jet_circle *x)
{
  jet_quad_draw(x->x_radius, x->x_radius, true);
  outlet_bang(x->x_outlet);
}

static void jet_circle_size(t_jet_circle *x, t_floatarg r)
{
  x->x_radius = r;
}

static void *jet_circle_new(t_symbol *s, int argc, t_atom *argv)
{
  t_jet_circle *x = (t_jet_circle *)pd_new(jet_circle_class);
  (void)s;
  x->x_radius = (argc >= 1) ? atom_getfloat(argv) : 1.f;
  x->x_outlet = outlet_new(&x->x_obj, &s_bang);
  floatinlet_new(&x->x_obj, &x->x_radius);
  return (void *)x;
}

extern "C" void jet_circle_setup(void)
{
  jet_circle_class = class_new(gensym("jet_circle"),
                               (t_newmethod)jet_circle_new, 0,
                               sizeof(t_jet_circle), CLASS_DEFAULT,
                               A_GIMME, 0);
  class_addbang(jet_circle_class, jet_circle_bang);
  class_addmethod(jet_circle_class, (t_method)jet_circle_size, gensym("size"), A_FLOAT, 0);
}
