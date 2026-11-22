#import "MulgEngineHooks.h"
#include <stdatomic.h>
#include <stdint.h>
#include <TargetConditionals.h>

static _Atomic(uint64_t) memory_limit;

void mulg_engine_set_memory_limit(uint64_t bytes) {
    atomic_store_explicit(&memory_limit, bytes, memory_order_release);
}

uint64_t mulg_engine_available_memory_answer(uint64_t native, BOOL game, uint64_t physical,
                                            uint64_t footprint, uint64_t headroom, uint64_t limit) {
    if (native != 0 || !game || physical == 0) return native;
    uint64_t budget = limit != 0 && limit < physical ? limit : physical;
    uint64_t left = budget > footprint ? budget - footprint : 0;
    return left < headroom ? left : headroom;
}

#if TARGET_OS_MACCATALYST
#include <mach/mach.h>
#include <os/lock.h>
#include <os/proc.h>
#include <sys/sysctl.h>
#include <time.h>

typedef struct {
    uint64_t at, physical, footprint, headroom;
} MulgMemorySnapshot;
static os_unfair_lock snapshot_lock = OS_UNFAIR_LOCK_INIT;
static MulgMemorySnapshot snapshot;

static uint64_t bytes_from_pages(uint64_t pages, uint64_t pageSize) {
    return pageSize != 0 && pages > UINT64_MAX / pageSize ? UINT64_MAX : pages * pageSize;
}

static MulgMemorySnapshot measure_memory(uint64_t now) {
    MulgMemorySnapshot value = { .at = now };
    size_t length = sizeof(value.physical);
    if (sysctlbyname("hw.memsize", &value.physical, &length, NULL, 0) != 0
        || length != sizeof(value.physical)) value.physical = 0;
    task_vm_info_data_t task = {0};
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&task, &count) == KERN_SUCCESS
        && count >= TASK_VM_INFO_REV1_COUNT) {
        value.footprint = task.phys_footprint;
    } else {
        mach_task_basic_info_data_t basic = {0};
        count = MACH_TASK_BASIC_INFO_COUNT;
        if (task_info(mach_task_self(), MACH_TASK_BASIC_INFO, (task_info_t)&basic, &count) == KERN_SUCCESS)
            value.footprint = basic.resident_size;
    }
    int level = 0;
    length = sizeof(level);
    if (value.physical != 0
        && sysctlbyname("kern.memorystatus_level", &level, &length, NULL, 0) == 0
        && length == sizeof(level) && level >= 0 && level <= 100) {
        value.headroom = value.physical / 100 * (uint64_t)level;
        return value;
    }
    // A missing iOS-style pressure counter must not erase a valid Mac memory
    // measurement. Use reclaimable VM pages, without relaxing sandbox permissions.
    mach_port_t host = mach_host_self();
    if (value.physical == 0) {
        host_basic_info_data_t basic = {0};
        count = HOST_BASIC_INFO_COUNT;
        if (host_info(host, HOST_BASIC_INFO, (host_info_t)&basic, &count) == KERN_SUCCESS)
            value.physical = basic.max_mem;
    }
    vm_statistics64_data_t stats = {0};
    count = HOST_VM_INFO64_COUNT;
    if (host_statistics64(host, HOST_VM_INFO64, (host_info64_t)&stats, &count) == KERN_SUCCESS) {
        value.headroom = bytes_from_pages((uint64_t)stats.free_count + stats.inactive_count, vm_page_size);
    } else {
        // No pressure reading is available. Bound the estimate by actual physical
        // memory and footprint; never turn a failed optional query into exhaustion.
        value.headroom = value.physical > value.footprint ? value.physical - value.footprint : 0;
    }
    mach_port_deallocate(mach_task_self(), host);
    return value;
}

static size_t mulg_os_proc_available_memory(void) {
    size_t native = os_proc_available_memory();
    if (native != 0 || !mulg_engine_is_game_memory_caller(__builtin_return_address(0))) return native;
    uint64_t now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    os_unfair_lock_lock(&snapshot_lock);
    MulgMemorySnapshot value = snapshot;
    os_unfair_lock_unlock(&snapshot_lock);
    if (value.at == 0 || now < value.at || now - value.at >= 250000000ULL) {
        value = measure_memory(now);
        os_unfair_lock_lock(&snapshot_lock);
        if (snapshot.at <= value.at) snapshot = value;
        else value = snapshot;
        os_unfair_lock_unlock(&snapshot_lock);
    }
    return (size_t)mulg_engine_available_memory_answer(native, YES, value.physical, value.footprint,
        value.headroom, atomic_load_explicit(&memory_limit, memory_order_acquire));
}

__attribute__((used)) static const struct {
    const void *replacement;
    const void *original;
} mulg_interpose_os_proc_available_memory __attribute__((section("__DATA,__interpose"))) = {
    (const void *)&mulg_os_proc_available_memory, (const void *)&os_proc_available_memory
};
#endif
