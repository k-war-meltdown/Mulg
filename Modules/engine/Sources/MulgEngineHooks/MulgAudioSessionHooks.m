#import "MulgEngineHooks.h"
#include <TargetConditionals.h>
#include <stdatomic.h>
#include <math.h>

static _Atomic(double) protected_sample_rate;
static void (^session_changed)(void);
@interface MulgAudioPolicyLock : NSObject @end
@implementation MulgAudioPolicyLock @end

void mulg_engine_configure_audio_preference(double rate, void (^handler)(void)) {
    atomic_store(&protected_sample_rate, isfinite(rate) && rate > 0 ? rate : 0);
    @synchronized ([MulgAudioPolicyLock class]) { session_changed = [handler copy]; }
}

#if TARGET_OS_IPHONE
#import <AVFoundation/AVFoundation.h>

static IMP original_rate, original_active, original_active_options;
static __thread unsigned applying_audio_preference;

static void audio_session_changed(void) {
    void (^handler)(void);
    @synchronized ([MulgAudioPolicyLock class]) { handler = [session_changed copy]; }
    if (handler) dispatch_async(dispatch_get_main_queue(), handler);
}

static BOOL preferred_rate(id session, SEL selector, double requested, NSError **error) {
    double target = atomic_load(&protected_sample_rate);
    if (applying_audio_preference || target <= 0
        || !mulg_engine_is_game_caller(__builtin_return_address(0))) {
        return ((BOOL (*)(id, SEL, double, NSError **))original_rate)(session, selector, requested, error);
    }
    applying_audio_preference++;
    BOOL result;
    @try {
        NSError *preferenceError = nil;
        result = ((BOOL (*)(id, SEL, double, NSError **))original_rate)(session, selector, target, &preferenceError);
        // Some session categories reject a high rate even when the Mac device supports it.
        // Keep playback viable and let CoreAudio convert the client's real format instead.
        if (!result && target != requested) {
            result = ((BOOL (*)(id, SEL, double, NSError **))original_rate)(session, selector, requested, error);
        } else if (error) { *error = result ? nil : preferenceError; }
    } @finally { applying_audio_preference--; }
    audio_session_changed();
    return result;
}

static BOOL set_active(id session, SEL selector, BOOL active, NSError **error) {
    BOOL game = !applying_audio_preference && mulg_engine_is_game_caller(__builtin_return_address(0));
    applying_audio_preference++;
    BOOL result;
    @try { result = ((BOOL (*)(id, SEL, BOOL, NSError **))original_active)(session, selector, active, error); }
    @finally { applying_audio_preference--; }
    if (game && result && active) audio_session_changed();
    return result;
}

static BOOL set_active_options(id session, SEL selector, BOOL active, NSUInteger options, NSError **error) {
    BOOL game = !applying_audio_preference && mulg_engine_is_game_caller(__builtin_return_address(0));
    applying_audio_preference++;
    BOOL result;
    @try { result = ((BOOL (*)(id, SEL, BOOL, NSUInteger, NSError **))original_active_options)(session, selector, active, options, error); }
    @finally { applying_audio_preference--; }
    if (game && result && active) audio_session_changed();
    return result;
}

MulgEngineAudioHook mulg_engine_install_audio_hooks(void) {
    MulgEngineAudioHook installed = 0;
    Class cls = [AVAudioSession class];
    if (mulg_swizzle_checked_owned("engine", cls, @selector(setPreferredSampleRate:error:),
        (IMP)preferred_rate, &original_rate, @encode(BOOL), @[@"d", @"^@"]) == MulgSwizzleResultReplaced)
        installed |= MulgEngineAudioHookPreferredRate;
    if (mulg_swizzle_checked_owned("engine", cls, @selector(setActive:error:),
        (IMP)set_active, &original_active, @encode(BOOL), @[@(@encode(BOOL)), @"^@"]) == MulgSwizzleResultReplaced)
        installed |= MulgEngineAudioHookActive;
    if (mulg_swizzle_checked_owned("engine", cls, @selector(setActive:withOptions:error:),
        (IMP)set_active_options, &original_active_options, @encode(BOOL),
        @[@(@encode(BOOL)), @(@encode(NSUInteger)), @"^@"]) == MulgSwizzleResultReplaced)
        installed |= MulgEngineAudioHookActiveOptions;
    return installed;
}

double mulg_engine_audio_session_sample_rate(void) {
    return AVAudioSession.sharedInstance.sampleRate; // Actual getter; never spoof this value.
}
#else
MulgEngineAudioHook mulg_engine_install_audio_hooks(void) { return 0; }
double mulg_engine_audio_session_sample_rate(void) { return 0; }
#endif
