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

/// Register PCM callbacks on `player` and pin its decoder output to
/// FL32 (float32 native endian, interleaved) at the given rate/channels.
/// Must be called before `[player play]`.  Returns YES if the underlying
/// libvlc handle was reachable and callbacks were registered.
+ (BOOL)attachAudioCallbacksToPlayer:(VLCMediaPlayer *)player
                          sampleRate:(uint32_t)sampleRate
                            channels:(uint32_t)channels;

/// Pull up to `maxFrames` stereo interleaved float32 frames from the
/// ring buffer into `dest`.  Returns the number of frames actually
/// written.  REAL-TIME SAFE — no allocations, no locks.  Intended for
/// invocation from an AVAudioSourceNode render block.
+ (NSInteger)pullFramesInto:(float *)dest maxFrames:(NSInteger)maxFrames;

/// Drop everything currently buffered.  Call between streams (after
/// mediaPlayer.stop, before the next mediaPlayer.play) so the tail of
/// the previous channel doesn't leak into the new one.
+ (void)flushBuffer;

@end

NS_ASSUME_NONNULL_END
