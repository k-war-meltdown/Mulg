#import <Foundation/Foundation.h>
#import <MulgEngineHooks.h>
#include <assert.h>
static int baseCalls, childCalls, hookCalls, classCalls;
@interface AuditBase : NSObject
- (void)render;
+ (void)render;
@end
@implementation AuditBase
- (void)render { baseCalls++; }
+ (void)render { classCalls++; }
@end
@interface AuditChild : AuditBase @end
@implementation AuditChild
- (void)render { childCalls++; [super render]; }
@end
static void replacement(id object, SEL selector) {
    hookCalls++;
    IMP original = mulg_swizzle_original(object_getClass(object), selector, (IMP)replacement);
    assert(original != NULL);
    ((void (*)(id, SEL))original)(object, selector);
}
@interface AuditInherited : AuditBase @end
@implementation AuditInherited @end
@interface ReverseBase : NSObject
- (void)render;
@end
@implementation ReverseBase
- (void)render { baseCalls++; }
@end
@interface ReverseChild : ReverseBase @end
@implementation ReverseChild
- (void)render { childCalls++; [super render]; }
@end
int main(void) { @autoreleasepool {
    assert(mulg_swizzle_instance_owned("graphics", AuditBase.class, @selector(render), (IMP)replacement, NULL) == MulgSwizzleResultReplaced);
    assert(mulg_swizzle_instance_owned("graphics", AuditChild.class, @selector(render), (IMP)replacement, NULL) == MulgSwizzleResultConflict);
    [[AuditChild new] render];
    assert(hookCalls == 1 && childCalls == 1 && baseCalls == 1);
    assert(mulg_swizzle_instance_owned("graphics", AuditInherited.class, @selector(render), (IMP)replacement, NULL) == MulgSwizzleResultReplaced);
    [[AuditInherited new] render]; assert(baseCalls == 2 && hookCalls == 2);
    assert(mulg_swizzle_instance_owned("graphics", AuditBase.class, @selector(render), (IMP)replacement, NULL) == MulgSwizzleResultReplaced);
    assert(mulg_swizzle_instance_owned("other", AuditBase.class, @selector(render), (IMP)replacement, NULL) == MulgSwizzleResultConflict);
    assert(mulg_swizzle_instance_owned("graphics", ReverseChild.class, @selector(render), (IMP)replacement, NULL) == MulgSwizzleResultReplaced);
    assert(mulg_swizzle_instance_owned("graphics", ReverseBase.class, @selector(render), (IMP)replacement, NULL) == MulgSwizzleResultConflict);
    [[ReverseChild new] render]; assert(baseCalls == 3 && childCalls == 2 && hookCalls == 3);
    assert(mulg_swizzle_class_owned("graphics", AuditBase.class, @selector(render), (IMP)replacement, NULL) == MulgSwizzleResultReplaced);
    [AuditBase render]; assert(classCalls == 1 && hookCalls == 4 && baseCalls == 3);
    puts("PASS: either hierarchy installation order preserves native super calls, inheritance and ownership");
} }
