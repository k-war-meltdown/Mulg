#import "MulgControlsHooks.h"
#import <MulgEngineHooks.h>
#import <objc/runtime.h>
#include <assert.h>
#include <string.h>

static int initialized;
@interface UIViewController : NSObject
- (BOOL)prefersPointerLocked;
@end
@implementation UIViewController
- (BOOL)prefersPointerLocked { return NO; }
@end
@interface GamePointerController : UIViewController
@end
@implementation GamePointerController
+ (void)initialize { initialized++; }
- (BOOL)prefersPointerLocked { return YES; }
@end
@interface NativePointerController : UIViewController
@end
@implementation NativePointerController
- (BOOL)prefersPointerLocked { return YES; }
@end
static IMP gamePointer, latePointer;
BOOL mulg_engine_is_game_caller(const void *caller) { return caller == (const void *)gamePointer || caller == (const void *)latePointer; }
static BOOL lateLocked(id self, SEL selector) { return YES; }
int main(void) {
    @autoreleasepool {
        SEL selector = sel_registerName("prefersPointerLocked");
        gamePointer = method_getImplementation(class_getInstanceMethod(objc_getClass("GamePointerController"), selector));
        assert(mulg_controls_install_pointer_cursor_hooks() == 1);
        assert(initialized == 0); // Inspecting classes must not run game initialization.
        assert([[GamePointerController new] prefersPointerLocked]);
        mulg_controls_set_pointer_cursor_override(YES);
        assert(![[GamePointerController new] prefersPointerLocked]);
        mulg_controls_set_pointer_cursor_override(NO);
        assert([[GamePointerController new] prefersPointerLocked]);
        mulg_controls_set_pointer_cursor_override(YES);
        assert([[NativePointerController new] prefersPointerLocked]);
        assert(mulg_controls_install_pointer_cursor_hooks() == 0);
        latePointer = (IMP)lateLocked;
        Class late = objc_allocateClassPair(objc_getClass("UIViewController"), "LateGamePointerController", 0);
        assert(late && class_addMethod(late, selector, latePointer, method_getTypeEncoding(class_getInstanceMethod(objc_getClass("UIViewController"), selector))));
        objc_registerClassPair(late);
        assert(mulg_controls_install_pointer_cursor_hooks() == 1);
        assert(!((BOOL (*)(id, SEL))class_getMethodImplementation(late, selector))(nil, selector));
        mulg_controls_set_pointer_cursor_override(NO);
        assert(((BOOL (*)(id, SEL))class_getMethodImplementation(late, selector))(nil, selector));
        assert([[GamePointerController new] prefersPointerLocked]);
        assert([[NativePointerController new] prefersPointerLocked]);
        puts("Native cursor hooks: game classes, late images, native passthrough and startup safety passed.");
    }
}
