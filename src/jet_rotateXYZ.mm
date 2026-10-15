/* ------------------------------------------------------------------
 * jet_rotateXYZ - like Gem's [rotateXYZ]: one rotate object for the whole chain, X/Y/Z degrees at once
 * (applied in the order X, then Y, then Z).
 * Multiplies its operation onto the chain's model transform (see
 * jet_shared.h), then forwards the bang. Shapes and 3D objects after
 * it in the chain pick the result up.
 *
 * Inlets, Gem-style: the LEFT inlet takes the chain (bang) and the
 * messages; the three inlets after it are the X, Y and Z values. They
 * only store - nothing is recomputed until the next bang arrives,
 * and since jet_win bangs the chain every frame, a changed value
 * shows up in the next picture. "set x y z" stores all three at once
 * (degrees).
 * ------------------------------------------------------------------
 */

#include "m_pd.h"
#include "jet_shared.h"

#include <math.h>

static t_class *jet_rotateXYZ_class;

typedef struct _jet_rotateXYZ {
  t_object  x_obj;
  t_outlet *x_outlet;
  t_float   x_rx, x_ry, x_rz;
} t_jet_rotateXYZ;

static void jet_rotateXYZ_bang(t_jet_rotateXYZ *x)
{
  const float radX = x->x_rx * (float)M_PI / 180.f;
  const float radY = x->x_ry * (float)M_PI / 180.f;
  const float radZ = x->x_rz * (float)M_PI / 180.f;
  float rxm[16], rym[16], rzm[16], ryx[16], op[16];
  jet_mat4_rotationX(radX, rxm);
  jet_mat4_rotationY(radY, rym);
  jet_mat4_rotationZ(radZ, rzm);
  jet_mat4_mul(rym, rxm, ryx);
  jet_mat4_mul(rzm, ryx, op);
  float cur[16], result[16];
  jet_win_get_transform3d(cur);
  jet_mat4_mul(cur, op, result);
  jet_win_set_transform3d(result);

  outlet_bang(x->x_outlet);
}

static void jet_rotateXYZ_applyArgs(t_jet_rotateXYZ *x, int argc, t_atom *argv)
{
  if(argc >= 1) {
    x->x_rx = atom_getfloatarg(0, argc, argv);
  }
  if(argc >= 2) {
    x->x_ry = atom_getfloatarg(1, argc, argv);
  }
  if(argc >= 3) {
    x->x_rz = atom_getfloatarg(2, argc, argv);
  }
}

static void jet_rotateXYZ_set(t_jet_rotateXYZ *x, t_symbol *s, int argc, t_atom *argv)
{
  (void)s;
  jet_rotateXYZ_applyArgs(x, argc, argv);
}

static void *jet_rotateXYZ_new(t_symbol *s, int argc, t_atom *argv)
{
  t_jet_rotateXYZ *x = (t_jet_rotateXYZ *)pd_new(jet_rotateXYZ_class);
  (void)s;

  x->x_outlet = outlet_new(&x->x_obj, &s_bang);
  x->x_rx = x->x_ry = x->x_rz = 0.f;
  jet_rotateXYZ_applyArgs(x, argc, argv);

  // cold X/Y/Z inlets writing straight into the fields
  floatinlet_new(&x->x_obj, &x->x_rx);
  floatinlet_new(&x->x_obj, &x->x_ry);
  floatinlet_new(&x->x_obj, &x->x_rz);

  return (void *)x;
}

extern "C" void jet_rotateXYZ_setup(void)
{
  jet_rotateXYZ_class = class_new(gensym("jet_rotateXYZ"),
                           (t_newmethod)jet_rotateXYZ_new, 0,
                           sizeof(t_jet_rotateXYZ), CLASS_DEFAULT,
                           A_GIMME, 0);
  class_addbang(jet_rotateXYZ_class, jet_rotateXYZ_bang);
  class_addmethod(jet_rotateXYZ_class, (t_method)jet_rotateXYZ_set,
                  gensym("set"), A_GIMME, 0);
}
