/* ------------------------------------------------------------------
 * jet_movie~ - decodes a movie file's audio track and plays it as
 * a Pd signal (stereo), at a controllable "speed" - the video half of
 * this pair is jet_movie (see jet_movie.mm); this object handles
 * only audio, on purpose (a signal object has a completely different
 * API from the bang-driven control objects everywhere else in this
 * collection).
 *
 * Decodes the whole track up front into memory via AVAssetReader,
 * requesting stereo output already resampled to Pd's own sample rate
 * (AVFoundation's audio converter does both the channel remix and the
 * sample-rate conversion for us) - simpler and safer than streaming
 * a compressed file's decode live inside the DSP callback. Fine for
 * typical clip lengths; a very long file will take a moment to load.
 *
 * Playback is a fractional read pointer into that buffer, advanced by
 * "speed" samples per output sample and linearly interpolated - so
 * speed 2.0 plays twice as fast AND an octave higher, speed 0.5 half
 * as fast and an octave lower: a physical tape machine's behavior,
 * not a time-stretcher (which would need much heavier DSP - a phase
 * vocoder or similar - to keep pitch constant while speed changes).
 *
 * Registers itself by name (jet_movie_shared.h) so a jet_movie
 * given the same name can slave its frame timing to this object's
 * playback position - see jet_movie.mm's sync branch in its own
 * bang handler.
 * ------------------------------------------------------------------
 */

#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <Foundation/Foundation.h>

#include "m_pd.h"
#include "jet_movie_shared.h"

#include <cmath>
#include <map>
#include <string>
#include <vector>

static t_class *jet_movie_tilde_class;

// ---------------------------------------------------------------
// cross-bundle registry (see jet_movie_shared.h)
// ---------------------------------------------------------------

typedef struct _jet_movie_tilde t_jet_movie_tilde;
static std::map<t_symbol *, t_jet_movie_tilde *> g_audioByName;

// ---------------------------------------------------------------
// decode: whole track, up front, into interleaved-turned-planar
// float buffers already at Pd's sample rate
// ---------------------------------------------------------------

static int jet_movie_tilde_decode(NSString *path, double sampleRate,
                                    std::vector<float> *outL,
                                    std::vector<float> *outR,
                                    NSString **errorOut)
{
  // NOTE: deliberately not wrapped in @autoreleasepool, unlike
  // jet_win_tick - this only runs once per "open", not once per
  // frame, so the garbage it produces isn't the accumulation problem;
  // more importantly, *errorOut below can point at an autoreleased
  // NSString (e.g. err.localizedDescription), and the caller reads it
  // right after this function returns - draining a pool before then
  // would leave that pointer dangling.
  NSURL *url = [NSURL fileURLWithPath:path];
  AVURLAsset *asset = [AVURLAsset URLAssetWithURL:url options:nil];
  AVAssetTrack *track = [[asset tracksWithMediaType:AVMediaTypeAudio] firstObject];
  if(!track) {
    if(errorOut) {
      *errorOut = @"no audio track";
    }
    return 0;
  }

  NSError *err = nil;
  AVAssetReader *reader = [[AVAssetReader alloc] initWithAsset:asset error:&err];
  if(!reader) {
    if(errorOut) {
      *errorOut = err.localizedDescription;
    }
    return 0;
  }

  // ask AVFoundation's own converter to do both the channel remix
  // (mono/surround -> stereo) and the sample-rate conversion to Pd's
  // rate, so we don't have to write either ourselves
  NSDictionary *settings = @{
    AVFormatIDKey : @(kAudioFormatLinearPCM),
    AVLinearPCMBitDepthKey : @32,
    AVLinearPCMIsFloatKey : @YES,
    AVLinearPCMIsBigEndianKey : @NO,
    AVLinearPCMIsNonInterleaved : @NO,
    AVNumberOfChannelsKey : @2,
    AVSampleRateKey : @(sampleRate),
  };
  AVAssetReaderTrackOutput *output =
    [[AVAssetReaderTrackOutput alloc] initWithTrack:track outputSettings:settings];
  [reader addOutput:output];

  if(![reader startReading]) {
    if(errorOut) {
      *errorOut = reader.error.localizedDescription ?: @"startReading failed";
    }
    return 0;
  }

  outL->clear();
  outR->clear();

  CMSampleBufferRef sample;
  while((sample = [output copyNextSampleBuffer])) {
    CMBlockBufferRef block = CMSampleBufferGetDataBuffer(sample);
    if(block) {
      size_t length = 0;
      char *dataPtr = NULL;
      CMBlockBufferGetDataPointer(block, 0, NULL, &length, &dataPtr);
      if(dataPtr) {
        const float *floats = (const float *)dataPtr;
        const size_t numFrames = length / (sizeof(float) * 2);  // interleaved stereo
        outL->reserve(outL->size() + numFrames);
        outR->reserve(outR->size() + numFrames);
        for(size_t i = 0; i < numFrames; i++) {
          outL->push_back(floats[i * 2 + 0]);
          outR->push_back(floats[i * 2 + 1]);
        }
      }
    }
    CFRelease(sample);
  }

  return !outL->empty();
}

// ---------------------------------------------------------------
// the Pd object
// ---------------------------------------------------------------

struct _jet_movie_tilde {
  t_object   x_obj;
  t_outlet  *x_outL;
  t_outlet  *x_outR;
  t_outlet  *x_doneOutlet;
  t_canvas  *x_canvas;

  t_symbol  *x_name;
  std::string *x_path;

  std::vector<float> *x_bufL;
  std::vector<float> *x_bufR;
  double     x_lenSamples;

  int        x_loaded;
  int        x_playing;
  int        x_loop;
  int        x_atEnd;
  double     x_speed;    // 1.0 = native rate/pitch
  double     x_readPos;  // fractional sample index into x_bufL/x_bufR
};

static void jet_movie_tilde_open(t_jet_movie_tilde *x, t_symbol *path)
{
  char resolved[MAXPDSTRING];
  canvas_makefilename(x->x_canvas, path->s_name, resolved, MAXPDSTRING);
  *x->x_path = resolved;

  NSString *nsPath = [NSString stringWithUTF8String:x->x_path->c_str()];
  NSString *err = nil;
  x->x_loaded = jet_movie_tilde_decode(nsPath, sys_getsr(), x->x_bufL, x->x_bufR, &err);
  if(x->x_loaded) {
    x->x_lenSamples = (double)x->x_bufL->size();
    x->x_readPos = 0.0;
    x->x_atEnd = 0;
    x->x_playing = 1;
    post("jet_movie~: loaded %s (%.2fs)", x->x_path->c_str(),
        x->x_lenSamples / sys_getsr());
  } else {
    pd_error(x, "jet_movie~: could not open '%s' (%s)", x->x_path->c_str(),
             err ? [err UTF8String] : "unknown error");
  }
}

static void jet_movie_tilde_play(t_jet_movie_tilde *x, t_floatarg f)
{
  x->x_playing = (f != 0.f);
}

static void jet_movie_tilde_loop(t_jet_movie_tilde *x, t_floatarg f)
{
  x->x_loop = (f != 0.f);
  if(x->x_loop) {
    x->x_atEnd = 0;
  }
}

static void jet_movie_tilde_speed(t_jet_movie_tilde *x, t_floatarg f)
{
  // clamp to a generous but finite range - beyond this it's just
  // noise anyway, and it keeps pos's per-sample step bounded
  if(f > 50.f) f = 50.f;
  if(f < -50.f) f = -50.f;
  x->x_speed = f;  // negative = backward, 0 = frozen on the current sample
}

static t_int *jet_movie_tilde_perform(t_int *w)
{
  t_jet_movie_tilde *x = (t_jet_movie_tilde *)w[1];
  t_sample *outL = (t_sample *)w[2];
  t_sample *outR = (t_sample *)w[3];
  int n = (int)w[4];

  if(!x->x_loaded || !x->x_playing || x->x_lenSamples < 2.0) {
    while(n--) {
      *outL++ = 0;
      *outR++ = 0;
    }
    return w + 5;
  }

  const std::vector<float> &bufL = *x->x_bufL;
  const std::vector<float> &bufR = *x->x_bufR;
  const double len = x->x_lenSamples;
  const double wrapLen = len - 1.0;  // leaves room for the i1 = i0+1 lookahead
  double pos = x->x_readPos;
  int hitEnd = 0;

  for(int i = 0; i < n; i++) {
    if(pos < 0.0 || pos >= wrapLen) {
      if(x->x_loop) {
        // fmod, not a single +=/-= len correction: a large |speed|
        // (someone yanking the speed slider) can overshoot by more
        // than one buffer length in a single sample - that used to
        // leave pos out of range and read bufL/bufR out of bounds
        pos = fmod(pos, wrapLen);
        if(pos < 0.0) {
          pos += wrapLen;
        }
      } else {
        hitEnd = 1;
        outL[i] = 0.f;
        outR[i] = 0.f;
        pos += x->x_speed;
        continue;
      }
    }

    const int i0 = (int)pos;
    const int i1 = (i0 + 1 < (int)len) ? i0 + 1 : i0;
    const float frac = (float)(pos - i0);
    outL[i] = bufL[i0] + frac * (bufL[i1] - bufL[i0]);
    outR[i] = bufR[i0] + frac * (bufR[i1] - bufR[i0]);
    pos += x->x_speed;
  }

  x->x_readPos = pos;

  if(hitEnd && !x->x_atEnd) {
    x->x_atEnd = 1;
    x->x_playing = 0;
    // stock (non-JACK) Pd runs perform on the same single thread as
    // message dispatch, so calling outlet_bang from here is safe -
    // same convention sfplay~/tabplay~-style objects rely on.
    outlet_bang(x->x_doneOutlet);
  }

  return w + 5;
}

static void jet_movie_tilde_dsp(t_jet_movie_tilde *x, t_signal **sp)
{
  dsp_add(jet_movie_tilde_perform, 4, x, sp[0]->s_vec, sp[1]->s_vec,
         (t_int)sp[0]->s_n);
}

static void *jet_movie_tilde_new(t_symbol *s, int argc, t_atom *argv)
{
  t_jet_movie_tilde *x = (t_jet_movie_tilde *)pd_new(jet_movie_tilde_class);
  (void)s;

  x->x_outL = outlet_new(&x->x_obj, &s_signal);
  x->x_outR = outlet_new(&x->x_obj, &s_signal);
  x->x_doneOutlet = outlet_new(&x->x_obj, &s_bang);
  x->x_canvas = canvas_getcurrent();

  x->x_path = new std::string();
  x->x_bufL = new std::vector<float>();
  x->x_bufR = new std::vector<float>();
  x->x_lenSamples = 0.0;

  x->x_loaded = 0;
  x->x_playing = 0;
  x->x_loop = 1;
  x->x_atEnd = 0;
  x->x_speed = 1.0;
  x->x_readPos = 0.0;

  t_symbol *name = gensym("default");
  t_symbol *path = nullptr;
  for(int i = 0; i < argc; i++) {
    if(argv[i].a_type == A_SYMBOL) {
      if(!path) {
        path = atom_getsymbol(argv + i);
      } else {
        name = atom_getsymbol(argv + i);
      }
    }
  }
  x->x_name = name;

  if(g_audioByName.count(name)) {
    pd_error(x, "jet_movie~: a jet_movie~ named '%s' already exists - a "
             "jet_movie targeting that name will sync to whichever one was "
             "created last", name->s_name);
  }
  g_audioByName[name] = x;

  if(path) {
    jet_movie_tilde_open(x, path);
  }

  return (void *)x;
}

static void jet_movie_tilde_free(t_jet_movie_tilde *x)
{
  auto it = g_audioByName.find(x->x_name);
  if(it != g_audioByName.end() && it->second == x) {
    g_audioByName.erase(it);
  }
  delete x->x_path;
  delete x->x_bufL;
  delete x->x_bufR;
}

extern "C" int jet_movie_audio_get_position(t_symbol *name, double *outSeconds)
{
  auto it = g_audioByName.find(name);
  if(it == g_audioByName.end() || !it->second->x_loaded) {
    return 0;
  }
  *outSeconds = it->second->x_readPos / sys_getsr();
  return 1;
}

extern "C" void jet_movie_tilde_setup(void)
{
  jet_movie_tilde_class = class_new(gensym("jet_movie~"),
                                      (t_newmethod)jet_movie_tilde_new,
                                      (t_method)jet_movie_tilde_free,
                                      sizeof(t_jet_movie_tilde), CLASS_DEFAULT,
                                      A_GIMME, 0);
  class_addmethod(jet_movie_tilde_class, (t_method)jet_movie_tilde_dsp,
                  gensym("dsp"), A_CANT, 0);
  class_addmethod(jet_movie_tilde_class, (t_method)jet_movie_tilde_open,
                  gensym("open"), A_SYMBOL, 0);
  class_addmethod(jet_movie_tilde_class, (t_method)jet_movie_tilde_play,
                  gensym("play"), A_FLOAT, 0);
  class_addmethod(jet_movie_tilde_class, (t_method)jet_movie_tilde_loop,
                  gensym("loop"), A_FLOAT, 0);
  class_addmethod(jet_movie_tilde_class, (t_method)jet_movie_tilde_speed,
                  gensym("speed"), A_FLOAT, 0);
}
