/* ------------------------------------------------------------------
 * jet_image - loads an image file (JPEG/PNG/... - anything
 * ImageIO understands) into a CPU-side RGBA buffer on a bang, and
 * sets it as the chain's "current pixels" (jet_win_set_current_
 * pixels()) for jet_texture to pick up and upload to the GPU.
 * Mirrors Gem's [pix_image]: loading is a separate step from
 * uploading/binding, done via jet_texture, exactly like
 * [pix_image] -> [pix_texture].
 *
 * Uses only macOS system frameworks (ImageIO/CoreGraphics) - no new
 * third-party dependency, same as everything else in this project.
 * ------------------------------------------------------------------
 */

#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>
#import <ImageIO/ImageIO.h>

#include "m_pd.h"
#include "jet_shared.h"

#include <string>
#include <vector>

static t_class *jet_image_class;

typedef struct _jet_image {
  t_object x_obj;
  t_outlet *x_outlet;
  t_canvas *x_canvas;  // owning patch, for resolving relative paths
  std::string *x_path;
  std::vector<unsigned char> *x_rgba;
  int x_w, x_h;
  int x_loaded;
} t_jet_image;

static int loadImageRGBA(const char *path, std::vector<unsigned char> &outRgba,
                         int &outW, int &outH)
{
  NSString *nsPath = [NSString stringWithUTF8String:path];
  NSURL *url = [NSURL fileURLWithPath:nsPath];
  CGImageSourceRef src = CGImageSourceCreateWithURL((__bridge CFURLRef)url, NULL);
  if(!src) {
    return 0;
  }
  CGImageRef img = CGImageSourceCreateImageAtIndex(src, 0, NULL);
  CFRelease(src);
  if(!img) {
    return 0;
  }

  const int w = (int)CGImageGetWidth(img);
  const int h = (int)CGImageGetHeight(img);
  outRgba.assign((size_t)w * h * 4, 0);

  CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
  CGContextRef ctx = CGBitmapContextCreate(outRgba.data(), w, h, 8, w * 4, cs,
                       kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
  CGColorSpaceRelease(cs);
  if(!ctx) {
    CGImageRelease(img);
    return 0;
  }

  // flip so row 0 in memory is the TOP of the image (Core Graphics'
  // default bitmap-context coordinate system is bottom-up)
  CGContextTranslateCTM(ctx, 0, h);
  CGContextScaleCTM(ctx, 1, -1);
  CGContextDrawImage(ctx, CGRectMake(0, 0, w, h), img);
  CGContextRelease(ctx);
  CGImageRelease(img);

  outW = w;
  outH = h;
  return 1;
}

static void jet_image_bang(t_jet_image *x)
{
  if(!x->x_loaded) {
    pd_error(x, "jet_image: no image loaded (path was '%s')", x->x_path->c_str());
    return;
  }
  jet_win_set_current_pixels(x->x_rgba->data(), x->x_w, x->x_h);
  // invalidate any texture a *different* chain may have left bound
  // earlier this same frame (current-texture only resets at end of
  // frame, not between chains), so jet_texture actually re-uploads
  // for this chain instead of mistaking that leftover for "ready"
  jet_win_set_current_texture(nil);
  outlet_bang(x->x_outlet);
}

static void jet_image_open(t_jet_image *x, t_symbol *path)
{
  // resolve relative to the patch that owns this object (same
  // mechanism Gem's pix_image uses), so "./fractal.jpg" means "next
  // to this patch", not "relative to wherever Pd's process cwd is"
  char resolved[MAXPDSTRING];
  canvas_makefilename(x->x_canvas, path->s_name, resolved, MAXPDSTRING);

  *x->x_path = resolved;
  x->x_loaded = loadImageRGBA(x->x_path->c_str(), *x->x_rgba, x->x_w, x->x_h);
  if(x->x_loaded) {
    post("jet_image: loaded %s (%dx%d)", x->x_path->c_str(), x->x_w, x->x_h);
  } else {
    pd_error(x, "jet_image: could not load '%s'", x->x_path->c_str());
  }
}

static void *jet_image_new(t_symbol *s, int argc, t_atom *argv)
{
  t_jet_image *x = (t_jet_image *)pd_new(jet_image_class);
  (void)s;

  x->x_outlet = outlet_new(&x->x_obj, &s_bang);
  x->x_canvas = canvas_getcurrent();
  x->x_path = new std::string();
  x->x_rgba = new std::vector<unsigned char>();
  x->x_w = x->x_h = 0;
  x->x_loaded = 0;

  if(argc >= 1) {
    jet_image_open(x, atom_getsymbol(argv));
  }
  return (void *)x;
}

static void jet_image_free(t_jet_image *x)
{
  delete x->x_path;
  delete x->x_rgba;
}

extern "C" void jet_image_setup(void)
{
  jet_image_class = class_new(gensym("jet_image"),
                                (t_newmethod)jet_image_new,
                                (t_method)jet_image_free,
                                sizeof(t_jet_image), CLASS_DEFAULT,
                                A_GIMME, 0);
  class_addbang(jet_image_class, jet_image_bang);
  class_addmethod(jet_image_class, (t_method)jet_image_open,
                  gensym("open"), A_SYMBOL, 0);
}
