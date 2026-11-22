#import <MulgEngineHooks.h>
#include <pthread.h>
#include <pthread/qos.h>
#include <sys/sysctl.h>
#include <assert.h>
#include <string.h>

BOOL mulg_engine_is_game_caller(const void *caller) { return YES; }
static int fixture_sysctl(const char *name, void *value, size_t *length, void *newValue, size_t newLength) {
    assert(*length == sizeof(int));
    *(int *)value = strcmp(name, "hw.nperflevels") == 0 ? 2 : 3; // One worker slot.
    return 0;
}
static qos_class_t fixture_current_qos(void) { return QOS_CLASS_DEFAULT; }
static int fixture_set_qos(qos_class_t qos, int relative) { return 0; }
#define sysctlbyname fixture_sysctl
#define qos_class_self fixture_current_qos
#define pthread_set_qos_class_self_np fixture_set_qos
#include "../../Sources/MulgEngineHooks/MulgThreadPriority.m"
#undef sysctlbyname
#undef qos_class_self
#undef pthread_set_qos_class_self_np

static void *worker(void *unused) {
    assert(mulg_pthread_setname_np("Job.Worker 0") == 0);
    assert(mulg_engine_raised_worker_count() == 1);
    assert(mulg_pthread_setname_np("Job.Worker 1") == 0); // A rename does not reserve twice.
    assert(mulg_engine_raised_worker_count() == 1);
    return NULL;
}
int main(void) { @autoreleasepool {
    mulg_engine_set_thread_priorities(YES);
    for (int index = 0; index < 3; index++) {
        pthread_t thread;
        assert(pthread_create(&thread, NULL, worker, NULL) == 0);
        assert(pthread_join(thread, NULL) == 0);
        assert(mulg_engine_raised_worker_count() == 0);
    }
    assert(mulg_engine_prioritized_thread_count() == 6);
    puts("PASS: exited workers release priority slots and repeated names do not exhaust the budget");
} }
