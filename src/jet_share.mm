/* ------------------------------------------------------------------
 * jet_share - publishes the chain's current texture under a name, so
 * any other chain (or later in this one) can pick it up with
 * [jet_use <name>] instead of having to sit downstream of the
 * producer. The bang is forwarded unchanged and the current texture
 * stays bound, so the chain can carry on (e.g. into a shape).
 *
 * [jet_share <name>]  right inlet / "name <symbol>" changes the name.
 *
 * Names live per window and persist across chains and frames until the
 * same name is published again. A consumer in a chain that runs
 * BEFORE the producer (lower jet_head priority number) sees the
 * previous frame's texture - one frame of latency, which is also what
 * makes feedback loops across chains possible. Textures are shared,
 * not copied: don't expect a snapshot.
 * ------------------------------------------------------------------
 */

#import <Metal/Metal.h>

#include "m_pd.h"
#include "jet_shared.h"

static t_class *jet_share_class;

typedef struct _jet_share {
  t_object  x_obj;
  t_outlet *x_outlet;
  t_symbol *x_name;
  int       x_warned;
} t_jet_share;

static void jet_share_bang(t_jet_share *x)
{
  if(!jet_win_frame_active()) {
    return;
  }
  if(x->x_name == &s_) {
    if(!x->x_warned) {
      pd_error(x, "jet_share: no name given ([jet_share <name>])");
      x->x_warned = 1;
    }
    return;
  }
  id<MTLTexture> tex = jet_win_current_texture();
  if(!tex) {
    if(!x->x_warned) {
      pd_error(x, "jet_share: no current texture to share as '%s' (put a "
               "texture-producing object before this in the chain)",
               x->x_name->s_name);
      x->x_warned = 1;
    }
    return;
  }
  x->x_warned = 0;
  jet_win_publish_texture(x->x_name, tex);
  outlet_bang(x->x_outlet);
}

static void jet_share_name(t_jet_share *x, t_symbol *s)
{
  x->x_name = s;
}

static void *jet_share_new(t_symbol *name)
{
  t_jet_share *x = (t_jet_share *)pd_new(jet_share_class);
  x->x_name = name;
  x->x_warned = 0;
  x->x_outlet = outlet_new(&x->x_obj, &s_bang);
  symbolinlet_new(&x->x_obj, &x->x_name);
  return (void *)x;
}

extern "C" void jet_share_setup(void)
{
  jet_share_class = class_new(gensym("jet_share"),
                              (t_newmethod)jet_share_new, 0,
                              sizeof(t_jet_share), CLASS_DEFAULT,
                              A_DEFSYM, 0);
  class_addbang(jet_share_class, jet_share_bang);
  class_addmethod(jet_share_class, (t_method)jet_share_name,
                  gensym("name"), A_SYMBOL, 0);
}
