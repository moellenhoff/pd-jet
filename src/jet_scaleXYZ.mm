/* ------------------------------------------------------------------
 * jet_scaleXYZ - like Gem's [scaleXYZ]: one scale object for the
 * whole chain, X/Y/Z all at once, instead of separate 2D
 * (jet_scale) and 3D (jet_scale3d) objects. Updates BOTH
 * transforms every bang - see jet_rotateXYZ.mm's header comment
 * for the full reasoning (identical here): the 3D 4x4 model transform
 * gets the full X/Y/Z scale, the 2D 3x3 transform gets just X/Y (Z
 * has no meaning on a flat plane), so the same object works whether
 * a 2D or 3D shape follows it in the chain. A single creation arg (or
 * a single "set" arg) scales all three axes uniformly, matching
 * jet_scale/jet_scale3d's own single-argument convention.
 *
 * Three inlets, Gem-style: X/Y/Z are ALL hot - a float to any one of
 * them updates that axis and immediately recomputes+forwards, same
 * as a bang (matches real Gem, where every scaleXYZ inlet is hot).
 * Unlike creation args/"set", a bare float to any one inlet only
 * ever sets that one axis (not a uniform scale) - each inlet
 * consistently controls just its own axis.
 * ------------------------------------------------------------------
 */

#include "m_pd.h"
#include "jet_shared.h"

static t_class *jet_scaleXYZ_class;

typedef struct _jet_scaleXYZ {
  t_object  x_obj;
  t_outlet *x_outlet;
  float     x_sx, x_sy, x_sz;
} t_jet_scaleXYZ;

static void jet_scaleXYZ_bang(t_jet_scaleXYZ *x)
{
  float cur3d[16];
  jet_win_get_transform3d(cur3d);
  float op3d[16];
  jet_mat4_scale(x->x_sx, x->x_sy, x->x_sz, op3d);
  float result3d[16];
  jet_mat4_mul(cur3d, op3d, result3d);
  jet_win_set_transform3d(result3d);

  float cur2d[9];
  jet_win_get_transform(cur2d);
  float op2d[9] = { x->x_sx, 0,       0,
                    0,       x->x_sy, 0,
                    0,       0,       1 };
  float result2d[9];
  jet_mat3_mul(cur2d, op2d, result2d);
  jet_win_set_transform(result2d);

  outlet_bang(x->x_outlet);
}

static void jet_scaleXYZ_applyArgs(t_jet_scaleXYZ *x, int argc, t_atom *argv)
{
  if(argc >= 3) {
    x->x_sx = atom_getfloatarg(0, argc, argv);
    x->x_sy = atom_getfloatarg(1, argc, argv);
    x->x_sz = atom_getfloatarg(2, argc, argv);
  } else if(argc >= 1) {
    x->x_sx = x->x_sy = x->x_sz = atom_getfloatarg(0, argc, argv);
  }
}

static void jet_scaleXYZ_float(t_jet_scaleXYZ *x, t_floatarg f)
{
  x->x_sx = f;  // inlet 0 alone only sets X - see the file header comment for why
  jet_scaleXYZ_bang(x);
}

static void jet_scaleXYZ_inY(t_jet_scaleXYZ *x, t_floatarg f)
{
  x->x_sy = f;
  jet_scaleXYZ_bang(x);
}

static void jet_scaleXYZ_inZ(t_jet_scaleXYZ *x, t_floatarg f)
{
  x->x_sz = f;
  jet_scaleXYZ_bang(x);
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

  // hot Y/Z inlets - see jet_rotateXYZ.mm's constructor comment
  inlet_new(&x->x_obj, &x->x_obj.ob_pd, &s_float, gensym("iny"));
  inlet_new(&x->x_obj, &x->x_obj.ob_pd, &s_float, gensym("inz"));

  return (void *)x;
}

extern "C" void jet_scaleXYZ_setup(void)
{
  jet_scaleXYZ_class = class_new(gensym("jet_scaleXYZ"),
                                   (t_newmethod)jet_scaleXYZ_new, 0,
                                   sizeof(t_jet_scaleXYZ), CLASS_DEFAULT,
                                   A_GIMME, 0);
  class_addbang(jet_scaleXYZ_class, jet_scaleXYZ_bang);
  class_addfloat(jet_scaleXYZ_class, jet_scaleXYZ_float);
  class_addmethod(jet_scaleXYZ_class, (t_method)jet_scaleXYZ_inY,
                  gensym("iny"), A_FLOAT, 0);
  class_addmethod(jet_scaleXYZ_class, (t_method)jet_scaleXYZ_inZ,
                  gensym("inz"), A_FLOAT, 0);
  class_addmethod(jet_scaleXYZ_class, (t_method)jet_scaleXYZ_set,
                  gensym("set"), A_GIMME, 0);
}
