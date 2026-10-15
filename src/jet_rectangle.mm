/* ------------------------------------------------------------------
 * jet_rectangle - a "shape object" for the jet_win render chain,
 * texture-aware: if jet_texture has bound a texture this frame
 * (jet_win_current_texture()), draws a textured quad sampling it,
 * tinted by the chain color; otherwise a flat quad in the chain
 * color (see jet_color). Mirrors how Gem's [square] renders textured
 * or flat depending on whether a texture preceded it in the chain.
 * It is real 3D geometry in the XY plane, unlit, drawn through the
 * window's camera with the chain's model transform - so it can be
 * moved in Z, turned around any axis and is depth-tested (see
 * jet_depth).
 *
 * [jet_rectangle <halfwidth> <halfheight>]
 *   halfwidth/   HALF the size - the rectangle reaches halfwidth to
 *   halfheight   the left AND right of the origin (same convention
 *                as Gem), so [jet_rectangle 5.33 4] is 10.67 x 8.
 *                One argument means a square; default 1 1.
 * Inlets, Gem-style: left = the chain (bang, plus the messages
 * "size w h" and a list "w h" that set both), middle = half width,
 * right = half height. The value inlets only store - drawing happens
 * on the chain's bang.
 *
 * It is centered on the origin: move it with jet_translateXYZ, turn
 * it with jet_rotateXYZ, colour it with jet_color. Units are Gem
 * units: with the default camera the window is 8 units tall
 * (y = -4..+4) and 8*aspect wide, so on an 800x600 window
 * [jet_rectangle 5.33 4] fills the whole picture. The bang is
 * forwarded out of the outlet after drawing.
 * ------------------------------------------------------------------
 */

#import <Metal/Metal.h>

#include "m_pd.h"
#include "jet_shared.h"

#include <string.h>

static t_class *jet_rectangle_class;

typedef struct _jet_rectangle {
  t_object  x_obj;
  t_outlet *x_outlet;
  t_float   x_w, x_h;      // half-width / half-height, Gem units
} t_jet_rectangle;

static void jet_rectangle_bang(t_jet_rectangle *x)
{
  if(!jet_win_frame_active()) {
    return;  // no jet_win mid-frame right now - just skip quietly
  }

  const float w = x->x_w, h = x->x_h;
  // corners: [0]=top-left [1]=bottom-left [2]=bottom-right [3]=top-right
  const float cx[4] = { -w, -w,  w,  w };
  const float cy[4] = {  h, -h, -h,  h };
  const float cu[4] = {  0,  0,  1,  1 };
  const float cv[4] = {  0,  1,  1,  0 };
  const int   tri[6] = { 0, 1, 2, 0, 2, 3 };

  JetDrawDesc d;
  memset(&d, 0, sizeof(d));
  jet_fill_uniforms3d(&d.uniforms, true);  // flat shapes are unlit
  d.vertexCount = 6;

  id<MTLTexture> tex = jet_win_current_texture();
  JetVertex3DTex tverts[6];
  JetVertex3D fverts[6];
  if(tex) {
    for(int i = 0; i < 6; i++) {
      const int c = tri[i];
      tverts[i].pos[0] = cx[c]; tverts[i].pos[1] = cy[c]; tverts[i].pos[2] = 0.f;
      tverts[i].normal[0] = 0.f; tverts[i].normal[1] = 0.f; tverts[i].normal[2] = 1.f;
      tverts[i].uv[0] = cu[c]; tverts[i].uv[1] = cv[c];
    }
    d.pipeline = JET_PIPE_TEXTURED3D;
    d.texture = tex;
    d.vertices = tverts;
    d.vertexBytes = sizeof(tverts);
  } else {
    for(int i = 0; i < 6; i++) {
      const int c = tri[i];
      fverts[i].pos[0] = cx[c]; fverts[i].pos[1] = cy[c]; fverts[i].pos[2] = 0.f;
      fverts[i].normal[0] = 0.f; fverts[i].normal[1] = 0.f; fverts[i].normal[2] = 1.f;
      memcpy(fverts[i].color, d.uniforms.tint, 3 * sizeof(float));
    }
    d.pipeline = JET_PIPE_FLAT3D;
    d.vertices = fverts;
    d.vertexBytes = sizeof(fverts);
  }
  jet_win_submit_draw(&d);
  outlet_bang(x->x_outlet);
}

static void jet_rectangle_size(t_jet_rectangle *x, t_symbol *s, int argc, t_atom *argv)
{
  (void)s;
  if(argc >= 1) {
    x->x_w = x->x_h = atom_getfloatarg(0, argc, argv);  // one value = square
  }
  if(argc >= 2) {
    x->x_h = atom_getfloatarg(1, argc, argv);
  }
}

static void *jet_rectangle_new(t_symbol *s, int argc, t_atom *argv)
{
  t_jet_rectangle *x = (t_jet_rectangle *)pd_new(jet_rectangle_class);

  x->x_w = x->x_h = 1.f;
  jet_rectangle_size(x, s, argc, argv);

  x->x_outlet = outlet_new(&x->x_obj, &s_bang);
  floatinlet_new(&x->x_obj, &x->x_w);
  floatinlet_new(&x->x_obj, &x->x_h);

  return (void *)x;
}

extern "C" void jet_rectangle_setup(void)
{
  jet_rectangle_class = class_new(gensym("jet_rectangle"),
                                    (t_newmethod)jet_rectangle_new, 0,
                                    sizeof(t_jet_rectangle), CLASS_DEFAULT,
                                    A_GIMME, 0);
  class_addbang(jet_rectangle_class, jet_rectangle_bang);
  class_addlist(jet_rectangle_class, (t_method)jet_rectangle_size);
  class_addmethod(jet_rectangle_class, (t_method)jet_rectangle_size,
                  gensym("size"), A_GIMME, 0);
}
