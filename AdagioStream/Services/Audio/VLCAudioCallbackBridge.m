#import "VLCAudioCallbackBridge.h"
#import <stdatomic.h>
#import <string.h>

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wnon-modular-include-in-framework-module"
#pragma clang diagnostic ignored "-Wquoted-include-in-framework-header"
#import <MobileVLCKit/MobileVLCKit.h>
// vlc.h is the umbrella; it defines LIBVLC_API and pulls in the
// libvlc_media_t / libvlc_instance_t typedefs that libvlc_media_player.h
// depends on.  Importing the real header (instead of hand-typed extern
// declarations) means the compiler validates our call sites against the
// same signatures the framework was built against — any future libvlc
// API drift fails loudly at build time instead of silently at runtime.
#import <MobileVLCKit/vlc/vlc.h>
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

/// PRODUCER side — called from VLC's audio thread.
static void adg_ring_write(const float *samples, uint64_t frames) {
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
    if (frames <= until_wrap) {
        memcpy(&adg_ring_buffer[head_idx * ADG_FRAME_FLOATS],
               samples,
               frames * ADG_FRAME_FLOATS * sizeof(float));
    } else {
        memcpy(&adg_ring_buffer[head_idx * ADG_FRAME_FLOATS],
               samples,
               until_wrap * ADG_FRAME_FLOATS * sizeof(float));
        memcpy(&adg_ring_buffer[0],
               samples + until_wrap * ADG_FRAME_FLOATS,
               (frames - until_wrap) * ADG_FRAME_FLOATS * sizeof(float));
    }
    atomic_store_explicit(&adg_ring_head, head + frames, memory_order_release);
}

/// CONSUMER side — called from the AVAudioSourceNode render thread.
static uint64_t adg_ring_read(float *dest, uint64_t max_frames) {
    if (max_frames == 0) { return 0; }
    uint64_t tail = atomic_load_explicit(&adg_ring_tail, memory_order_relaxed);
    uint64_t head = atomic_load_explicit(&adg_ring_head, memory_order_acquire);
    uint64_t available = head - tail;
    uint64_t to_read = available < max_frames ? available : max_frames;
    if (to_read == 0) { return 0; }

    uint64_t tail_idx = tail & ADG_RING_MASK;
    uint64_t until_wrap = (uint64_t)ADG_RING_CAPACITY - tail_idx;
    if (to_read <= until_wrap) {
        memcpy(dest,
               &adg_ring_buffer[tail_idx * ADG_FRAME_FLOATS],
               to_read * ADG_FRAME_FLOATS * sizeof(float));
    } else {
        memcpy(dest,
               &adg_ring_buffer[tail_idx * ADG_FRAME_FLOATS],
               until_wrap * ADG_FRAME_FLOATS * sizeof(float));
        memcpy(dest + until_wrap * ADG_FRAME_FLOATS,
               &adg_ring_buffer[0],
               (to_read - until_wrap) * ADG_FRAME_FLOATS * sizeof(float));
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
    adg_ring_write((const float *)samples, (uint64_t)count);
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

+ (NSInteger)pullFramesInto:(float *)dest maxFrames:(NSInteger)maxFrames {
    if (!dest || maxFrames <= 0) { return 0; }
    return (NSInteger)adg_ring_read(dest, (uint64_t)maxFrames);
}

+ (void)flushBuffer {
    adg_ring_flush();
}

@end
