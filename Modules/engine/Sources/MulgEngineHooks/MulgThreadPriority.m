//
//  MulgThreadPriority.m
//  engine module: frame-critical game threads on the performance cores.
//
//  Games see every Mac core and start a worker for most of them. Without a QoS class, macOS may
//  run those workers on the efficiency cores, and each frame then waits for the slowest one.
//  Threads name themselves (pthread_setname_np names only the calling thread), so the name call
//  is where a thread's role is known and the only place its QoS needs setting: no polling, and
//  nothing for threads that are not frame-critical. Loading and background threads keep theirs.
//
//    render: the engine's render/RHI thread           -> QOS_CLASS_USER_INTERACTIVE
//    worker: per-frame job and task-graph workers     -> QOS_CLASS_USER_INITIATED
//
//  Both classes may run on every core; performance cores are used first. Workers are raised only up
//  to the fast cores left after the main and render threads (fast cores - 2, from hw.perflevel*):
//  games start a worker for nearly every core (11 on a 12-core M6 with 6 fast cores), and raising
//  them all made them compete with the main and render threads for the fast cores. The rest keep
//  their default QoS, which may still use fast cores when they are free. A thread that later
//  sets a fixed scheduling priority (pthread_setschedparam) opts out of QoS, as macOS intends.
//

#import "MulgEngineHooks.h"

#include <pthread.h>
#include <pthread/qos.h>
#include <stdio.h>
#include <sys/sysctl.h>
#include <stdatomic.h>
#include <string.h>
#include <os/log.h>

#define MULG_INTERPOSE(replacement, original)                                            \
    __attribute__((used)) static const struct {                                          \
        const void *replacement_function;                                                \
        const void *original_function;                                                   \
    } mulg_interpose_##original __attribute__((section("__DATA,__interpose"))) = {       \
        (const void *)(unsigned long)&replacement, (const void *)(unsigned long)&original \
    };

static _Atomic(bool) mulg_thread_priority_enabled = false;
static _Atomic(unsigned) mulg_prioritized_threads = 0;
/// Workers that may still be raised; -1 means no limit (the core layout could not be read).
static _Atomic(int) mulg_worker_budget = -1;
static _Atomic(unsigned) mulg_raised_workers = 0;
static pthread_key_t mulg_worker_slot;
static int mulg_worker_slot_error;
static _Atomic(bool) mulg_worker_slot_initialised;
static __thread bool mulg_qos_changed;
static __thread qos_class_t mulg_original_qos, mulg_applied_qos;
static __thread int mulg_original_relative;

static void release_worker_slot(void *slot) {
    if (slot) atomic_fetch_sub_explicit(&mulg_raised_workers, 1, memory_order_relaxed);
}

static bool has_prefix(const char *name, const char *prefix) {
    return strncmp(name, prefix, strlen(prefix)) == 0;
}

MulgEngineThreadRole mulg_engine_thread_role(const char *name) {
    if (name == NULL) return MulgEngineThreadRoleNone;
    // Unity: "UnityGfxDeviceWorker" and "UnityMultiRenderingThread"; Unreal: "RenderThread 1",
    // "RHIThread", "RHISubmissionThread". An engine's render threads hand work to each other, so
    // they are raised together: raising one alone changes the order they ran in (Genshin crashed
    // in UnityMultiRenderingThread on 2026-10-04 with only its sibling raised).
    static const char *const render[] = {"UnityGfxDeviceWorker", "UnityMultiRenderingThread",
                                         "RenderThread", "RHIThread", "RHISubmissionThread"};
    // Unity: "Job.Worker 0"…; Unreal: "TaskGraphThreadHP 3", "TaskGraphThreadNP 1", "Foreground Worker #0".
    // Not "Background Job.Worker", "Background Worker" or "TaskGraphThreadBP": they load and stream.
    static const char *const worker[] = {"Job.Worker", "TaskGraphThreadHP", "TaskGraphThreadNP", "Foreground Worker"};
    for (size_t i = 0; i < sizeof render / sizeof *render; i++) {
        if (has_prefix(name, render[i])) return MulgEngineThreadRoleRender;
    }
    for (size_t i = 0; i < sizeof worker / sizeof *worker; i++) {
        if (has_prefix(name, worker[i])) return MulgEngineThreadRoleWorker;
    }
    return MulgEngineThreadRoleNone;
}

int mulg_engine_worker_budget(int fastCores) {
    return fastCores > 0 ? (fastCores > 2 ? fastCores - 2 : 0) : -1;
}

/// Cores in every performance level but the slowest (Super + Performance on an M6), or -1.
int mulg_engine_fast_core_count(void) {
    int levels = 0;
    size_t length = sizeof(levels);
    if (sysctlbyname("hw.nperflevels", &levels, &length, NULL, 0) != 0 || levels < 2) return -1;
    int fast = 0;
    for (int level = 0; level < levels - 1; level++) {
        char name[48];
        snprintf(name, sizeof(name), "hw.perflevel%d.physicalcpu", level);
        int cores = 0;
        length = sizeof(cores);
        if (sysctlbyname(name, &cores, &length, NULL, 0) != 0 || cores < 0) return -1;
        fast += cores;
    }
    return fast;
}

unsigned mulg_engine_raised_worker_count(void) {
    return atomic_load_explicit(&mulg_raised_workers, memory_order_relaxed);
}

void mulg_engine_set_thread_priorities(BOOL enabled) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        atomic_store(&mulg_worker_budget, mulg_engine_worker_budget(mulg_engine_fast_core_count()));
        mulg_worker_slot_error = pthread_key_create(&mulg_worker_slot, release_worker_slot);
        atomic_store(&mulg_worker_slot_initialised, true);
    });
    atomic_store_explicit(&mulg_thread_priority_enabled, enabled, memory_order_release);
}

unsigned mulg_engine_prioritized_thread_count(void) {
    return atomic_load_explicit(&mulg_prioritized_threads, memory_order_relaxed);
}

static int mulg_pthread_setname_np(const char *name) {
    int result = pthread_setname_np(name);
    if (result != 0) return result;
    // A worker renamed as a render/background thread no longer occupies a worker slot.
    BOOL enabled = atomic_load_explicit(&mulg_thread_priority_enabled, memory_order_acquire);
    MulgEngineThreadRole role = enabled && mulg_engine_is_game_caller(__builtin_return_address(0))
        ? mulg_engine_thread_role(name) : MulgEngineThreadRoleNone;
    qos_class_t desired = role == MulgEngineThreadRoleRender ? QOS_CLASS_USER_INTERACTIVE
        : role == MulgEngineThreadRoleWorker ? QOS_CLASS_USER_INITIATED : QOS_CLASS_UNSPECIFIED;
    if (mulg_qos_changed && (role == MulgEngineThreadRoleNone || desired != mulg_applied_qos)) {
        // A reused render thread must release our stronger boost before the worker
        // budget is applied. Preserve a priority the game independently changed.
        qos_class_t current;
        int relative;
        if (pthread_get_qos_class_np(pthread_self(), &current, &relative) == 0
            && current == mulg_applied_qos && relative == 0)
            pthread_set_qos_class_self_np(mulg_original_qos, mulg_original_relative);
        mulg_qos_changed = false;
    }
    if (atomic_load(&mulg_worker_slot_initialised) && mulg_worker_slot_error == 0 && role != MulgEngineThreadRoleWorker
        && pthread_getspecific(mulg_worker_slot)) {
        pthread_setspecific(mulg_worker_slot, NULL);
        release_worker_slot((void *)1);
    }
    qos_class_t qos;
    switch (role) {
        case MulgEngineThreadRoleRender: qos = QOS_CLASS_USER_INTERACTIVE; break;
        case MulgEngineThreadRoleWorker: qos = QOS_CLASS_USER_INITIATED; break;
        case MulgEngineThreadRoleNone: return result;
    }
    // Never lower a thread the game already raised.
    qos_class_t current = qos_class_self();
    if (current != QOS_CLASS_UNSPECIFIED && current >= qos) return result;
    bool worker = qos == QOS_CLASS_USER_INITIATED;
    bool reserved = worker && mulg_worker_slot_error == 0 && !pthread_getspecific(mulg_worker_slot);
    if (worker && mulg_worker_slot_error != 0) return result;
    if (reserved) {
        // Reserve a slot only while one is free: over the budget the worker keeps the game's own QoS, and
        // the count (reported as raised workers) never grows past the budget.
        int budget = atomic_load_explicit(&mulg_worker_budget, memory_order_relaxed);
        unsigned raised = atomic_load_explicit(&mulg_raised_workers, memory_order_relaxed);
        do {
            if (budget >= 0 && (int)raised >= budget) return result;
        } while (!atomic_compare_exchange_weak_explicit(&mulg_raised_workers, &raised, raised + 1,
                                                        memory_order_relaxed, memory_order_relaxed));
        if (pthread_setspecific(mulg_worker_slot, (void *)1) != 0) {
            release_worker_slot((void *)1);
            return result;
        }
    }
    qos_class_t before;
    int beforeRelative;
    BOOL canRestore = pthread_get_qos_class_np(pthread_self(), &before, &beforeRelative) == 0;
    if (pthread_set_qos_class_self_np(qos, 0) != 0) {
        // Not raised: give the slot back.
        if (reserved) {
            pthread_setspecific(mulg_worker_slot, NULL);
            release_worker_slot((void *)1);
        }
        return result;
    }
    if (!mulg_qos_changed && canRestore) {
        // The public setter cannot restore UNSPECIFIED. A thread without an
        // explicit QoS returns to the platform default rather than retaining our boost.
        mulg_original_qos = before == QOS_CLASS_UNSPECIFIED ? QOS_CLASS_DEFAULT : before;
        mulg_original_relative = before == QOS_CLASS_UNSPECIFIED ? 0 : beforeRelative;
        mulg_qos_changed = true;
    }
    mulg_applied_qos = qos;
    if (atomic_fetch_add_explicit(&mulg_prioritized_threads, 1, memory_order_relaxed) == 0) {
        os_log_info(OS_LOG_DEFAULT, "Mulg engine: frame-critical game threads run at raised QoS (first: %{public}s)", name);
    }
    return result;
}

MULG_INTERPOSE(mulg_pthread_setname_np, pthread_setname_np)
