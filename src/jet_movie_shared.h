/* ------------------------------------------------------------------
 * jet_movie_shared.h - lets a jet_movie (video, bang-driven)
 * slave its frame timing to a jet_movie~ (audio, signal-rate) by
 * name, the same cross-bundle-symbol trick as jet_shared.h.
 *
 * jet_movie~ decodes its track once up front into an in-memory
 * buffer and plays it back with a fractional read pointer whose step
 * size is the "speed" message (1.0 = native) - so raising speed
 * raises pitch too, like a tape machine, rather than time-stretching.
 * That same fractional position, in source-clip seconds, is what
 * jet_movie_audio_get_position exposes below: a synced jet_movie
 * decodes forward to keep pace with it instead of free-running off
 * its own fps timer, so picture and sound (and picture and
 * pitch-shifted sound) stay together even while speed changes.
 *
 * The name -> jet_movie~ registry itself lives inside
 * jet_movie~.mm (it's the only bundle that ever needs to look
 * itself up); this header only exposes the read-only query other
 * bundles actually need.
 *
 * Both objects default to name "default" when no name is given, so
 * a lone [jet_movie~ clip.mp4] with no matching [jet_movie ...]
 * just plays audio on its own, and a lone [jet_movie ...] with no
 * matching [jet_movie~ ...] keeps its existing self-timed fps
 * playback - this is opt-in, not a required pairing.
 *
 * jet_movie.mm does NOT call jet_movie_audio_get_position as a
 * normal declared-and-linked symbol - it resolves it itself via
 * dlsym(RTLD_DEFAULT, ...) at first use instead. Two reasons ruled
 * out the obvious alternatives: a plain -undefined dynamic_lookup
 * reference (no attribute) makes dlopen() fail for the WHOLE
 * jet_movie.pd_darwin bundle if jet_movie~.pd_darwin hasn't
 * loaded yet - breaking every plain video-only patch. Marking it
 * weak_import fixes that dlopen failure, but weak references are
 * bound once, at the moment the REFERENCING bundle loads, using
 * whatever's in the process at that exact instant - if jet_movie~
 * sits below jet_movie in a patch (the common case), the weak
 * reference binds to NULL permanently, even after jet_movie~ loads
 * moments later. dlsym has neither problem: it's a live lookup
 * against the process's current state, safe to call (and retry)
 * regardless of load/creation order. This header still documents the
 * function's signature/contract, but nothing links against it.
 * ------------------------------------------------------------------
 */
#ifndef _INCLUDE__JET_MOVIE_SHARED_H_
#define _INCLUDE__JET_MOVIE_SHARED_H_

#include "m_pd.h"

#ifdef __cplusplus
extern "C" {
#endif

// fills outSeconds with the current playback position (in the source
// clip's own timeline, already accounting for "speed") of the
// jet_movie~ registered under `name` and returns 1, or returns 0 if
// no jet_movie~ is registered under that name (caller should fall
// back to its own timing in that case). callers should look this up
// via dlsym(RTLD_DEFAULT, "jet_movie_audio_get_position") - see the
// note above - rather than declaring/calling it directly.
int jet_movie_audio_get_position(t_symbol *name, double *outSeconds);

#ifdef __cplusplus
}
#endif

#endif
