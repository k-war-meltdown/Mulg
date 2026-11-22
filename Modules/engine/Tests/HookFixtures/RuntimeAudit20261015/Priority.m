#import <MulgEngineHooks.h>
#include <pthread/qos.h>
#include <sys/sysctl.h>
#include <assert.h>
#include <string.h>
BOOL mulg_engine_is_game_caller(const void *caller) { return YES; }
static qos_class_t fixture_qos = QOS_CLASS_DEFAULT;
static int fixture_relative = -3;
static int fixture_sysctl(const char *name, void *value, size_t *length, void *newValue, size_t newLength) {
    *(int *)value = strcmp(name, "hw.nperflevels") == 0 ? 2 : 3; return 0;
}
static qos_class_t fixture_current(void) { return fixture_qos; }
static int fixture_get(pthread_t thread, qos_class_t *qos, int *relative) { *qos = fixture_qos; *relative = fixture_relative; return 0; }
static int fixture_set(qos_class_t qos, int relative) { fixture_qos = qos; fixture_relative = relative; return 0; }
#define sysctlbyname fixture_sysctl
#define qos_class_self fixture_current
#define pthread_get_qos_class_np fixture_get
#define pthread_set_qos_class_self_np fixture_set
// __PRODUCTION__
int main(void) { @autoreleasepool {
    mulg_engine_set_thread_priorities(YES);
    assert(mulg_pthread_setname_np("RenderThread 0") == 0 && fixture_qos == QOS_CLASS_USER_INTERACTIVE);
    assert(mulg_pthread_setname_np("Job.Worker 0") == 0 && fixture_qos == QOS_CLASS_USER_INITIATED);
    assert(mulg_engine_raised_worker_count() == 1);
    mulg_pthread_setname_np("Background Worker");
    assert(fixture_qos == QOS_CLASS_DEFAULT && fixture_relative == -3 && mulg_engine_raised_worker_count() == 0);
    mulg_pthread_setname_np("RenderThread 0");
    fixture_qos = QOS_CLASS_USER_INTERACTIVE; fixture_relative = -2; // A game-owned change.
    mulg_pthread_setname_np("Job.Worker 0");
    assert(fixture_qos == QOS_CLASS_USER_INTERACTIVE && fixture_relative == -2);
    puts("PASS: render-to-worker reuse obeys the worker budget and preserves game-owned QoS");
} }
