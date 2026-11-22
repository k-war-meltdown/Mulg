#import <MulgEngineHooks.h>
#include <assert.h>
static BOOL gameCaller;
BOOL mulg_engine_is_game_caller(const void *caller) { return gameCaller; }
void mulg_engine_set_memory_limit(uint64_t bytes) { (void)bytes; }
#include "../../Sources/MulgIdentityHooks/MulgIdentityHooks.m"
CFTypeRef MGCopyAnswer(CFStringRef question, CFDictionaryRef options) { return CFRetain(CFSTR("NativeMac")); }
int main(void) { @autoreleasepool {
    mulg_identity_set_game_only_answers(YES);
    mulg_identity_configure("iPad17,3", "J820AP");
    mulg_identity_configure_cpu(3, 6, 0, 0);
    mulg_identity_configure_host_name("__Mulg_iPad__");
    mulg_identity_configure_memory_limit(1073741824ULL);
    struct utsname native, wrapped;
    assert(uname(&native) == 0 && mulg_uname(&wrapped) == 0);
    assert(!strcmp(native.machine, wrapped.machine));
    int machineMIB[] = { CTL_HW, HW_MACHINE };
    char nativeMachine[256], machine[256];
    size_t length = sizeof(nativeMachine);
    assert(native_sysctlbyname()("hw.machine", nativeMachine, &length, NULL, 0) == 0);
    length = sizeof(machine);
    assert(sysctlbyname("hw.machine", machine, &length, NULL, 0) == 0);
    assert(!strcmp(machine, nativeMachine));
    length = sizeof(machine);
    assert(sysctl(machineMIB, 2, machine, &length, NULL, 0) == 0);
    assert(!strcmp(machine, nativeMachine));
    uint64_t nativeMemory = 0, memory = 0;
    length = sizeof(nativeMemory);
    assert(native_sysctlbyname()("hw.memsize", &nativeMemory, &length, NULL, 0) == 0);
    length = sizeof(memory);
    assert(sysctlbyname("hw.memsize", &memory, &length, NULL, 0) == 0 && memory == nativeMemory);
    int memoryMIB[] = { CTL_HW, HW_MEMSIZE };
    length = sizeof(memory);
    assert(sysctl(memoryMIB, 2, &memory, &length, NULL, 0) == 0 && memory == nativeMemory);
    // A game caller during profile setup must also keep native answers until publication.
    gameCaller = YES;
    mulg_identity_begin_profile_configuration();
    assert(!mulg_identity_is_active());
    assert(mulg_identity_has_configured_profile());
    assert(mulg_identity_sysctl_value("hw.machine") == NULL);
    assert(mulg_identity_cpu_count_for_caller((const void *)&main) == 0);
    assert(mulg_identity_limited_memory(nativeMemory) == nativeMemory);
    assert(mulg_uname(&wrapped) == 0 && !strcmp(wrapped.machine, native.machine));
    length = sizeof(machine);
    assert(sysctlbyname("hw.machine", machine, &length, NULL, 0) == 0 && !strcmp(machine, nativeMachine));
    length = sizeof(machine);
    assert(sysctl(machineMIB, 2, machine, &length, NULL, 0) == 0 && !strcmp(machine, nativeMachine));
    mulg_identity_finish_profile_configuration();
    assert(mulg_identity_is_active());
    gameCaller = NO;
    assert(mulg_identity_cpu_count_for_caller((const void *)&main) == 0);
    char host[256]; assert(gethostname(host, sizeof(host)) == 0 && strcmp(host, "__Mulg_iPad__"));
    CFTypeRef answer = mulg_MGCopyAnswer(CFSTR("ProductType"), NULL);
    assert(CFEqual(answer, CFSTR("NativeMac"))); CFRelease(answer);
    gameCaller = YES;
    assert(mulg_uname(&wrapped) == 0 && !strcmp(wrapped.machine, "iPad17,3"));
    length = sizeof(machine);
    assert(sysctlbyname("hw.machine", machine, &length, NULL, 0) == 0 && !strcmp(machine, "iPad17,3"));
    length = sizeof(machine);
    assert(sysctl(machineMIB, 2, machine, &length, NULL, 0) == 0 && !strcmp(machine, "iPad17,3"));
    // A short name or integer transfer must not claim that unfilled bytes were returned.
    char shortMachine[2] = { 0x7F, 0x7F };
    length = sizeof(shortMachine);
    assert(sysctlbyname("hw.machine", shortMachine, &length, NULL, 0) == -1 && errno == ENOMEM);
    assert(length == 0 && shortMachine[0] == 0x7F && shortMachine[1] == 0x7F);
    length = sizeof(shortMachine);
    assert(sysctl(machineMIB, 2, shortMachine, &length, NULL, 0) == -1 && errno == ENOMEM);
    assert(length == 0 && shortMachine[0] == 0x7F && shortMachine[1] == 0x7F);
    length = sizeof(shortMachine);
    assert(sysctlbyname("hw.ncpu", shortMachine, &length, NULL, 0) == -1 && errno == ENOMEM);
    assert(length == 0 && shortMachine[0] == 0x7F && shortMachine[1] == 0x7F);
    #if MULG_HAS_IOKIT
    int numericModel = 42;
    CFNumberRef nativeNumericModel = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &numericModel);
    assert(device_tree_answer(CFSTR("model"), nativeNumericModel) == NULL);
    CFRelease(nativeNumericModel);
    assert(device_tree_answer(CFSTR("compatible"), kCFBooleanTrue) == NULL);
    #endif
    length = sizeof(memory);
    assert(sysctlbyname("hw.memsize", &memory, &length, NULL, 0) == 0
        && memory == mulg_identity_limited_memory(nativeMemory));
    length = sizeof(memory);
    assert(sysctl(memoryMIB, 2, &memory, &length, NULL, 0) == 0
        && memory == mulg_identity_limited_memory(nativeMemory));
    answer = mulg_MGCopyAnswer(CFSTR("ProductType"), NULL);
    assert(CFEqual(answer, CFSTR("iPad17,3"))); CFRelease(answer);
    assert(mulg_identity_cpu_count_for_caller((const void *)&main) == 9);
    assert(gethostname(host, sizeof(host)) == 0 && !strcmp(host, "__Mulg_iPad__"));
    gameCaller = NO;
    assert(called_from_system((const void *)&main));
    gameCaller = YES; assert(!called_from_system((const void *)&main));
    uint32_t subfamily = UINT32_MAX;
    mulg_identity_configure_cpu(4, 4, 0x07d34b9f, 0);
    assert(mulg_identity_cpu_number("hw.cpusubfamily", &subfamily) == 1 && subfamily == 0);
    // Ordinary mode still routes direct game callers, while native callers keep Mac answers.
    gameCaller = NO;
    mulg_identity_set_game_only_answers(NO);
    assert(mulg_uname(&wrapped) == 0 && !strcmp(wrapped.machine, "iPad17,3"));
    length = sizeof(machine);
    assert(sysctlbyname("hw.machine", machine, &length, NULL, 0) == 0 && !strcmp(machine, nativeMachine));
    length = sizeof(machine);
    assert(sysctl(machineMIB, 2, machine, &length, NULL, 0) == 0 && !strcmp(machine, nativeMachine));
    length = sizeof(memory);
    assert(sysctlbyname("hw.memsize", &memory, &length, NULL, 0) == 0
        && memory == nativeMemory);
    // Clearing an identity also clears its auxiliary CPU, hostname and RAM answers.
    mulg_identity_configure(NULL, NULL);
    assert(!mulg_identity_is_active());
    assert(!mulg_identity_has_configured_profile());
    assert(mulg_identity_sysctl_value("kern.hostname") == NULL);
    assert(mulg_identity_cpu_count_for_caller((const void *)&main) == 0);
    assert(mulg_identity_limited_memory(nativeMemory) == nativeMemory);
    assert(mulg_uname(&wrapped) == 0 && !strcmp(native.machine, wrapped.machine));
    puts("PASS: opt-in identity isolates machine and RAM answers; legacy mode and native fallback remain intact");
    return 0;
} }
