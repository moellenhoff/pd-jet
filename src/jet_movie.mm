/* ------------------------------------------------------------------
 * jet_movie - decodes video frames from a movie file (mp4 and
 * anything else AVFoundation understands) and, like jet_image,
 * sets them as the chain's "current pixels" for jet_texture to
 * pick up. Audio is NOT handled here - see jet_movie~.mm for that
 * (a real Pd signal object feeding dac~, different API entirely from
 * our bang-driven control objects).
 *
 * All AVFoundation work (decode, seek) happens on a dedicated
 * background thread, never on bang()'s own call path. This used to
 * run synchronously inside bang(), which is dispatched from
 * jet_win_tick - itself driven by Pd's own scheduler, which (in
 * the default callback-audio configuration) runs on the SAME thread
 * the audio DSP deadline depends on. Decoding there directly steals
 * time from that deadline, and - worse - it's simply not something
 * AVFoundation's APIs are meant to be called from under hard
 * real-time constraints. Moving decode off that path is what fixed
 * the crackle a synced audio+video patch produced, and what made
 * reverse playback (which has to reseek every single frame, since
 * AVAssetReader is forward-only) usable rather than a stutter.
 *
 * bang() itself is now just a few mutex-protected field reads/writes
 * (cheap) plus, when the background thread has produced a new frame,
 * a memcpy-sized jet_win_set_current_pixels call - no AVFoundation
 * calls, no NSObject allocation, nothing that can block or allocate
 * unpredictably. See JetMovieAsync below for the actual protocol.
 *
 * Optional second creation arg names a jet_movie~ (see
 * jet_movie_shared.h and jet_movie~.mm) to sync frame timing to:
 * when given and found, the background thread decodes forward (or
 * seeks, for backward/large jumps - see jet_movie_async_run) to
 * keep pace with that audio object's playback position, instead of
 * free-running off its own fps timer - so picture stays with sound
 * even as the audio's "speed" changes, including reverse.
 *
 * jet_movie_audio_get_position (jet_movie~'s exported lookup
 * function) is resolved via dlsym(RTLD_DEFAULT, ...) at first use,
 * NOT via a normal declared-and-linked symbol: a plain
 * -undefined dynamic_lookup + weak_import reference gets bound once,
 * at the moment THIS bundle is dlopen'd, using whatever's already
 * loaded in the process at that exact instant - if jet_movie~
 * hasn't loaded yet (e.g. it sits below this jet_movie in the
 * patch, the common case), the weak reference binds to NULL
 * permanently, even after jet_movie~ loads moments later. dlsym
 * does a fresh lookup against the process's CURRENT state every time
 * it's called, so retrying it each bang until it first succeeds is
 * completely independent of object creation order in the patch.
 * ------------------------------------------------------------------
 */

#import <AVFoundation/AVFoundation.h>
#import <Accelerate/Accelerate.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>

#include "m_pd.h"
#include "jet_shared.h"
#include "jet_movie_shared.h"

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <dlfcn.h>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

static t_class *jet_movie_class;

// ---------------------------------------------------------------
// the AVFoundation-facing decoder object - only ever touched from
// the background thread (see JetMovieAsync below) once an object
// is up and running; jet_movie_open still calls openPath: directly
// from the control thread, but only after stopping/joining any
// existing background thread first, so there's never concurrent
// access to it from two threads at once.
// ---------------------------------------------------------------

@interface JetMovieDecoder : NSObject
@property(nonatomic, strong) AVAsset *asset;
@property(nonatomic, strong) AVAssetReader *reader;
@property(nonatomic, strong) AVAssetReaderTrackOutput *trackOutput;
@property(nonatomic, assign) int width;
@property(nonatomic, assign) int height;
@property(nonatomic, assign) float nominalFrameRate;  // the clip's own fps, from its track
@property(nonatomic, assign) double lastPts;  // last decoded frame's timestamp, in clip seconds

- (BOOL)openPath:(NSString *)path errorOut:(NSString **)errorOut;
// returns YES and fills outRgba (width*height*4 bytes) on success;
// NO if the file has no more frames (and loop was NO, or looping
// itself failed)
- (BOOL)nextFrameRGBA:(std::vector<unsigned char> &)outRgba loop:(BOOL)loop;
// random-access seek (tears down and rebuilds the reader with a
// timeRange starting at that frame - AVAssetReader has no seek of
// its own). Playback continues forward from here afterwards.
- (BOOL)seekToFrame:(int)frameIndex rgba:(std::vector<unsigned char> &)outRgba errorOut:(NSString **)errorOut;
@end

@implementation JetMovieDecoder

- (BOOL)restartReaderErrorOut:(NSString **)errorOut
{
  NSError *err = nil;
  AVAssetReader *reader = [[AVAssetReader alloc] initWithAsset:self.asset error:&err];
  if(!reader) {
    if(errorOut) {
      *errorOut = err.localizedDescription;
    }
    return NO;
  }

  AVAssetTrack *track = [[self.asset tracksWithMediaType:AVMediaTypeVideo] firstObject];
  if(!track) {
    if(errorOut) {
      *errorOut = @"no video track";
    }
    return NO;
  }

  NSDictionary *settings =
    // BGRA, not RGBA: it's the one pixel format essentially every
    // codec's decoder reliably supports for AVAssetReaderTrackOutput
    // (matches the native hardware-decode/Metal-texture layout).
    // Requesting RGBA directly can silently produce zero frames on
    // some codecs - we byte-swap to RGBA ourselves when copying, in
    // nextFrameRGBA below.
    @{ (id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA) };
  AVAssetReaderTrackOutput *output =
    [[AVAssetReaderTrackOutput alloc] initWithTrack:track outputSettings:settings];
  [reader addOutput:output];

  if(![reader startReading]) {
    if(errorOut) {
      *errorOut = reader.error.localizedDescription ?: @"startReading failed";
    }
    return NO;
  }

  self.reader = reader;
  self.trackOutput = output;
  return YES;
}

- (BOOL)openPath:(NSString *)path errorOut:(NSString **)errorOut
{
  NSURL *url = [NSURL fileURLWithPath:path];
  AVURLAsset *asset = [AVURLAsset URLAssetWithURL:url options:nil];
  AVAssetTrack *track = [[asset tracksWithMediaType:AVMediaTypeVideo] firstObject];
  if(!track) {
    if(errorOut) {
      *errorOut = @"could not find a video track";
    }
    return NO;
  }

  self.asset = asset;
  const CGSize size = track.naturalSize;
  self.width = (int)fabs(size.width);
  self.height = (int)fabs(size.height);
  self.nominalFrameRate = (track.nominalFrameRate > 0.f) ? track.nominalFrameRate : 30.f;
  self.lastPts = 0.0;

  return [self restartReaderErrorOut:errorOut];
}

// shared by nextFrameRGBA: and seekToFrame: - swaps BGRA -> RGBA
// while copying (see why we request BGRA above). Uses vImage
// (Accelerate) instead of a scalar per-pixel loop - vectorized
// (NEON) and handles the row-stride padding itself.
- (void)copyPixelBuffer:(CVPixelBufferRef)pixbuf toRgba:(std::vector<unsigned char> &)outRgba
{
  CVPixelBufferLockBaseAddress(pixbuf, kCVPixelBufferLock_ReadOnly);
  const int w = (int)CVPixelBufferGetWidth(pixbuf);
  const int h = (int)CVPixelBufferGetHeight(pixbuf);
  const size_t srcStride = CVPixelBufferGetBytesPerRow(pixbuf);
  const unsigned char *base = (const unsigned char *)CVPixelBufferGetBaseAddress(pixbuf);

  outRgba.resize((size_t)w * h * 4);
  const size_t dstStride = (size_t)w * 4;

  vImage_Buffer srcBuf = { (void *)base, (vImagePixelCount)h, (vImagePixelCount)w, srcStride };
  vImage_Buffer dstBuf = { outRgba.data(), (vImagePixelCount)h, (vImagePixelCount)w, dstStride };
  // destination channel i takes source channel permuteMap[i]; source
  // is B,G,R,A (0,1,2,3) and we want R,G,B,A out
  const uint8_t permuteMap[4] = {2, 1, 0, 3};
  vImagePermuteChannels_ARGB8888(&srcBuf, &dstBuf, permuteMap, kvImageNoFlags);

  CVPixelBufferUnlockBaseAddress(pixbuf, kCVPixelBufferLock_ReadOnly);

  self.width = w;
  self.height = h;
}

- (BOOL)nextFrameRGBA:(std::vector<unsigned char> &)outRgba loop:(BOOL)loop
{
  CMSampleBufferRef sample = [self.trackOutput copyNextSampleBuffer];
  if(!sample) {
    if(!loop) {
      return NO;
    }
    NSString *err = nil;
    if(![self restartReaderErrorOut:&err]) {
      return NO;
    }
    sample = [self.trackOutput copyNextSampleBuffer];
    if(!sample) {
      return NO;  // e.g. a genuinely empty/zero-frame file
    }
  }

  CVPixelBufferRef pixbuf = CMSampleBufferGetImageBuffer(sample);
  if(!pixbuf) {
    CFRelease(sample);
    return NO;
  }

  self.lastPts = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample));
  [self copyPixelBuffer:pixbuf toRgba:outRgba];
  CFRelease(sample);
  return YES;
}

- (BOOL)seekToFrame:(int)frameIndex rgba:(std::vector<unsigned char> &)outRgba errorOut:(NSString **)errorOut
{
  AVAssetTrack *track = [[self.asset tracksWithMediaType:AVMediaTypeVideo] firstObject];
  if(!track) {
    if(errorOut) {
      *errorOut = @"no video track";
    }
    return NO;
  }

  float fps = track.nominalFrameRate;
  if(fps <= 0.f) {
    fps = 30.f;  // fallback for files that don't report one
  }
  CMTime seekTime = CMTimeMakeWithSeconds((double)frameIndex / fps, 600);

  NSError *err = nil;
  AVAssetReader *reader = [[AVAssetReader alloc] initWithAsset:self.asset error:&err];
  if(!reader) {
    if(errorOut) {
      *errorOut = err.localizedDescription;
    }
    return NO;
  }
  reader.timeRange = CMTimeRangeMake(seekTime, kCMTimePositiveInfinity);

  NSDictionary *settings =
    @{ (id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA) };
  AVAssetReaderTrackOutput *output =
    [[AVAssetReaderTrackOutput alloc] initWithTrack:track outputSettings:settings];
  [reader addOutput:output];

  if(![reader startReading]) {
    if(errorOut) {
      *errorOut = reader.error.localizedDescription ?: @"startReading failed";
    }
    return NO;
  }

  CMSampleBufferRef sample = [output copyNextSampleBuffer];
  if(!sample) {
    if(errorOut) {
      *errorOut = @"no frame at that position (past end of clip?)";
    }
    return NO;
  }

  CVPixelBufferRef pixbuf = CMSampleBufferGetImageBuffer(sample);
  if(!pixbuf) {
    CFRelease(sample);
    if(errorOut) {
      *errorOut = @"no image buffer";
    }
    return NO;
  }

  self.lastPts = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample));
  [self copyPixelBuffer:pixbuf toRgba:outRgba];
  CFRelease(sample);

  // keep this reader so forward playback continues on from the
  // sought position, instead of jumping back to the start
  self.reader = reader;
  self.trackOutput = output;
  return YES;
}

@end

// ---------------------------------------------------------------
// dlsym-based lookup of jet_movie~'s exported position query - see
// the comment atop this file for why this isn't a plain declared,
// linked symbol
// ---------------------------------------------------------------

typedef int (*JetMovieAudioGetPositionFn)(t_symbol *, double *);

static JetMovieAudioGetPositionFn jet_movie_audio_get_position_fn(void)
{
  static JetMovieAudioGetPositionFn fn = nullptr;
  if(!fn) {
    // only cache a successful lookup - jet_movie~ may simply not
    // have loaded yet the first few times this is called, and we
    // want the very next bang after it does to start using it
    fn = (JetMovieAudioGetPositionFn)dlsym(RTLD_DEFAULT,
                                             "jet_movie_audio_get_position");
  }
  return fn;
}

// ---------------------------------------------------------------
// the background decode thread and its handoff protocol.
//
// "control -> background" fields tell the thread what to do; it
// re-reads them every wakeup (no queue - only the LATEST request
// matters, e.g. re-issuing the same sync target twice is a no-op).
// "background -> control" fields are the result: a generation
// counter bang() compares against what it last saw, so it only calls
// jet_win_set_current_pixels when there's actually a new frame.
//
// Only the control (Pd) thread ever touches Pd's API (pd_error,
// outlet_bang, jet_win_set_current_pixels, ...) or the decoder
// object concurrently with the background thread - the background
// thread exclusively owns the JetMovieDecoder once started, and
// only ever writes into the mutex-protected fields below, matching
// the project's existing background-thread + polling pattern (see
// vae_encode/vae_decode) adapted for a continuously-running producer
// instead of one-shot request/response.
// ---------------------------------------------------------------

struct JetMovieAsync {
  std::mutex mutex;
  std::condition_variable cv;
  std::thread thread;
  std::atomic<bool> stopRequested{false};
  JetMovieDecoder *decoder;  // unretained here - owned by t_jet_movie, outlives the thread
  const bool hasSync;          // fixed for this object's lifetime, no lock needed to read it

  // control -> background
  int loop = 1;
  int playing = 0;
  // self-timed mode (hasSync == false): bumped once per due-time
  // frame; background thread decodes exactly one frame per
  // increment it observes.
  uint32_t nextFrameRequest = 0;
  // sync mode (hasSync == true): continuously-updated target
  // position; background thread decodes/seeks forward to follow it.
  double syncTargetSeconds = 0.0;
  // manual seek (either mode, from a plain float to the inlet):
  // bumped to request an immediate, unconditional seek.
  uint32_t manualSeekRequest = 0;
  double manualSeekTargetSeconds = 0.0;

  // background -> control
  std::vector<unsigned char> readyRgba;
  int readyWidth = 0, readyHeight = 0;
  uint32_t readyGeneration = 0;
  uint32_t readyHitEndGeneration = 0;

  JetMovieAsync(JetMovieDecoder *dec, bool sync) : decoder(dec), hasSync(sync) {}
};

static void jet_movie_async_run(JetMovieAsync *a)
{
  uint32_t seenNextFrameRequest = 0;
  uint32_t seenManualSeekRequest = 0;
  int seenLoop = 1;
  bool shownFirstSyncFrame = false;
  double lastSeenSyncTarget = 0.0;
  bool atEnd = false;
  int staleSyncWakeups = 0;  // watchdog - see kMaxStaleWakeups below
  const double kResyncThreshold = 1.0;  // seconds, forward-jump case only
  const int kMaxCatchupFrames = 8;
  // if sync mode goes this many wakeups in a row without managing to
  // decode anything, force a fresh reseek regardless of the
  // direction/distance heuristics below - a safety net against any
  // edge case (e.g. a transiently negative position right at a
  // reverse loop-wrap boundary, before jet_movie~'s own wrap
  // correction catches up) leaving the picture stuck indefinitely
  const int kMaxStaleWakeups = 15;  // ~300ms at the 20ms wakeup interval

  // reverse playback throttle: AVAssetReader can't decode backward,
  // so every step of reverse motion needs a brand-new AVAssetReader
  // (see the "movingBackward" branch below). Doing that on every
  // single ~20ms wakeup (50/sec) turned out to be far more than
  // AVFoundation's decoder-session churn can sustain - it can back up
  // badly enough to stall for whole MINUTES once it does. Capping
  // reverse to a much gentler cadence fixes that; it still looks like
  // motion, just at a lower "frame rate" than forward playback.
  auto lastReverseSeekTime = std::chrono::steady_clock::time_point();
  const double kMinReverseSeekIntervalMs = 80.0;  // ~12.5 reseeks/sec

  while(!a->stopRequested.load()) {
    int loop, playing;
    uint32_t nextFrameRequest, manualSeekRequest;
    double syncTarget, manualSeekTarget;
    {
      std::unique_lock<std::mutex> lock(a->mutex);
      a->cv.wait_for(lock, std::chrono::milliseconds(20));
      loop = a->loop;
      playing = a->playing;
      nextFrameRequest = a->nextFrameRequest;
      syncTarget = a->syncTargetSeconds;
      manualSeekRequest = a->manualSeekRequest;
      manualSeekTarget = a->manualSeekTargetSeconds;
    }
    if(a->stopRequested.load()) {
      break;
    }
    if(loop && !seenLoop) {
      atEnd = false;  // give a forward-stalled reader another chance
    }
    seenLoop = loop;
    if(!playing) {
      continue;
    }

    @autoreleasepool {
      std::vector<unsigned char> rgba;
      bool decoded = false;
      bool hitEnd = false;

      if(manualSeekRequest != seenManualSeekRequest) {
        seenManualSeekRequest = manualSeekRequest;
        const float fps = a->decoder.nominalFrameRate;
        int frame = (int)(manualSeekTarget * (fps > 0.f ? fps : 30.f));
        if(frame < 0) {
          frame = 0;
        }
        NSString *err = nil;
        if([a->decoder seekToFrame:frame rgba:rgba errorOut:&err]) {
          decoded = true;
          atEnd = false;
          shownFirstSyncFrame = true;
          lastSeenSyncTarget = manualSeekTarget;
          staleSyncWakeups = 0;
        }
      } else if(a->hasSync) {
        const double moved = syncTarget - lastSeenSyncTarget;
        lastSeenSyncTarget = syncTarget;
        // AVAssetReader can only decode forward, so a backward move
        // (reverse "speed", or a reverse-direction loop wrap) can
        // only ever be followed by reseeking - every single wakeup,
        // not just once - forward catch-up literally cannot help.
        // a big FORWARD jump (an ordinary forward loop wrap) also
        // can't be closed by the capped catch-up loop below in one
        // wakeup, so that gets the same seek-based resync, just
        // gated by a distance threshold instead of firing every time.
        const bool movingBackward = shownFirstSyncFrame && moved < 0.0;
        const bool bigForwardJump = shownFirstSyncFrame && !movingBackward &&
          fabs(syncTarget - a->decoder.lastPts) > kResyncThreshold;
        // watchdog: force it regardless of the heuristics above once
        // we've gone too long without a single successful decode -
        // e.g. jet_movie~'s read position can transiently read
        // slightly negative for one query, right at a reverse
        // loop-wrap boundary, before its own wrap correction runs on
        // the next DSP block; a negative target used to compute a
        // negative (invalid) seek time, whose failure then left
        // things stuck with nothing to trigger a retry
        const bool watchdogForce = staleSyncWakeups >= kMaxStaleWakeups;

        bool throttledSkip = false;
        if(movingBackward && !watchdogForce) {
          const auto nowSteady = std::chrono::steady_clock::now();
          const double sinceLastMs = std::chrono::duration<double, std::milli>(
              nowSteady - lastReverseSeekTime).count();
          if(sinceLastMs < kMinReverseSeekIntervalMs) {
            throttledSkip = true;
          } else {
            lastReverseSeekTime = nowSteady;
          }
        }

        if(throttledSkip) {
          // deliberate pacing, not staleness - don't feed the watchdog
          staleSyncWakeups = 0;
        } else if(!shownFirstSyncFrame || movingBackward || bigForwardJump || watchdogForce) {
          const float fps = a->decoder.nominalFrameRate;
          int frame = (int)(syncTarget * (fps > 0.f ? fps : 30.f));
          if(frame < 0) {
            frame = 0;
          }
          NSString *err = nil;
          if([a->decoder seekToFrame:frame rgba:rgba errorOut:&err]) {
            decoded = true;
            atEnd = false;
            shownFirstSyncFrame = true;
          }
          staleSyncWakeups = decoded ? 0 : (staleSyncWakeups + 1);
        } else {
          for(int i = 0; i < kMaxCatchupFrames && a->decoder.lastPts < syncTarget; i++) {
            std::vector<unsigned char> frame;
            if(![a->decoder nextFrameRGBA:frame loop:(loop ? YES : NO)]) {
              if(!atEnd) {
                hitEnd = true;
                atEnd = true;
              }
              break;
            }
            atEnd = false;
            rgba.swap(frame);
            decoded = true;
          }
          staleSyncWakeups = decoded ? 0 : (staleSyncWakeups + 1);
        }
      } else if(nextFrameRequest != seenNextFrameRequest) {
        seenNextFrameRequest = nextFrameRequest;
        if(![a->decoder nextFrameRGBA:rgba loop:(loop ? YES : NO)]) {
          if(!atEnd) {
            hitEnd = true;
            atEnd = true;
          }
        } else {
          decoded = true;
        }
      }

      if(decoded || hitEnd) {
        std::lock_guard<std::mutex> lock(a->mutex);
        if(decoded) {
          a->readyRgba.swap(rgba);
          a->readyWidth = a->decoder.width;
          a->readyHeight = a->decoder.height;
          a->readyGeneration++;
        }
        if(hitEnd) {
          a->readyHitEndGeneration++;
        }
      }
    }  // @autoreleasepool
  }
}

// ---------------------------------------------------------------
// the Pd object
// ---------------------------------------------------------------

typedef struct _jet_movie {
  t_object x_obj;
  t_outlet *x_outlet;
  t_canvas *x_canvas;  // owning patch, for resolving relative paths
  JetMovieDecoder *x_decoder;
  std::string *x_path;
  int x_loaded;
  int x_loop;
  int x_playing;

  // playback rate: 0 means "the clip's own native fps" (the default -
  // see jet_movie_rearm below), anything else is a user-set custom
  // rate from the "fps" message. either way, x_frameInterval/
  // x_nextDueTime gate how often bang() posts a "decode one more
  // frame" request to the background thread, independent of how
  // often the render chain itself bangs it.
  float x_customFps;
  double x_frameInterval;
  double x_nextDueTime;

  // optional sync partner: a jet_movie~ playing this same clip's
  // audio (see jet_movie_shared.h).
  int x_hasSync;
  t_symbol *x_syncName;

  JetMovieAsync *x_async;
  uint32_t x_seenHitEndGeneration;
} t_jet_movie;

// (re)computes x_frameInterval from the current fps setting and
// resets x_nextDueTime so the change takes effect immediately -
// called on open and from the "fps" message
static void jet_movie_rearm(t_jet_movie *x)
{
  float effective = x->x_customFps;
  if(effective <= 0.f) {
    effective = x->x_loaded ? x->x_decoder.nominalFrameRate : 30.f;
  }
  x->x_frameInterval = 1.0 / (double)effective;
  x->x_nextDueTime = sys_getrealtime();
}

static void jet_movie_stop_async(t_jet_movie *x)
{
  if(!x->x_async) {
    return;
  }
  x->x_async->stopRequested = true;
  x->x_async->cv.notify_one();
  if(x->x_async->thread.joinable()) {
    x->x_async->thread.join();
  }
  delete x->x_async;
  x->x_async = nullptr;
}

static void jet_movie_start_async(t_jet_movie *x)
{
  jet_movie_stop_async(x);
  x->x_async = new JetMovieAsync(x->x_decoder, x->x_hasSync != 0);
  x->x_seenHitEndGeneration = 0;
  x->x_async->loop = x->x_loop;
  x->x_async->playing = x->x_playing != 0;
  x->x_async->thread = std::thread(jet_movie_async_run, x->x_async);
}

static void jet_movie_open(t_jet_movie *x, t_symbol *path)
{
  // stop the background thread BEFORE touching the decoder from the
  // control thread - openPath: mutates x_decoder's reader/trackOutput
  // etc, and the background thread must never see it mid-mutation
  jet_movie_stop_async(x);

  char resolved[MAXPDSTRING];
  canvas_makefilename(x->x_canvas, path->s_name, resolved, MAXPDSTRING);
  *x->x_path = resolved;

  NSString *nsPath = [NSString stringWithUTF8String:x->x_path->c_str()];
  NSString *err = nil;
  x->x_loaded = [x->x_decoder openPath:nsPath errorOut:&err];
  if(x->x_loaded) {
    x->x_playing = 1;
    jet_movie_rearm(x);
    jet_movie_start_async(x);
    post("jet_movie: loaded %s (%dx%d, native %.3g fps)", x->x_path->c_str(),
        x->x_decoder.width, x->x_decoder.height, x->x_decoder.nominalFrameRate);
  } else {
    pd_error(x, "jet_movie: could not open '%s' (%s)", x->x_path->c_str(),
             err ? [err UTF8String] : "unknown error");
  }
}

static void jet_movie_bang(t_jet_movie *x)
{
  if(!x->x_loaded) {
    pd_error(x, "jet_movie: no movie loaded (path was '%s')", x->x_path->c_str());
    return;
  }

  // publish the latest decoded frame - cheap: a short lock plus one
  // pixel-buffer memcpy. no AVFoundation calls happen on this thread
  // at all. published on EVERY bang, not only when a new frame
  // arrived: "current pixels" is window-wide and not something to
  // rely on still holding our last frame (see jet_shared.h's note on
  // state scopes) - a tick without a new frame, or a paused clip,
  // must still hand jet_texture the frame to show.
  {
    std::lock_guard<std::mutex> lock(x->x_async->mutex);
    if(x->x_async->readyGeneration != 0) {
      jet_win_set_current_pixels(x->x_async->readyRgba.data(),
                                   x->x_async->readyWidth, x->x_async->readyHeight);
      // new pixels invalidate any texture already bound (see
      // jet_image.mm) so jet_texture uploads these, not a stale one
      jet_win_set_current_texture(nil);
    }
    if(x->x_async->readyHitEndGeneration != x->x_seenHitEndGeneration) {
      x->x_seenHitEndGeneration = x->x_async->readyHitEndGeneration;
      pd_error(x, "jet_movie: reached end of clip, stopping (loop is off)");
      x->x_playing = 0;
    }
  }

  if(!x->x_playing) {
    // stopped: keep whatever's currently bound and just let the rest
    // of the chain redraw it, so the picture stays frozen instead of
    // going black
    outlet_bang(x->x_outlet);
    return;
  }

  {
    std::lock_guard<std::mutex> lock(x->x_async->mutex);
    if(x->x_hasSync) {
      double audioPos;
      JetMovieAudioGetPositionFn getAudioPos = jet_movie_audio_get_position_fn();
      if(getAudioPos && getAudioPos(x->x_syncName, &audioPos)) {
        x->x_async->syncTargetSeconds = audioPos;
      }
      // no audio partner resolvable (yet) - leave the previous
      // target; the background thread just stays put until it is
    } else {
      const double now = sys_getrealtime();
      if(now >= x->x_nextDueTime) {
        x->x_async->nextFrameRequest++;
        x->x_nextDueTime += x->x_frameInterval;
        if(x->x_nextDueTime < now) {
          // fell far behind (a stall, or the render fps is much lower
          // than the playback rate) - don't try to burst-catch-up,
          // just resync
          x->x_nextDueTime = now + x->x_frameInterval;
        }
      }
    }
  }
  x->x_async->cv.notify_one();

  outlet_bang(x->x_outlet);
}

static void jet_movie_loop(t_jet_movie *x, t_floatarg f)
{
  x->x_loop = (f != 0.f);
  if(x->x_async) {
    std::lock_guard<std::mutex> lock(x->x_async->mutex);
    x->x_async->loop = x->x_loop;
  }
}

static void jet_movie_play(t_jet_movie *x, t_floatarg f)
{
  x->x_playing = (f != 0.f);
  if(x->x_async) {
    std::lock_guard<std::mutex> lock(x->x_async->mutex);
    x->x_async->playing = x->x_playing;
  }
  if(x->x_async && x->x_playing) {
    x->x_async->cv.notify_one();
  }
}

static void jet_movie_float(t_jet_movie *x, t_floatarg f)
{
  if(!x->x_loaded) {
    pd_error(x, "jet_movie: no movie loaded");
    return;
  }

  int frame = (int)f;
  if(frame < 0) {
    frame = 0;
  }
  const float fps = x->x_decoder.nominalFrameRate;
  {
    std::lock_guard<std::mutex> lock(x->x_async->mutex);
    x->x_async->manualSeekTargetSeconds = frame / (double)(fps > 0.f ? fps : 30.f);
    x->x_async->manualSeekRequest++;
  }
  x->x_async->cv.notify_one();

  // one interval's grace before the next self-timed auto-advance, so
  // a seek while playing (self-timed mode) doesn't immediately jump
  // another frame forward right after the seek lands
  jet_movie_rearm(x);
}

static void jet_movie_fps(t_jet_movie *x, t_floatarg f)
{
  x->x_customFps = (f > 0.f) ? f : 0.f;  // 0/negative -> back to native
  jet_movie_rearm(x);
}

static void *jet_movie_new(t_symbol *s, int argc, t_atom *argv)
{
  t_jet_movie *x = (t_jet_movie *)pd_new(jet_movie_class);
  (void)s;

  x->x_outlet = outlet_new(&x->x_obj, &s_bang);
  x->x_canvas = canvas_getcurrent();
  x->x_decoder = [[JetMovieDecoder alloc] init];
  x->x_path = new std::string();
  x->x_loaded = 0;
  x->x_loop = 1;
  x->x_playing = 1;
  x->x_customFps = 0.f;
  x->x_frameInterval = 1.0 / 30.0;
  x->x_nextDueTime = 0.0;
  x->x_hasSync = 0;
  x->x_syncName = gensym("default");
  x->x_async = nullptr;
  x->x_seenHitEndGeneration = 0;

  if(argc >= 2 && argv[1].a_type == A_SYMBOL) {
    x->x_syncName = atom_getsymbol(argv + 1);
    x->x_hasSync = 1;
  }
  if(argc >= 1) {
    jet_movie_open(x, atom_getsymbol(argv));
  }
  return (void *)x;
}

static void jet_movie_free(t_jet_movie *x)
{
  jet_movie_stop_async(x);
  [x->x_decoder release];
  delete x->x_path;
}

extern "C" void jet_movie_setup(void)
{
  jet_movie_class = class_new(gensym("jet_movie"),
                                (t_newmethod)jet_movie_new,
                                (t_method)jet_movie_free,
                                sizeof(t_jet_movie), CLASS_DEFAULT,
                                A_GIMME, 0);
  class_addbang(jet_movie_class, jet_movie_bang);
  class_addfloat(jet_movie_class, jet_movie_float);
  class_addmethod(jet_movie_class, (t_method)jet_movie_open,
                  gensym("open"), A_SYMBOL, 0);
  class_addmethod(jet_movie_class, (t_method)jet_movie_loop,
                  gensym("loop"), A_FLOAT, 0);
  class_addmethod(jet_movie_class, (t_method)jet_movie_fps,
                  gensym("fps"), A_FLOAT, 0);
  class_addmethod(jet_movie_class, (t_method)jet_movie_play,
                  gensym("play"), A_FLOAT, 0);
}
