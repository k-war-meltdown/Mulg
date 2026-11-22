#import <Foundation/Foundation.h>
#import "MulgEngineHooks.h"
#include <stdio.h>
#include <string.h>

static NSInteger native_value(id self, SEL command) { return 11; }
static NSInteger sdk_value(id self, SEL command) { return 22; }
static NSInteger wrapper_value(id self, SEL command) { return 33; }
BOOL mulg_engine_is_game_caller(const void *caller) { return caller == (const void *)sdk_value; }

@interface FixtureGameControl : NSObject
@end
@implementation FixtureGameControl
@end

#ifndef FIXTURE_SWIZZLE_SOURCE
#define FIXTURE_SWIZZLE_SOURCE "../../Sources/MulgEngineHooks/MulgSwizzle.m"
#endif
#include FIXTURE_SWIZZLE_SOURCE

#define CHECK(condition, message) do { if (!(condition)) { fputs("FAIL: " message "\n", stderr); return 1; } } while (0)
int main(void) {
    @autoreleasepool {
        // A bundled SDK has installed its implementation on a native class before
        // wrapper preparation. The shared installer must leave that method alone.
        Class nativeClass = objc_lookUpClass("NSProcessInfo");
        SEL foreign = sel_registerName("mulgFixtureForeignOwnedValue");
        class_addMethod(nativeClass, foreign, (IMP)sdk_value, "q@:");
        IMP previous = NULL;
        CHECK(mulg_swizzle_checked_owned("fixture", nativeClass, foreign, (IMP)wrapper_value,
              &previous, @encode(NSInteger), @[]) == MulgSwizzleResultConflict, "SDK implementation was overwritten");
        CHECK(previous == NULL, "a refused hook published an original");
        CHECK(method_getImplementation(class_getInstanceMethod(nativeClass, foreign)) == (IMP)sdk_value,
              "SDK method changed despite refusal");

        // The same rule covers class methods and inherited SDK methods on system classes.
        Class nativeMeta = object_getClass(nativeClass);
        class_addMethod(nativeMeta, foreign, (IMP)sdk_value, "q@:");
        CHECK(mulg_swizzle_class_owned("fixture", nativeClass, foreign, (IMP)wrapper_value, NULL)
              == MulgSwizzleResultConflict, "SDK class method was overwritten");
        SEL inherited = sel_registerName("mulgFixtureInheritedSDKValue");
        class_addMethod(objc_lookUpClass("NSObject"), inherited, (IMP)sdk_value, "q@:");
        CHECK(mulg_swizzle_instance_owned("fixture", nativeClass, inherited, (IMP)wrapper_value, NULL)
              == MulgSwizzleResultConflict, "inherited SDK implementation was overwritten");

        // Normal native methods remain hookable, including idempotent installation.
        SEL ordinary = sel_registerName("mulgFixtureNativeValue");
        class_addMethod(nativeClass, ordinary, (IMP)native_value, "q@:");
        CHECK(mulg_swizzle_instance_owned("fixture", nativeClass, ordinary, (IMP)wrapper_value, &previous)
              == MulgSwizzleResultReplaced, "normal native hook stopped working");
        CHECK(previous == (IMP)native_value, "native original was lost");
        CHECK(mulg_swizzle_instance_owned("fixture", nativeClass, ordinary, (IMP)wrapper_value, &previous)
              == MulgSwizzleResultReplaced, "repeated install failed");
        CHECK(previous == (IMP)native_value, "repeated install captured wrapper as original");

        // A later SDK takeover is respected on retry rather than reported as installed.
        Method ordinaryMethod = class_getInstanceMethod(nativeClass, ordinary);
        method_setImplementation(ordinaryMethod, (IMP)sdk_value);
        CHECK(mulg_swizzle_instance_owned("fixture", nativeClass, ordinary, (IMP)wrapper_value, &previous)
              == MulgSwizzleResultConflict, "late SDK takeover was ignored");
        CHECK(method_getImplementation(ordinaryMethod) == (IMP)sdk_value, "retry overwrote late SDK hook");

        // Game-authored methods are different: controls/renderers still need their hooks.
        Class gameClass = objc_lookUpClass("FixtureGameControl");
        class_addMethod(gameClass, foreign, (IMP)sdk_value, "q@:");
        CHECK(mulg_swizzle_instance_owned("fixture", gameClass, foreign, (IMP)wrapper_value, &previous)
              == MulgSwizzleResultReplaced, "game class override was rejected");
        CHECK(previous == (IMP)sdk_value, "game original was lost");
        puts("PASS: SDK-owned native methods preserved; ordinary native and game methods still hookable");
        return 0;
    }
}
