/* ------------------------------------------------------------------
 * jet_head - the chain-entry-point half of the jet_win/jet_head
 * split (mirrors Gem's gemwin/gemhead split, and for the same
 * reasons - see the comment atop jet_win.mm). Registers its outlet
 * with a specific jet_win (across the bundle boundary, via
 * jet_shared.h) so it gets banged once per frame, in ascending
 * priority order, same convention as [gemhead priority].
 *
 * Creation args: [jet_head <priority>] or
 * [jet_head <priority> <window-name>] - the window name matches a
 * jet_win's own (also optional) name arg, so a plain [jet_head 0]
 * binds to a plain unnamed [jet_win] as before; multiple independent
 * windows need both named to tell their chains apart.
 * ------------------------------------------------------------------
 */

#include "m_pd.h"
#include "jet_shared.h"

static t_class *jet_head_class;

typedef struct _jet_head {
  t_object   x_obj;
  t_outlet  *x_outlet;
  int        x_priority;
} t_jet_head;

static void *jet_head_new(t_symbol *s, int argc, t_atom *argv)
{
  t_jet_head *x = (t_jet_head *)pd_new(jet_head_class);
  (void)s;

  x->x_priority = (argc >= 1) ? (int)atom_getfloatarg(0, argc, argv) : 0;
  t_symbol *windowName = gensym("default");
  if(argc >= 2 && argv[1].a_type == A_SYMBOL) {
    windowName = atom_getsymbol(argv + 1);
  }
  x->x_outlet = outlet_new(&x->x_obj, &s_bang);

  jet_win_register_head(windowName, x, x->x_outlet, x->x_priority);
  return (void *)x;
}

static void jet_head_free(t_jet_head *x)
{
  jet_win_unregister_head(x->x_outlet);
}

extern "C" void jet_head_setup(void)
{
  jet_head_class = class_new(gensym("jet_head"),
                               (t_newmethod)jet_head_new,
                               (t_method)jet_head_free,
                               sizeof(t_jet_head), CLASS_DEFAULT, A_GIMME, 0);
}
