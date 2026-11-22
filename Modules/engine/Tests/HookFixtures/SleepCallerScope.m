#import <MulgEngineHooks.h>
#include <unistd.h>
#include <time.h>
#include <errno.h>
#include <assert.h>

static BOOL gameCaller;
static unsigned backoffs, nativeCalls;
BOOL mulg_engine_is_game_caller(const void *caller) { return gameCaller; }
static int fixture_usleep(useconds_t duration) { nativeCalls++; return 0; }
static int fixture_nanosleep(const struct timespec *request, struct timespec *remaining) { backoffs++; return 0; }
#define usleep fixture_usleep
#define nanosleep fixture_nanosleep
#include "../../Sources/MulgEngineHooks/MulgSleepThrottle.m"
#undef usleep
#undef nanosleep

int main(void) { @autoreleasepool {
    mulg_engine_configure_sleep_throttle(YES, 100000);
    gameCaller = NO;
    for (int index = 0; index < 105; index++) assert(mulg_usleep(100000) == 0);
    assert(backoffs == 0 && nativeCalls == 105);
    gameCaller = YES;
    for (int index = 0; index < 105; index++) assert(mulg_usleep(100000) == 0);
    assert(backoffs == 1 && mulg_engine_throttled_thread_count() == 1);
    errno = EINTR;
    assert(mulg_usleep(50000) == 0 && errno == EINTR);
    mulg_engine_configure_sleep_throttle(NO, 100000);
    for (int index = 0; index < 105; index++) assert(mulg_usleep(100000) == 0);
    assert(backoffs == 1);
    puts("PASS: native polling bypasses the throttle; opted-in game spam is slowed with errno preserved");
} }
