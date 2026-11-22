#import <Foundation/Foundation.h>
#import <CoreMotion/CoreMotion.h>
#import <MulgEngineHooks.h>
#include <TargetConditionals.h>
#include <assert.h>
@interface FixtureManager:NSObject
@property double gyroUpdateInterval,deviceMotionUpdateInterval;
@property(readonly) CMAttitudeReferenceFrame attitudeReferenceFrame;
+ (CMAttitudeReferenceFrame)availableAttitudeReferenceFrames;
@end
@implementation FixtureManager
+ (CMAttitudeReferenceFrame)availableAttitudeReferenceFrames{return 0;}
- (CMAttitudeReferenceFrame)attitudeReferenceFrame{return 0;}
@end
MulgSwizzleResult mulg_swizzle_instance_owned(const char *owner,Class cls,SEL sel,IMP replacement,IMP *previous){
 Method method=class_getInstanceMethod(cls,sel);if(!method)return MulgSwizzleResultMethodMissing;
 *previous=method_getImplementation(method);class_replaceMethod(cls,sel,replacement,method_getTypeEncoding(method));return MulgSwizzleResultReplaced;
}
MulgSwizzleResult mulg_swizzle_checked_owned(const char *owner,Class cls,SEL sel,IMP replacement,IMP *previous,const char *result,NSArray *args){
 Method method=class_getInstanceMethod(cls,sel);if(!method)return MulgSwizzleResultMethodMissing;
 *previous=method_getImplementation(method);class_replaceMethod(cls,sel,replacement,method_getTypeEncoding(method));return MulgSwizzleResultReplaced;
}
#undef TARGET_OS_IPHONE
#define TARGET_OS_IPHONE 1
#define CMMotionManager FixtureManager
// __MOTION_INCLUDE__
@interface UnlockHook:NSLock
@property(copy) void (^afterUnlock)(void);
@end
@implementation UnlockHook
- (void)unlock{[super unlock];void (^hook)(void)=self.afterUnlock;self.afterUnlock=nil;if(hook)hook();}
@end
int main(int argc,const char **argv){@autoreleasepool {
 mulg_motion_configure(YES);
 if(argc>1 && strcmp(argv[1],"capability")==0){
  mulg_motion_install_hooks();
  assert(FixtureManager.availableAttitudeReferenceFrames==CMAttitudeReferenceFrameXArbitraryZVertical);
  assert([FixtureManager new].attitudeReferenceFrame==CMAttitudeReferenceFrameXArbitraryZVertical);
  mulg_motion_configure(NO);assert(FixtureManager.availableAttitudeReferenceFrames==0 && [FixtureManager new].attitudeReferenceFrame==0);
  puts("PASS: emulation advertises its supported attitude frame and preserves native capability when disabled");return 0;
 }
 FixtureManager *manager=[FixtureManager new];
 start_timer(manager,&kGyroTimerKey,60,nil,^id{return nil;},^(id sample){});
 MulgMotionTimer *old=objc_getAssociatedObject(manager,&kGyroTimerKey);
 UnlockHook *lock=[UnlockHook new];old.lock=lock;
 lock.afterUnlock=^{start_timer(manager,&kGyroTimerKey,60,nil,^id{return nil;},^(id sample){});};
 [old cancel];
 assert(objc_getAssociatedObject(manager,&kGyroTimerKey)!=old);
 assert(objc_getAssociatedObject(manager,&kGyroActiveKey)!=nil && mulg_clock_users==1);
 stop_timer(manager,&kGyroTimerKey);assert(mulg_clock_users==0 && objc_getAssociatedObject(manager,&kGyroActiveKey)==nil);
 puts("PASS: obsolete timer cancellation cannot clear a replacement gyro's active state");return 0;
}}
