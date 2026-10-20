/* ------------------------------------------------------------------
 * jet_square - a square, like Gem's [square]: the same flat shape as
 * jet_rectangle with one size for both directions. Texture-aware (a
 * texture that is current is drawn on it, tinted by the chain colour),
 * otherwise flat in the chain colour (jet_color); unlit, real 3D
 * geometry in the XY plane, centred on the chain's origin.
 *
 * [jet_square <halfsize>]
 *   halfsize   HALF the side length, as in Gem - [jet_square 2] is 4 units
 *              wide and 4 tall. Default 1.
 * Inlets: the chain (bang, plus "size s"), and the half size (stores
 * only; drawing happens on the chain's bang). The bang is forwarded.
 * ------------------------------------------------------------------
 */

#import <Metal/Metal.h>

#include "m_pd.h"
#include "jet_shared.h"
#include "jet_quad.h"

static t_class *jet_square_class;

typedef struct _jet_square {
  t_object  x_obj;
  t_outlet *x_outlet;
  t_float   x_size;
} t_jet_square;

static void jet_square_bang(t_jet_square *x)
{
  jet_quad_draw(x->x_size, x->x_size, false);
  outlet_bang(x->x_outlet);
}

static void jet_square_size(t_jet_square *x, t_floatarg s)
{
  x->x_size = s;
}

static void *jet_square_new(t_symbol *s, int argc, t_atom *argv)
{
  t_jet_square *x = (t_jet_square *)pd_new(jet_square_class);
  (void)s;
  x->x_size = (argc >= 1) ? atom_getfloat(argv) : 1.f;
  x->x_outlet = outlet_new(&x->x_obj, &s_bang);
  floatinlet_new(&x->x_obj, &x->x_size);
  return (void *)x;
}

extern "C" void jet_square_setup(void)
{
  jet_square_class = class_new(gensym("jet_square"),
                               (t_newmethod)jet_square_new, 0,
                               sizeof(t_jet_square), CLASS_DEFAULT,
                               A_GIMME, 0);
  class_addbang(jet_square_class, jet_square_bang);
  class_addmethod(jet_square_class, (t_method)jet_square_size, gensym("size"), A_FLOAT, 0);
}
