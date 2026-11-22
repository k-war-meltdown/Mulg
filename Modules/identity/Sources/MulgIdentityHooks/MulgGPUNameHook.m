//
//  MulgGPUNameHook.m
//  identity module: the GPU name the game reads (PLAN.md §3.7).
//
//  A game can compare MTLDevice.name ("Apple M3 Pro") with the spoofed iPad and see they don't
//  match. This reports the iPad's GPU name instead. Only the name: supportsFamily and every
//  other capability stay the Mac's, because claiming features the GPU lacks crashes games.
//  On by default (identity.reportDeviceGPUName); the M5 string is unverified on a real iPad.
//

#import "MulgIdentityHooks.h"
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <MulgEngineHooks.h>
#include <stdatomic.h>
#include <limits.h>

static _Atomic(CFStringRef) mulg_gpu_name_value;
static _Atomic(int) installed_gpu_name;

int mulg_identity_copy_gpu_name(char *buffer, size_t capacity) {
    if (!mulg_identity_is_active() || !buffer || capacity == 0 || capacity > (size_t)LONG_MAX) return 0;
    CFStringRef value = atomic_load(&mulg_gpu_name_value);
    return value != NULL && CFStringGetCString(value, buffer, (CFIndex)capacity, kCFStringEncodingUTF8);
}

static NSString *mulg_gpu_name(id self, SEL _cmd) {
    if (mulg_identity_is_active() && mulg_engine_is_game_caller(__builtin_return_address(0))) {
        return (__bridge NSString *)atomic_load(&mulg_gpu_name_value);
    }
    IMP original = mulg_swizzle_original(object_getClass(self), _cmd, (IMP)mulg_gpu_name);
    return ((NSString *(*)(id, SEL))original)(self, _cmd);
}

static void install_gpu_class(__unsafe_unretained Class cls) {
    if (cls && mulg_swizzle_checked_owned("identity", cls, @selector(name), (IMP)mulg_gpu_name,
                                        NULL, @encode(id), @[]) == MulgSwizzleResultReplaced) {
        atomic_store(&installed_gpu_name, 1);
    }
}

static void observed_gpu_device(id device) {
    // The native factory already initialized this object. No device creation or +class
    // message is needed, and original lookup stays correct across different driver classes.
    install_gpu_class(object_getClass(device));
}

int mulg_identity_install_gpu_name_hook(const char *name) {
    NSString *value = name ? [NSString stringWithUTF8String:name] : nil; // stringWithUTF8String: throws on NULL.
    if (!value) return 0;
    CFStringRef previous = atomic_load(&mulg_gpu_name_value);
    if (!previous || !CFEqual(previous, (__bridge CFStringRef)value)) {
        CFRetain((__bridge CFStringRef)value); // Retained immutable identity, read on arbitrary threads.
        atomic_store(&mulg_gpu_name_value, (__bridge CFStringRef)value);
    }
    mulg_engine_set_metal_device_handler(observed_gpu_device);
    if (!atomic_load(&installed_gpu_name)) {
        // A framework may have obtained a device before runtime preparation. Cover its
        // registered classes using metadata only; factories cover drivers loaded later.
        Protocol *protocol = objc_getProtocol("MTLDevice");
        unsigned count = 0;
        Class __unsafe_unretained *classes = objc_copyClassList(&count);
        for (unsigned i = 0; protocol && i < count; i++) {
            __unsafe_unretained Class cls = classes[i];
            if (class_conformsToProtocol(cls, protocol)) install_gpu_class(cls);
        }
        free(classes);
    }
    // Report actual installation, not just an armed callback: late-image retries/diagnostics
    // still see pending coverage until a real driver class has been discovered.
    return atomic_load(&installed_gpu_name);
}
