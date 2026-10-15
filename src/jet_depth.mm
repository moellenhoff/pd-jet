/* ------------------------------------------------------------------
 * jet_depth - like Gem's [depth]: switches depth testing on or off
 * for the shapes after it in the chain. Depth testing is ON by
 * default (as in Gem), so shapes hide what lies behind them - a
 * rectangle moved back in Z disappears behind a cube in front of it.
 * Switch it off for flat layered content: shapes then simply paint
 * over each other in the order the chain draws them, which avoids
 * z-fighting between shapes sitting in the same plane.
 *
 * [jet_depth <0|1>]  creation arg, default 1. Left inlet: the chain
 * (bang); right inlet: the on/off value (stores only). Chain-scoped
 * state - every chain starts with depth on, jet_separator restores
 * it afterwards.
 * ------------------------------------------------------------------
 */

#include "m_pd.h"
#include "jet_shared.h"

static t_class *jet_depth_class;

typedef struct _jet_depth {
  t_object  x_obj;
  t_outlet *x_outlet;
  t_float   x_on;
} t_jet_depth;

static void jet_depth_bang(t_jet_depth *x)
{
  jet_win_set_depth(x->x_on != 0.f);
  outlet_bang(x->x_outlet);
}

static void *jet_depth_new(t_symbol *s, int argc, t_atom *argv)
{
  t_jet_depth *x = (t_jet_depth *)pd_new(jet_depth_class);
  (void)s;

  x->x_outlet = outlet_new(&x->x_obj, &s_bang);
  x->x_on = (argc >= 1) ? atom_getfloatarg(0, argc, argv) : 1.f;
  floatinlet_new(&x->x_obj, &x->x_on);

  return (void *)x;
}

extern "C" void jet_depth_setup(void)
{
  jet_depth_class = class_new(gensym("jet_depth"),
                              (t_newmethod)jet_depth_new, 0,
                              sizeof(t_jet_depth), CLASS_DEFAULT,
                              A_GIMME, 0);
  class_addbang(jet_depth_class, jet_depth_bang);
}
