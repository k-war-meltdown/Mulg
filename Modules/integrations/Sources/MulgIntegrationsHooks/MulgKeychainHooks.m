//
//  MulgKeychainHooks.m
//  integrations module: explicit game credential imports for MulgChain.
//
//  Replaces the keychain part of upstream's MulgLoader.m, with these fixes:
//   - the setting is read once at start-up instead of through MulgKitSettings on every call;
//   - the debug log no longer prints whole queries and results, which contained passwords
//     and tokens in clear text; it logs the item class, the call and the status only;
//   - a NULL `result` pointer is honoured (upstream dereferenced it when logging);
//   - a game call never reaches the real Keychain: with no store it is refused (2026-10-10).
//
//  Game imports are bound to these exports by the installer. System frameworks keep
//  their Security imports; native helpers resolve Security directly without reentry.
//

#import "MulgIntegrationsHooks.h"
#import <MulgEngineHooks.h>

#include <dlfcn.h>
#include <os/log.h>
#include <stdatomic.h>
#include <string.h>

static void *mulg_security_symbol(const char *name) {
    static void *security;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        security = dlopen("/System/Library/Frameworks/Security.framework/Security",
                          RTLD_LAZY | RTLD_NOLOAD | RTLD_FIRST);
    });
    return security == NULL ? NULL : dlsym(security, name);
}

#ifndef MULG_SECURITY_SYMBOL_LOOKUP
#define MULG_SECURITY_SYMBOL_LOOKUP mulg_security_symbol
#endif
#define MULG_NATIVE_SECURITY(name) \
    static __typeof__(&name) mulg_native_##name(void) { \
        static __typeof__(&name) function; \
        static dispatch_once_t once; \
        dispatch_once(&once, ^{ function = (__typeof__(&name))MULG_SECURITY_SYMBOL_LOOKUP(#name); }); \
        return function; \
    }
MULG_NATIVE_SECURITY(SecItemCopyMatching)
MULG_NATIVE_SECURITY(SecItemAdd)
MULG_NATIVE_SECURITY(SecItemUpdate)
MULG_NATIVE_SECURITY(SecItemDelete)
MULG_NATIVE_SECURITY(SecKeyCreateRandomKey)
MULG_NATIVE_SECURITY(SecKeyGeneratePair)

// Set once at start-up; read on every keychain call from any thread.
static _Atomic(void *) mulg_backend = NULL;
static atomic_bool mulg_log_calls = false;
static atomic_ulong mulg_answered = 0;
static _Atomic(void *) mulg_retry = NULL;
static atomic_bool mulg_retry_queued = false;
static dispatch_group_t mulg_loading;
static atomic_bool mulg_is_loading = false;

void mulg_keychain_begin_loading(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        mulg_loading = dispatch_group_create();
        dispatch_group_enter(mulg_loading);
        atomic_store(&mulg_is_loading, true);
    });
}

void mulg_keychain_end_loading(void) {
    if (atomic_exchange(&mulg_is_loading, false)) dispatch_group_leave(mulg_loading);
}

void mulg_keychain_require_backend(void (^retry)(void)) {
    // Like the backend, the published block survives calls already using it on another thread.
    atomic_store(&mulg_retry, (__bridge_retained void *)[retry copy]);
}

void mulg_keychain_install(id<MulgKeychainBackend> backend, BOOL logCalls) {
    atomic_store(&mulg_log_calls, logCalls);
    // The backend lives for the whole process: a call on another thread may still be using
    // an older one, so it is retained and never released.
    void *retained = backend != nil ? (__bridge_retained void *)backend : NULL;
    atomic_store(&mulg_backend, retained);
    atomic_store(&mulg_retry, NULL);
}

NSUInteger mulg_keychain_answered_count(void) {
    return atomic_load(&mulg_answered);
}

OSStatus mulg_keychain_native_copy(CFDictionaryRef query, CFTypeRef *result) {
    __typeof__(&SecItemCopyMatching) native = mulg_native_SecItemCopyMatching();
    if (native != NULL) return native(query, result);
    if (result) *result = NULL;
    return errSecUnimplemented;
}
OSStatus mulg_keychain_native_update(CFDictionaryRef query, CFDictionaryRef changes) {
    __typeof__(&SecItemUpdate) native = mulg_native_SecItemUpdate();
    return native != NULL ? native(query, changes) : errSecUnimplemented;
}
OSStatus mulg_keychain_native_delete(CFDictionaryRef query) {
    __typeof__(&SecItemDelete) native = mulg_native_SecItemDelete();
    return native != NULL ? native(query) : errSecUnimplemented;
}
SecKeyRef mulg_keychain_native_create_key(CFDictionaryRef parameters, CFErrorRef *error) {
    __typeof__(&SecKeyCreateRandomKey) native = mulg_native_SecKeyCreateRandomKey();
    if (native != NULL) return native(parameters, error);
    if (error) *error = CFErrorCreate(NULL, kCFErrorDomainOSStatus, errSecUnimplemented, NULL);
    return NULL;
}

static id<MulgKeychainBackend> current_backend(BOOL *unavailable) {
    if (atomic_load(&mulg_backend) == NULL && atomic_load(&mulg_is_loading)) {
        // Every thread waits, the main one too: a token read refused here looks to a sign-in SDK like "signed
        // out", and a refused save makes the login itself fail. Loading always ends with a store now (a session
        // store when saved logins cannot open), so the wait is only as long as reading the key; on a launch that
        // moves an older Keychain key it can include the macOS password prompt.
        dispatch_group_wait(mulg_loading, dispatch_time(DISPATCH_TIME_NOW, 10 * (int64_t)NSEC_PER_SEC));
    }
    void *retry = atomic_load(&mulg_retry);
    void *backend = atomic_load(&mulg_backend);
    // No store means no keychain for the game, never the real macOS Keychain (2026-10-10): like a locked
    // iPhone, the call is refused. Mulg's own callers and the system's still reach the native functions,
    // and the game's sandbox walls those off from the Keychain services.
    *unavailable = backend == NULL;
    if (backend == NULL) {
        bool expected = false;
        if (retry != NULL && atomic_compare_exchange_strong(&mulg_retry_queued, &expected, true)) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                if (atomic_load(&mulg_backend) == NULL && atomic_load(&mulg_retry) == retry) {
                    ((__bridge void (^)(void))retry)();
                }
                atomic_store(&mulg_retry_queued, false);
            });
        }
        return nil;
    }
    atomic_fetch_add(&mulg_answered, 1);
    return (__bridge id<MulgKeychainBackend>)backend;
}

static os_log_t keychain_log(void) {
    static os_log_t log;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        log = os_log_create("io.mulg", "integrations");
    });
    return log;
}

static void log_call(const char *call, CFDictionaryRef dictionary, OSStatus status) {
    if (!atomic_load(&mulg_log_calls)) {
        return;
    }
    NSString *itemClass = dictionary != NULL ? ((__bridge NSDictionary *)dictionary)[(__bridge id)kSecClass] : nil;
    os_log(keychain_log(), "MulgChain %{public}s class=%{public}@ status=%d", call,
           itemClass ?: @"-", (int)status);
}

// MARK: - SecItem

__attribute__((visibility("default"))) OSStatus SecItemCopyMatching(CFDictionaryRef query, CFTypeRef *result) {
    if (!mulg_engine_is_game_memory_caller(__builtin_return_address(0))) return mulg_keychain_native_copy(query, result);
    BOOL unavailable;
    id<MulgKeychainBackend> backend = current_backend(&unavailable);
    if (unavailable) { if (result) *result = NULL; return errSecInteractionNotAllowed; }
    id answer = nil;
    OSStatus status = [backend copyMatching:(__bridge NSDictionary *)query result:&answer];
    if (result != NULL) {
        *result = status == errSecSuccess && answer != nil ? CFBridgingRetain(answer) : NULL;
    }
    log_call("SecItemCopyMatching", query, status);
    return status;
}

__attribute__((visibility("default"))) OSStatus SecItemAdd(CFDictionaryRef attributes, CFTypeRef *result) {
    if (!mulg_engine_is_game_memory_caller(__builtin_return_address(0))) {
        __typeof__(&SecItemAdd) native = mulg_native_SecItemAdd();
        if (native != NULL) return native(attributes, result);
        if (result) *result = NULL;
        return errSecUnimplemented;
    }
    BOOL unavailable;
    id<MulgKeychainBackend> backend = current_backend(&unavailable);
    if (unavailable) { if (result) *result = NULL; return errSecInteractionNotAllowed; }
    id answer = nil;
    OSStatus status = [backend add:(__bridge NSDictionary *)attributes result:&answer];
    if (result != NULL) {
        *result = status == errSecSuccess && answer != nil ? CFBridgingRetain(answer) : NULL;
    }
    log_call("SecItemAdd", attributes, status);
    return status;
}

__attribute__((visibility("default"))) OSStatus SecItemUpdate(CFDictionaryRef query, CFDictionaryRef attributesToUpdate) {
    if (!mulg_engine_is_game_memory_caller(__builtin_return_address(0))) return mulg_keychain_native_update(query, attributesToUpdate);
    BOOL unavailable;
    id<MulgKeychainBackend> backend = current_backend(&unavailable);
    if (unavailable) return errSecInteractionNotAllowed;
    OSStatus status = [backend update:(__bridge NSDictionary *)query
                           attributes:(__bridge NSDictionary *)attributesToUpdate];
    log_call("SecItemUpdate", query, status);
    return status;
}

__attribute__((visibility("default"))) OSStatus SecItemDelete(CFDictionaryRef query) {
    if (!mulg_engine_is_game_memory_caller(__builtin_return_address(0))) return mulg_keychain_native_delete(query);
    BOOL unavailable;
    id<MulgKeychainBackend> backend = current_backend(&unavailable);
    if (unavailable) return errSecInteractionNotAllowed;
    OSStatus status = [backend remove:(__bridge NSDictionary *)query];
    log_call("SecItemDelete", query, status);
    return status;
}

// MARK: - SecKey

__attribute__((visibility("default"))) SecKeyRef SecKeyCreateRandomKey(CFDictionaryRef parameters, CFErrorRef *error) {
    if (!mulg_engine_is_game_memory_caller(__builtin_return_address(0))) return mulg_keychain_native_create_key(parameters, error);
    BOOL unavailable;
    id<MulgKeychainBackend> backend = current_backend(&unavailable);
    if (unavailable) {
        if (error) *error = CFErrorCreate(NULL, kCFErrorDomainOSStatus, errSecInteractionNotAllowed, NULL);
        return NULL;
    }
    id failure = nil;
    id key = [backend createRandomKey:(__bridge NSDictionary *)parameters failure:&failure];
    if (error != NULL) {
        *error = key == nil && failure != nil ? (CFErrorRef)CFBridgingRetain(failure) : NULL;
    }
    log_call("SecKeyCreateRandomKey", parameters, key != nil ? errSecSuccess : errSecParam);
    return key != nil ? (SecKeyRef)CFBridgingRetain(key) : NULL;
}

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
__attribute__((visibility("default"))) OSStatus SecKeyGeneratePair(CFDictionaryRef parameters, SecKeyRef *publicKey, SecKeyRef *privateKey) {
    if (!mulg_engine_is_game_memory_caller(__builtin_return_address(0))) {
        __typeof__(&SecKeyGeneratePair) native = mulg_native_SecKeyGeneratePair();
        if (native != NULL) return native(parameters, publicKey, privateKey);
        if (publicKey) *publicKey = NULL;
        if (privateKey) *privateKey = NULL;
        return errSecUnimplemented;
    }
    BOOL unavailable;
    id<MulgKeychainBackend> backend = current_backend(&unavailable);
    if (unavailable) {
        if (publicKey) *publicKey = NULL;
        if (privateKey) *privateKey = NULL;
        return errSecInteractionNotAllowed;
    }
    id publicAnswer = nil;
    id privateAnswer = nil;
    OSStatus status = [backend generatePair:(__bridge NSDictionary *)parameters
                                  publicKey:&publicAnswer
                                 privateKey:&privateAnswer];
    if (publicKey != NULL) {
        *publicKey = status == errSecSuccess && publicAnswer != nil ? (SecKeyRef)CFBridgingRetain(publicAnswer) : NULL;
    }
    if (privateKey != NULL) {
        *privateKey = status == errSecSuccess && privateAnswer != nil ? (SecKeyRef)CFBridgingRetain(privateAnswer) : NULL;
    }
    log_call("SecKeyGeneratePair", parameters, status);
    return status;
}

#pragma clang diagnostic pop
