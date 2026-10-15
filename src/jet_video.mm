/* ------------------------------------------------------------------
 * jet_video - live camera capture straight onto the GPU, zero-copy.
 *
 * This is the object that actually shows what a GPU-native pipeline
 * can do that Gem's CPU-bound pix_video/pix_* chain structurally
 * can't: a captured camera frame arrives from the hardware ISP as a
 * CVPixelBuffer backed by an IOSurface (GPU-visible memory), and
 * CVMetalTextureCache wraps that SAME memory as an id<MTLTexture> -
 * no pixel data is copied anywhere, ever, on the way in. Gem's own
 * pix_video decodes into CPU RAM and every pix_* effect after it
 * runs as a CPU loop over that RAM; here the frame never touches the
 * CPU at all unless something later explicitly reads it back.
 *
 * Like jet_perlin, this sets the chain's "current texture" directly
 * (see jet_shared.h) rather than "current pixels" - put a
 * jet_texture after it in the chain exactly as usual; it'll see a
 * texture already bound and just pass it through.
 *
 * Threading: AVCaptureVideoDataOutput delivers frames on its own
 * dispatch queue, not the Pd/render thread. The delegate callback
 * does only a cheap CVPixelBufferRetain + mutex-protected pointer
 * swap - no decode, no Metal calls. The actual CVMetalTextureCache
 * wrap (a lightweight "view over existing memory" call, not a copy)
 * happens on the control thread inside bang(), which is safe and
 * fast enough not to need its own background thread the way
 * jet_movie's AVAssetReader decode did.
 *
 * "start"/"stop" (not auto-started on creation) mirror jet_win's
 * create/destroy convention, and give the OS camera-permission
 * prompt a predictable moment to appear rather than firing the
 * instant the patch loads.
 * ------------------------------------------------------------------
 */

#import <AVFoundation/AVFoundation.h>
#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

#include "m_pd.h"
#include "jet_shared.h"

#include <mutex>

static t_class *jet_video_class;

// ---------------------------------------------------------------
// the AVFoundation-facing capture object
// ---------------------------------------------------------------

@interface JetVideoCapture : NSObject <AVCaptureVideoDataOutputSampleBufferDelegate>
- (instancetype)initWithDevice:(id<MTLDevice>)device errorOut:(NSString **)errorOut;
- (BOOL)start:(NSString **)errorOut;
- (void)stop;
// returns YES and fills outTexture/outWidth/outHeight if a NEW frame
// has arrived since the last call; NO (leaving the out-params alone)
// if nothing new has come in yet.
- (BOOL)latestTexture:(id<MTLTexture> *)outTexture width:(int *)outWidth height:(int *)outHeight;
@end

@implementation JetVideoCapture {
  AVCaptureSession *_session;
  std::mutex _mutex;
  CVPixelBufferRef _latestPixelBuffer;  // retained; written by the capture queue, read by bang()
  BOOL _hasNewFrame;
  CVMetalTextureCacheRef _textureCache;
  CVMetalTextureRef _currentCVTexture;  // keeps the currently-bound id<MTLTexture>'s backing memory alive
}

- (instancetype)initWithDevice:(id<MTLDevice>)device errorOut:(NSString **)errorOut
{
  self = [super init];
  if(!self) {
    return nil;
  }

  if(CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &_textureCache) != kCVReturnSuccess) {
    if(errorOut) {
      *errorOut = @"could not create a CVMetalTextureCache";
    }
    return nil;
  }

  AVCaptureDevice *device_ = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
  if(!device_) {
    if(errorOut) {
      *errorOut = @"no camera found";
    }
    return nil;
  }

  NSError *nsErr = nil;
  AVCaptureDeviceInput *input = [AVCaptureDeviceInput deviceInputWithDevice:device_ error:&nsErr];
  if(!input) {
    if(errorOut) {
      *errorOut = nsErr.localizedDescription;
    }
    return nil;
  }

  _session = [[AVCaptureSession alloc] init];
  _session.sessionPreset = AVCaptureSessionPresetHigh;
  if(![_session canAddInput:input]) {
    if(errorOut) {
      *errorOut = @"could not add camera input to capture session";
    }
    return nil;
  }
  [_session addInput:input];

  AVCaptureVideoDataOutput *output = [[AVCaptureVideoDataOutput alloc] init];
  // BGRA: a natively-supported Metal pixel format, so the
  // CVMetalTextureCache wrap below needs no conversion either
  output.videoSettings = @{ (id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA) };
  output.alwaysDiscardsLateVideoFrames = YES;
  dispatch_queue_t queue = dispatch_queue_create("jet_video.capture", DISPATCH_QUEUE_SERIAL);
  [output setSampleBufferDelegate:self queue:queue];
  if(![_session canAddOutput:output]) {
    if(errorOut) {
      *errorOut = @"could not add video output to capture session";
    }
    return nil;
  }
  [_session addOutput:output];

  _latestPixelBuffer = NULL;
  _hasNewFrame = NO;
  _currentCVTexture = NULL;
  return self;
}

- (BOOL)start:(NSString **)errorOut
{
  if([AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo] == AVAuthorizationStatusDenied) {
    if(errorOut) {
      *errorOut = @"camera access denied - check System Settings > Privacy & Security > Camera";
    }
    return NO;
  }
  [_session startRunning];
  return YES;
}

- (void)stop
{
  [_session stopRunning];
}

- (void)captureOutput:(AVCaptureOutput *)output
 didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
        fromConnection:(AVCaptureConnection *)connection
{
  CVPixelBufferRef pixbuf = CMSampleBufferGetImageBuffer(sampleBuffer);
  if(!pixbuf) {
    return;
  }
  CVPixelBufferRetain(pixbuf);

  std::lock_guard<std::mutex> lock(_mutex);
  if(_latestPixelBuffer) {
    CVPixelBufferRelease(_latestPixelBuffer);
  }
  _latestPixelBuffer = pixbuf;
  _hasNewFrame = YES;
}

- (BOOL)latestTexture:(id<MTLTexture> *)outTexture width:(int *)outWidth height:(int *)outHeight
{
  CVPixelBufferRef pixbuf = NULL;
  {
    std::lock_guard<std::mutex> lock(_mutex);
    if(!_hasNewFrame || !_latestPixelBuffer) {
      return NO;
    }
    pixbuf = CVPixelBufferRetain(_latestPixelBuffer);
    _hasNewFrame = NO;
  }

  const size_t w = CVPixelBufferGetWidth(pixbuf);
  const size_t h = CVPixelBufferGetHeight(pixbuf);

  CVMetalTextureRef cvTexture = NULL;
  const CVReturn err = CVMetalTextureCacheCreateTextureFromImage(
      kCFAllocatorDefault, _textureCache, pixbuf, nil,
      MTLPixelFormatBGRA8Unorm, w, h, 0, &cvTexture);
  CVPixelBufferRelease(pixbuf);

  if(err != kCVReturnSuccess || !cvTexture) {
    if(cvTexture) {
      CFRelease(cvTexture);
    }
    return NO;
  }

  // hold onto this wrapped texture (and thus the memory it views)
  // until the NEXT frame replaces it - only then release the
  // previous one, matching how jet_win only needs "current
  // texture" valid for the one tick it's bound during
  if(_currentCVTexture) {
    CFRelease(_currentCVTexture);
  }
  _currentCVTexture = cvTexture;

  *outTexture = CVMetalTextureGetTexture(cvTexture);
  *outWidth = (int)w;
  *outHeight = (int)h;
  return YES;
}

- (void)dealloc
{
  if(_currentCVTexture) {
    CFRelease(_currentCVTexture);
  }
  if(_latestPixelBuffer) {
    CVPixelBufferRelease(_latestPixelBuffer);
  }
  if(_textureCache) {
    CFRelease(_textureCache);
  }
  [_session release];
  [super dealloc];
}

@end

// ---------------------------------------------------------------
// the Pd object
// ---------------------------------------------------------------

typedef struct _jet_video {
  t_object x_obj;
  t_outlet *x_outlet;
  JetVideoCapture *x_capture;
  int x_started;
  int x_warnedNotStarted;  // suppresses repeated "not started" errors
  id<MTLTexture> x_lastTexture;  // unretained here - kept alive by x_capture's own _currentCVTexture
  int x_width, x_height;
} t_jet_video;

static void jet_video_start(t_jet_video *x)
{
  if(x->x_started) {
    post("jet_video: already started");
    return;
  }
  if(!x->x_capture) {
    id<MTLDevice> device = jet_win_device();
    if(!device) {
      pd_error(x, "jet_video: no jet_win open yet - create one first "
               "(it owns the shared MTLDevice)");
      return;
    }
    NSString *err = nil;
    x->x_capture = [[JetVideoCapture alloc] initWithDevice:device errorOut:&err];
    if(!x->x_capture) {
      pd_error(x, "jet_video: could not set up camera capture (%s)",
               err ? [err UTF8String] : "unknown error");
      return;
    }
  }

  NSString *err = nil;
  if(![x->x_capture start:&err]) {
    pd_error(x, "jet_video: could not start capture (%s)",
             err ? [err UTF8String] : "unknown error");
    return;
  }
  x->x_started = 1;
  x->x_warnedNotStarted = 0;
  post("jet_video: capture started");
}

static void jet_video_stop(t_jet_video *x)
{
  if(!x->x_started) {
    return;
  }
  [x->x_capture stop];
  x->x_started = 0;
  x->x_lastTexture = nil;
  post("jet_video: capture stopped");
}

static void jet_video_bang(t_jet_video *x)
{
  if(!x->x_started) {
    if(!x->x_warnedNotStarted) {
      pd_error(x, "jet_video: not started (send 'start' first)");
      x->x_warnedNotStarted = 1;
    }
    return;
  }

  id<MTLTexture> tex = nil;
  int w = 0, h = 0;
  if([x->x_capture latestTexture:&tex width:&w height:&h]) {
    x->x_lastTexture = tex;
    x->x_width = w;
    x->x_height = h;
  }

  if(x->x_lastTexture) {
    // re-bind every tick, not just when a genuinely new camera frame
    // arrived: jet_win_tick clears "current texture" at the end of
    // every frame, and the camera can easily deliver frames slower
    // than the render tick rate - without this, a tick with no new
    // frame would leave "current texture" nil and jet_texture would
    // report "no current pixels" (there aren't any - this is a
    // texture-only source), exactly the bug jet_movie hit early on.
    jet_win_set_current_texture(x->x_lastTexture);
  }

  outlet_bang(x->x_outlet);
}

static void *jet_video_new(void)
{
  t_jet_video *x = (t_jet_video *)pd_new(jet_video_class);
  x->x_outlet = outlet_new(&x->x_obj, &s_bang);
  x->x_capture = nil;
  x->x_started = 0;
  x->x_warnedNotStarted = 0;
  x->x_lastTexture = nil;
  x->x_width = 0;
  x->x_height = 0;
  return (void *)x;
}

static void jet_video_free(t_jet_video *x)
{
  if(x->x_started) {
    [x->x_capture stop];
  }
  [x->x_capture release];
}

extern "C" void jet_video_setup(void)
{
  jet_video_class = class_new(gensym("jet_video"),
                                (t_newmethod)jet_video_new,
                                (t_method)jet_video_free,
                                sizeof(t_jet_video), CLASS_DEFAULT, A_NULL, 0);
  class_addbang(jet_video_class, jet_video_bang);
  class_addmethod(jet_video_class, (t_method)jet_video_start,
                  gensym("start"), A_NULL, 0);
  class_addmethod(jet_video_class, (t_method)jet_video_stop,
                  gensym("stop"), A_NULL, 0);
}
