/* ------------------------------------------------------------------
 * jet_cube - the first 3D shape object: a unit cube (edge length
 * settable via creation arg, default 1.0), lit by jet_win's single
 * directional light, drawn with depth testing against everything
 * else in the scene. Same draw-directly-into-the-shared-on-screen-
 * encoder pattern as jet_triangle/jet_rectangle (as opposed to
 * jet_perlin/jet_feedback's render-to-texture pattern) - it's a
 * shape, not a texture source.
 *
 * Texture-aware exactly like jet_rectangle: if jet_texture has
 * bound a texture this frame, draws textured (still lit); otherwise
 * flat per-vertex color. 24 unique corners (4 per face, so each face
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

// must match the MSL Vertex3D/Vertex3DTex/Uniforms3D structs in
// jet_win.mm's setupPipelines byte-for-byte - these plain float[3]
// arrays are already tightly packed with no gaps, matching the MSL
// side's packed_float3 (NOT plain float3, which is 16-byte-aligned
// per field and would silently misalign every vertex after the
// first - see jet_win.mm's comment on Vertex3D for the bug this was)
typedef struct { float pos[3]; float normal[3]; float color[3]; } Vertex3D;
typedef struct { float pos[3]; float normal[3]; float uv[2]; }    Vertex3DTex;
typedef struct {
  float model[16], view[16], projection[16];
  float lightDir[4];    // w unused - see jet_win.mm's setupPipelines for why float4
  float lightColor[4];  // w unused
} Uniforms3D;

typedef struct _jet_cube {
  t_object x_obj;
  t_outlet *x_outlet;
  float    x_size;  // full edge length
  float    x_r, x_g, x_b;
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
  id<MTLRenderCommandEncoder> enc = jet_win_current_encoder();
  id<MTLDepthStencilState> depthState = jet_win_depth_state();
  if(!enc || !depthState) {
    return;  // no jet_win mid-frame right now - just skip quietly
  }

  Uniforms3D u;
  jet_win_get_transform3d(u.model);
  jet_win_get_view(u.view);
  jet_win_get_projection(u.projection);
  jet_win_get_light(u.lightDir, u.lightColor);
  u.lightDir[3] = u.lightColor[3] = 0.f;

  [enc setDepthStencilState:depthState];

  id<MTLTexture> tex = jet_win_current_texture();
  const float s = x->x_size;

  if(tex) {
    id<MTLRenderPipelineState> pipeline = jet_win_textured3d_pipeline();
    if(!pipeline) {
      return;
    }
    Vertex3DTex verts[36];
    int vi = 0;
    for(int f = 0; f < 6; f++) {
      const CubeFace &face = kCubeFaces[f];
      const int tri[6] = { 0, 1, 2, 0, 2, 3 };
      for(int t = 0; t < 6; t++) {
        const int c = tri[t];
        Vertex3DTex &v = verts[vi++];
        v.pos[0] = face.c[c][0] * s;
        v.pos[1] = face.c[c][1] * s;
        v.pos[2] = face.c[c][2] * s;
        v.normal[0] = face.n[0]; v.normal[1] = face.n[1]; v.normal[2] = face.n[2];
        v.uv[0] = face.uv[c][0]; v.uv[1] = face.uv[c][1];
      }
    }
    [enc setRenderPipelineState:pipeline];
    [enc setVertexBytes:verts length:sizeof(verts) atIndex:0];
    [enc setVertexBytes:&u length:sizeof(u) atIndex:1];
    [enc setFragmentBytes:&u length:sizeof(u) atIndex:1];
    [enc setFragmentTexture:tex atIndex:0];
    [enc setFragmentSamplerState:jet_win_sampler() atIndex:0];
    [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:36];
  } else {
    id<MTLRenderPipelineState> pipeline = jet_win_flat3d_pipeline();
    if(!pipeline) {
      return;
    }
    Vertex3D verts[36];
    int vi = 0;
    for(int f = 0; f < 6; f++) {
      const CubeFace &face = kCubeFaces[f];
      const int tri[6] = { 0, 1, 2, 0, 2, 3 };
      for(int t = 0; t < 6; t++) {
        const int c = tri[t];
        Vertex3D &v = verts[vi++];
        v.pos[0] = face.c[c][0] * s;
        v.pos[1] = face.c[c][1] * s;
        v.pos[2] = face.c[c][2] * s;
        v.normal[0] = face.n[0]; v.normal[1] = face.n[1]; v.normal[2] = face.n[2];
        v.color[0] = x->x_r; v.color[1] = x->x_g; v.color[2] = x->x_b;
      }
    }
    [enc setRenderPipelineState:pipeline];
    [enc setVertexBytes:verts length:sizeof(verts) atIndex:0];
    [enc setVertexBytes:&u length:sizeof(u) atIndex:1];
    [enc setFragmentBytes:&u length:sizeof(u) atIndex:1];
    [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:36];
  }

  outlet_bang(x->x_outlet);
}

static void jet_cube_size(t_jet_cube *x, t_floatarg s)
{
  x->x_size = s;
}
static void jet_cube_color(t_jet_cube *x, t_floatarg r, t_floatarg g, t_floatarg b)
{
  x->x_r = r;
  x->x_g = g;
  x->x_b = b;
}

static void *jet_cube_new(t_symbol *s, int argc, t_atom *argv)
{
  t_jet_cube *x = (t_jet_cube *)pd_new(jet_cube_class);
  (void)s;

  x->x_outlet = outlet_new(&x->x_obj, &s_bang);
  x->x_size = (argc >= 1) ? atom_getfloatarg(0, argc, argv) : 1.f;
  x->x_r = (argc >= 2) ? atom_getfloatarg(1, argc, argv) : 0.75f;
  x->x_g = (argc >= 3) ? atom_getfloatarg(2, argc, argv) : 0.75f;
  x->x_b = (argc >= 4) ? atom_getfloatarg(3, argc, argv) : 0.8f;

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
  class_addmethod(jet_cube_class, (t_method)jet_cube_color,
                  gensym("color"), A_FLOAT, A_FLOAT, A_FLOAT, 0);
}
