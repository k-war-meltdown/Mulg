//
//  MulgAudioMute.m
//  engine module: the game falls silent while it is not in focus (engine.muteWhenUnfocused).
//
//  Every engine plays through an output audio unit (RemoteIO, VoiceProcessingIO, HAL output; used by
//  Unity, Unreal, FMOD, Wwise and AVAudioEngine) or an audio queue (AVAudioPlayer, simple players).
//  Output units created in the process get a render notification that zeroes what they hand to the
//  device while muted, on the audio thread, with one atomic load per buffer. Output queues are muted
//  through their volume parameter, and the game's own volume comes back when the mute ends. The game
//  never sees a format, session or route change, so nothing restarts when sound returns.
//

#import "MulgEngineHooks.h"
#include <AudioToolbox/AudioToolbox.h>
#include <os/lock.h>
#include <stdatomic.h>
#include <string.h>
#include <unistd.h>

#define MULG_INTERPOSE(replacement, original)                                            \
    __attribute__((used)) static const struct {                                          \
        const void *replacement_function;                                                \
        const void *original_function;                                                   \
    } mulg_interpose_##original __attribute__((section("__DATA,__interpose"))) = {       \
        (const void *)(unsigned long)&replacement, (const void *)(unsigned long)&original \
    };

static _Atomic(bool) muted;
static _Atomic(unsigned) mute_generation;
static _Atomic(unsigned) mute_transitions;
static _Atomic(unsigned) silenced_buffers;

BOOL mulg_engine_audio_muted(void) {
    return atomic_load_explicit(&muted, memory_order_relaxed);
}

unsigned mulg_engine_audio_silenced_buffers(void) {
    return atomic_load_explicit(&silenced_buffers, memory_order_relaxed);
}

// MARK: - Output units

/// Audio thread. After the unit rendered the output bus, its samples become silence.
static OSStatus silence_output(void *refCon, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *time,
                               UInt32 bus, UInt32 frames, AudioBufferList *data) {
    if (!(*flags & kAudioUnitRenderAction_PostRender) || bus != 0 || data == NULL
        || !atomic_load_explicit(&muted, memory_order_relaxed)) return noErr;
    for (UInt32 i = 0; i < data->mNumberBuffers; i++) {
        if (data->mBuffers[i].mData) memset(data->mBuffers[i].mData, 0, data->mBuffers[i].mDataByteSize);
    }
    *flags |= kAudioUnitRenderAction_OutputIsSilence;
    atomic_fetch_add_explicit(&silenced_buffers, 1, memory_order_relaxed);
    return noErr;
}

static BOOL is_output_unit(AudioComponent component) {
    AudioComponentDescription description = {0};
    return component && AudioComponentGetDescription(component, &description) == noErr
        && description.componentType == kAudioUnitType_Output;
}

static void watch_output_unit(AudioComponentInstance unit) {
    if (unit) AudioUnitAddRenderNotify(unit, silence_output, NULL);
}

static OSStatus mulg_instance_new(AudioComponent component, AudioComponentInstance *instance) {
    OSStatus status = AudioComponentInstanceNew(component, instance);
    if (status == noErr && instance && is_output_unit(component)) watch_output_unit(*instance);
    return status;
}

static void mulg_instantiate(AudioComponent component, AudioComponentInstantiationOptions options,
                             void (^handler)(AudioComponentInstance, OSStatus)) {
    if (!handler || !is_output_unit(component)) {
        AudioComponentInstantiate(component, options, handler);
        return;
    }
    AudioComponentInstantiate(component, options, ^(AudioComponentInstance unit, OSStatus status) {
        if (status == noErr) watch_output_unit(unit);
        handler(unit, status);
    });
}

MULG_INTERPOSE(mulg_instance_new, AudioComponentInstanceNew)
MULG_INTERPOSE(mulg_instantiate, AudioComponentInstantiate)

// MARK: - Output queues

// Each live output queue with the volume the game last set (1 until it sets one). The lock guards the
// table only: Apple's queue calls are never made while holding it, because a game may set a volume from
// its own audio callback while AudioToolbox holds the queue's internal lock (a lock-order freeze).
static os_unfair_lock queues_lock = OS_UNFAIR_LOCK_INIT;
static CFMutableDictionaryRef queues; // AudioQueueRef -> Float32 bits
/// Native updates in flight per queue. Disposal drains only its own operations;
/// an unrelated queue's callback/lock must never hold another queue's teardown.
static CFMutableDictionaryRef queue_updates; // AudioQueueRef -> uintptr_t count

static BOOL begin_queue_update(AudioQueueRef queue) {
    os_unfair_lock_lock(&queues_lock);
    BOOL known = queues && CFDictionaryContainsKey(queues, queue);
    if (known) {
        if (!queue_updates) queue_updates = CFDictionaryCreateMutable(NULL, 0, NULL, NULL);
        uintptr_t count = (uintptr_t)CFDictionaryGetValue(queue_updates, queue);
        CFDictionarySetValue(queue_updates, queue, (const void *)(count + 1));
    }
    os_unfair_lock_unlock(&queues_lock);
    return known;
}

static void end_queue_update(AudioQueueRef queue) {
    os_unfair_lock_lock(&queues_lock);
    uintptr_t count = queue_updates ? (uintptr_t)CFDictionaryGetValue(queue_updates, queue) : 0;
    if (count > 1) CFDictionarySetValue(queue_updates, queue, (const void *)(count - 1));
    else if (queue_updates) CFDictionaryRemoveValue(queue_updates, queue);
    os_unfair_lock_unlock(&queues_lock);
}

static const void *volume_bits(Float32 volume) {
    uint32_t bits;
    memcpy(&bits, &volume, sizeof bits);
    return (const void *)(uintptr_t)bits;
}

static Float32 game_volume(const void *value) {
    uint32_t bits = (uint32_t)(uintptr_t)value;
    Float32 volume;
    memcpy(&volume, &bits, sizeof volume);
    return volume;
}

/// The queue's volume for the current state; called after any change, so a race always ends right.
static OSStatus settle_queue(AudioQueueRef queue) {
    // Covers game volume setters and initial muted setup too, not just focus passes.
    // Removing a queue prevents new leases before native disposal begins.
    if (!begin_queue_update(queue)) return noErr;
    OSStatus status = noErr;
    @try {
    while (true) {
        os_unfair_lock_lock(&queues_lock);
        const void *value = NULL;
        bool known = queues && CFDictionaryGetValueIfPresent(queues, queue, &value);
        bool mute = atomic_load(&muted);
        os_unfair_lock_unlock(&queues_lock);
        if (!known) return status;
        status = AudioQueueSetParameter(queue, kAudioQueueParam_Volume, mute ? 0 : game_volume(value));
        // A newer mute or volume update can complete while this native call is
        // in flight. Reapply the latest state if this call wrote a stale value.
        os_unfair_lock_lock(&queues_lock);
        const void *current = NULL;
        bool stillKnown = queues && CFDictionaryGetValueIfPresent(queues, queue, &current);
        bool settled = !stillKnown || (current == value && atomic_load(&muted) == mute);
        os_unfair_lock_unlock(&queues_lock);
        if (settled) return status;
    }
    } @finally { end_queue_update(queue); }
}

/// A new output queue, silent from the start while muted.
static void track_new_queue(AudioQueueRef queue) {
    os_unfair_lock_lock(&queues_lock);
    if (!queues) queues = CFDictionaryCreateMutable(NULL, 0, NULL, NULL);
    CFDictionarySetValue(queues, queue, volume_bits(1));
    os_unfair_lock_unlock(&queues_lock);
    if (atomic_load(&muted)) settle_queue(queue);
}

static OSStatus mulg_queue_new_output(const AudioStreamBasicDescription *format, AudioQueueOutputCallback callback,
                                      void *user, CFRunLoopRef runLoop, CFStringRef mode, UInt32 flags,
                                      AudioQueueRef *queue) {
    OSStatus status = AudioQueueNewOutput(format, callback, user, runLoop, mode, flags, queue);
    if (status == noErr && queue && *queue) track_new_queue(*queue);
    return status;
}

static OSStatus mulg_queue_new_output_block(AudioQueueRef *queue, const AudioStreamBasicDescription *format,
                                            UInt32 flags, dispatch_queue_t callbackQueue,
                                            AudioQueueOutputCallbackBlock callback) {
    OSStatus status = AudioQueueNewOutputWithDispatchQueue(queue, format, flags, callbackQueue, callback);
    if (status == noErr && queue && *queue) track_new_queue(*queue);
    return status;
}

static OSStatus mulg_queue_set_parameter(AudioQueueRef queue, AudioQueueParameterID parameter, AudioQueueParameterValue value) {
    if (parameter != kAudioQueueParam_Volume) return AudioQueueSetParameter(queue, parameter, value);
    os_unfair_lock_lock(&queues_lock);
    bool known = queues && CFDictionaryContainsKey(queues, queue);
    if (known) CFDictionarySetValue(queues, queue, volume_bits(value));
    os_unfair_lock_unlock(&queues_lock);
    if (!known) return AudioQueueSetParameter(queue, parameter, value);
    // Muted: the game's volume is kept for later and the queue stays silent.
    return atomic_load(&muted) ? noErr : settle_queue(queue);
}

static OSStatus mulg_queue_get_parameter(AudioQueueRef queue, AudioQueueParameterID parameter, AudioQueueParameterValue *value) {
    if (parameter != kAudioQueueParam_Volume || !value) return AudioQueueGetParameter(queue, parameter, value);
    BOOL leased = begin_queue_update(queue);
    unsigned generation = atomic_load(&mute_generation);
    BOOL wasMuted = atomic_load(&muted) || atomic_load(&mute_transitions) != 0;
    @try {
        OSStatus status = AudioQueueGetParameter(queue, parameter, value);
        if (status == noErr && leased && (wasMuted || atomic_load(&muted)
            || atomic_load(&mute_transitions) != 0 || generation != atomic_load(&mute_generation))) {
            os_unfair_lock_lock(&queues_lock);
            const void *saved = NULL;
            // Hide our mute (including a transition during the native read), but
            // keep native volume readback while unmuted: queue ramps and native
            // framework volume updates need not pass through our setter hook.
            if (queues && CFDictionaryGetValueIfPresent(queues, queue, &saved)) *value = game_volume(saved);
            os_unfair_lock_unlock(&queues_lock);
        }
        return status;
    } @finally { if (leased) end_queue_update(queue); }
}

static OSStatus mulg_queue_dispose(AudioQueueRef queue, Boolean immediate) {
    os_unfair_lock_lock(&queues_lock);
    if (queues) CFDictionaryRemoveValue(queues, queue);
    while (queue_updates && CFDictionaryContainsKey(queue_updates, queue)) {
        os_unfair_lock_unlock(&queues_lock);
        usleep(200);
        os_unfair_lock_lock(&queues_lock);
    }
    os_unfair_lock_unlock(&queues_lock);
    return AudioQueueDispose(queue, immediate);
}

MULG_INTERPOSE(mulg_queue_new_output, AudioQueueNewOutput)
MULG_INTERPOSE(mulg_queue_new_output_block, AudioQueueNewOutputWithDispatchQueue)
MULG_INTERPOSE(mulg_queue_set_parameter, AudioQueueSetParameter)
MULG_INTERPOSE(mulg_queue_get_parameter, AudioQueueGetParameter)
MULG_INTERPOSE(mulg_queue_dispose, AudioQueueDispose)

// MARK: - Switch

void mulg_engine_set_audio_muted(BOOL enabled) {
    bool mute = enabled;
    os_unfair_lock_lock(&queues_lock);
    if (atomic_load(&muted) == mute) { os_unfair_lock_unlock(&queues_lock); return; }
    // Publish ownership before the new state: a concurrent getter can otherwise
    // see "unmuted" while the native queue still contains our previous zero.
    atomic_fetch_add(&mute_transitions, 1);
    atomic_fetch_add(&mute_generation, 1);
    atomic_store(&muted, mute);
    CFIndex count = queues ? CFDictionaryGetCount(queues) : 0;
    const void **keys = count ? calloc((size_t)count, sizeof *keys) : NULL;
    if (keys) CFDictionaryGetKeysAndValues(queues, keys, NULL);
    os_unfair_lock_unlock(&queues_lock);
    // Snapshot addresses are checked and leased before use; disposed queues are skipped.
    @try {
        for (CFIndex i = 0; keys && i < count; i++) settle_queue((AudioQueueRef)keys[i]);
    } @finally {
        free(keys);
        atomic_fetch_sub(&mute_transitions, 1);
    }
}

// MARK: - Tests (interposing applies only to images loaded at launch, not to a test bundle)

void mulg_engine_audio_mute_track_queue_for_testing(void *queue) {
    track_new_queue((AudioQueueRef)queue);
}

int32_t mulg_engine_audio_queue_set_volume_for_testing(void *queue, float volume) {
    return mulg_queue_set_parameter((AudioQueueRef)queue, kAudioQueueParam_Volume, volume);
}

int32_t mulg_engine_audio_queue_dispose_for_testing(void *queue) {
    return mulg_queue_dispose((AudioQueueRef)queue, true);
}
