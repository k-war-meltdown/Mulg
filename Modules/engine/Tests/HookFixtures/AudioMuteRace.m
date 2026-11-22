#import <Foundation/Foundation.h>
#include <AudioToolbox/AudioToolbox.h>
#include <assert.h>
#include <stdatomic.h>

static dispatch_semaphore_t staleWrite, resumeWrite;
static atomic_bool blockNextWrite;
static _Atomic(float) outputVolume;
static OSStatus fixture_set_parameter(AudioQueueRef queue, AudioQueueParameterID parameter, AudioQueueParameterValue volume) {
    if (atomic_exchange(&blockNextWrite, false)) {
        dispatch_semaphore_signal(staleWrite);
        assert(dispatch_semaphore_wait(resumeWrite, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)) == 0);
    }
    atomic_store(&outputVolume, volume);
    return noErr;
}
#define AudioQueueSetParameter fixture_set_parameter
#include "../../Sources/MulgEngineHooks/MulgAudioMute.m"
#undef AudioQueueSetParameter

int main(void) { @autoreleasepool {
    staleWrite = dispatch_semaphore_create(0); resumeWrite = dispatch_semaphore_create(0);
    AudioQueueRef queue = (AudioQueueRef)(uintptr_t)1;
    track_new_queue(queue);
    assert(mulg_queue_set_parameter(queue, kAudioQueueParam_Volume, 0.5) == noErr);
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    atomic_store(&blockNextWrite, true);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        mulg_engine_set_audio_muted(YES);
        dispatch_semaphore_signal(done);
    });
    assert(dispatch_semaphore_wait(staleWrite, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)) == 0);
    mulg_engine_set_audio_muted(NO);
    dispatch_semaphore_signal(resumeWrite);
    assert(dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)) == 0);
    assert(atomic_load(&outputVolume) == 0.5); // The stale mute cannot silence the now-focused game.

    atomic_store(&blockNextWrite, true);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        assert(mulg_queue_set_parameter(queue, kAudioQueueParam_Volume, 0.2) == noErr);
        dispatch_semaphore_signal(done);
    });
    assert(dispatch_semaphore_wait(staleWrite, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)) == 0);
    assert(mulg_queue_set_parameter(queue, kAudioQueueParam_Volume, 0.8) == noErr);
    dispatch_semaphore_signal(resumeWrite);
    assert(dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)) == 0);
    assert(atomic_load(&outputVolume) == 0.8f);
    puts("PASS: overlapping mute/unmute and volume writes converge to the latest game state");
} }
