#import <Foundation/Foundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <MulgEngineHooks.h>
#include <assert.h>
static Float32 nativeVolume = 1;
static OSStatus nativeStatus;
static BOOL changeMuteOnRead;
static BOOL completeCycleOnRead, inspectUnmute;
static OSStatus mulg_queue_get_parameter(AudioQueueRef, AudioQueueParameterID, AudioQueueParameterValue *);
static OSStatus fixture_set(AudioQueueRef queue, AudioQueueParameterID parameter, AudioQueueParameterValue value) {
    if (inspectUnmute && value > 0) {
        inspectUnmute = NO;
        Float32 reported = 0;
        assert(mulg_queue_get_parameter(queue, parameter, &reported) == noErr && reported == .8f);
    }
    nativeVolume = value; return noErr;
}
static OSStatus fixture_get(AudioQueueRef queue, AudioQueueParameterID parameter, AudioQueueParameterValue *value) {
    *value = nativeVolume;
    if (changeMuteOnRead) {
        changeMuteOnRead = NO; mulg_engine_set_audio_muted(YES);
        if (completeCycleOnRead) mulg_engine_set_audio_muted(NO);
    }
    return nativeStatus;
}
#define AudioQueueSetParameter fixture_set
#define AudioQueueGetParameter fixture_get
// __PRODUCTION__
#undef AudioQueueSetParameter
#undef AudioQueueGetParameter
int main(void) { @autoreleasepool {
    AudioQueueRef queue = (AudioQueueRef)(uintptr_t)1;
    track_new_queue(queue);
    assert(mulg_queue_set_parameter(queue, kAudioQueueParam_Volume, .8f) == noErr);
    nativeVolume = .35f; // A native queue ramp bypasses the direct setter.
    Float32 reported = 0;
    assert(mulg_queue_get_parameter(queue, kAudioQueueParam_Volume, &reported) == noErr && reported == .35f);
    mulg_engine_set_audio_muted(YES);
    assert(nativeVolume == 0);
    assert(mulg_queue_get_parameter(queue, kAudioQueueParam_Volume, &reported) == noErr && reported == .8f);
    inspectUnmute = YES;
    mulg_engine_set_audio_muted(NO);
    changeMuteOnRead = YES;
    assert(mulg_queue_get_parameter(queue, kAudioQueueParam_Volume, &reported) == noErr && reported == .8f);
    mulg_engine_set_audio_muted(NO);
    nativeVolume = 0; changeMuteOnRead = YES; completeCycleOnRead = YES;
    assert(mulg_queue_get_parameter(queue, kAudioQueueParam_Volume, &reported) == noErr && reported == .8f);
    nativeStatus = -50;
    assert(mulg_queue_get_parameter(queue, kAudioQueueParam_Volume, &reported) == -50);
    puts("PASS: unmuted native volume changes, mute readback and native errors are preserved");
} }
