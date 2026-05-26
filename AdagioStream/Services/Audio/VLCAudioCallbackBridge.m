#import "VLCAudioCallbackBridge.h"
#import <stdatomic.h>

// The libvlc C audio-callback API lives in vlc/libvlc_media_player.h, which
// ships inside MobileVLCKit.framework/Headers/vlc/ but is explicitly excluded
// from the framework's modulemap (so Swift's `import MobileVLCKit` can't see
// it).  Obj-C `#import` by path still resolves through the framework search
// path; we just need to silence the modularity warning that Clang emits when
// pulling a non-modular header into a framework-aware translation unit.
//
// Importing the real header (instead of hand-typing `extern` declarations)
// means the compiler validates our call sites against the same signatures
// the framework was built against — any future libvlc API drift fails loudly
// at build time instead of silently at runtime.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wnon-modular-include-in-framework-module"
#pragma clang diagnostic ignored "-Wquoted-include-in-framework-header"
#import <MobileVLCKit/MobileVLCKit.h>
// vlc.h is the umbrella; it defines LIBVLC_API and pulls in the
// libvlc_media_t / libvlc_instance_t typedefs that libvlc_media_player.h
// depends on.  Including just libvlc_media_player.h fails to compile
// because those dependencies are expected to already be in scope.
#import <MobileVLCKit/vlc/vlc.h>
#pragma clang diagnostic pop

// VLCMediaPlayer+Internal.h (PrivateHeaders) exposes
// `@property (readonly) libvlc_media_player_t *playerInstance`.  Re-declare
// as a category so Obj-C runtime dispatch resolves to the same getter
// without touching PrivateHeaders.  If a future VLCKit removes the selector,
// the respondsToSelector check below catches it gracefully.
@interface VLCMediaPlayer (AdagioInternal)
- (libvlc_media_player_t *)playerInstance;
@end

static atomic_long _playCallbackCount = 0;
static atomic_long _formatCallbackCount = 0;

static void adagio_audio_play_cb(void *data, const void *samples,
                                 unsigned count, int64_t pts) {
    atomic_fetch_add(&_playCallbackCount, 1);
}

static void adagio_audio_pause_cb(void *data, int64_t pts) { }
static void adagio_audio_resume_cb(void *data, int64_t pts) { }
static void adagio_audio_flush_cb(void *data, int64_t pts) { }
static void adagio_audio_drain_cb(void *data) { }

static int adagio_audio_setup_cb(void **data, char *format,
                                 unsigned *rate, unsigned *channels) {
    atomic_fetch_add(&_formatCallbackCount, 1);
    // Accept whatever VLC negotiates — phase 1 doesn't route PCM anywhere.
    return 0;
}

static void adagio_audio_cleanup_cb(void *data) { }

@implementation VLCAudioCallbackBridge

+ (NSInteger)playCallbackCount {
    return (NSInteger)atomic_load(&_playCallbackCount);
}

+ (NSInteger)formatCallbackCount {
    return (NSInteger)atomic_load(&_formatCallbackCount);
}

+ (BOOL)attachCountingCallbacksToPlayer:(VLCMediaPlayer *)player {
    if (!player) { return NO; }
    if (![player respondsToSelector:@selector(playerInstance)]) { return NO; }

    libvlc_media_player_t *mp = [player playerInstance];
    if (!mp) { return NO; }

    libvlc_audio_set_format_callbacks(mp,
                                      adagio_audio_setup_cb,
                                      adagio_audio_cleanup_cb);
    libvlc_audio_set_callbacks(mp,
                               adagio_audio_play_cb,
                               adagio_audio_pause_cb,
                               adagio_audio_resume_cb,
                               adagio_audio_flush_cb,
                               adagio_audio_drain_cb,
                               NULL);
    return YES;
}

@end
