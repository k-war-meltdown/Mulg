//
//  MulgIntegrationsHooks.h
//  integrations module: game credential imports call MulgChain answers.
//
//  The exported adapters live here in C; the keychain itself is Swift (`MulgChain`). The two meet
//  through a backend object the Swift side installs once at start-up.
//

#ifndef MULG_INTEGRATIONS_HOOKS_H
#define MULG_INTEGRATIONS_HOOKS_H

#import <Foundation/Foundation.h>
#import <Security/Security.h>

NS_ASSUME_NONNULL_BEGIN

/// Public AuthenticationServices presentation/lifetime compatibility. Providers' requests,
/// callbacks and credentials are forwarded unchanged. Callbacks below run on main and carry
/// only an allowlisted error domain/code, never authorization URLs or credential payloads.
NSArray<NSString *> *mulg_authentication_install(NSObject * _Nullable (^anchor)(void),
    void (^event)(NSString *provider, NSString *state, NSString * _Nullable domain, NSInteger code));
void mulg_authentication_disable(void);

/// Answers keychain calls instead of the system keychain, which ad-hoc signed games can't
/// use. Called on whatever thread the game called from, so implementations must be
/// thread-safe. Objects handed back through the out-parameters are autoreleased; the hooks
/// retain them for the caller as the Security framework's Create rule requires.
NS_SWIFT_NAME(KeychainBackend)
@protocol MulgKeychainBackend <NSObject>
- (OSStatus)copyMatching:(NSDictionary *)query
                  result:(id _Nullable __autoreleasing * _Nullable)result
    NS_SWIFT_NAME(copyMatching(_:result:));
- (OSStatus)add:(NSDictionary *)attributes
         result:(id _Nullable __autoreleasing * _Nullable)result
    NS_SWIFT_NAME(add(_:result:));
- (OSStatus)update:(NSDictionary *)query
        attributes:(NSDictionary *)attributesToUpdate
    NS_SWIFT_NAME(update(_:attributes:));
- (OSStatus)remove:(NSDictionary *)query
    NS_SWIFT_NAME(remove(_:));
/// Returns a SecKeyRef, or nil with `failure` set to a CFErrorRef.
- (nullable id)createRandomKey:(NSDictionary *)parameters
                       failure:(id _Nullable __autoreleasing * _Nullable)failure
    NS_SWIFT_NAME(createRandomKey(_:failure:));
- (OSStatus)generatePair:(NSDictionary *)parameters
               publicKey:(id _Nullable __autoreleasing * _Nullable)publicKey
              privateKey:(id _Nullable __autoreleasing * _Nullable)privateKey
    NS_SWIFT_NAME(generatePair(_:publicKey:privateKey:));
@end

/// Routes the six keychain calls to `backend`, or back to the system with nil. With
/// `logCalls`, every call and its status are written to the log (never the secrets).
void mulg_keychain_install(id<MulgKeychainBackend> _Nullable backend, BOOL logCalls);
/// Startup: the backend is being built on another thread. Until `mulg_keychain_end_loading`,
/// a game keychain call waits for it (at most 10 s) instead of failing or reaching the system.
/// The builder must never need the main thread, which may be the one waiting.
void mulg_keychain_begin_loading(void);
/// Ends that wait, whether or not a backend was installed. Only the first call does anything.
void mulg_keychain_end_loading(void);
/// Requested compatibility storage is unavailable: fail closed and coalesce retries on main.
void mulg_keychain_require_backend(void (^retry)(void));

/// Number of keychain calls answered by the backend so far (for diagnostics).
NSUInteger mulg_keychain_answered_count(void);

/// Explicit native calls to Security; never re-enter the compatibility backend.
OSStatus mulg_keychain_native_copy(CFDictionaryRef query, CFTypeRef _Nullable * _Nullable result);
OSStatus mulg_keychain_native_update(CFDictionaryRef query, CFDictionaryRef changes);
OSStatus mulg_keychain_native_delete(CFDictionaryRef query);
SecKeyRef _Nullable mulg_keychain_native_create_key(CFDictionaryRef parameters, CFErrorRef _Nullable * _Nullable error) CF_RETURNS_RETAINED;

NS_ASSUME_NONNULL_END

#endif
