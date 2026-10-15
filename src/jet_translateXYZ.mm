/* ------------------------------------------------------------------
 * jet_translateXYZ - like Gem's [translateXYZ]: one translate
 * object for the whole chain, X/Y/Z all at once, instead of separate
 * 2D (jet_translate) and 3D (jet_translate3d) objects. Updates
 * BOTH transforms every bang - see jet_rotateXYZ.mm's header
 * comment for the full reasoning (identical here): the 3D 4x4 model
 * transform gets the full X/Y/Z translation, the 2D 3x3 transform
 * gets just X/Y (Z has no meaning on a flat plane), so the same
 * object works whether a 2D or 3D shape follows it in the chain.
 *
 * Three inlets, Gem-style: X/Y/Z are ALL hot - a float to any one of
 * them updates that axis and immediately recomputes+forwards, same
 * as a bang (matches real Gem, where every translateXYZ inlet is
 * hot).
 * ------------------------------------------------------------------
 */

#include "m_pd.h"
#include "jet_shared.h"

static t_class *jet_translateXYZ_class;

typedef struct _jet_translateXYZ {
  t_object  x_obj;
  t_outlet *x_outlet;
  float     x_tx, x_ty, x_tz;
} t_jet_translateXYZ;

static void jet_translateXYZ_bang(t_jet_translateXYZ *x)
{
  float cur3d[16];
  jet_win_get_transform3d(cur3d);
  float op3d[16];
  jet_mat4_translation(x->x_tx, x->x_ty, x->x_tz, op3d);
  float result3d[16];
  jet_mat4_mul(cur3d, op3d, result3d);
  jet_win_set_transform3d(result3d);

  float cur2d[9];
  jet_win_get_transform(cur2d);
  float op2d[9] = { 1, 0, x->x_tx,
                    0, 1, x->x_ty,
                    0, 0, 1 };
  float result2d[9];
  jet_mat3_mul(cur2d, op2d, result2d);
  jet_win_set_transform(result2d);

  outlet_bang(x->x_outlet);
}

static void jet_translateXYZ_float(t_jet_translateXYZ *x, t_floatarg f)
{
  x->x_tx = f;
  jet_translateXYZ_bang(x);
}

static void jet_translateXYZ_inY(t_jet_translateXYZ *x, t_floatarg f)
{
  x->x_ty = f;
  jet_translateXYZ_bang(x);
}

static void jet_translateXYZ_inZ(t_jet_translateXYZ *x, t_floatarg f)
{
  x->x_tz = f;
  jet_translateXYZ_bang(x);
}

static void jet_translateXYZ_set(t_jet_translateXYZ *x, t_symbol *s, int argc, t_atom *argv)
{
  (void)s;
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

static void *jet_translateXYZ_new(t_symbol *s, int argc, t_atom *argv)
{
  t_jet_translateXYZ *x = (t_jet_translateXYZ *)pd_new(jet_translateXYZ_class);
  (void)s;

  x->x_outlet = outlet_new(&x->x_obj, &s_bang);
  x->x_tx = (argc >= 1) ? atom_getfloatarg(0, argc, argv) : 0.f;
  x->x_ty = (argc >= 2) ? atom_getfloatarg(1, argc, argv) : 0.f;
  x->x_tz = (argc >= 3) ? atom_getfloatarg(2, argc, argv) : 0.f;

  // hot Y/Z inlets - see jet_rotateXYZ.mm's constructor comment
  inlet_new(&x->x_obj, &x->x_obj.ob_pd, &s_float, gensym("iny"));
  inlet_new(&x->x_obj, &x->x_obj.ob_pd, &s_float, gensym("inz"));

  return (void *)x;
}

extern "C" void jet_translateXYZ_setup(void)
{
  jet_translateXYZ_class = class_new(gensym("jet_translateXYZ"),
                                       (t_newmethod)jet_translateXYZ_new, 0,
                                       sizeof(t_jet_translateXYZ), CLASS_DEFAULT,
                                       A_GIMME, 0);
  class_addbang(jet_translateXYZ_class, jet_translateXYZ_bang);
  class_addfloat(jet_translateXYZ_class, jet_translateXYZ_float);
  class_addmethod(jet_translateXYZ_class, (t_method)jet_translateXYZ_inY,
                  gensym("iny"), A_FLOAT, 0);
  class_addmethod(jet_translateXYZ_class, (t_method)jet_translateXYZ_inZ,
                  gensym("inz"), A_FLOAT, 0);
  class_addmethod(jet_translateXYZ_class, (t_method)jet_translateXYZ_set,
                  gensym("set"), A_GIMME, 0);
}
