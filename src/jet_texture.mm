/* ------------------------------------------------------------------
 * jet_texture - on a bang, makes sure the chain's "current texture"
 * slot is a ready-to-sample GPU texture, regardless of where it came
 * from:
 *   - if a GPU-native source already ran this frame (e.g. jet_perlin
 *     rendering to its own offscreen texture) and already set the
 *     current texture, this is a no-op passthrough - nothing to do.
 *   - otherwise, uploads whatever's in the "current pixels" CPU slot
 *     (set by jet_image) to a fresh GPU texture and binds that.
 * Either way, subsequent shape objects (jet_rectangle) just sample
 * "current texture". Mirrors Gem's [pix_texture], generalized to
 * also work transparently after a GPU-shader source instead of only
 * after [pix_image]-like CPU sources.
 * ------------------------------------------------------------------
 */

#import <Metal/Metal.h>

#include "m_pd.h"
#include "jet_shared.h"

static t_class *jet_texture_class;

typedef struct _jet_texture {
  t_object x_obj;
  t_outlet *x_outlet;
  id<MTLTexture> x_tex;
} t_jet_texture;

static void jet_texture_bang(t_jet_texture *x)
{
  if(jet_win_current_texture()) {
    // a GPU-native source (e.g. jet_perlin) already bound a texture
    // this frame - nothing to upload, just forward the chain
    outlet_bang(x->x_outlet);
    return;
  }

  const unsigned char *rgba = NULL;
  int w = 0, h = 0;
  if(!jet_win_get_current_pixels(&rgba, &w, &h)) {
    pd_error(x, "jet_texture: no current pixels (put a jet_image before this)");
    return;
  }

  id<MTLDevice> device = jet_win_device();
  if(!device) {
    return;  // no jet_win open yet
  }

  MTLTextureDescriptor *desc =
    [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                        width:w
                                                       height:h
                                                    mipmapped:NO];
  desc.usage = MTLTextureUsageShaderRead;
  id<MTLTexture> tex = [device newTextureWithDescriptor:desc];

  MTLRegion region = MTLRegionMake2D(0, 0, w, h);
  [tex replaceRegion:region mipmapLevel:0 withBytes:rgba bytesPerRow:(NSUInteger)(w * 4)];

  x->x_tex = tex;
  jet_win_set_current_texture(tex);
  outlet_bang(x->x_outlet);
}

static void *jet_texture_new(void)
{
  t_jet_texture *x = (t_jet_texture *)pd_new(jet_texture_class);
  x->x_outlet = outlet_new(&x->x_obj, &s_bang);
  x->x_tex = nil;
  return (void *)x;
}

extern "C" void jet_texture_setup(void)
{
  jet_texture_class = class_new(gensym("jet_texture"),
                                  (t_newmethod)jet_texture_new, 0,
                                  sizeof(t_jet_texture), CLASS_DEFAULT,
                                  (t_atomtype)0);
  class_addbang(jet_texture_class, jet_texture_bang);
}
