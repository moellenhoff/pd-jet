/* ------------------------------------------------------------------
 * jet_separator - like Gem's [separator]: runs everything connected
 * below it, then puts the chain's state back the way it was. Without
 * it, a branch's translate/rotate/scale/color/texture stays applied
 * to whatever the chain does next, so two shapes fanned out from one
 * point would drag each other around. Pd's message dispatch is
 * synchronous and depth-first, so "save, forward the bang, restore"
 * is all it takes - everything downstream has finished by the time
 * outlet_bang returns.
 *
 * Saves/restores the chain-scoped state from jet_shared.h: the model
 * transform, the color, the depth flag and the bound texture.
 * ------------------------------------------------------------------
 */

#include "m_pd.h"
#include "jet_shared.h"

static t_class *jet_separator_class;

typedef struct _jet_separator {
  t_object  x_obj;
  t_outlet *x_outlet;
} t_jet_separator;

static void jet_separator_bang(t_jet_separator *x)
{
  float t3d[16], color[4];
  jet_win_get_transform3d(t3d);
  jet_win_get_color(color);
  const int depth = jet_win_get_depth();
  id<MTLTexture> tex = jet_win_current_texture();

  outlet_bang(x->x_outlet);

  jet_win_set_transform3d(t3d);
  jet_win_set_color(color);
  jet_win_set_depth(depth);
  jet_win_set_current_texture(tex);
}

static void *jet_separator_new(void)
{
  t_jet_separator *x = (t_jet_separator *)pd_new(jet_separator_class);
  x->x_outlet = outlet_new(&x->x_obj, &s_bang);
  return (void *)x;
}

extern "C" void jet_separator_setup(void)
{
  jet_separator_class = class_new(gensym("jet_separator"),
                                  (t_newmethod)jet_separator_new, 0,
                                  sizeof(t_jet_separator), CLASS_DEFAULT,
                                  A_NULL, 0);
  class_addbang(jet_separator_class, jet_separator_bang);
}
