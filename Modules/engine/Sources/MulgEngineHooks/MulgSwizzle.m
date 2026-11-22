//
//  MulgSwizzle.m
//  engine module: IMP-based swizzling.
//
//  Upstream swizzled by adding "hook_" methods to NSObject and exchanging them. Replacing
//  the IMP directly keeps NSObject clean, needs no category methods, and returns the
//  previous implementation so the hook can call it.
//

#import "MulgEngineHooks.h"
#include <os/lock.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

static os_unfair_lock installation_lock = OS_UNFAIR_LOCK_INIT;
static NSMutableDictionary<NSString *, NSDictionary *> *installed_hooks;
static NSMutableDictionary<NSString *, NSDictionary *> *hook_reports;
/// Bumped (under installation_lock) whenever hook_reports changes.
static _Atomic(uint64_t) hook_reports_generation;

// Append-only entries: render-thread original lookup allocates nothing and takes no lock.
typedef struct OriginalEntry {
    Class cls;
    SEL selector;
    IMP replacement, original;
    struct OriginalEntry *next;
} OriginalEntry;
static _Atomic(OriginalEntry *) originals;

static BOOL related_classes(Class a, Class b) {
    if (class_isMetaClass(a) != class_isMetaClass(b)) return NO;
    for (Class current = a; current; current = class_getSuperclass(current)) if (current == b) return YES;
    for (Class current = b; current; current = class_getSuperclass(current)) if (current == a) return YES;
    return NO;
}

/// Bumped after every new entry is published, so a cached answer from before it is never reused.
static _Atomic(uint64_t) originals_generation = 1;

static IMP lookup_original(Class cls, SEL selector, IMP replacement) {
    for (Class current = cls; current; current = class_getSuperclass(current)) {
        for (OriginalEntry *entry = atomic_load(&originals); entry; entry = entry->next) {
            if (entry->cls == current && entry->selector == selector && entry->replacement == replacement) return entry->original;
        }
    }
    return NULL;
}

/// Every hook calls this on every call, render-path hooks every frame: the walk is the list of all hooks
/// (about 160) for each class up the hierarchy. A small per-thread cache answers repeated calls at once;
/// entries are immutable once published and the generation drops every cached answer when one is added.
/// The superclass is part of the key: a class a game created and disposed may have its address reused by
/// one with another hierarchy, and the answer depends on the whole chain.
typedef struct { Class cls, superclass; SEL selector; IMP replacement, original; uint64_t generation; } OriginalCacheLine;
// Two ways per bucket keep alternating hooks with the same hash resident. A direct-mapped
// cache made both calls walk the entire registry on every alternation, even after warming up.
typedef struct { OriginalCacheLine recent, previous; } OriginalCacheBucket;
static __thread OriginalCacheBucket original_cache[8];

IMP mulg_swizzle_original(Class cls, SEL selector, IMP replacement) {
    uint64_t generation = atomic_load_explicit(&originals_generation, memory_order_acquire);
    Class superclass = cls ? class_getSuperclass(cls) : Nil;
    size_t slot = (((uintptr_t)cls >> 4) ^ ((uintptr_t)selector >> 3) ^ ((uintptr_t)replacement >> 2)) & 7;
    OriginalCacheBucket *bucket = &original_cache[slot];
    OriginalCacheLine *line = &bucket->recent;
    if (line->generation == generation && line->cls == cls && line->superclass == superclass
        && line->selector == selector && line->replacement == replacement) return line->original;
    OriginalCacheLine *previous = &bucket->previous;
    if (previous->generation == generation && previous->cls == cls && previous->superclass == superclass
        && previous->selector == selector && previous->replacement == replacement) {
        OriginalCacheLine hit = *previous;
        *previous = *line;
        *line = hit;
        return hit.original;
    }
    IMP found = lookup_original(cls, selector, replacement);
    if (found) {
        *previous = *line;
        *line = (OriginalCacheLine){ cls, superclass, selector, replacement, found, generation };
    }
    return found;
}

/// Runs under installation_lock. NSMethodSignature throws on encodings it cannot parse (some private
/// and game classes have them); an exception leaving here skipped the unlock, and the next install on
/// any thread then deadlocked or crashed the game. An unreadable signature is a mismatch.
static BOOL signature_matches(Method method, const char *result, NSArray<NSString *> *arguments) {
    const char *types = method_getTypeEncoding(method);
    if (types == NULL) return NO;
    @try {
        NSMethodSignature *signature = [NSMethodSignature signatureWithObjCTypes:types];
        if (signature == nil || strcmp(signature.methodReturnType, result) != 0
            || signature.numberOfArguments != arguments.count + 2) return NO;
        for (NSUInteger i = 0; i < arguments.count; i++) {
            const char *actual = [signature getArgumentTypeAtIndex:i + 2];
            const char *expected = arguments[i].UTF8String;
            if (actual == NULL || expected == NULL || strcmp(actual, expected) != 0) return NO;
        }
        return YES;
    } @catch (NSException *exception) {
        return NO;
    }
}

static BOOL sdk_owns_system_method(Class cls, const char *className, Method method) {
    Class imageClass = class_isMetaClass(cls) ? objc_lookUpClass(className) : cls;
    const char *image = class_getImageName(imageClass);
    // A game/SDK can replace an Apple method before us. Preserve its ownership;
    // overwriting it breaks the SDK's saved method chain. Game-defined classes
    // and ordinary native implementations remain hookable. Metadata lookup only.
    return image && (strncmp(image, "/System/", 8) == 0 || strncmp(image, "/usr/lib/", 9) == 0)
        && mulg_engine_is_game_caller((const void *)method_getImplementation(method));
}

static MulgSwizzleResult install_owned(const char *owner, Class cls, const char *className, BOOL classMethod,
                                       SEL selector, IMP replacement, IMP *previous,
                                       const char *returnType, NSArray<NSString *> *arguments) {
    NSString *ownerName = @(owner);
    NSString *target = [NSString stringWithFormat:@"%s%s.%s", classMethod ? "+" : "-", className, sel_getName(selector)];
    os_unfair_lock_lock(&installation_lock);
    if (!installed_hooks) installed_hooks = [NSMutableDictionary dictionary];
    if (!hook_reports) hook_reports = [NSMutableDictionary dictionary];
    NSDictionary *existing = installed_hooks[target];
    MulgSwizzleResult result;
    Method method = cls ? class_getInstanceMethod(cls, selector) : NULL;
    if (existing && (![existing[@"owner"] isEqual:ownerName]
                     || (IMP)[existing[@"replacement"] pointerValue] != replacement)) {
        result = MulgSwizzleResultConflict;
    } else if (!cls) {
        result = MulgSwizzleResultClassMissing;
    } else if (!method) {
        result = MulgSwizzleResultMethodMissing;
    } else if (sdk_owns_system_method(cls, className, method)) {
        result = MulgSwizzleResultConflict;
    } else if (returnType && !signature_matches(method, returnType, arguments)) {
        result = MulgSwizzleResultSignatureMismatch;
    } else if (existing) {
        // Repeated installation must never replace the saved original with our own hook.
        if (previous && *previous != (IMP)[existing[@"previous"] pointerValue])
            *previous = (IMP)[existing[@"previous"] pointerValue];
        result = MulgSwizzleResultReplaced;
    } else {
        IMP original = method_getImplementation(method);
        if (original == replacement) {
            IMP inherited = lookup_original(class_getSuperclass(cls), selector, replacement);
            if (inherited && previous) *previous = inherited;
            if (inherited) installed_hooks[target] = @{ @"owner": ownerName,
                @"replacement": [NSValue valueWithPointer:replacement], @"previous": [NSValue valueWithPointer:inherited] };
            result = inherited ? MulgSwizzleResultReplaced : MulgSwizzleResultConflict;
        } else {
            // A shared replacement cannot identify a superclass entry when a native override
            // calls super. Keep that override native instead of making original lookup recurse.
            for (OriginalEntry *entry = atomic_load(&originals); entry; entry = entry->next) {
                if (entry->selector == selector && entry->replacement == replacement
                    && related_classes(cls, entry->cls)) {
                    atomic_fetch_add(&hook_reports_generation, 1);
                    hook_reports[[ownerName stringByAppendingString:target]] =
                        @{ @"target": target, @"owner": ownerName, @"result": @(MulgSwizzleResultConflict) };
                    os_unfair_lock_unlock(&installation_lock);
                    return MulgSwizzleResultConflict;
                }
            }
            OriginalEntry *entry = calloc(1, sizeof(*entry));
            if (!entry) { os_unfair_lock_unlock(&installation_lock); return MulgSwizzleResultConflict; }
            *entry = (OriginalEntry){ cls, selector, replacement, original, atomic_load(&originals) };
            atomic_store(&originals, entry); // Publish before exposing the replacement IMP.
            atomic_fetch_add_explicit(&originals_generation, 1, memory_order_release);
            if (previous) *previous = original;
            installed_hooks[target] = @{@"owner": ownerName,
                                        @"replacement": [NSValue valueWithPointer:replacement],
                                        @"previous": [NSValue valueWithPointer:original]};
            class_replaceMethod(cls, selector, replacement, method_getTypeEncoding(method));
            result = MulgSwizzleResultReplaced;
        }
    }
    hook_reports[[ownerName stringByAppendingString:target]] =
        @{@"target": target, @"owner": ownerName, @"result": @(result)};
    atomic_fetch_add(&hook_reports_generation, 1);
    os_unfair_lock_unlock(&installation_lock);
    return result;
}

MulgSwizzleResult mulg_swizzle_instance_owned(const char *owner, Class cls, SEL selector,
                                             IMP replacement, IMP *previous) {
    return install_owned(owner, cls, cls ? class_getName(cls) : "(missing class)",
                         cls ? class_isMetaClass(cls) : NO, selector, replacement, previous, NULL, nil);
}

MulgSwizzleResult mulg_swizzle_checked_owned(const char *owner, Class cls, SEL selector,
                                            IMP replacement, IMP *previous,
                                            const char *returnType, NSArray<NSString *> *arguments) {
    return install_owned(owner, cls, cls ? class_getName(cls) : "(missing class)",
                         cls ? class_isMetaClass(cls) : NO, selector, replacement, previous, returnType, arguments);
}

MulgSwizzleResult mulg_swizzle_class_owned(const char *owner, Class cls, SEL selector,
                                          IMP replacement, IMP *previous) {
    return install_owned(owner, cls ? object_getClass(cls) : Nil, cls ? class_getName(cls) : "(missing class)",
                         YES, selector, replacement, previous, NULL, nil);
}

MulgSwizzleResult mulg_swizzle_instance_named_owned(const char *owner, const char *className, SEL selector,
                                                   IMP replacement, IMP *previous) {
    MulgSwizzleResult result = install_owned(owner, objc_getClass(className), className, NO, selector,
                                             replacement, previous, NULL, nil);
    if (result == MulgSwizzleResultClassMissing) {
        // Hooks by name target one engine's classes (Unreal's IOSViewController, for one): a game
        // without that class has nothing to hook, which is not a broken hook.
        NSString *key = [NSString stringWithFormat:@"%s-%s.%s", owner, className, sel_getName(selector)];
        os_unfair_lock_lock(&installation_lock);
        NSMutableDictionary *report = [hook_reports[key] mutableCopy];
        if (report) {
            report[@"absent"] = @YES;
            hook_reports[key] = report;
            atomic_fetch_add(&hook_reports_generation, 1);
        }
        os_unfair_lock_unlock(&installation_lock);
    }
    return result;
}

uint64_t mulg_hook_installation_generation(void) {
    return atomic_load(&hook_reports_generation);
}

NSArray<NSDictionary<NSString *, id> *> *mulg_hook_installation_reports(void) {
    os_unfair_lock_lock(&installation_lock);
    NSArray *reports = hook_reports.allValues ?: @[];
    os_unfair_lock_unlock(&installation_lock);
    return reports;
}

MulgSwizzleResult mulg_swizzle_instance(Class cls, SEL selector, IMP replacement, IMP *previous) {
    return mulg_swizzle_instance_owned("unassigned", cls, selector, replacement, previous);
}

MulgSwizzleResult mulg_swizzle_class(Class cls, SEL selector, IMP replacement, IMP *previous) {
    return mulg_swizzle_class_owned("unassigned", cls, selector, replacement, previous);
}

MulgSwizzleResult mulg_swizzle_instance_named(const char *className, SEL selector, IMP replacement,
                                              IMP *previous) {
    return mulg_swizzle_instance_named_owned("unassigned", className, selector, replacement, previous);
}
