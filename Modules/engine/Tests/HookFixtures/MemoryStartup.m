// Standalone Catalyst fixture for the production memory interpose. Kernel failures
// are injected locally; no installed game, identity configuration or sandbox edit.
#import "MulgEngineHooks.h"
#include <assert.h>
#include <mach/mach.h>
#include <os/lock.h>
#include <os/proc.h>
#include <sys/sysctl.h>
#include <time.h>
#include <string.h>

static const uint64_t gib = 1073741824ULL;
static BOOL game = YES, deny_size, deny_level, deny_vm, deny_task_vm;
static uint64_t native_answer, footprint = 1073741824ULL;
static int pressure = 50;
static BOOL fixture_game(const void *caller) { (void)caller; return game; }
static size_t fixture_native(void) { return (size_t)native_answer; }
static int fixture_sysctl(const char *name, void *bytes, size_t *length, void *newBytes, size_t newLength) {
    (void)newBytes; (void)newLength;
    if (strcmp(name, "hw.memsize") == 0) {
        if (deny_size) return -1;
        uint64_t physical = 16 * gib;
        memcpy(bytes, &physical, sizeof(physical)); *length = sizeof(physical);
    } else {
        if (deny_level) return -1;
        memcpy(bytes, &pressure, sizeof(pressure)); *length = sizeof(pressure);
    }
    return 0;
}
static kern_return_t fixture_task(task_name_t port, task_flavor_t flavor, task_info_t info,
                                  mach_msg_type_number_t *count) {
    (void)port; (void)count;
    if (flavor == TASK_VM_INFO) {
        if (deny_task_vm) return KERN_FAILURE;
        task_vm_info_t task = (task_vm_info_t)info;
        memset(task, 0, sizeof(*task)); task->phys_footprint = footprint;
    } else {
        mach_task_basic_info_t task = (mach_task_basic_info_t)info;
        memset(task, 0, sizeof(*task)); task->resident_size = footprint;
    }
    return KERN_SUCCESS;
}
static kern_return_t fixture_host(host_t host, host_flavor_t flavor, host_info_t info,
                                  mach_msg_type_number_t *count) {
    (void)host; (void)flavor; (void)count;
    host_basic_info_t basic = (host_basic_info_t)info;
    memset(basic, 0, sizeof(*basic)); basic->max_mem = 16 * gib;
    return KERN_SUCCESS;
}
static kern_return_t fixture_vm(host_t host, host_flavor_t flavor, host_info64_t info,
                                mach_msg_type_number_t *count) {
    (void)host; (void)flavor; (void)count;
    if (deny_vm) return KERN_FAILURE;
    vm_statistics64_t stats = (vm_statistics64_t)info;
    memset(stats, 0, sizeof(*stats)); stats->free_count = (natural_t)(2 * gib / vm_page_size);
    stats->inactive_count = (natural_t)(2 * gib / vm_page_size);
    return KERN_SUCCESS;
}
#define mulg_engine_is_game_memory_caller fixture_game
#define os_proc_available_memory fixture_native
#define sysctlbyname fixture_sysctl
#define task_info fixture_task
#define host_info fixture_host
#define host_statistics64 fixture_vm
#include "../../Sources/MulgEngineHooks/MulgMemoryHooks.m"

static void refresh(void) {
    os_unfair_lock_lock(&snapshot_lock);
    memset(&snapshot, 0, sizeof(snapshot));
    os_unfair_lock_unlock(&snapshot_lock);
}
int main(void) {
    // No identity setup: a converted game's allocator still gets a usable budget.
    assert(mulg_os_proc_available_memory() == 8 * gib);
    // Apply new caps to an existing cached measurement, and reset them immediately.
    mulg_engine_set_memory_limit(4 * gib);
    assert(mulg_os_proc_available_memory() == 3 * gib);
    mulg_engine_set_memory_limit(0);
    assert(mulg_os_proc_available_memory() == 8 * gib);
    game = NO;
    assert(mulg_os_proc_available_memory() == 0);
    game = YES; native_answer = 3 * gib;
    assert(mulg_os_proc_available_memory() == 3 * gib);
    native_answer = 0; deny_level = YES; refresh();
    assert(mulg_os_proc_available_memory() == 4 * gib);
    deny_task_vm = YES; refresh();
    mulg_engine_set_memory_limit(4 * gib);
    assert(mulg_os_proc_available_memory() == 3 * gib);
    mulg_engine_set_memory_limit(0);
    deny_size = YES; refresh();
    assert(mulg_os_proc_available_memory() == 4 * gib);
    deny_vm = YES; refresh();
    assert(mulg_os_proc_available_memory() == 15 * gib);
    deny_size = NO; deny_level = NO; pressure = 0; refresh();
    assert(mulg_os_proc_available_memory() == 0);
    pressure = 50; footprint = 17 * gib; refresh();
    assert(mulg_os_proc_available_memory() == 0);
    return 0;
}
