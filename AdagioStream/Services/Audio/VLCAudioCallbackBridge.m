#import "VLCAudioCallbackBridge.h"
#import <stdatomic.h>
#import <string.h>

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wnon-modular-include-in-framework-module"
#pragma clang diagnostic ignored "-Wquoted-include-in-framework-header"
#if TARGET_OS_TV
#import <TVVLCKit/TVVLCKit.h>
// vlc.h is the umbrella; it defines LIBVLC_API and pulls in the
// libvlc_media_t / libvlc_instance_t typedefs that libvlc_media_player.h
// depends on.  Importing the real header (instead of hand-typed extern
// declarations) means the compiler validates our call sites against the
// same signatures the framework was built against — any future libvlc
// API drift fails loudly at build time instead of silently at runtime.
#import <TVVLCKit/vlc/vlc.h>
#else
#import <MobileVLCKit/MobileVLCKit.h>
#import <MobileVLCKit/vlc/vlc.h>
#endif
#pragma clang diagnostic pop

// VLCMediaPlayer+Internal.h (PrivateHeaders) exposes
// `@property (readonly) libvlc_media_player_t *playerInstance`.  Declare
// it via a category so Obj-C dispatch resolves to the same getter at
// runtime without needing the PrivateHeaders on the search path.  The
// respondsToSelector check inside attachAudioCallbacksToPlayer turns a
// future selector removal into a graceful runtime failure.
@interface VLCMediaPlayer (AdagioInternal)
- (libvlc_media_player_t *)playerInstance;
@end

#pragma mark - Lock-free SPSC ring buffer

// Capacity is in stereo FRAMES (one frame = 2 floats = 8 bytes).
// 131072 frames at 48kHz ≈ 2.73 seconds — plenty of headroom against
// AVAudioEngine render bursts while staying small enough that flushes
// are cheap.  Must be a power of two so the wrap mask works.
#define ADG_RING_CAPACITY 131072u
#define ADG_RING_MASK (ADG_RING_CAPACITY - 1u)
#define ADG_FRAME_FLOATS 2u  // stereo

static float adg_ring_buffer[ADG_RING_CAPACITY * ADG_FRAME_FLOATS];
// Indices are monotonic frame counts; we mask to derive the in-buffer
// position.  Using monotonic counters avoids the "empty vs full"
// ambiguity that plagues mod-capacity index designs.
static _Atomic uint64_t adg_ring_head = 0;  // producer writes here
static _Atomic uint64_t adg_ring_tail = 0;  // consumer reads from here

static _Atomic long adg_play_count = 0;
static _Atomic long adg_format_count = 0;
static _Atomic long adg_dropped_frames = 0;
static _Atomic long adg_last_cb_count = 0;
static _Atomic int_least64_t adg_last_cb_pts = 0;
static _Atomic long adg_total_frames = 0;
static _Atomic long adg_render_underruns = 0;
static _Atomic long adg_render_calls = 0;

/// 1.0 / 32768.0, precomputed so the conversion loop is a single
/// multiplication per sample.  Int16 PCM is signed [-32768, 32767];
/// dividing by 32768 maps to [-1.0, 1.0) which is what AVAudioEngine
/// expects for float32 audio.
static const float kInt16ToFloat = 1.0f / 32768.0f;

/// PRODUCER side — called from VLC's audio thread.
///
/// VLC 3.x's amem audio output module hardcodes its sample format to
/// S16N regardless of what libvlc_audio_set_format() requests (see
/// modules/audio_output/amem.c — there's a literal `TODO: amem-format`
/// in the source).  So `samples` is ALWAYS interleaved int16 here,
/// never float32 as the API surface implies.  We convert on the
/// producer side so the rest of the pipeline (ring buffer, render
/// block) keeps the cleaner float32 contract.
static void adg_ring_write(const int16_t *samples, uint64_t frames) {
    if (frames == 0) { return; }
    uint64_t head = atomic_load_explicit(&adg_ring_head, memory_order_relaxed);
    uint64_t tail = atomic_load_explicit(&adg_ring_tail, memory_order_acquire);
    uint64_t used = head - tail;
    uint64_t freeFrames = (uint64_t)ADG_RING_CAPACITY - used;

    if (frames > freeFrames) {
        // Drop the overflow rather than block.  Blocking VLC's audio
        // thread would cascade into decoder stalls; dropping is the
        // standard CoreAudio overflow policy.
        atomic_fetch_add_explicit(&adg_dropped_frames,
                                  (long)(frames - freeFrames),
                                  memory_order_relaxed);
        frames = freeFrames;
        if (frames == 0) { return; }
    }

    uint64_t head_idx = head & ADG_RING_MASK;
    uint64_t until_wrap = (uint64_t)ADG_RING_CAPACITY - head_idx;
    uint64_t first_chunk = (frames <= until_wrap) ? frames : until_wrap;

    // Convert int16 → float32 sample-by-sample.  Hot path, but the
    // math is one multiply per sample and modern CPUs vectorise this
    // trivially; profile if it ever shows up as a hotspot.
    float *dst = &adg_ring_buffer[head_idx * ADG_FRAME_FLOATS];
    const int16_t *src = samples;
    for (uint64_t i = 0; i < first_chunk * ADG_FRAME_FLOATS; i++) {
        dst[i] = (float)src[i] * kInt16ToFloat;
    }

    if (frames > until_wrap) {
        uint64_t second_chunk = frames - until_wrap;
        float *dst2 = &adg_ring_buffer[0];
        const int16_t *src2 = samples + until_wrap * ADG_FRAME_FLOATS;
        for (uint64_t i = 0; i < second_chunk * ADG_FRAME_FLOATS; i++) {
            dst2[i] = (float)src2[i] * kInt16ToFloat;
        }
    }
    atomic_store_explicit(&adg_ring_head, head + frames, memory_order_release);
}

/// CONSUMER side — called from the AVAudioSourceNode render thread.
/// De-interleaves into separate L/R buffers in the same pass that
/// reads from the ring, keeping the render block allocation-free.
static uint64_t adg_ring_read_planar(float *left, float *right,
                                     uint64_t max_frames) {
    if (max_frames == 0) { return 0; }
    uint64_t tail = atomic_load_explicit(&adg_ring_tail, memory_order_relaxed);
    uint64_t head = atomic_load_explicit(&adg_ring_head, memory_order_acquire);
    uint64_t available = head - tail;
    uint64_t to_read = available < max_frames ? available : max_frames;
    if (to_read == 0) { return 0; }

    for (uint64_t i = 0; i < to_read; i++) {
        uint64_t idx = (tail + i) & ADG_RING_MASK;
        left[i]  = adg_ring_buffer[idx * ADG_FRAME_FLOATS + 0];
        right[i] = adg_ring_buffer[idx * ADG_FRAME_FLOATS + 1];
    }
    atomic_store_explicit(&adg_ring_tail, tail + to_read, memory_order_release);
    return to_read;
}

static void adg_ring_flush(void) {
    // Snap tail to head — drops anything currently buffered.  Producer
    // may be writing concurrently; that's fine, we just lose whatever
    // it adds between our load and store (intentional for flush).
    uint64_t head = atomic_load_explicit(&adg_ring_head, memory_order_acquire);
    atomic_store_explicit(&adg_ring_tail, head, memory_order_release);
}

#pragma mark - libvlc callbacks

static void adg_audio_play_cb(void *data, const void *samples,
                              unsigned count, int64_t pts) {
    atomic_fetch_add_explicit(&adg_play_count, 1, memory_order_relaxed);
    atomic_store_explicit(&adg_last_cb_count, (long)count, memory_order_relaxed);
    atomic_store_explicit(&adg_last_cb_pts, (int_least64_t)pts, memory_order_relaxed);
    atomic_fetch_add_explicit(&adg_total_frames, (long)count, memory_order_relaxed);
    adg_ring_write((const int16_t *)samples, (uint64_t)count);
}

static void adg_audio_pause_cb(void *data, int64_t pts) {
    // VLC handles the pause itself (stops issuing play_cb).  We don't
    // flush the ring buffer here so resume picks up where we left off
    // without an audible jump.
}

static void adg_audio_resume_cb(void *data, int64_t pts) { }

static void adg_audio_flush_cb(void *data, int64_t pts) {
    adg_ring_flush();
}

static void adg_audio_drain_cb(void *data) {
    // Let already-buffered audio play out; nothing to do.
}

#pragma mark - VLCAudioCallbackBridge

@implementation VLCAudioCallbackBridge

+ (NSInteger)playCallbackCount {
    return (NSInteger)atomic_load_explicit(&adg_play_count, memory_order_relaxed);
}

+ (NSInteger)formatCallbackCount {
    return (NSInteger)atomic_load_explicit(&adg_format_count, memory_order_relaxed);
}

+ (NSInteger)bufferedFrames {
    uint64_t head = atomic_load_explicit(&adg_ring_head, memory_order_acquire);
    uint64_t tail = atomic_load_explicit(&adg_ring_tail, memory_order_acquire);
    return (NSInteger)(head - tail);
}

+ (NSInteger)droppedFrameCount {
    return (NSInteger)atomic_load_explicit(&adg_dropped_frames, memory_order_relaxed);
}

+ (NSInteger)lastPlayCallbackCount {
    return (NSInteger)atomic_load_explicit(&adg_last_cb_count, memory_order_relaxed);
}

+ (int64_t)lastPlayCallbackPTS {
    return (int64_t)atomic_load_explicit(&adg_last_cb_pts, memory_order_relaxed);
}

+ (NSInteger)totalReceivedFrames {
    return (NSInteger)atomic_load_explicit(&adg_total_frames, memory_order_relaxed);
}

+ (NSInteger)renderUnderrunCount {
    return (NSInteger)atomic_load_explicit(&adg_render_underruns, memory_order_relaxed);
}

+ (NSInteger)renderCallCount {
    return (NSInteger)atomic_load_explicit(&adg_render_calls, memory_order_relaxed);
}

+ (void)reportUnderrun {
    atomic_fetch_add_explicit(&adg_render_underruns, 1, memory_order_relaxed);
}

+ (void)reportRenderCall {
    atomic_fetch_add_explicit(&adg_render_calls, 1, memory_order_relaxed);
}

+ (void)resetRenderCounters {
    atomic_store_explicit(&adg_render_calls, 0, memory_order_relaxed);
    atomic_store_explicit(&adg_render_underruns, 0, memory_order_relaxed);
}

+ (BOOL)attachAudioCallbacksToPlayer:(VLCMediaPlayer *)player
                          sampleRate:(uint32_t)sampleRate
                            channels:(uint32_t)channels {
    if (!player) { return NO; }
    if (![player respondsToSelector:@selector(playerInstance)]) { return NO; }

    libvlc_media_player_t *mp = [player playerInstance];
    if (!mp) { return NO; }

    // Pin VLC's decoder output to FL32 interleaved at the requested
    // rate / channel count.  libvlc handles any necessary resampling
    // internally, so we always receive the AVAudioEngine-friendly
    // format and never need a Swift-side converter.  This call must
    // come BEFORE set_callbacks per the libvlc docs.
    libvlc_audio_set_format(mp, "FL32", sampleRate, channels);
    atomic_fetch_add_explicit(&adg_format_count, 1, memory_order_relaxed);

    libvlc_audio_set_callbacks(mp,
                               adg_audio_play_cb,
                               adg_audio_pause_cb,
                               adg_audio_resume_cb,
                               adg_audio_flush_cb,
                               adg_audio_drain_cb,
                               NULL);
    return YES;
}

+ (NSInteger)pullFramesIntoLeft:(float *)left
                          right:(float *)right
                      maxFrames:(NSInteger)maxFrames {
    if (!left || !right || maxFrames <= 0) { return 0; }
    return (NSInteger)adg_ring_read_planar(left, right, (uint64_t)maxFrames);
}

+ (void)flushBuffer {
    adg_ring_flush();
}

@end
