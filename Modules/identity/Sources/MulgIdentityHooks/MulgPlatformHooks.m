//
//  MulgPlatformHooks.m
//  identity module: how the game sees the platform it runs on.
//
//  Upstream overrode these NSProcessInfo properties for every game through a Swift extension
//  (MulgInfo.swift), which replaced them globally with no way to switch off. Here they are
//  installed by the identity module, so switching the module off for a game restores the
//  real values.
//

#import "MulgIdentityHooks.h"
#import <Foundation/Foundation.h>
#import <MulgEngineHooks.h>
#include <stdatomic.h>
#include <limits.h>
#include <objc/runtime.h>
#include <stdlib.h>
#include <string.h>

static IMP previous_catalyst;
static IMP previous_ios_on_mac;
static BOOL mulg_isMacCatalystApp(id self, SEL _cmd) {
    return mulg_identity_is_active() && mulg_engine_is_game_caller(__builtin_return_address(0)) ? NO
        : ((BOOL (*)(id, SEL))previous_catalyst)(self, _cmd);
}

// YES as upstream by default; NO when the game should see a real iPad (identity.presentAsIPad).
static _Atomic(_Bool) mulg_report_on_mac = 1;

void mulg_identity_set_reports_mac(_Bool onMac) {
    atomic_store(&mulg_report_on_mac, onMac);
}

static BOOL mulg_isiOSAppOnMac(id self, SEL _cmd) {
    return mulg_identity_is_active() && mulg_engine_is_game_caller(__builtin_return_address(0)) ? atomic_load(&mulg_report_on_mac)
        : ((BOOL (*)(id, SEL))previous_ios_on_mac)(self, _cmd);
}

int mulg_identity_install_platform_hooks(void) {
    static BOOL catalystInstalled, iosOnMacInstalled;
    Class processInfo = [NSProcessInfo class];
    if (!catalystInstalled) catalystInstalled = mulg_swizzle_checked_owned("identity", processInfo,
        @selector(isMacCatalystApp), (IMP)mulg_isMacCatalystApp, &previous_catalyst, @encode(BOOL), @[]) == MulgSwizzleResultReplaced;
    if (!iosOnMacInstalled) iosOnMacInstalled = mulg_swizzle_checked_owned("identity", processInfo,
        @selector(isiOSAppOnMac), (IMP)mulg_isiOSAppOnMac, &previous_ios_on_mac, @encode(BOOL), @[]) == MulgSwizzleResultReplaced;
    return catalystInstalled + iosOnMacInstalled;
}

// The device name alone does not make UIKit's direct idiom queries agree. This
// opt-in override is confined to game callers, so macOS window/layout code stays native.
static _Atomic(int32_t) mobile_idiom = -1;
static IMP previous_device_idiom;
static IMP previous_trait_idiom;
static BOOL device_idiom_installed;
static BOOL trait_idiom_installed;

static NSInteger game_device_idiom(id self, SEL command) {
    int32_t idiom = atomic_load(&mobile_idiom);
    return mulg_identity_is_active() && idiom >= 0 && mulg_engine_is_game_caller(__builtin_return_address(0)) ? idiom
        : ((NSInteger (*)(id, SEL))previous_device_idiom)(self, command);
}

static NSInteger game_trait_idiom(id self, SEL command) {
    int32_t idiom = atomic_load(&mobile_idiom);
    return mulg_identity_is_active() && idiom >= 0 && mulg_engine_is_game_caller(__builtin_return_address(0)) ? idiom
        : ((NSInteger (*)(id, SEL))previous_trait_idiom)(self, command);
}

static BOOL install_idiom(Class cls, IMP replacement, IMP *previous) {
    SEL selector = NSSelectorFromString(@"userInterfaceIdiom");
    Method method = cls ? class_getInstanceMethod(cls, selector) : NULL;
    if (!method || method_getNumberOfArguments(method) != 2) return NO;
    char *type = method_copyReturnType(method);
    BOOL valid = type && strcmp(type, @encode(NSInteger)) == 0;
    free(type);
    return valid && mulg_swizzle_instance_owned("identity", cls, selector, replacement, previous)
        == MulgSwizzleResultReplaced;
}

int mulg_identity_install_mobile_ui_hooks(int32_t idiom) {
    if (idiom != 0 && idiom != 1) return 0;
    atomic_store(&mobile_idiom, idiom);
    if (!device_idiom_installed) device_idiom_installed = install_idiom(NSClassFromString(@"UIDevice"),
        (IMP)game_device_idiom, &previous_device_idiom);
    if (!trait_idiom_installed) trait_idiom_installed = install_idiom(NSClassFromString(@"UITraitCollection"),
        (IMP)game_trait_idiom, &previous_trait_idiom);
    return device_idiom_installed + trait_idiom_installed;
}

// MARK: - Memory and device name (PLAN.md §3.7: names and ranges, never capabilities)

typedef unsigned long long (*MemoryGetter)(id, SEL);
static IMP previous_physical_memory;

static unsigned long long mulg_physical_memory(id self, SEL _cmd) {
    unsigned long long real = ((MemoryGetter)previous_physical_memory)(self, _cmd);
    if (mulg_identity_game_only_answers() && !mulg_engine_is_game_caller(__builtin_return_address(0))) return real;
    return mulg_identity_limited_memory(real);
}

int mulg_identity_install_memory_hook(void) {
    static int installed = -1;
    if (installed != 1) {
        installed = mulg_swizzle_checked_owned("identity", [NSProcessInfo class], @selector(physicalMemory),
            (IMP)mulg_physical_memory, &previous_physical_memory, @encode(unsigned long long), @[]) == MulgSwizzleResultReplaced;
    }
    return installed;
}

// Immutable retained values have the same process lifetime as the C identity strings.
// Retry attempts do not replace equal values; concurrent getters never read released objects.
static _Atomic(CFStringRef) mulg_device_name_value;
static _Atomic(CFStringRef) mulg_device_model_value;
static _Atomic(CFStringRef) mulg_system_name_value;
static void publish_device_string(_Atomic(CFStringRef) *slot, NSString *value) {
    CFStringRef current = atomic_load(slot);
    CFStringRef next = (__bridge CFStringRef)value;
    if (current && CFEqual(current, next)) return;
    CFRetain(next);
    atomic_store(slot, next);
}

int mulg_identity_copy_device_string(const char *property, char *buffer, size_t capacity) {
    if (!mulg_identity_is_active() || !property || !buffer || capacity == 0 || capacity > (size_t)LONG_MAX) return 0;
    CFStringRef value = NULL;
    if (strcmp(property, "UIDevice.name") == 0) value = atomic_load(&mulg_device_name_value);
    else if (strcmp(property, "UIDevice.model") == 0 || strcmp(property, "UIDevice.localizedModel") == 0) {
        value = atomic_load(&mulg_device_model_value);
    } else if (strcmp(property, "UIDevice.systemName") == 0) value = atomic_load(&mulg_system_name_value);
    return value != NULL && CFStringGetCString(value, buffer, (CFIndex)capacity, kCFStringEncodingUTF8);
}

int mulg_identity_platform_number(const char *property, int32_t *value) {
    if (!mulg_identity_is_active() || !property || !value) return 0;
    if (strcmp(property, "NSProcessInfo.isMacCatalystApp") == 0) {
        *value = 0;
    } else if (strcmp(property, "NSProcessInfo.isiOSAppOnMac") == 0) {
        *value = atomic_load(&mulg_report_on_mac) ? 1 : 0;
    } else if (strcmp(property, "UIDevice.userInterfaceIdiom") == 0
               || strcmp(property, "UITraitCollection.userInterfaceIdiom") == 0) {
        int32_t idiom = atomic_load(&mobile_idiom);
        if (idiom < 0) return 0;
        *value = idiom;
    } else {
        return 0;
    }
    return 1;
}

static IMP previous_device_name;
static IMP previous_device_model;
static IMP previous_localized_model;
static IMP previous_system_name;

static BOOL native_device_answer(const void *caller) {
    return !mulg_identity_is_active()
        || (mulg_identity_game_only_answers() && !mulg_engine_is_game_caller(caller));
}

static NSString *mulg_device_name(id self, SEL _cmd) {
    return native_device_answer(__builtin_return_address(0))
        ? ((id (*)(id, SEL))previous_device_name)(self, _cmd) : (__bridge NSString *)atomic_load(&mulg_device_name_value);
}

static NSString *mulg_device_model(id self, SEL _cmd) {
    return native_device_answer(__builtin_return_address(0))
        ? ((id (*)(id, SEL))previous_device_model)(self, _cmd) : (__bridge NSString *)atomic_load(&mulg_device_model_value);
}

static NSString *mulg_localized_model(id self, SEL _cmd) {
    return native_device_answer(__builtin_return_address(0))
        ? ((id (*)(id, SEL))previous_localized_model)(self, _cmd) : (__bridge NSString *)atomic_load(&mulg_device_model_value);
}

static NSString *mulg_system_name(id self, SEL _cmd) {
    return native_device_answer(__builtin_return_address(0))
        ? ((id (*)(id, SEL))previous_system_name)(self, _cmd) : (__bridge NSString *)atomic_load(&mulg_system_name_value);
}

int mulg_identity_install_device_name_hook(const char *name) {
    static int installed = 0;
    publish_device_string(&mulg_device_name_value, (name ? [NSString stringWithUTF8String:name] : nil) ?: @"iPad");
    if (!installed) {
        Class device = NSClassFromString(@"UIDevice");
        installed = device != Nil
            && mulg_swizzle_checked_owned("identity", device, NSSelectorFromString(@"name"), (IMP)mulg_device_name,
                &previous_device_name, @encode(id), @[]) == MulgSwizzleResultReplaced;
    }
    return installed;
}

int mulg_identity_install_device_strings(const char *model, const char *systemName) {
    static BOOL modelInstalled, localizedInstalled, systemInstalled;
    publish_device_string(&mulg_device_model_value, (model ? [NSString stringWithUTF8String:model] : nil) ?: @"iPad");
    publish_device_string(&mulg_system_name_value, (systemName ? [NSString stringWithUTF8String:systemName] : nil) ?: @"iPadOS");
    Class device = NSClassFromString(@"UIDevice");
    if (!device) return 0;
    if (!modelInstalled) modelInstalled = mulg_swizzle_checked_owned("identity", device,
        NSSelectorFromString(@"model"), (IMP)mulg_device_model, &previous_device_model, @encode(id), @[]) == MulgSwizzleResultReplaced;
    if (!localizedInstalled) localizedInstalled = mulg_swizzle_checked_owned("identity", device,
        NSSelectorFromString(@"localizedModel"), (IMP)mulg_localized_model, &previous_localized_model, @encode(id), @[]) == MulgSwizzleResultReplaced;
    if (!systemInstalled) systemInstalled = mulg_swizzle_checked_owned("identity", device,
        NSSelectorFromString(@"systemName"), (IMP)mulg_system_name, &previous_system_name, @encode(id), @[]) == MulgSwizzleResultReplaced;
    return modelInstalled + localizedInstalled + systemInstalled;
}

// NSProcessInfo.hostName asks the system from inside Foundation, where the host-name hooks see a
// system caller, so it is answered here.
typedef NSString *(*StringGetter)(id, SEL);
static IMP previous_host_name;

static NSString *mulg_process_host_name(id self, SEL _cmd) {
    const char *host = mulg_identity_sysctl_value("kern.hostname");
    return host != NULL && mulg_engine_is_game_caller(__builtin_return_address(0))
        ? @(host) : ((StringGetter)previous_host_name)(self, _cmd);
}

int mulg_identity_install_host_name_hook(void) {
    static int installed = -1;
    if (installed != 1) {
        installed = mulg_swizzle_checked_owned("identity", [NSProcessInfo class], @selector(hostName),
            (IMP)mulg_process_host_name, &previous_host_name, @encode(id), @[]) == MulgSwizzleResultReplaced;
    }
    return installed;
}

// NSProcessInfo's processor counts ask the system from inside Foundation, where the sysctl hooks
// see a system caller, so they are answered here. objc_msgSend jumps to the method without a new
// frame, so the return address is the code that sent the message.
typedef NSUInteger (*CountGetter)(id, SEL);
static IMP previous_processor_count;
static IMP previous_active_processor_count;

static NSUInteger mulg_processor_count(id self, SEL _cmd) {
    uint32_t cores = mulg_identity_cpu_count_for_caller(__builtin_return_address(0));
    return cores != 0 ? cores : ((CountGetter)previous_processor_count)(self, _cmd);
}

static NSUInteger mulg_active_processor_count(id self, SEL _cmd) {
    uint32_t cores = mulg_identity_cpu_count_for_caller(__builtin_return_address(0));
    return cores != 0 ? cores : ((CountGetter)previous_active_processor_count)(self, _cmd);
}

int mulg_identity_install_cpu_count_hooks(void) {
    static BOOL countInstalled, activeInstalled;
    Class processInfo = [NSProcessInfo class];
    if (!countInstalled) countInstalled = mulg_swizzle_checked_owned("identity", processInfo,
        @selector(processorCount), (IMP)mulg_processor_count, &previous_processor_count, @encode(NSUInteger), @[]) == MulgSwizzleResultReplaced;
    if (!activeInstalled) activeInstalled = mulg_swizzle_checked_owned("identity", processInfo,
        @selector(activeProcessorCount), (IMP)mulg_active_processor_count, &previous_active_processor_count, @encode(NSUInteger), @[]) == MulgSwizzleResultReplaced;
    return countInstalled + activeInstalled;
}
