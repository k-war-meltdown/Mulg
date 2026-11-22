//
//  MulgIdentityHooks.m
//  identity module: what device the game thinks it is running on (PLAN.md §3).
//
//  Replaces the identity part of upstream's MulgLoader.m and fixes its bugs (§3.4):
//   a. hw.product via a MIB array was never spoofed (it tested name[0] instead of name[1]);
//   b. an exactly-sized buffer was rejected, breaking the "ask size, then read" pattern;
//   c. failures returned ENOMEM directly instead of -1 with errno set;
//   d. hw.model returned the product ID instead of the board ID a real device reports;
//   e. the copied length was not written back.
//  It also reads fixed C strings instead of re-encoding the model on every call (§16.2 E3).
//
//  It also answers hw.targettype, machdep.cpu.brand_string and MobileGestalt's model questions
//  (MGCopyAnswer), so every place a game can read the model names the same iPad (§3.7).
//  The Mac's host name ("Someones-MacBook-Pro.local") becomes the iPad's generic name for the game.
//  The kernel version ends with the iPad's SoC ("RELEASE_ARM64_T8142") instead of the Mac's, and
//  MobileGestalt's HardwarePlatform names it ("t8142").
//  MobileGestalt also answers the numbers a real iPad gives (ChipID 0x8142, DeviceClassNumber,
//  the panel size), and IOKit's platform-expert device (the device-tree root: "model",
//  "compatible", "target-type", "platform-name") names the iPad instead of the Mac.
//  Game callers also see the device's CPU when one is configured: its core counts per performance
//  level and XNU's CPU family (hw.cpufamily 0x1d5a87e8 for the M5), through sysctl, sysctlbyname
//  and sysconf.
//
//  The engine owns Mac Catalyst memory compatibility independently of identity.
//
//  This file explicitly exports sysctl, sysctlbyname and gethostname for staged game imports,
//  and interposes uname, sysconf, MGCopyAnswer and, where
//  IOKit exists (the Mac), IORegistryEntryCreateCFProperty, IORegistryEntrySearchCFProperty and
//  IORegistryEntryCreateCFProperties. It replaces
//  upstream's versions and must never be loaded into the same game as upstream MulgKit'
//  MulgLoader.m.
//

#import "MulgIdentityHooks.h"
#import <MulgEngineHooks.h>

#include <CoreFoundation/CoreFoundation.h>
#include <ctype.h>
#include <dlfcn.h>
#include <errno.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <sys/sysctl.h>
#include <sys/utsname.h>
#include <time.h>
#include <TargetConditionals.h>

#if (TARGET_OS_OSX || TARGET_OS_MACCATALYST) && __has_include(<IOKit/IOKitLib.h>)
#include <IOKit/IOKitLib.h>
#define MULG_HAS_IOKIT 1
#else
#define MULG_HAS_IOKIT 0
#endif

#define MULG_INTERPOSE(replacement, original)                                            \
    __attribute__((used)) static const struct {                                          \
        const void *replacement_function;                                                \
        const void *original_function;                                                   \
    } mulg_interpose_##original __attribute__((section("__DATA,__interpose"))) = {       \
        (const void *)(unsigned long)&replacement, (const void *)(unsigned long)&original \
    };

// Set once at start-up, before the game's own code runs. NULL means "module off".
// Memory reported by hw.memsize and NSProcessInfo.physicalMemory is capped here; 0 is no cap.
static _Atomic(uint64_t) mulg_memory_limit = 0;
static _Atomic(bool) mulg_game_only_answers = false;
// Startup stages the complete profile before publishing any identity answer. Getters
// remain native while Apple/Metal classes are discovered and their replacements installed.
static _Atomic(bool) mulg_profile_ready = true;

void mulg_identity_begin_profile_configuration(void) {
    atomic_store_explicit(&mulg_profile_ready, false, memory_order_release);
}

void mulg_identity_finish_profile_configuration(void) {
    atomic_store_explicit(&mulg_profile_ready, true, memory_order_release);
}

static bool profile_answers_ready(void) {
    return atomic_load_explicit(&mulg_profile_ready, memory_order_acquire);
}

void mulg_identity_set_game_only_answers(_Bool enabled) {
    atomic_store(&mulg_game_only_answers, enabled);
}

_Bool mulg_identity_game_only_answers(void) {
    return atomic_load(&mulg_game_only_answers);
}

void mulg_identity_configure_memory_limit(uint64_t bytes) {
    atomic_store(&mulg_memory_limit, bytes);
    mulg_engine_set_memory_limit(bytes);
}

uint64_t mulg_identity_limited_memory(uint64_t real) {
    if (!profile_answers_ready()) return real;
    uint64_t limit = atomic_load(&mulg_memory_limit);
    return limit != 0 && real > limit ? limit : real;
}

uint64_t mulg_identity_available_memory(uint64_t limit, uint64_t footprint, uint64_t physical, int level) {
    uint64_t left = limit > footprint ? limit - footprint : 0;
    uint64_t percent = level < 0 ? 0 : (level > 100 ? 100 : (uint64_t)level);
    uint64_t available = physical / 100 * percent;
    return left < available ? left : available;
}

/// Lowers a memory size a real sysctl just wrote. Never raises it: a Mac with less memory than
/// the iPad keeps its real figure, so the game never plans for memory that isn't there.
static void limit_memory_result(void *oldp, size_t *oldlenp) {
    if (oldp == NULL || oldlenp == NULL || atomic_load(&mulg_memory_limit) == 0) {
        return;
    }
    if (*oldlenp == sizeof(uint64_t)) {
        uint64_t value;
        memcpy(&value, oldp, sizeof(value));
        value = mulg_identity_limited_memory(value);
        memcpy(oldp, &value, sizeof(value));
    }
}

static _Atomic(const char *) mulg_machine = NULL;
static _Atomic(const char *) mulg_board_id = NULL;
static _Atomic(const char *) mulg_target_type = NULL;
static _Atomic(const char *) mulg_device_class = NULL;
static _Atomic(const char *) mulg_cpu_brand = NULL;
static _Atomic(const char *) mulg_host_name = NULL;
static _Atomic(const char *) mulg_hardware_platform = NULL;
static _Atomic(const char *) mulg_kernel_version = NULL;
// The native panel in portrait pixels, as MobileGestalt reports it; 0 passes the Mac's through.
static _Atomic(int32_t) mulg_screen_width = 0;
static _Atomic(int32_t) mulg_screen_height = 0;
static _Atomic(double) mulg_screen_scale = 0;
// The device's CPU for game callers; 0 performance cores passes the Mac's through.
static _Atomic(uint32_t) mulg_cpu_performance = 0;
static _Atomic(uint32_t) mulg_cpu_efficiency = 0;
static _Atomic(uint32_t) mulg_cpu_family = 0;
static _Atomic(uint32_t) mulg_cpu_subfamily = 0;

// The copies are never freed: the identity lives for the whole process, and a hook on
// another thread may still be reading an older copy.
static const char *copy_or_null(const char *value) {
    return value != NULL ? strdup(value) : NULL;
}

void mulg_identity_configure(const char *machine, const char *board_id) {
    if (machine == NULL || board_id == NULL) {
        atomic_store(&mulg_machine, NULL);
        atomic_store(&mulg_board_id, NULL);
        atomic_store(&mulg_target_type, NULL);
        atomic_store(&mulg_device_class, NULL);
        atomic_store(&mulg_cpu_brand, NULL);
        atomic_store(&mulg_host_name, NULL);
        atomic_store(&mulg_hardware_platform, NULL);
        atomic_store(&mulg_kernel_version, NULL);
        mulg_identity_configure_memory_limit(0);
        mulg_identity_configure_screen(0, 0, 0);
        mulg_identity_configure_cpu(0, 0, 0, 0);
        return;
    }
    // hw.targettype is the board ID without "AP": "J820" for "J820AP", as on a Mac ("J316s").
    char *target_type = strdup(board_id);
    char *board_copy = strdup(board_id);
    char *machine_copy = strdup(machine);
    if (!target_type || !board_copy || !machine_copy) {
        free(target_type); free(board_copy); free(machine_copy);
        mulg_identity_configure(NULL, NULL);
        return;
    }
    size_t length = strlen(target_type);
    if (length > 2 && strcmp(target_type + length - 2, "AP") == 0) {
        target_type[length - 2] = '\0';
    }
    atomic_store(&mulg_target_type, target_type);
    atomic_store(&mulg_board_id, board_copy);
    atomic_store(&mulg_machine, machine_copy);
}

void mulg_identity_configure_platform(const char *device_class, const char *cpu_brand) {
    atomic_store(&mulg_device_class, copy_or_null(device_class));
    atomic_store(&mulg_cpu_brand, copy_or_null(cpu_brand));
}

void mulg_identity_configure_host_name(const char *name) {
    atomic_store(&mulg_host_name, copy_or_null(name));
}

char *mulg_identity_kernel_version(const char *real, const char *platform) {
    static const char marker[] = "RELEASE_ARM64_";
    const char *found = real != NULL && platform != NULL ? strstr(real, marker) : NULL;
    if (found == NULL) {
        return NULL;
    }
    size_t prefix = (size_t)(found - real) + sizeof(marker) - 1;
    const char *rest = real + prefix;
    while (isalnum((unsigned char)*rest)) {
        rest++;
    }
    size_t platform_length = strlen(platform);
    char *result = malloc(prefix + platform_length + strlen(rest) + 1);
    if (result == NULL) {
        return NULL;
    }
    memcpy(result, real, prefix);
    for (size_t i = 0; i < platform_length; i++) {
        result[prefix + i] = (char)toupper((unsigned char)platform[i]);
    }
    strcpy(result + prefix + platform_length, rest);
    return result;
}

void mulg_identity_configure_hardware_platform(const char *platform) {
    char *kernel = NULL;
    if (platform != NULL) {
        // This image's own uname is never interposed, so this is the Mac's real kernel version.
        struct utsname real;
        if (uname(&real) == 0) {
            kernel = mulg_identity_kernel_version(real.version, platform);
        }
    }
    atomic_store(&mulg_kernel_version, kernel);
    atomic_store(&mulg_hardware_platform, copy_or_null(platform));
}

void mulg_identity_configure_screen(int32_t width, int32_t height, double scale) {
    atomic_store(&mulg_screen_width, width);
    atomic_store(&mulg_screen_height, height);
    atomic_store(&mulg_screen_scale, scale);
}

void mulg_identity_configure_cpu(uint32_t performance, uint32_t efficiency, uint32_t family, uint32_t subfamily) {
    atomic_store(&mulg_cpu_efficiency, efficiency);
    atomic_store(&mulg_cpu_family, family);
    atomic_store(&mulg_cpu_subfamily, subfamily);
    atomic_store(&mulg_cpu_performance, performance);
}

int mulg_identity_is_active(void) {
    return profile_answers_ready() && mulg_identity_has_configured_profile();
}

_Bool mulg_identity_has_configured_profile(void) {
    return atomic_load(&mulg_machine) != NULL && atomic_load(&mulg_board_id) != NULL
        && atomic_load(&mulg_target_type) != NULL;
}

int mulg_identity_cpu_number(const char *name, uint32_t *value) {
    if (!profile_answers_ready()) return 0;
    uint32_t performance = atomic_load(&mulg_cpu_performance);
    uint32_t efficiency = atomic_load(&mulg_cpu_efficiency);
    if (performance == 0 || name == NULL || value == NULL) {
        return 0;
    }
    static const char *const totals[] = {
        "hw.ncpu", "hw.activecpu", "hw.physicalcpu", "hw.physicalcpu_max", "hw.logicalcpu", "hw.logicalcpu_max",
        "machdep.cpu.core_count", "machdep.cpu.thread_count", "machdep.cpu.cores_per_package",
        "machdep.cpu.logical_per_package"
    };
    for (size_t i = 0; i < sizeof(totals) / sizeof(totals[0]); i++) {
        if (strcmp(name, totals[i]) == 0) {
            *value = performance + efficiency;
            return 1;
        }
    }
    if (strcmp(name, "hw.nperflevels") == 0) {
        *value = efficiency > 0 ? 2 : 1;
        return 1;
    }
    // hw.perflevel0 is the fastest level ("Super" or "Performance" on the M5), hw.perflevel1 the
    // efficiency cores. Their names and cache sizes stay the Mac's.
    if (strncmp(name, "hw.perflevel", 12) == 0 && (name[12] == '0' || name[12] == '1') && name[13] == '.') {
        const char *field = name + 14;
        uint32_t cores = name[12] == '0' ? performance : efficiency;
        if (cores > 0 && (strcmp(field, "physicalcpu") == 0 || strcmp(field, "physicalcpu_max") == 0
                          || strcmp(field, "logicalcpu") == 0 || strcmp(field, "logicalcpu_max") == 0)) {
            *value = cores;
            return 1;
        }
        return 0;
    }
    uint32_t family = atomic_load(&mulg_cpu_family);
    if (family != 0 && (strcmp(name, "hw.cpufamily") == 0 || strcmp(name, "hw.cpusubfamily") == 0)) {
        // Zero is a valid subfamily (A12X). Once its family is known, report zero
        // instead of falling through to the Mac's unrelated subfamily.
        *value = strcmp(name, "hw.cpufamily") == 0 ? family : atomic_load(&mulg_cpu_subfamily);
        return 1;
    }
    return 0;
}

const char *mulg_identity_sysctl_value(const char *name) {
    if (!profile_answers_ready()) return NULL;
    const char *machine = atomic_load(&mulg_machine);
    if (machine == NULL || name == NULL) {
        return NULL;
    }
    if (strcmp(name, "hw.machine") == 0 || strcmp(name, "hw.product") == 0) {
        return machine;
    }
    if (strcmp(name, "hw.model") == 0 || strcmp(name, "hw.target") == 0) {
        return atomic_load(&mulg_board_id);
    }
    if (strcmp(name, "hw.targettype") == 0) {
        return atomic_load(&mulg_target_type);
    }
    if (strcmp(name, "machdep.cpu.brand_string") == 0) {
        return atomic_load(&mulg_cpu_brand);
    }
    if (strcmp(name, "kern.hostname") == 0) {
        return atomic_load(&mulg_host_name);
    }
    if (strcmp(name, "kern.version") == 0) {
        return atomic_load(&mulg_kernel_version);
    }
    return NULL;
}

const char *mulg_identity_gestalt_value(CFStringRef question) {
    if (!profile_answers_ready()) return NULL;
    const char *machine = atomic_load(&mulg_machine);
    if (machine == NULL || question == NULL || CFGetTypeID(question) != CFStringGetTypeID()) {
        return NULL;
    }
    // Plain keys and the obfuscated forms SDKs use for them. The obfuscated ones come from public
    // MobileGestalt key lists; check them on a real device (PLAN.md §3.2).
    if (CFEqual(question, CFSTR("ProductType")) || CFEqual(question, CFSTR("h9jDsbgj7xIVeIQ8S3/X3Q"))) {
        return machine;
    }
    if (CFEqual(question, CFSTR("HWModelStr")) || CFEqual(question, CFSTR("/YYygAofPDbhrwToVsXdeA"))) {
        return atomic_load(&mulg_board_id);
    }
    if (CFEqual(question, CFSTR("DeviceClass")) || CFEqual(question, CFSTR("+3Uf0Pm5F8Xy7Onyvko0vA"))
        || CFEqual(question, CFSTR("DeviceName"))) {
        return atomic_load(&mulg_device_class);
    }
    if (CFEqual(question, CFSTR("HardwarePlatform"))) {
        return atomic_load(&mulg_hardware_platform);
    }
    if (CFEqual(question, CFSTR("UserAssignedDeviceName"))) {
        return atomic_load(&mulg_host_name);
    }
    return NULL;
}

int mulg_identity_gestalt_number(CFStringRef question, double *value) {
    if (!mulg_identity_is_active() || question == NULL || value == NULL
        || CFGetTypeID(question) != CFStringGetTypeID()) {
        return 0;
    }
    if (CFEqual(question, CFSTR("ChipID"))) {
        // The CPID is the platform's number in hex: "t8142" is 0x8142.
        const char *platform = atomic_load(&mulg_hardware_platform);
        if (platform == NULL || platform[0] == '\0') {
            return 0;
        }
        *value = (double)strtol(platform + 1, NULL, 16);
        return *value > 0 ? 1 : 0;
    }
    if (CFEqual(question, CFSTR("DeviceClassNumber"))) {
        // MobileGestalt's device classes: 1 iPhone, 3 iPad.
        const char *device_class = atomic_load(&mulg_device_class);
        if (device_class == NULL) {
            return 0;
        }
        *value = strcmp(device_class, "iPad") == 0 ? 3 : strcmp(device_class, "iPhone") == 0 ? 1 : 0;
        return *value > 0 ? 1 : 0;
    }
    if (CFEqual(question, CFSTR("main-screen-width"))) {
        *value = atomic_load(&mulg_screen_width);
        return *value > 0 ? 1 : 0;
    }
    if (CFEqual(question, CFSTR("main-screen-height"))) {
        *value = atomic_load(&mulg_screen_height);
        return *value > 0 ? 1 : 0;
    }
    if (CFEqual(question, CFSTR("main-screen-scale"))) {
        *value = atomic_load(&mulg_screen_scale);
        return *value > 0 ? 2 : 0;
    }
    return 0;
}

size_t mulg_identity_platform_expert_value(CFStringRef key, char *out, size_t capacity) {
    if (!profile_answers_ready()) return 0;
    const char *machine = atomic_load(&mulg_machine);
    if (machine == NULL || key == NULL || out == NULL || CFGetTypeID(key) != CFStringGetTypeID()) {
        return 0;
    }
    // The device tree stores these as NUL-terminated strings back to back.
    const char *parts[3] = {NULL, NULL, NULL};
    if (CFEqual(key, CFSTR("model"))) {
        parts[0] = machine;
    } else if (CFEqual(key, CFSTR("target-type"))) {
        parts[0] = atomic_load(&mulg_target_type);
    } else if (CFEqual(key, CFSTR("compatible"))) {
        parts[0] = atomic_load(&mulg_board_id);
        parts[1] = machine;
        parts[2] = "AppleARM";
    } else if (CFEqual(key, CFSTR("platform-name"))) {
        parts[0] = atomic_load(&mulg_hardware_platform);
    }
    size_t used = 0;
    for (int i = 0; i < 3 && parts[i] != NULL; i++) {
        size_t length = strlen(parts[i]) + 1;
        if (used + length > capacity) {
            return 0;
        }
        memcpy(out + used, parts[i], length);
        used += length;
    }
    return used;
}

static int copy_sysctl_bytes(const void *value, size_t required, void *buffer, size_t *length) {
    if (buffer == NULL) {
        if (length != NULL) {
            *length = required;
        }
        return 0;
    }
    if (length == NULL) {
        errno = EINVAL;
        return -1;
    }
    if (*length < required) {
        // XNU's user-space scalar/string output rejects the complete transfer before
        // copying and returns an output cursor of zero, not the input capacity.
        // A caller must issue a separate NULL-buffer query to obtain the required size.
        *length = 0;
        errno = ENOMEM;
        return -1;
    }
    memcpy(buffer, value, required);
    *length = required;
    return 0;
}

int mulg_sysctl_copy_string(const char *value, void *buffer, size_t *length) {
    return copy_sysctl_bytes(value, strlen(value) + 1, buffer, length);
}

/// The same contract for the 4-byte integers (CTLTYPE_INT) the CPU sysctls return.
static int copy_sysctl_int(uint32_t value, void *buffer, size_t *length) {
    return copy_sysctl_bytes(&value, sizeof(value), buffer, length);
}

// MARK: - Replacements

// Game-image imports name this image as their provider. Keep the native implementation
// explicitly bound to libSystem so a runtime-internal call cannot recurse through our
// exported adapter and Apple's own frameworks retain their original imports.
static void *native_identity_function(const char *name) {
    static void *system;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ system = dlopen("/usr/lib/libSystem.B.dylib", RTLD_LAZY | RTLD_NOLOAD | RTLD_FIRST); });
    void *function = system ? dlsym(system, name) : NULL;
    if (!function) {
        fprintf(stderr, "Mulg: native identity API unavailable: %s\n", name);
        _exit(78);
    }
    return function;
}
#define MULG_NATIVE_IDENTITY(name) \
    static __typeof__(&name) native_##name(void) { \
        static __typeof__(&name) function; \
        static dispatch_once_t once; \
        dispatch_once(&once, ^{ function = native_identity_function(#name); }); \
        return function; \
    }
MULG_NATIVE_IDENTITY(sysctl)
MULG_NATIVE_IDENTITY(sysctlbyname)
MULG_NATIVE_IDENTITY(gethostname)

/// Native helpers and Apple's frameworks keep the Mac's answers for the newer questions (MobileGestalt,
/// hw.targettype, the CPU brand, the host name): UIKit and the system decide how to run the app
/// and tune for the hardware from them. Only the game and its bundled libraries see the iPad there.
/// Explicitly linked sysctl and hostname imports stay game-only; uname retains its
/// older ordinary-mode behavior for callers that already received that hook.
static int called_from_system(const void *address) {
    // The engine caches this hot path and distinguishes native helpers even inside the bundle.
    return !mulg_engine_is_game_caller(address);
}

/// The sysctl names only the game sees spoofed (see called_from_system).
static int game_only_sysctl(const char *name) {
    return strcmp(name, "hw.targettype") == 0 || strcmp(name, "machdep.cpu.brand_string") == 0
        || strcmp(name, "kern.hostname") == 0 || strcmp(name, "kern.version") == 0;
}

uint32_t mulg_identity_cpu_count_for_caller(const void *caller) {
    uint32_t total = 0;
    return mulg_identity_cpu_number("hw.ncpu", &total) && !called_from_system(caller) ? total : 0;
}

static int mulg_uname(struct utsname *name) {
    int result = uname(name);
    if (result != 0 || name == NULL) {
        return result;
    }
    if (!profile_answers_ready()) return result;
    const char *machine = atomic_load(&mulg_machine);
    if (machine != NULL && (!mulg_identity_game_only_answers() || !called_from_system(__builtin_return_address(0)))) {
        strlcpy(name->machine, machine, sizeof(name->machine));
    }
    const char *host = atomic_load(&mulg_host_name);
    const char *kernel = atomic_load(&mulg_kernel_version);
    if ((host != NULL || kernel != NULL) && !called_from_system(__builtin_return_address(0))) {
        if (host != NULL) {
            strlcpy(name->nodename, host, sizeof(name->nodename));
        }
        if (kernel != NULL) {
            strlcpy(name->version, kernel, sizeof(name->version));
        }
    }
    return result;
}

__attribute__((visibility("default"))) int sysctl(int *name, u_int namelen, void *oldp, size_t *oldlenp, void *newp, size_t newlen) {
    if (called_from_system(__builtin_return_address(0)) || !profile_answers_ready()) return native_sysctl()(name, namelen, oldp, oldlenp, newp, newlen);
    const char *machine = atomic_load(&mulg_machine);
    // Only reads are spoofed; anything else goes to the real sysctl.
    if (machine != NULL && newp == NULL && name != NULL && namelen == 2 && name[0] == CTL_HW
        && (!mulg_identity_game_only_answers() || !called_from_system(__builtin_return_address(0)))) {
        const char *board_id = atomic_load(&mulg_board_id);
        switch (name[1]) {
            case HW_MACHINE:
#ifdef HW_PRODUCT
            case HW_PRODUCT:
#endif
                return mulg_sysctl_copy_string(machine, oldp, oldlenp);
            case HW_MODEL:
#ifdef HW_TARGET
            case HW_TARGET:
#endif
                if (board_id != NULL) return mulg_sysctl_copy_string(board_id, oldp, oldlenp);
                break;
            default:
                break;
        }
    }
    if (newp == NULL && name != NULL && namelen == 2 && name[0] == CTL_KERN) {
        const char *value = name[1] == KERN_HOSTNAME ? atomic_load(&mulg_host_name)
            : name[1] == KERN_VERSION ? atomic_load(&mulg_kernel_version) : NULL;
        if (value != NULL && !called_from_system(__builtin_return_address(0))) {
            return mulg_sysctl_copy_string(value, oldp, oldlenp);
        }
    }
    // hw.ncpu and hw.activecpu by number; the rest of the CPU names have no fixed number.
    if (newp == NULL && name != NULL && namelen == 2 && name[0] == CTL_HW
        && (name[1] == HW_NCPU || name[1] == HW_AVAILCPU)) {
        uint32_t cores = mulg_identity_cpu_count_for_caller(__builtin_return_address(0));
        if (cores != 0) {
            return copy_sysctl_int(cores, oldp, oldlenp);
        }
    }
    int result = native_sysctl()(name, namelen, oldp, oldlenp, newp, newlen);
    if (result == 0 && newp == NULL && name != NULL && namelen == 2 && name[0] == CTL_HW && name[1] == HW_MEMSIZE
        && (!mulg_identity_game_only_answers() || !called_from_system(__builtin_return_address(0)))) {
        limit_memory_result(oldp, oldlenp);
    }
    return result;
}

__attribute__((visibility("default"))) int sysctlbyname(const char *name, void *oldp, size_t *oldlenp, void *newp, size_t newlen) {
    if (called_from_system(__builtin_return_address(0)) || !profile_answers_ready()) return native_sysctlbyname()(name, oldp, oldlenp, newp, newlen);
    const char *value = newp == NULL ? mulg_identity_sysctl_value(name) : NULL;
    if (value != NULL && (mulg_identity_game_only_answers() || game_only_sysctl(name))
        && called_from_system(__builtin_return_address(0))) {
        value = NULL;
    }
    if (value != NULL) {
        return mulg_sysctl_copy_string(value, oldp, oldlenp);
    }
    uint32_t number = 0;
    if (newp == NULL && mulg_identity_cpu_number(name, &number) && !called_from_system(__builtin_return_address(0))) {
        return copy_sysctl_int(number, oldp, oldlenp);
    }
    int result = native_sysctlbyname()(name, oldp, oldlenp, newp, newlen);
    if (result == 0 && newp == NULL && name != NULL && strcmp(name, "hw.memsize") == 0
        && (!mulg_identity_game_only_answers() || !called_from_system(__builtin_return_address(0)))) {
        limit_memory_result(oldp, oldlenp);
    }
    return result;
}

/// sysconf's processor counts read hw.ncpu from inside libc, where the sysctl hook sees a system caller.
// ponytail: std::thread::hardware_concurrency asks from inside libc++ and still sees the Mac's
// count; answer it too if a game is seen sizing its workers from it.
static long mulg_sysconf(int name) {
    if (name == _SC_NPROCESSORS_CONF || name == _SC_NPROCESSORS_ONLN) {
        uint32_t cores = mulg_identity_cpu_count_for_caller(__builtin_return_address(0));
        if (cores != 0) {
            return cores;
        }
    }
    return sysconf(name);
}

/// gethostname reads kern.hostname from inside libc, where the sysctl hook sees a system caller.
__attribute__((visibility("default"))) int gethostname(char *name, size_t namelen) {
    if (!profile_answers_ready()) return native_gethostname()(name, namelen);
    const char *host = atomic_load(&mulg_host_name);
    if (host == NULL || called_from_system(__builtin_return_address(0))) {
        return native_gethostname()(name, namelen);
    }
    if (name == NULL || strlen(host) >= namelen) {
        errno = ENAMETOOLONG;
        return -1;
    }
    strlcpy(name, host, namelen);
    return 0;
}

// Private libMobileGestalt function (linked through the SDK's libMobileGestalt.tbd).
extern CFTypeRef MGCopyAnswer(CFStringRef question, CFDictionaryRef options);

static CFTypeRef mulg_MGCopyAnswer(CFStringRef question, CFDictionaryRef options) {
    const char *value = mulg_identity_gestalt_value(question);
    if (value != NULL && !called_from_system(__builtin_return_address(0))) {
        // "Copy" rule: the caller releases the answer, as with the real function.
        return CFStringCreateWithCString(kCFAllocatorDefault, value, kCFStringEncodingUTF8);
    }
    double number = 0;
    int kind = mulg_identity_gestalt_number(question, &number);
    if (kind != 0 && !called_from_system(__builtin_return_address(0))) {
        if (kind == 2) {
            return CFNumberCreate(kCFAllocatorDefault, kCFNumberFloat64Type, &number);
        }
        int64_t integer = (int64_t)number;
        return CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt64Type, &integer);
    }
    return MGCopyAnswer(question, options);
}

#if MULG_HAS_IOKIT
/// The device-tree answer for `key` in the type the Mac answered (data on Apple silicon), or NULL
/// to keep `real`. The caller releases the answer.
static CFTypeRef device_tree_answer(CFStringRef key, CFTypeRef real) {
    if (real == NULL) return NULL;
    CFTypeID type = CFGetTypeID(real);
    // A numeric or collection property must keep its original type and value.
    // Treating every non-string object as CFData can crash a typed caller.
    if (type != CFStringGetTypeID() && type != CFDataGetTypeID()) return NULL;
    char bytes[128];
    size_t length = mulg_identity_platform_expert_value(key, bytes, sizeof(bytes));
    if (length == 0) {
        return NULL;
    }
    return type == CFStringGetTypeID()
        ? (CFTypeRef)CFStringCreateWithCString(kCFAllocatorDefault, bytes, kCFStringEncodingUTF8)
        : (CFTypeRef)CFDataCreate(kCFAllocatorDefault, (const UInt8 *)bytes, (CFIndex)length);
}

/// Game callers reading the platform-expert device get the iPad's device-tree strings. Consumes `real`.
static CFTypeRef platform_expert_answer(io_registry_entry_t entry, CFStringRef key, CFTypeRef real,
                                        const void *caller) {
    // Native framework readers must not allocate or transform profile answers.
    if (real == NULL || !mulg_identity_is_active() || called_from_system(caller)) {
        return real;
    }
    CFTypeRef answer = device_tree_answer(key, real);
    if (answer == NULL) return real;
    // Check the entry only for a relevant property, avoiding an IOKit query on every read.
    if (!IOObjectConformsTo(entry, "IOPlatformExpertDevice")) {
        CFRelease(answer);
        return real;
    }
    CFRelease(real);
    return answer;
}

static CFTypeRef mulg_IORegistryEntryCreateCFProperty(io_registry_entry_t entry, CFStringRef key,
                                                      CFAllocatorRef allocator, IOOptionBits options) {
    CFTypeRef real = IORegistryEntryCreateCFProperty(entry, key, allocator, options);
    return platform_expert_answer(entry, key, real, __builtin_return_address(0));
}

static CFTypeRef mulg_IORegistryEntrySearchCFProperty(io_registry_entry_t entry, const io_name_t plane,
                                                      CFStringRef key, CFAllocatorRef allocator,
                                                      IOOptionBits options) {
    CFTypeRef real = IORegistryEntrySearchCFProperty(entry, plane, key, allocator, options);
    return platform_expert_answer(entry, key, real, __builtin_return_address(0));
}

/// Every property of the entry as one mutable dictionary: the same four names are replaced in it.
static kern_return_t mulg_IORegistryEntryCreateCFProperties(io_registry_entry_t entry,
                                                            CFMutableDictionaryRef *properties,
                                                            CFAllocatorRef allocator, IOOptionBits options) {
    kern_return_t result = IORegistryEntryCreateCFProperties(entry, properties, allocator, options);
    if (result != KERN_SUCCESS || properties == NULL || *properties == NULL || !mulg_identity_is_active()
        || called_from_system(__builtin_return_address(0)) || !IOObjectConformsTo(entry, "IOPlatformExpertDevice")) {
        return result;
    }
    CFStringRef keys[] = {CFSTR("model"), CFSTR("compatible"), CFSTR("target-type"), CFSTR("platform-name")};
    for (size_t i = 0; i < sizeof(keys) / sizeof(keys[0]); i++) {
        CFTypeRef answer = device_tree_answer(keys[i], CFDictionaryGetValue(*properties, keys[i]));
        if (answer != NULL) {
            CFDictionarySetValue(*properties, keys[i], answer);
            CFRelease(answer);
        }
    }
    return result;
}

MULG_INTERPOSE(mulg_IORegistryEntryCreateCFProperty, IORegistryEntryCreateCFProperty)
MULG_INTERPOSE(mulg_IORegistryEntryCreateCFProperties, IORegistryEntryCreateCFProperties)
MULG_INTERPOSE(mulg_IORegistryEntrySearchCFProperty, IORegistryEntrySearchCFProperty)
#endif

int mulg_identity_iokit_hooked(void) {
    return MULG_HAS_IOKIT;
}

MULG_INTERPOSE(mulg_uname, uname)
MULG_INTERPOSE(mulg_sysconf, sysconf)
MULG_INTERPOSE(mulg_MGCopyAnswer, MGCopyAnswer)


