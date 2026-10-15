/* ------------------------------------------------------------------
 * jet_scaleXYZ - like Gem's [scaleXYZ]: one scale object for the whole chain, X/Y/Z at once.
 * Multiplies its operation onto the chain's model transform (see
 * jet_shared.h), then forwards the bang. Shapes and 3D objects after
 * it in the chain pick the result up.
 *
 * Inlets, Gem-style: the LEFT inlet takes the chain (bang) and the
 * messages; the three inlets after it are the X, Y and Z values. They
 * only store - nothing is recomputed until the next bang arrives,
 * and since jet_win bangs the chain every frame, a changed value
 * shows up in the next picture. "set x y z" stores all three at once
 * (a single value scales all three uniformly - in the creation argument too).
 * ------------------------------------------------------------------
 */

#include "m_pd.h"
#include "jet_shared.h"

static t_class *jet_scaleXYZ_class;

typedef struct _jet_scaleXYZ {
  t_object  x_obj;
  t_outlet *x_outlet;
  t_float   x_sx, x_sy, x_sz;
} t_jet_scaleXYZ;

static void jet_scaleXYZ_bang(t_jet_scaleXYZ *x)
{
  float op[16];
  jet_mat4_scale(x->x_sx, x->x_sy, x->x_sz, op);
  float cur[16], result[16];
  jet_win_get_transform3d(cur);
  jet_mat4_mul(cur, op, result);
  jet_win_set_transform3d(result);

  outlet_bang(x->x_outlet);
}

static void jet_scaleXYZ_applyArgs(t_jet_scaleXYZ *x, int argc, t_atom *argv)
{
  if(argc >= 3) {
    x->x_sx = atom_getfloatarg(0, argc, argv);
    x->x_sy = atom_getfloatarg(1, argc, argv);
    x->x_sz = atom_getfloatarg(2, argc, argv);
  } else if(argc >= 1) {
    x->x_sx = x->x_sy = x->x_sz = atom_getfloatarg(0, argc, argv);  // one value = uniform
  }
}

static void jet_scaleXYZ_set(t_jet_scaleXYZ *x, t_symbol *s, int argc, t_atom *argv)
{
  (void)s;
  jet_scaleXYZ_applyArgs(x, argc, argv);
}

static void *jet_scaleXYZ_new(t_symbol *s, int argc, t_atom *argv)
{
  t_jet_scaleXYZ *x = (t_jet_scaleXYZ *)pd_new(jet_scaleXYZ_class);
  (void)s;

  x->x_outlet = outlet_new(&x->x_obj, &s_bang);
  x->x_sx = x->x_sy = x->x_sz = 1.f;
  jet_scaleXYZ_applyArgs(x, argc, argv);

  // cold X/Y/Z inlets writing straight into the fields
  floatinlet_new(&x->x_obj, &x->x_sx);
  floatinlet_new(&x->x_obj, &x->x_sy);
  floatinlet_new(&x->x_obj, &x->x_sz);

  return (void *)x;
}

extern "C" void jet_scaleXYZ_setup(void)
{
  jet_scaleXYZ_class = class_new(gensym("jet_scaleXYZ"),
                           (t_newmethod)jet_scaleXYZ_new, 0,
                           sizeof(t_jet_scaleXYZ), CLASS_DEFAULT,
                           A_GIMME, 0);
  class_addbang(jet_scaleXYZ_class, jet_scaleXYZ_bang);
  class_addmethod(jet_scaleXYZ_class, (t_method)jet_scaleXYZ_set,
                  gensym("set"), A_GIMME, 0);
}
