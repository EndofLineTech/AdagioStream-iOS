#import <Foundation/Foundation.h>

@class VLCMediaPlayer;

NS_ASSUME_NONNULL_BEGIN

/// Bridges to libvlc's PCM-callback audio output (the "amem" module).  When
/// callbacks are registered on a VLCMediaPlayer's underlying libvlc handle,
/// VLC switches away from the iOS audiounit output module.  audiounit_ios is
/// what owns the AVAudioSession and calls
/// setActive(false, .notifyOthersOnDeactivation) on mediaPlayer.stop() —
/// the root cause of Apple Music auto-resuming during channel changes.
/// Once amem is engaged, AdagioStream owns AVAudioSession exclusively.
///
/// Phase 1 spike: counter-only callbacks (no PCM routing).  The goal is to
/// confirm the switch to amem actually neutralises the session manipulation.
@interface VLCAudioCallbackBridge : NSObject

/// Total play callbacks fired across all players since bridge load.
@property (class, readonly) NSInteger playCallbackCount;

/// Total format-setup callbacks fired since bridge load.
@property (class, readonly) NSInteger formatCallbackCount;

/// Register no-op PCM callbacks on `player`.  Must be called before
/// `[player play]`; libvlc binds the audio output module at playback start.
/// Returns YES if the underlying libvlc handle was accessible and
/// callbacks were registered.
+ (BOOL)attachCountingCallbacksToPlayer:(VLCMediaPlayer *)player;

@end

NS_ASSUME_NONNULL_END
