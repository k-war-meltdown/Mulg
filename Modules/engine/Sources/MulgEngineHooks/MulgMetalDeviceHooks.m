// Engine-owned native device discovery; callbacks never request another Metal device.
#import "MulgEngineHooks.h"
#import <Metal/Metal.h>
#include <stdatomic.h>

static _Atomic(MulgMetalDeviceHandler) metal_device_handler;
static _Atomic(MulgMetalDeviceHandler) extra_handlers[4];

void mulg_engine_set_metal_device_handler(MulgMetalDeviceHandler handler) {
    atomic_store_explicit(&metal_device_handler, handler, memory_order_release);
}

void mulg_engine_add_metal_device_handler(MulgMetalDeviceHandler handler) {
    for (size_t i = 0; i < 4; i++) {
        MulgMetalDeviceHandler empty = NULL;
        if (atomic_load_explicit(&extra_handlers[i], memory_order_acquire) == handler) return;
        if (atomic_compare_exchange_strong(&extra_handlers[i], &empty, handler)) return;
    }
}

static void observed_device(id device) {
    MulgMetalDeviceHandler handler = atomic_load_explicit(&metal_device_handler, memory_order_acquire);
    if (device && handler) handler(device);
    for (size_t i = 0; device && i < 4; i++) {
        MulgMetalDeviceHandler extra = atomic_load_explicit(&extra_handlers[i], memory_order_acquire);
        if (extra) extra(device);
    }
}

static id<MTLDevice> __attribute__((ns_returns_retained)) mulg_create_default_device(void) {
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    observed_device(device);
    return device;
}

static NSArray<id<MTLDevice>> * __attribute__((ns_returns_retained)) mulg_copy_all_devices(void) {
    NSArray<id<MTLDevice>> *devices = MTLCopyAllDevices();
    for (id<MTLDevice> device in devices) observed_device(device);
    return devices;
}

#define MULG_METAL_INTERPOSE(replacement, original)                                      \
    __attribute__((used)) static const struct {                                         \
        const void *replacement_function;                                              \
        const void *original_function;                                                 \
    } mulg_interpose_##original __attribute__((section("__DATA,__interpose"))) = {       \
        (const void *)(unsigned long)&replacement, (const void *)(unsigned long)&original \
    };

MULG_METAL_INTERPOSE(mulg_create_default_device, MTLCreateSystemDefaultDevice)
MULG_METAL_INTERPOSE(mulg_copy_all_devices, MTLCopyAllDevices)
