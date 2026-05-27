#import <Foundation/Foundation.h>

@class VLCMediaPlayer;

NS_ASSUME_NONNULL_BEGIN

/// Bridges to libvlc's PCM-callback audio output (the "amem" module) and
/// routes the decoded samples through a lock-free single-producer
/// single-consumer ring buffer for an AVAudioEngine-based Swift pipeline.
///
/// Engaging amem switches VLC away from the iOS audiounit_ios output
/// module, which is the module that owns AVAudioSession and calls
/// `setActive(false, .notifyOthersOnDeactivation)` on mediaPlayer.stop()
/// — the root cause of Apple Music auto-resuming during channel changes.
/// With this bridge live, AdagioStream owns the audio session exclusively
/// and VLC never touches it.
@interface VLCAudioCallbackBridge : NSObject

/// Total play callbacks fired across all players since bridge load.
@property (class, readonly) NSInteger playCallbackCount;

/// Total format-setup callbacks fired since bridge load.
@property (class, readonly) NSInteger formatCallbackCount;

/// Frames currently buffered (ready to be pulled by the render block).
@property (class, readonly) NSInteger bufferedFrames;

/// Frames dropped because the ring buffer was full when VLC tried to
/// push samples.  Steady-state should be 0; non-zero indicates the
/// AVAudioEngine isn't draining fast enough.
@property (class, readonly) NSInteger droppedFrameCount;

/// The `count` argument from the most recent play_cb invocation.
/// VLC's chunk size — typically 1024–2048 stereo frames per call.
/// Useful for sanity-checking the frames-per-channel interpretation
/// of the libvlc audio callback contract.
@property (class, readonly) NSInteger lastPlayCallbackCount;

/// The PTS (presentation timestamp, microseconds) of the most recent
/// play_cb invocation.  Combined with playCallbackCount and wall-clock
/// delta, lets us empirically verify VLC is producing audio at the
/// requested sample rate.
@property (class, readonly) int64_t lastPlayCallbackPTS;

/// Total frames received across all play_cb invocations.  At 48 kHz
/// stereo this should accumulate at roughly 48,000 frames/sec of
/// playback wall-clock time; large deviations indicate sample-rate
/// mismatch between what we asked for and what VLC produced.
@property (class, readonly) NSInteger totalReceivedFrames;

/// Render-block invocations where the ring buffer didn't have enough
/// frames to satisfy the requested frameCount and we had to zero-fill
/// the tail.  Steady-state should be 0; occasional underruns at
/// startup are expected.
@property (class, readonly) NSInteger renderUnderrunCount;

/// Total render-block invocations since launch.  Provides a denominator
/// for the underrun rate.
@property (class, readonly) NSInteger renderCallCount;

/// Called from the render block whenever we couldn't deliver as many
/// frames as the engine asked for.  REAL-TIME safe (atomic increment).
+ (void)reportUnderrun;

/// Called from the render block on every invocation.  REAL-TIME safe.
+ (void)reportRenderCall;

/// Zero the render-block counters (renderCallCount, renderUnderrunCount).
/// Call when a new stream starts so the per-stream underrun rate is
/// visible — without this, counters accumulate across long buffering
/// gaps where every render call is naturally an underrun, swamping
/// the steady-state signal.
+ (void)resetRenderCounters;

/// Register PCM callbacks on `player` and pin its decoder output to
/// FL32 (float32 native endian, interleaved) at the given rate/channels.
/// Must be called before `[player play]`.  Returns YES if the underlying
/// libvlc handle was reachable and callbacks were registered.
+ (BOOL)attachAudioCallbacksToPlayer:(VLCMediaPlayer *)player
                          sampleRate:(uint32_t)sampleRate
                            channels:(uint32_t)channels;

/// Pull up to `maxFrames` stereo frames from the ring buffer and
/// de-interleave them into the planar `left` and `right` channel
/// destinations.  Returns the number of frames actually written.
/// REAL-TIME SAFE — no allocations, no locks.  Intended for invocation
/// from an AVAudioSourceNode render block configured with a non-
/// interleaved AVAudioFormat (iOS only accepts planar formats on AU
/// input buses, which is why we de-interleave here instead of giving
/// Swift the raw interleaved bytes).
+ (NSInteger)pullFramesIntoLeft:(float *)left
                          right:(float *)right
                      maxFrames:(NSInteger)maxFrames;

/// Drop everything currently buffered.  Call between streams (after
/// mediaPlayer.stop, before the next mediaPlayer.play) so the tail of
/// the previous channel doesn't leak into the new one.
+ (void)flushBuffer;

@end

NS_ASSUME_NONNULL_END
