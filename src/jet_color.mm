/* ------------------------------------------------------------------
 * jet_color - like Gem's [color]: sets the chain's current color
 * (RGB, 0..1), then forwards the bang. Every shape after it in the
 * chain draws with that color - as its flat color when it has no
 * texture, as a multiplicative tint when it has one. The color is
 * chain-scoped state (see jet_shared.h): it starts out white in
 * every chain and never leaks into the next one; wrap a branch in
 * jet_separator to keep its color from reaching its siblings.
 *
 * [jet_color <r> <g> <b>]  creation args, default 1 1 1.
 * Inlets, Gem-style: the left one takes the chain (bang); the three
 * after it are red, green and blue. They only store - the chain's
 * next bang applies them. "set r g b" (or a list "r g b") stores all
 * three at once.
 * ------------------------------------------------------------------
 */

#include "m_pd.h"
#include "jet_shared.h"

static t_class *jet_color_class;

typedef struct _jet_color {
  t_object  x_obj;
  t_outlet *x_outlet;
  t_float   x_r, x_g, x_b;
} t_jet_color;

static void jet_color_bang(t_jet_color *x)
{
  const float rgba[4] = { x->x_r, x->x_g, x->x_b, 1.f };
  jet_win_set_color(rgba);
  outlet_bang(x->x_outlet);
}

static void jet_color_set(t_jet_color *x, t_symbol *s, int argc, t_atom *argv)
{
  (void)s;
  if(argc >= 1) {
    x->x_r = atom_getfloatarg(0, argc, argv);
  }
  if(argc >= 2) {
    x->x_g = atom_getfloatarg(1, argc, argv);
  }
  if(argc >= 3) {
    x->x_b = atom_getfloatarg(2, argc, argv);
  }
}

static void *jet_color_new(t_symbol *s, int argc, t_atom *argv)
{
  t_jet_color *x = (t_jet_color *)pd_new(jet_color_class);
  (void)s;

  x->x_outlet = outlet_new(&x->x_obj, &s_bang);
  x->x_r = x->x_g = x->x_b = 1.f;
  jet_color_set(x, s, argc, argv);

  floatinlet_new(&x->x_obj, &x->x_r);
  floatinlet_new(&x->x_obj, &x->x_g);
  floatinlet_new(&x->x_obj, &x->x_b);

  return (void *)x;
}

extern "C" void jet_color_setup(void)
{
  jet_color_class = class_new(gensym("jet_color"),
                              (t_newmethod)jet_color_new, 0,
                              sizeof(t_jet_color), CLASS_DEFAULT,
                              A_GIMME, 0);
  class_addbang(jet_color_class, jet_color_bang);
  class_addlist(jet_color_class, (t_method)jet_color_set);
  class_addmethod(jet_color_class, (t_method)jet_color_set,
                  gensym("set"), A_GIMME, 0);
}
