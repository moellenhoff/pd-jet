/* ------------------------------------------------------------------
 * jet_use - binds a named texture (published with [jet_share <name>])
 * as the chain's current texture, then forwards the bang. Everything
 * after it - jet_rectangle, jet_cube, jet_feedback, jet_slitscan, ... -
 * sees it exactly as if the producer sat right above it. The same
 * name can be used by any number of consumers, in any chain.
 *
 * [jet_use <name>]  right inlet / "name <symbol>" changes the name.
 *
 * If the name isn't published (yet), the current texture is left as it
 * is and the bang is still forwarded (so a fallback texture set earlier
 * in the chain keeps working). That's normal for the first frame or
 * two; if it is still missing after ~2 seconds of frames you get one
 * message in the Pd window.
 * ------------------------------------------------------------------
 */

#import <Metal/Metal.h>

#include "m_pd.h"
#include "jet_shared.h"

static t_class *jet_use_class;

typedef struct _jet_use {
  t_object  x_obj;
  t_outlet *x_outlet;
  t_symbol *x_name;
  int       x_misses;
} t_jet_use;

static void jet_use_bang(t_jet_use *x)
{
  if(!jet_win_frame_active()) {
    return;
  }
  id<MTLTexture> tex = jet_win_named_texture(x->x_name);
  if(tex) {
    x->x_misses = 0;
    jet_win_set_current_texture(tex);
  } else if(++x->x_misses == 120) {
    pd_error(x, "jet_use: no texture named '%s' has been published (is a "
             "[jet_share %s] running in this window?)",
             x->x_name->s_name, x->x_name->s_name);
  }
  outlet_bang(x->x_outlet);
}

static void jet_use_name(t_jet_use *x, t_symbol *s)
{
  x->x_name = s;
  x->x_misses = 0;
}

static void *jet_use_new(t_symbol *name)
{
  t_jet_use *x = (t_jet_use *)pd_new(jet_use_class);
  x->x_name = name;
  x->x_misses = 0;
  x->x_outlet = outlet_new(&x->x_obj, &s_bang);
  symbolinlet_new(&x->x_obj, &x->x_name);
  return (void *)x;
}

extern "C" void jet_use_setup(void)
{
  jet_use_class = class_new(gensym("jet_use"),
                            (t_newmethod)jet_use_new, 0,
                            sizeof(t_jet_use), CLASS_DEFAULT,
                            A_DEFSYM, 0);
  class_addbang(jet_use_class, jet_use_bang);
  class_addmethod(jet_use_class, (t_method)jet_use_name,
                  gensym("name"), A_SYMBOL, 0);
}
