#import <Foundation/Foundation.h>
#import <MulgIntegrationsHooks.h>
#import <MulgEngineHooks.h>
#include <assert.h>
#include <string.h>

static BOOL game_caller;
static int native_calls, backend_calls;
BOOL mulg_engine_is_game_caller(const void *caller) { return game_caller; }
BOOL mulg_engine_is_game_memory_caller(const void *caller) { return game_caller; }
static OSStatus native_copy(CFDictionaryRef query, CFTypeRef *result) {
    native_calls++; if (result) *result = NULL; return errSecAuthFailed;
}
static OSStatus native_add(CFDictionaryRef query, CFTypeRef *result) { return native_copy(query, result); }
static OSStatus native_update(CFDictionaryRef query, CFDictionaryRef changes) { native_calls++; return errSecAuthFailed; }
static OSStatus native_delete(CFDictionaryRef query) { native_calls++; return errSecAuthFailed; }
static SecKeyRef native_create(CFDictionaryRef query, CFErrorRef *error) {
    native_calls++; if (error) *error = CFErrorCreate(NULL, kCFErrorDomainOSStatus, errSecAuthFailed, NULL); return NULL;
}
static OSStatus native_pair(CFDictionaryRef query, SecKeyRef *publicKey, SecKeyRef *privateKey) {
    native_calls++; if (publicKey) *publicKey = NULL; if (privateKey) *privateKey = NULL; return errSecAuthFailed;
}
static void *fixture_native_security_symbol(const char *name) {
    if (strcmp(name, "SecItemCopyMatching") == 0) return (void *)native_copy;
    if (strcmp(name, "SecItemAdd") == 0) return (void *)native_add;
    if (strcmp(name, "SecItemUpdate") == 0) return (void *)native_update;
    if (strcmp(name, "SecItemDelete") == 0) return (void *)native_delete;
    if (strcmp(name, "SecKeyCreateRandomKey") == 0) return (void *)native_create;
    if (strcmp(name, "SecKeyGeneratePair") == 0) return (void *)native_pair;
    return NULL;
}
#define MULG_SECURITY_SYMBOL_LOOKUP fixture_native_security_symbol
#include "../../Sources/MulgIntegrationsHooks/MulgKeychainHooks.m"

@interface FixtureBackend : NSObject <MulgKeychainBackend>
@end
@implementation FixtureBackend
- (OSStatus)copyMatching:(NSDictionary *)query result:(id __autoreleasing *)result {
    backend_calls++; if (result) *result = @"fixture"; return errSecSuccess;
}
- (OSStatus)add:(NSDictionary *)query result:(id __autoreleasing *)result { return [self copyMatching:query result:result]; }
- (OSStatus)update:(NSDictionary *)query attributes:(NSDictionary *)changes { backend_calls++; return errSecSuccess; }
- (OSStatus)remove:(NSDictionary *)query { backend_calls++; return errSecSuccess; }
- (id)createRandomKey:(NSDictionary *)query failure:(id __autoreleasing *)failure {
    backend_calls++; if (failure) *failure = nil; return @"key";
}
- (OSStatus)generatePair:(NSDictionary *)query publicKey:(id __autoreleasing *)publicKey privateKey:(id __autoreleasing *)privateKey {
    backend_calls++; if (publicKey) *publicKey = @"public"; if (privateKey) *privateKey = @"private"; return errSecSuccess;
}
@end

static void exercise(OSStatus expected) {
    CFDictionaryRef query = (__bridge CFDictionaryRef)@{ (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: @"same-service" };
    CFTypeRef result = NULL;
    assert(SecItemCopyMatching(query, &result) == expected);
    if (result) CFRelease(result);
    assert(SecItemAdd(query, NULL) == expected);
    assert(SecItemUpdate(query, query) == expected);
    assert(SecItemDelete(query) == expected);
    CFErrorRef error = NULL;
    SecKeyRef key = SecKeyCreateRandomKey(query, &error);
    assert((expected == errSecSuccess) == (key != NULL));
    if (key) CFRelease(key);
    if (error) { assert(CFErrorGetCode(error) == expected); CFRelease(error); }
    SecKeyRef publicKey = NULL, privateKey = NULL;
    assert(SecKeyGeneratePair(query, &publicKey, &privateKey) == expected);
    if (publicKey) CFRelease(publicKey);
    if (privateKey) CFRelease(privateKey);
}

int main(void) { @autoreleasepool {
    mulg_keychain_install([FixtureBackend new], NO);
    game_caller = YES; exercise(errSecSuccess);
    assert(backend_calls == 6 && native_calls == 0 && mulg_keychain_answered_count() == 6);
    game_caller = NO; exercise(errSecAuthFailed);
    assert(backend_calls == 6 && native_calls == 6 && mulg_keychain_answered_count() == 6);
    // No store at all (MulgChain off, module switched off): a game call is refused, never the real Keychain.
    mulg_keychain_install(nil, NO);
    game_caller = YES; exercise(errSecInteractionNotAllowed);
    assert(backend_calls == 6 && native_calls == 6);
    mulg_keychain_install(nil, NO);
    mulg_keychain_require_backend(^{});
    game_caller = YES; exercise(errSecInteractionNotAllowed);
    assert(backend_calls == 6 && native_calls == 6);
    game_caller = NO; exercise(errSecAuthFailed);
    assert(backend_calls == 6 && native_calls == 12);
    puts("PASS: all six credential hooks isolate game callers, never reach the real Keychain for them, and preserve native helper Security results");
} }
