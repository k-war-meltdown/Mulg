#import "MulgControlsHooks.h"
#import <MulgEngineHooks.h>
#import <objc/runtime.h>
#include <stdlib.h>
#include <stdatomic.h>

// UIKit's native pointer lock can hide the cursor independently of AppKitBridge.
// Mapped gameplay owns capture; native gameplay keeps its original pointer policy
// except while the player explicitly releases the cursor.
// Inspect registered metadata only: sending messages to game classes here would
// initialize them before their own startup. Native framework implementations stay intact.

static _Atomic(BOOL) cursor_override;

void mulg_controls_set_pointer_cursor_override(BOOL enabled) {
    atomic_store_explicit(&cursor_override, enabled, memory_order_release);
}

int mulg_controls_install_pointer_cursor_hooks(void) {
    Class base = objc_getClass("UIViewController");
    if (!base) return 0;
    int count = objc_getClassList(NULL, 0);
    static int checkedClassCount;
    if (count <= 0 || count == checkedClassCount) return 0;
    Class __unsafe_unretained *classes = (Class __unsafe_unretained *)calloc((size_t)count, sizeof(Class));
    if (!classes) return 0;
    int found = objc_getClassList(classes, count);
    int installed = 0;
    SEL selector = sel_registerName("prefersPointerLocked");
    for (int index = 0; index < count && index < found; index++) {
        Class cls = classes[index];
        Class ancestor = cls;
        while (ancestor && ancestor != base) ancestor = class_getSuperclass(ancestor);
        if (!ancestor) continue;
        unsigned int methodsCount = 0;
        Method *methods = class_copyMethodList(cls, &methodsCount);
        for (unsigned int method = 0; method < methodsCount; method++) {
            if (method_getName(methods[method]) != selector) continue;
            IMP implementation = method_getImplementation(methods[method]);
            if (!mulg_engine_is_game_caller((const void *)implementation)) break;
            // Unique replacements keep superclass/subclass ownership unambiguous.
            IMP replacement = imp_implementationWithBlock(^BOOL(id controller) {
                if (atomic_load_explicit(&cursor_override, memory_order_acquire)) return NO;
                return ((BOOL (*)(id, SEL))implementation)(controller, selector);
            });
            if (mulg_swizzle_checked_owned("controls", cls, selector, replacement, NULL,
                    @encode(BOOL), @[]) == MulgSwizzleResultReplaced) installed++;
            else imp_removeBlock(replacement);
            break;
        }
        free(methods);
    }
    free(classes);
    if (found <= count) checkedClassCount = found;
    return installed;
}
