#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#include <TargetConditionals.h>
#import <objc/runtime.h>
#import <MulgEngineHooks.h>
#import <MulgDisplayHooks.h>
#include <assert.h>

@interface FixtureLink : NSObject
@property(nonatomic) CAFrameRateRange preferredFrameRateRange;
@property(nonatomic) NSInteger preferredFramesPerSecond;
+ (instancetype)displayLinkWithTarget:(id)target selector:(SEL)selector;
@end
@implementation FixtureLink
+ (instancetype)displayLinkWithTarget:(id)target selector:(SEL)selector { return [self new]; }
@end

static BOOL rejectRange, rejectFPS;
static int fpsAttempts;
MulgSwizzleResult mulg_swizzle_checked_owned(const char *owner, Class cls, SEL selector, IMP replacement,
                                            IMP *previous, const char *returnType, NSArray<NSString *> *arguments) {
    if (selector == @selector(setPreferredFrameRateRange:) && rejectRange) return MulgSwizzleResultSignatureMismatch;
    if (selector == @selector(setPreferredFramesPerSecond:)) {
        if (cls == [FixtureLink class]) fpsAttempts++;
        if (rejectFPS) return MulgSwizzleResultConflict;
    }
    Method method = class_getInstanceMethod(cls, selector);
    if (!method) return MulgSwizzleResultMethodMissing;
    *previous = method_getImplementation(method);
    class_replaceMethod(cls, selector, replacement, method_getTypeEncoding(method));
    return MulgSwizzleResultReplaced;
}
BOOL mulg_engine_display_link_callback(BOOL drivesFrames, void (^callback)(void)) { callback(); return drivesFrames; }
MulgDisplayConfig mulg_display_current_config(void) { return (MulgDisplayConfig){0}; }
CAFrameRateRange mulg_display_apply_rules(CAFrameRateRange range, MulgDisplayConfig config) { return range; }

#undef TARGET_OS_IPHONE
#define TARGET_OS_IPHONE 1
#define CADisplayLink FixtureLink
#include "../../Sources/MulgDisplayHooks/MulgFrameRateHooks.m"

int main(int argc, const char **argv) {
    @autoreleasepool {
        rejectRange = argc > 1 && strcmp(argv[1], "range") == 0;
        rejectFPS = argc > 1 && strcmp(argv[1], "fps") == 0;
        MulgDisplayHook attempted = 0;
        MulgDisplayHook installed = mulg_display_install_frame_rate_hooks(&attempted);
        assert(!rejectRange || fpsAttempts == 0);
        assert((rejectRange || rejectFPS) ? !(installed & MulgDisplayHookDisplayLinkRate) : (installed & MulgDisplayHookDisplayLinkRate));
        FixtureLink *link = [FixtureLink new];
        link.preferredFramesPerSecond = 60;
        if (rejectRange || rejectFPS) assert(link.preferredFramesPerSecond == 60);
        else assert(link.preferredFrameRateRange.preferred == 60);
        puts("PASS: partial display hook failure preserves a callable native FPS setter");
    }
}
