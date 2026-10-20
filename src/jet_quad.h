/* ------------------------------------------------------------------
 * jet_quad.h - the flat quad that jet_rectangle, jet_square, jet_circle
 * and jet_ellipse all draw: centred on the origin of the chain, in the XY
 * plane, half sizes hw / hh, unlit, in the chain colour, or filled with the
 * chain's current texture. With disc = true the quad is drawn as the
 * ellipse inscribed in it (smooth edge, see fragment3DDiscFlatMain in
 * jet_win.mm) instead of the full rectangle.
 * ------------------------------------------------------------------
 */
#ifndef _INCLUDE__JET_QUAD_H_
#define _INCLUDE__JET_QUAD_H_

#include "jet_shared.h"

#include <string.h>

static inline void jet_quad_draw(float hw, float hh, bool disc)
{
  if(!jet_win_frame_active()) {
    return;  // no jet_win mid-frame right now - just skip quietly
  }
  // corners: [0]=top-left [1]=bottom-left [2]=bottom-right [3]=top-right
  const float cx[4] = { -hw, -hw,  hw,  hw };
  const float cy[4] = {  hh, -hh, -hh,  hh };
  const float cu[4] = {   0,   0,   1,   1 };
  const float cv[4] = {   0,   1,   1,   0 };
  const int   tri[6] = { 0, 1, 2, 0, 2, 3 };

  JetDrawDesc d;
  memset(&d, 0, sizeof(d));
  jet_fill_uniforms3d(&d.uniforms, true);  // flat shapes are unlit
  d.vertexCount = 6;

  id<MTLTexture> tex = jet_win_current_texture();
  JetVertex3DTex tverts[6];
  JetVertex3D fverts[6];
  if(tex || disc) {
    for(int i = 0; i < 6; i++) {
      const int c = tri[i];
      tverts[i].pos[0] = cx[c]; tverts[i].pos[1] = cy[c]; tverts[i].pos[2] = 0.f;
      tverts[i].normal[0] = 0.f; tverts[i].normal[1] = 0.f; tverts[i].normal[2] = 1.f;
      tverts[i].uv[0] = cu[c]; tverts[i].uv[1] = cv[c];
    }
    d.pipeline = disc ? (tex ? JET_PIPE_DISC_TEXTURED : JET_PIPE_DISC_FLAT) : JET_PIPE_TEXTURED3D;
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
}

#endif
