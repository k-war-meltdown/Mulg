#import <Foundation/Foundation.h>
#include <assert.h>
#include "MulgForcedResolution.m"

// This fixture intentionally has the Unity player ivar but NO requestedRenderingSize
// getter, matching the installed Star Rail trampoline's Objective-C metadata.
@interface DisplayConnection : NSObject {
@public
    CGSize _requestedRenderingSize;
}
- (void)requestRenderingResolution:(CGSize)size;
@end
static CGSize received;
static unsigned int requests;
@implementation DisplayConnection
- (void)requestRenderingResolution:(CGSize)size { _requestedRenderingSize = size; received = size; requests++; }
@end

@interface DisplayManager : NSObject
@property(nonatomic, strong) DisplayConnection *mainDisplay;
+ (instancetype)Instance;
@end
@implementation DisplayManager
+ (instancetype)Instance {
    static DisplayManager *manager;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ manager = [DisplayManager new]; });
    return manager;
}
@end

@interface WrongDisplay : NSObject { @public CGPoint _requestedRenderingSize; }
@end
@implementation WrongDisplay
@end

MulgSwizzleResult mulg_swizzle_checked_owned(const char *owner, Class cls, SEL selector,
        IMP replacement, IMP *previous, const char *returnType, NSArray<NSString *> *arguments) {
    (void)owner; (void)arguments;
    Method method = class_getInstanceMethod(cls, selector);
    if (!method) return MulgSwizzleResultMethodMissing;
    char type[64]; method_getReturnType(method, type, sizeof type);
    if (strcmp(type, returnType)) return MulgSwizzleResultSignatureMismatch;
    *previous = method_setImplementation(method, replacement);
    return MulgSwizzleResultReplaced;
}

int main(void) { @autoreleasepool {
    assert(mulg_graphics_install_unity_display_hook());
    mulg_graphics_set_forced_resolution(YES, 3840, 2160);
    assert(!mulg_graphics_unity_display_apply() && requests == 0); // Display is not ready yet.
    DisplayConnection *display = [DisplayConnection new];
    DisplayManager.Instance.mainDisplay = display;
    assert(![display respondsToSelector:NSSelectorFromString(@"requestedRenderingSize")]);

    assert(mulg_graphics_unity_display_apply());
    assert(CGSizeEqualToSize(received, CGSizeMake(3840, 2160)) && requests == 1);
    assert([mulg_graphics_forced_resolution_report()[@"unityPlayerSnapshotSource"] isEqual:@"typed ivar"]);
    assert([mulg_graphics_forced_resolution_report()[@"unityPlayerDefaultSurfaceAdopted"] boolValue]);
    assert(!mulg_graphics_unity_display_apply() && requests == 1); // No needless surface rebuild.
    mulg_graphics_set_forced_resolution(YES, 5120, 2880);
    assert(mulg_graphics_unity_display_apply() && CGSizeEqualToSize(received, CGSizeMake(5120, 2880)));
    mulg_graphics_set_forced_resolution(NO, 5120, 2880);
    assert(mulg_graphics_unity_display_apply() && CGSizeEqualToSize(received, CGSizeZero));

    // Nonzero pre-existing requests also survive a trial; only the engine API writes them.
    mulg_graphics_reset_forced_resolution_for_testing();
    display->_requestedRenderingSize = CGSizeMake(1920, 1080);
    mulg_graphics_set_forced_resolution(YES, 2880, 1800);
    assert(mulg_graphics_unity_display_apply() && CGSizeEqualToSize(received, CGSizeMake(2880, 1800)));
    mulg_graphics_set_forced_resolution(NO, 2880, 1800);
    assert(mulg_graphics_unity_display_apply() && CGSizeEqualToSize(received, CGSizeMake(1920, 1080)));

    CGSize snapshot; NSString *source;
    WrongDisplay *wrong = [WrongDisplay new];
    assert(!read_display_request(wrong, WrongDisplay.class, &snapshot, &source));
    display->_requestedRenderingSize = CGSizeMake(NAN, 2160);
    assert(!read_display_request(display, DisplayConnection.class, &snapshot, &source));
    display->_requestedRenderingSize = CGSizeMake(0, 2160);
    assert(!read_display_request(display, DisplayConnection.class, &snapshot, &source));
} }
