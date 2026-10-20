/* ------------------------------------------------------------------
 * jet_render - renders a scene into a texture instead of the window,
 * like TouchDesigner's Render TOP. The chain below the LEFT outlet is
 * the scene: shapes, transforms, colours, even other effects, seen
 * through this object's own camera and light and drawn into a texture of
 * its own size. When the scene is done, the RIGHT outlet fires with that
 * texture bound as the chain's current texture, so anything can use it:
 * a shape, an effect block, a jet_shader, jet_share...
 *
 *   [jet_head 0]
 *   |
 *   [jet_render 512 512]
 *   |            \
 *   scene         [jet_rectangle 3 2]     <- the result, as a picture
 *   (cube, ...)
 *
 * The scene starts with a clean chain state (identity transform, white,
 * depth test on, no texture); the state of the chain above is saved
 * and put back afterwards, and the chain's texture is restored after the
 * right outlet has run, like every effect.
 *
 * [jet_render <width> <height>]  size of the texture, default 512 512.
 * Inlets (Gem-style): the chain (bang), width, height - the size inlets
 * only store.
 *
 * Messages (all optional; defaults are those of jet_win):
 *   camera x y z    camera position            (0 0 4)
 *   lookat x y z    point the camera looks at  (0 0 0)
 *   fov deg         vertical field of view     (90)
 *   range near far  clipping planes            (0.1 100)
 *   light x y z     direction TOWARD the light (the window's light)
 *   lightcolor r g b                           (the window's light)
 *   clear r g b [a] background colour          (0 0 0 1)
 *   resolution w h  same as the two inlets
 *   readback [fx fy]  diagnostic: the next bang prints the colour of the
 *                   centre and of a corner pixel of the result (and of the
 *                   pixel at fx fy, 0..1 across the texture, if given)
 *
 * With the default camera and a 4:3 texture, [jet_rectangle 5.33 4] fills
 * the whole scene, as it does in the window. The scene's aspect ratio is
 * width/height of this texture, independent of the window.
 * ------------------------------------------------------------------
 */

#import <Metal/Metal.h>

#include "m_pd.h"
#include "jet_shared.h"

#include <math.h>
#include <string.h>

static t_class *jet_render_class;

typedef struct _jet_render {
  t_object  x_obj;
  t_outlet *x_sceneOut;
  t_outlet *x_resultOut;
  t_float   x_w, x_h;
  float     x_camPos[3], x_camLook[3];
  float     x_fov, x_near, x_far;
  float     x_lightDir[3], x_lightColor[3];
  int       x_lightSet, x_lightColorSet;
  float     x_clear[4];
  id<MTLTexture> x_depth;     // Depth32Float, owned (+1)
  int       x_depthW, x_depthH;
  int       x_readback;
  float     x_readbackAt[2];   // extra pixel to print, 0..1 across the texture (-1 = none)
} t_jet_render;

static id<MTLTexture> jet_render_depth(t_jet_render *x, int w, int h)
{
  if(x->x_depth && x->x_depthW == w && x->x_depthH == h) return x->x_depth;
  id<MTLDevice> device = jet_win_device();
  if(!device) return nil;
  [x->x_depth release];
  MTLTextureDescriptor *desc =
    [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float
                                                        width:w height:h mipmapped:NO];
  desc.usage = MTLTextureUsageRenderTarget;
  desc.storageMode = MTLStorageModePrivate;
  x->x_depth = [device newTextureWithDescriptor:desc];
  x->x_depthW = w;
  x->x_depthH = h;
  return x->x_depth;
}

// diagnostic: wait for the scene and print the centre and a corner pixel
static void jet_render_readback(t_jet_render *x, id<MTLTexture> color, int w, int h)
{
  id<MTLDevice> device = jet_win_device();
  id<MTLBuffer> buf = [device newBufferWithLength:12 options:MTLResourceStorageModeShared];
  int ex = (int)(x->x_readbackAt[0] * w), ey = (int)(x->x_readbackAt[1] * h);
  if(ex < 0) ex = 0;
  if(ey < 0) ey = 0;
  if(ex >= w) ex = w - 1;
  if(ey >= h) ey = h - 1;
  id<MTLCommandBuffer> cb = [jet_win_queue() commandBuffer];
  id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
  [blit copyFromTexture:color sourceSlice:0 sourceLevel:0
           sourceOrigin:MTLOriginMake(w / 2, h / 2, 0) sourceSize:MTLSizeMake(1, 1, 1)
               toBuffer:buf destinationOffset:0 destinationBytesPerRow:4 destinationBytesPerImage:4];
  [blit copyFromTexture:color sourceSlice:0 sourceLevel:0
           sourceOrigin:MTLOriginMake(1, 1, 0) sourceSize:MTLSizeMake(1, 1, 1)
               toBuffer:buf destinationOffset:4 destinationBytesPerRow:4 destinationBytesPerImage:4];
  if(x->x_readbackAt[0] >= 0.f) {
    [blit copyFromTexture:color sourceSlice:0 sourceLevel:0
             sourceOrigin:MTLOriginMake(ex, ey, 0) sourceSize:MTLSizeMake(1, 1, 1)
                 toBuffer:buf destinationOffset:8 destinationBytesPerRow:4 destinationBytesPerImage:4];
  }
  [blit endEncoding];
  [cb commit];
  [cb waitUntilCompleted];
  const unsigned char *p = (const unsigned char *)[buf contents];
  // the texture is BGRA
  post("jet_render: centre pixel r=%d g=%d b=%d a=%d, corner pixel r=%d g=%d b=%d a=%d",
       p[2], p[1], p[0], p[3], p[6], p[5], p[4], p[7]);
  if(x->x_readbackAt[0] >= 0.f) {
    post("jet_render: pixel at %d %d: r=%d g=%d b=%d a=%d", ex, ey, p[10], p[9], p[8], p[11]);
  }
  [buf release];
}

static void jet_render_bang(t_jet_render *x)
{
  if(!jet_win_frame_active()) return;

  int w = (int)x->x_w, h = (int)x->x_h;
  if(w < 1) w = 1;
  if(h < 1) h = 1;
  if(w > 8192) w = 8192;
  if(h > 8192) h = 8192;

  id<MTLTexture> depth = jet_render_depth(x, w, h);
  if(!depth) return;
  id<MTLTexture> color = jet_win_pool_acquire_bgra(w, h);
  if(!color) return;

  JetSceneCamera cam;
  jet_mat4_lookAt(x->x_camPos[0], x->x_camPos[1], x->x_camPos[2],
                  x->x_camLook[0], x->x_camLook[1], x->x_camLook[2], cam.view);
  cam.aspect = (float)w / (float)h;
  jet_mat4_perspective(x->x_fov * (float)M_PI / 180.f, cam.aspect, x->x_near, x->x_far,
                       cam.projection);
  // unless set here, the scene is lit like the window
  float winDir[3], winColor[3];
  jet_win_get_light(winDir, winColor);
  for(int i = 0; i < 3; i++) {
    cam.lightDir[i] = x->x_lightSet ? x->x_lightDir[i] : winDir[i];
    cam.lightColor[i] = x->x_lightColorSet ? x->x_lightColor[i] : winColor[i];
  }

  if(!jet_win_scene_begin(&cam)) {
    pd_error(x, "jet_render: can't start a scene here (nested too deep?)");
    jet_win_pool_release(color);
    return;
  }
  outlet_bang(x->x_sceneOut);               // the scene is recorded
  jet_win_scene_end(color, depth, x->x_clear);   // ... and drawn into the texture

  if(x->x_readback) {
    x->x_readback = 0;
    jet_render_readback(x, color, w, h);
  }

  id<MTLTexture> before = jet_win_current_texture();
  jet_win_set_current_texture(color);
  outlet_bang(x->x_resultOut);              // the result is used
  jet_win_set_current_texture(before);
  jet_win_pool_release(color);
}

static void jet_render_camera(t_jet_render *x, t_floatarg a, t_floatarg b, t_floatarg c)
{
  x->x_camPos[0] = a; x->x_camPos[1] = b; x->x_camPos[2] = c;
}
static void jet_render_lookat(t_jet_render *x, t_floatarg a, t_floatarg b, t_floatarg c)
{
  x->x_camLook[0] = a; x->x_camLook[1] = b; x->x_camLook[2] = c;
}
static void jet_render_fov(t_jet_render *x, t_floatarg f)
{
  x->x_fov = f < 1.f ? 1.f : (f > 175.f ? 175.f : f);
}
static void jet_render_range(t_jet_render *x, t_floatarg n, t_floatarg f)
{
  if(n > 0.f && f > n) { x->x_near = n; x->x_far = f; }
}
static void jet_render_light(t_jet_render *x, t_floatarg a, t_floatarg b, t_floatarg c)
{
  x->x_lightDir[0] = a; x->x_lightDir[1] = b; x->x_lightDir[2] = c;
  x->x_lightSet = 1;
}
static void jet_render_lightcolor(t_jet_render *x, t_floatarg a, t_floatarg b, t_floatarg c)
{
  x->x_lightColor[0] = a; x->x_lightColor[1] = b; x->x_lightColor[2] = c;
  x->x_lightColorSet = 1;
}
static void jet_render_clear(t_jet_render *x, t_symbol *s, int argc, t_atom *argv)
{
  (void)s;
  for(int i = 0; i < 4 && i < argc; i++) x->x_clear[i] = atom_getfloat(argv + i);
}
static void jet_render_resolution(t_jet_render *x, t_floatarg w, t_floatarg h)
{
  x->x_w = w;
  x->x_h = h;
}
static void jet_render_readbackMsg(t_jet_render *x, t_symbol *s, int argc, t_atom *argv)
{
  (void)s;
  x->x_readback = 1;
  // optional: "readback fx fy" also prints the pixel at that fraction of the texture
  x->x_readbackAt[0] = (argc >= 2) ? atom_getfloat(argv) : -1.f;
  x->x_readbackAt[1] = (argc >= 2) ? atom_getfloat(argv + 1) : -1.f;
}

static void *jet_render_new(t_symbol *s, int argc, t_atom *argv)
{
  t_jet_render *x = (t_jet_render *)pd_new(jet_render_class);
  (void)s;
  x->x_w = (argc >= 1) ? atom_getfloat(argv) : 512.f;
  x->x_h = (argc >= 2) ? atom_getfloat(argv + 1) : 512.f;
  x->x_camPos[0] = 0.f; x->x_camPos[1] = 0.f; x->x_camPos[2] = 4.f;
  x->x_camLook[0] = x->x_camLook[1] = x->x_camLook[2] = 0.f;
  x->x_fov = 90.f;
  x->x_near = 0.1f;
  x->x_far = 100.f;
  x->x_lightSet = x->x_lightColorSet = 0;
  x->x_clear[0] = x->x_clear[1] = x->x_clear[2] = 0.f;
  x->x_clear[3] = 1.f;
  x->x_depth = nil;
  x->x_depthW = x->x_depthH = 0;
  x->x_readback = 0;
  x->x_readbackAt[0] = x->x_readbackAt[1] = -1.f;

  floatinlet_new(&x->x_obj, &x->x_w);
  floatinlet_new(&x->x_obj, &x->x_h);
  x->x_sceneOut = outlet_new(&x->x_obj, &s_bang);
  x->x_resultOut = outlet_new(&x->x_obj, &s_bang);
  return (void *)x;
}

static void jet_render_free(t_jet_render *x)
{
  [x->x_depth release];
  x->x_depth = nil;
}

extern "C" void jet_render_setup(void)
{
  jet_render_class = class_new(gensym("jet_render"),
                               (t_newmethod)jet_render_new, (t_method)jet_render_free,
                               sizeof(t_jet_render), CLASS_DEFAULT,
                               A_GIMME, 0);
  class_addbang(jet_render_class, jet_render_bang);
  class_addmethod(jet_render_class, (t_method)jet_render_camera, gensym("camera"),
                  A_FLOAT, A_FLOAT, A_FLOAT, 0);
  class_addmethod(jet_render_class, (t_method)jet_render_lookat, gensym("lookat"),
                  A_FLOAT, A_FLOAT, A_FLOAT, 0);
  class_addmethod(jet_render_class, (t_method)jet_render_fov, gensym("fov"), A_FLOAT, 0);
  class_addmethod(jet_render_class, (t_method)jet_render_range, gensym("range"),
                  A_FLOAT, A_FLOAT, 0);
  class_addmethod(jet_render_class, (t_method)jet_render_light, gensym("light"),
                  A_FLOAT, A_FLOAT, A_FLOAT, 0);
  class_addmethod(jet_render_class, (t_method)jet_render_lightcolor, gensym("lightcolor"),
                  A_FLOAT, A_FLOAT, A_FLOAT, 0);
  class_addmethod(jet_render_class, (t_method)jet_render_clear, gensym("clear"), A_GIMME, 0);
  class_addmethod(jet_render_class, (t_method)jet_render_resolution, gensym("resolution"),
                  A_FLOAT, A_FLOAT, 0);
  class_addmethod(jet_render_class, (t_method)jet_render_readbackMsg, gensym("readback"), A_GIMME, 0);
}
