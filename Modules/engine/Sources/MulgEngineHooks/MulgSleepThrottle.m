//
//  MulgSleepThrottle.m
//  engine module: sleep-spam throttle (PLAN.md §16.2 E4).
//
//  Some games run threads that call usleep(100000) in a tight loop. Upstream counted these
//  calls in shared dictionaries under a global lock on every usleep, and after 100 fast calls
//  blocked the thread forever. Here the counters are per thread (no lock), the setting is
//  read with one atomic load, and a spamming thread is slowed down instead of frozen, so it
//  can still finish and release what it holds.
//

#import "MulgEngineHooks.h"

#include <errno.h>
#include <pthread.h>
#include <stdatomic.h>
#include <time.h>
#include <unistd.h>
#include <mach/mach_time.h>
#include <os/log.h>
#include <os/signpost.h>

#define MULG_INTERPOSE(replacement, original)                                            \
    __attribute__((used)) static const struct {                                          \
        const void *replacement_function;                                                \
        const void *original_function;                                                   \
    } mulg_interpose_##original __attribute__((section("__DATA,__interpose"))) = {       \
        (const void *)(unsigned long)&replacement, (const void *)(unsigned long)&original \
    };

static const useconds_t kSpamDuration = 100000;         // the call pattern upstream detected
static const uint64_t kEarlyReturnNanoseconds = 10000000ULL;
static const uint32_t kRapidCallLimit = 100;

static _Atomic(int) mulg_throttle_enabled = 0;
static _Atomic(useconds_t) mulg_throttled_duration = 100000;
static _Atomic(unsigned) mulg_throttle_generation = 0;
static _Atomic(NSUInteger) mulg_throttled_threads = 0;

static __thread uint32_t mulg_rapid_calls = 0;
static __thread unsigned mulg_seen_generation = 0;
/// Whether this thread is already counted in `mulg_throttled_threads` (a thread backs off every
/// ~100 calls; it used to be counted each time, so one spinning thread inflated the count forever).
static __thread bool mulg_thread_counted = false;

void mulg_engine_configure_sleep_throttle(BOOL enabled, useconds_t throttledMicroseconds) {
    // Never turn a polling thread into a five-second stall.
    atomic_store(&mulg_throttled_duration, MAX(100000, MIN(throttledMicroseconds, 250000)));
    atomic_store(&mulg_throttle_enabled, enabled ? 1 : 0);
    atomic_fetch_add(&mulg_throttle_generation, 1);
}

uint32_t mulg_engine_sleep_streak(uint32_t previous, useconds_t requested,
                                 uint64_t elapsedNanoseconds, int result) {
    if (requested != kSpamDuration || result != 0 || elapsedNanoseconds >= kEarlyReturnNanoseconds) return 0;
    return previous < kRapidCallLimit + 1 ? previous + 1 : previous;
}

NSUInteger mulg_engine_throttled_thread_count(void) {
    return atomic_load(&mulg_throttled_threads);
}

/// Sleeps for any length, avoiding usleep's one-second limit on some systems.
static int mulg_sleep_microseconds(useconds_t duration) {
    struct timespec request = {
        .tv_sec = duration / 1000000,
        .tv_nsec = (long)(duration % 1000000) * 1000,
    };
    while (nanosleep(&request, &request) == -1) {
        if (errno != EINTR) {
            return -1;
        }
    }
    return 0;
}

static int mulg_usleep(useconds_t duration) {
    if (!atomic_load_explicit(&mulg_throttle_enabled, memory_order_relaxed)
        || duration != kSpamDuration
        || !mulg_engine_is_game_caller(__builtin_return_address(0))) {
        mulg_rapid_calls = 0;
        return usleep(duration);
    }
    unsigned generation = atomic_load(&mulg_throttle_generation);
    if (generation != mulg_seen_generation) {
        mulg_seen_generation = generation;
        mulg_rapid_calls = 0;
    }
    uint64_t start = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    int result = usleep(duration);
    int savedErrno = errno;
    uint64_t elapsed = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - start;
    mulg_rapid_calls = mulg_engine_sleep_streak(mulg_rapid_calls, duration, elapsed, result);
    if (mulg_rapid_calls > kRapidCallLimit) {
        if (!mulg_thread_counted) {
            mulg_thread_counted = true;
            atomic_fetch_add(&mulg_throttled_threads, 1);
            os_log(OS_LOG_DEFAULT, "[Mulg] Repeated successful early sleep returns on thread %{public}llu; backing off",
                   (unsigned long long)pthread_mach_thread_np(pthread_self()));
        }
        mulg_sleep_microseconds(atomic_load(&mulg_throttled_duration));
        mulg_rapid_calls = 0;
    }
    errno = savedErrno;
    return result;
}

MULG_INTERPOSE(mulg_usleep, usleep)

// MARK: - Just-in-time frame start (§6.1)

// ponytail: the wait happens on the thread that presents (or runs the display link); an engine
// that reads input on another thread gains less. Needs a per-engine input hook to do better.
static _Atomic(useconds_t) mulg_frame_start_delay = 0;
static __thread int mulg_in_display_link = 0;
@interface MulgFrameStartContext : NSObject {
@public
    _Atomic(unsigned) _frames;
    _Atomic(unsigned) _active;
    _Atomic(unsigned) _waitClaimed;
    MulgFrameStartContext *_waitOwner;
}
@end
@implementation MulgFrameStartContext
@end
static __thread void *mulg_frame_context;
static void (^mulg_frame_start_handler)(void);  // main thread only
static __thread BOOL mulg_in_frame_handler;

void mulg_engine_set_frame_start_delay(double seconds) {
    atomic_store(&mulg_frame_start_delay, seconds > 0 ? (useconds_t)(seconds * 1e6) : 0);
}

static void mulg_wait_frame_start(void) {
    useconds_t delay = atomic_load_explicit(&mulg_frame_start_delay, memory_order_relaxed);
    if (delay > 0) {
        mulg_sleep_microseconds(delay);
    }
}

void mulg_engine_frame_presented(void) {
    mulg_engine_frame_presented_in_context(mulg_engine_frame_start_context());
}

id mulg_engine_frame_start_context(void) {
    return (__bridge id)mulg_frame_context;
}

void mulg_engine_frame_presented_in_context(id context) {
    BOOL active = NO;
    if (context) {
        MulgFrameStartContext *frame = context;
        MulgFrameStartContext *owner = frame->_waitOwner ?: frame;
        atomic_fetch_add_explicit(&frame->_frames, 1, memory_order_relaxed);
        active = atomic_load_explicit(&frame->_active, memory_order_acquire) != 0
            || atomic_load_explicit(&owner->_active, memory_order_acquire) != 0;
        // A display-link entry owns the wait even if a worker commits after its return.
        // Submission-owned contexts can claim only one wait for the same frame.
        if (!active && atomic_exchange_explicit(&owner->_waitClaimed, 1, memory_order_acq_rel) != 0) return;
    }
    if (!active && !mulg_in_display_link) {
        mulg_wait_frame_start();
    }
}

void mulg_engine_set_frame_start_handler(void (^handler)(void)) {
    mulg_frame_start_handler = [handler copy];
}

/// Several display links (the game's, UIKit's animations, MetalKit's) fire within one refresh.
/// Input is delivered once per refresh: a callback within this time of the last delivery belongs
/// to the same frame. Shorter than a frame even at 240 Hz.
static uint64_t mulg_same_refresh_ticks(void) {
    static uint64_t ticks;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        mach_timebase_info_data_t base;
        mach_timebase_info(&base);
        ticks = 2000000ULL * base.denom / base.numer;  // 2 ms
    });
    return ticks;
}
static uint64_t mulg_last_input_delivery;  // main thread only

/// Instruments intervals ("frame", "input") on io.mulg/engine. Free unless a trace records them.
static os_log_t mulg_frame_signposts(void) {
    static os_log_t log;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ log = os_log_create("io.mulg", "engine"); });
    return log;
}

/// Touch delivery can synchronously call back into the game. Nested display callbacks
/// must not flush the same pending controls again before the first delivery completes.
static void mulg_deliver_frame_input(void) {
    if (!pthread_main_np() || mulg_in_display_link || mulg_in_frame_handler) return;
    void (^handler)(void) = mulg_frame_start_handler;
    if (!handler) return;
    uint64_t now = mach_absolute_time();
    if (now - mulg_last_input_delivery < mulg_same_refresh_ticks()) return;
    mulg_last_input_delivery = now;
    mulg_in_frame_handler = YES;
    os_log_t log = mulg_frame_signposts();
    os_signpost_id_t interval = os_signpost_enabled(log) ? os_signpost_id_generate(log) : OS_SIGNPOST_ID_NULL;
    if (interval != OS_SIGNPOST_ID_NULL) os_signpost_interval_begin(log, interval, "input");
    @try { handler(); }
    @finally {
        mulg_in_frame_handler = NO;
        if (interval != OS_SIGNPOST_ID_NULL) os_signpost_interval_end(log, interval, "input");
    }
}

BOOL mulg_engine_display_link_callback(BOOL drivesFrames, void (NS_NOESCAPE ^callback)(void)) {
    BOOL ownsWait = drivesFrames && !mulg_in_display_link && !mulg_in_frame_handler;
    if (ownsWait) {
        mulg_wait_frame_start();
    }
    // Only here, never inside a present: the handler injects touches, which must not reach the
    // game in the middle of its own rendering code.
    // Build 864: every main-thread tick (865 required present proof Unity never gives).
    mulg_deliver_frame_input();
    void *previousContext = mulg_frame_context;
    MulgFrameStartContext *context = [MulgFrameStartContext new];
    // Share wait ownership, but keep each display link's render proof independent.
    // Otherwise an animation-only nested callback could inherit the game's frames.
    MulgFrameStartContext *parent = (__bridge id)previousContext;
    context->_waitOwner = parent ? (parent->_waitOwner ?: parent) : nil;
    atomic_store_explicit(&context->_active, 1, memory_order_release);
    atomic_store_explicit(&context->_waitClaimed, ownsWait ? 1 : 0, memory_order_release);
    mulg_frame_context = (__bridge void *)context;
    // One interval per outermost display-link callback: the game's frame, as Mulg sees it.
    os_log_t log = mulg_frame_signposts();
    os_signpost_id_t interval = mulg_in_display_link == 0 && os_signpost_enabled(log)
        ? os_signpost_id_generate(log) : OS_SIGNPOST_ID_NULL;
    if (interval != OS_SIGNPOST_ID_NULL) os_signpost_interval_begin(log, interval, "frame");
    mulg_in_display_link += 1;
    @try { callback(); }
    @finally {
        atomic_store_explicit(&context->_active, 0, memory_order_release);
        mulg_in_display_link -= 1;
        mulg_frame_context = previousContext;
        if (interval != OS_SIGNPOST_ID_NULL) os_signpost_interval_end(log, interval, "frame");
    }
    // Only this callback's context proves that it renders. A nested game's
    // presentation must not turn an animation-only parent into a frame driver.
    return atomic_load(&context->_frames) != 0;
}
