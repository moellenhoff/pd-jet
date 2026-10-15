/* ------------------------------------------------------------------
 * jet_translateXYZ - like Gem's [translateXYZ]: one translate object for the whole chain, X/Y/Z at once.
 * Multiplies its operation onto the chain's model transform (see
 * jet_shared.h), then forwards the bang. Shapes and 3D objects after
 * it in the chain pick the result up.
 *
 * Inlets, Gem-style: the LEFT inlet takes the chain (bang) and the
 * messages; the three inlets after it are the X, Y and Z values. They
 * only store - nothing is recomputed until the next bang arrives,
 * and since jet_win bangs the chain every frame, a changed value
 * shows up in the next picture. "set x y z" stores all three at once
 * (units in Gem units).
 * ------------------------------------------------------------------
 */

#include "m_pd.h"
#include "jet_shared.h"

static t_class *jet_translateXYZ_class;

typedef struct _jet_translateXYZ {
  t_object  x_obj;
  t_outlet *x_outlet;
  t_float   x_tx, x_ty, x_tz;
} t_jet_translateXYZ;

static void jet_translateXYZ_bang(t_jet_translateXYZ *x)
{
  float op[16];
  jet_mat4_translation(x->x_tx, x->x_ty, x->x_tz, op);
  float cur[16], result[16];
  jet_win_get_transform3d(cur);
  jet_mat4_mul(cur, op, result);
  jet_win_set_transform3d(result);

  outlet_bang(x->x_outlet);
}

static void jet_translateXYZ_applyArgs(t_jet_translateXYZ *x, int argc, t_atom *argv)
{
  if(argc >= 1) {
    x->x_tx = atom_getfloatarg(0, argc, argv);
  }
  if(argc >= 2) {
    x->x_ty = atom_getfloatarg(1, argc, argv);
  }
  if(argc >= 3) {
    x->x_tz = atom_getfloatarg(2, argc, argv);
  }
}

static void jet_translateXYZ_set(t_jet_translateXYZ *x, t_symbol *s, int argc, t_atom *argv)
{
  (void)s;
  jet_translateXYZ_applyArgs(x, argc, argv);
}

static void *jet_translateXYZ_new(t_symbol *s, int argc, t_atom *argv)
{
  t_jet_translateXYZ *x = (t_jet_translateXYZ *)pd_new(jet_translateXYZ_class);
  (void)s;

  x->x_outlet = outlet_new(&x->x_obj, &s_bang);
  x->x_tx = x->x_ty = x->x_tz = 0.f;
  jet_translateXYZ_applyArgs(x, argc, argv);

  // cold X/Y/Z inlets writing straight into the fields
  floatinlet_new(&x->x_obj, &x->x_tx);
  floatinlet_new(&x->x_obj, &x->x_ty);
  floatinlet_new(&x->x_obj, &x->x_tz);

  return (void *)x;
}

extern "C" void jet_translateXYZ_setup(void)
{
  jet_translateXYZ_class = class_new(gensym("jet_translateXYZ"),
                           (t_newmethod)jet_translateXYZ_new, 0,
                           sizeof(t_jet_translateXYZ), CLASS_DEFAULT,
                           A_GIMME, 0);
  class_addbang(jet_translateXYZ_class, jet_translateXYZ_bang);
  class_addmethod(jet_translateXYZ_class, (t_method)jet_translateXYZ_set,
                  gensym("set"), A_GIMME, 0);
}
