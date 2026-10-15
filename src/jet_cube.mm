/* ------------------------------------------------------------------
 * jet_cube - the first 3D shape object: a unit cube (edge length
 * settable via creation arg, default 1.0), lit by jet_win's single
 * directional light, drawn with depth testing against everything
 * else in the scene. Like jet_triangle/jet_rectangle it records its
 * draw as a command for the window to execute at the end of the frame
 * (as opposed to jet_perlin/jet_feedback's render-to-texture pattern)
 * - it's a shape, not a texture source.
 *
 * [jet_cube <size>]  edge length, default 1. Inlets, Gem-style: left
 * = the chain (bang, plus "size s"), right = size (stores only);
 * drawing happens on the bang. Color comes from the chain (jet_color).
 *
 * Texture-aware exactly like jet_rectangle: if jet_texture has
 * bound a texture this frame, draws textured (still lit, tinted by
 * the chain color); otherwise flat in the chain color. 24 unique corners (4 per face, so each face
 * gets its own flat normal - a real cube has hard edges, not smoothed
 * ones) expanded to 36 non-indexed triangle vertices, same
 * no-index-buffer approach the 2D shapes already use.
 * ------------------------------------------------------------------
 */

#import <Metal/Metal.h>

#include "m_pd.h"
#include "jet_shared.h"

#include <string.h>

static t_class *jet_cube_class;

typedef JetVertex3D Vertex3D;
typedef JetVertex3DTex Vertex3DTex;
typedef JetUniforms3D Uniforms3D;

typedef struct _jet_cube {
  t_object x_obj;
  t_outlet *x_outlet;
  t_float  x_size;  // full edge length
} t_jet_cube;

// one entry per face: outward normal, then 4 corners going around
// (used as two triangles, v0-v1-v2 and v0-v2-v3), then the matching
// 4 UVs. corners are in UNIT-cube space (-0.5..0.5); jet_cube_bang
// scales them by x_size before uploading.
typedef struct { float n[3]; float c[4][3]; float uv[4][2]; } CubeFace;

static const CubeFace kCubeFaces[6] = {
  // +X
  { {1,0,0}, { {0.5f,-0.5f,-0.5f}, {0.5f,-0.5f,0.5f}, {0.5f,0.5f,0.5f}, {0.5f,0.5f,-0.5f} },
             { {0,1},{1,1},{1,0},{0,0} } },
  // -X
  { {-1,0,0}, { {-0.5f,-0.5f,0.5f}, {-0.5f,-0.5f,-0.5f}, {-0.5f,0.5f,-0.5f}, {-0.5f,0.5f,0.5f} },
              { {0,1},{1,1},{1,0},{0,0} } },
  // +Y
  { {0,1,0}, { {-0.5f,0.5f,-0.5f}, {0.5f,0.5f,-0.5f}, {0.5f,0.5f,0.5f}, {-0.5f,0.5f,0.5f} },
             { {0,1},{1,1},{1,0},{0,0} } },
  // -Y
  { {0,-1,0}, { {-0.5f,-0.5f,0.5f}, {0.5f,-0.5f,0.5f}, {0.5f,-0.5f,-0.5f}, {-0.5f,-0.5f,-0.5f} },
              { {0,1},{1,1},{1,0},{0,0} } },
  // +Z
  { {0,0,1}, { {-0.5f,-0.5f,0.5f}, {0.5f,-0.5f,0.5f}, {0.5f,0.5f,0.5f}, {-0.5f,0.5f,0.5f} },
             { {0,1},{1,1},{1,0},{0,0} } },
  // -Z
  { {0,0,-1}, { {0.5f,-0.5f,-0.5f}, {-0.5f,-0.5f,-0.5f}, {-0.5f,0.5f,-0.5f}, {0.5f,0.5f,-0.5f} },
              { {0,1},{1,1},{1,0},{0,0} } },
};

static void jet_cube_bang(t_jet_cube *x)
{
  if(!jet_win_frame_active()) {
    return;  // no jet_win mid-frame right now - just skip quietly
  }

  JetDrawDesc d;
  memset(&d, 0, sizeof(d));
  jet_fill_uniforms3d(&d.uniforms, false);  // solids are lit by the window light
  d.vertexCount = 36;

  id<MTLTexture> tex = jet_win_current_texture();
  const float s = x->x_size;
  const int tri[6] = { 0, 1, 2, 0, 2, 3 };
  Vertex3DTex tverts[36];
  Vertex3D fverts[36];

  int vi = 0;
  for(int f = 0; f < 6; f++) {
    const CubeFace &face = kCubeFaces[f];
    for(int t = 0; t < 6; t++, vi++) {
      const int c = tri[t];
      const float px = face.c[c][0] * s, py = face.c[c][1] * s, pz = face.c[c][2] * s;
      if(tex) {
        Vertex3DTex &v = tverts[vi];
        v.pos[0] = px; v.pos[1] = py; v.pos[2] = pz;
        v.normal[0] = face.n[0]; v.normal[1] = face.n[1]; v.normal[2] = face.n[2];
        v.uv[0] = face.uv[c][0]; v.uv[1] = face.uv[c][1];
      } else {
        Vertex3D &v = fverts[vi];
        v.pos[0] = px; v.pos[1] = py; v.pos[2] = pz;
        v.normal[0] = face.n[0]; v.normal[1] = face.n[1]; v.normal[2] = face.n[2];
        memcpy(v.color, d.uniforms.tint, 3 * sizeof(float));
      }
    }
  }
  if(tex) {
    d.pipeline = JET_PIPE_TEXTURED3D;
    d.texture = tex;
    d.vertices = tverts;
    d.vertexBytes = sizeof(tverts);
  } else {
    d.pipeline = JET_PIPE_FLAT3D;
    d.vertices = fverts;
    d.vertexBytes = sizeof(fverts);
  }
  jet_win_submit_draw(&d);

  outlet_bang(x->x_outlet);
}

static void jet_cube_size(t_jet_cube *x, t_floatarg s)
{
  x->x_size = s;
}

static void *jet_cube_new(t_symbol *s, int argc, t_atom *argv)
{
  t_jet_cube *x = (t_jet_cube *)pd_new(jet_cube_class);
  (void)s;

  x->x_outlet = outlet_new(&x->x_obj, &s_bang);
  x->x_size = (argc >= 1) ? atom_getfloatarg(0, argc, argv) : 1.f;
  floatinlet_new(&x->x_obj, &x->x_size);

  return (void *)x;
}

extern "C" void jet_cube_setup(void)
{
  jet_cube_class = class_new(gensym("jet_cube"),
                               (t_newmethod)jet_cube_new, 0,
                               sizeof(t_jet_cube), CLASS_DEFAULT,
                               A_GIMME, 0);
  class_addbang(jet_cube_class, jet_cube_bang);
  class_addmethod(jet_cube_class, (t_method)jet_cube_size,
                  gensym("size"), A_FLOAT, 0);
}
