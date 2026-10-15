/* ------------------------------------------------------------------
 * jet_rotateXYZ - like Gem's [rotateXYZ]: one rotate object for the
 * whole chain, X/Y/Z degrees all at once, instead of separate 2D
 * (jet_rotate) and 3D (jet_rotate3d) objects with a single-axis-
 * at-a-time interface. Updates BOTH transforms every bang:
 *
 *   - the 3D 4x4 model transform (jet_win_get/set_transform3d),
 *     with the full combined X-then-Y-then-Z rotation - this is what
 *     jet_cube and later 3D shapes read.
 *   - the 2D 3x3 transform (jet_win_get/set_transform), using ONLY
 *     the Z component - X/Y rotation has no meaning on a flat plane,
 *     but Z rotation is identical in both cases (rotating points in
 *     the XY plane), so a 2D chain (jet_triangle/jet_rectangle)
 *     downstream still responds exactly as jet_rotate used to.
 *
 * This means the SAME object works whether a 2D or 3D shape follows
 * it in the chain - it doesn't need to know or care which.
 *
 * Three inlets, Gem-style: X/Y/Z are ALL hot - a float to any one of
 * them updates that axis and immediately recomputes+forwards, same
 * as a bang (this matches real Gem's rotateXYZ/translateXYZ/
 * scaleXYZ, where every inlet is hot - unlike the more common Pd
 * convention of only the leftmost inlet being hot). "set <rx> <ry>
 * <rz>" still works too, for updating all three from one message
 * without forwarding.
 * ------------------------------------------------------------------
 */

#include "m_pd.h"
#include "jet_shared.h"

#include <math.h>

static t_class *jet_rotateXYZ_class;

typedef struct _jet_rotateXYZ {
  t_object  x_obj;
  t_outlet *x_outlet;
  float     x_rx, x_ry, x_rz;  // degrees
} t_jet_rotateXYZ;

static void jet_rotateXYZ_bang(t_jet_rotateXYZ *x)
{
  const float radX = x->x_rx * (float)M_PI / 180.f;
  const float radY = x->x_ry * (float)M_PI / 180.f;
  const float radZ = x->x_rz * (float)M_PI / 180.f;

  // 3D: X, then Y, then Z (matrices multiplied in that order - X
  // applied to the vertex first)
  float rxm[16], rym[16], rzm[16], ryx[16], op3d[16];
  jet_mat4_rotationX(radX, rxm);
  jet_mat4_rotationY(radY, rym);
  jet_mat4_rotationZ(radZ, rzm);
  jet_mat4_mul(rym, rxm, ryx);
  jet_mat4_mul(rzm, ryx, op3d);

  float cur3d[16];
  jet_win_get_transform3d(cur3d);
  float result3d[16];
  jet_mat4_mul(cur3d, op3d, result3d);
  jet_win_set_transform3d(result3d);

  // 2D: Z only - same op matrix jet_rotate itself used to build
  const float c = cosf(radZ), s = sinf(radZ);
  float op2d[9] = { c, -s, 0,
                    s,  c, 0,
                    0,  0, 1 };
  float cur2d[9];
  jet_win_get_transform(cur2d);
  float result2d[9];
  jet_mat3_mul(cur2d, op2d, result2d);
  jet_win_set_transform(result2d);

  outlet_bang(x->x_outlet);
}

static void jet_rotateXYZ_float(t_jet_rotateXYZ *x, t_floatarg f)
{
  x->x_rx = f;
  jet_rotateXYZ_bang(x);
}

static void jet_rotateXYZ_inY(t_jet_rotateXYZ *x, t_floatarg f)
{
  x->x_ry = f;
  jet_rotateXYZ_bang(x);
}

static void jet_rotateXYZ_inZ(t_jet_rotateXYZ *x, t_floatarg f)
{
  x->x_rz = f;
  jet_rotateXYZ_bang(x);
}

static void jet_rotateXYZ_set(t_jet_rotateXYZ *x, t_symbol *s, int argc, t_atom *argv)
{
  (void)s;
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

static void *jet_rotateXYZ_new(t_symbol *s, int argc, t_atom *argv)
{
  t_jet_rotateXYZ *x = (t_jet_rotateXYZ *)pd_new(jet_rotateXYZ_class);
  (void)s;

  x->x_outlet = outlet_new(&x->x_obj, &s_bang);
  x->x_rx = (argc >= 1) ? atom_getfloatarg(0, argc, argv) : 0.f;
  x->x_ry = (argc >= 2) ? atom_getfloatarg(1, argc, argv) : 0.f;
  x->x_rz = (argc >= 3) ? atom_getfloatarg(2, argc, argv) : 0.f;

  // hot Y/Z inlets: retarget a float landing on inlet 1/2 to our own
  // "iny"/"inz" selector, which (unlike floatinlet_new's silent cold
  // store) runs a full method that updates that axis AND recomputes+
  // forwards - matching real Gem, where every rotateXYZ inlet is hot.
  // inlet 0 (X) is the object's own automatically-created main inlet,
  // handled above via class_addfloat/class_addbang instead.
  inlet_new(&x->x_obj, &x->x_obj.ob_pd, &s_float, gensym("iny"));
  inlet_new(&x->x_obj, &x->x_obj.ob_pd, &s_float, gensym("inz"));

  return (void *)x;
}

extern "C" void jet_rotateXYZ_setup(void)
{
  jet_rotateXYZ_class = class_new(gensym("jet_rotateXYZ"),
                                    (t_newmethod)jet_rotateXYZ_new, 0,
                                    sizeof(t_jet_rotateXYZ), CLASS_DEFAULT,
                                    A_GIMME, 0);
  class_addbang(jet_rotateXYZ_class, jet_rotateXYZ_bang);
  class_addfloat(jet_rotateXYZ_class, jet_rotateXYZ_float);
  class_addmethod(jet_rotateXYZ_class, (t_method)jet_rotateXYZ_inY,
                  gensym("iny"), A_FLOAT, 0);
  class_addmethod(jet_rotateXYZ_class, (t_method)jet_rotateXYZ_inZ,
                  gensym("inz"), A_FLOAT, 0);
  class_addmethod(jet_rotateXYZ_class, (t_method)jet_rotateXYZ_set,
                  gensym("set"), A_GIMME, 0);
}
