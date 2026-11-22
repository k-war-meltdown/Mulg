#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import <MulgEngineHooks.h>
#import <MulgDisplayHooks.h>
#import <objc/runtime.h>
#include <TargetConditionals.h>
#include <assert.h>
@interface FixtureLink:NSObject
@property CAFrameRateRange preferredFrameRateRange;
@property NSInteger preferredFramesPerSecond;
+ (id)displayLinkWithTarget:(id)target selector:(SEL)selector;
@end
@implementation FixtureLink
+ (id)displayLinkWithTarget:(id)target selector:(SEL)selector{return [self new];}
@end
BOOL mulg_engine_display_link_callback(BOOL frames,void (^callback)(void)){callback();return frames;}
MulgSwizzleResult mulg_swizzle_checked_owned(const char *owner,Class cls,SEL sel,IMP replacement,IMP *previous,const char *result,NSArray *args){return MulgSwizzleResultMethodMissing;}
MulgDisplayConfig mulg_display_current_config(void){return (MulgDisplayConfig){0};}
CAFrameRateRange mulg_display_apply_rules(CAFrameRateRange range,MulgDisplayConfig config){return range;}
#undef TARGET_OS_IPHONE
#define TARGET_OS_IPHONE 1
#define CADisplayLink FixtureLink
// __FRAME_RATE_INCLUDE__
static dispatch_semaphore_t entered,released;
static BOOL pauseNext;
static void native_range(FixtureLink *link,SEL selector,CAFrameRateRange range){
 if (!NSThread.isMainThread && pauseNext){pauseNext=NO;dispatch_semaphore_signal(entered);dispatch_semaphore_wait(released,DISPATCH_TIME_FOREVER);}
 link.preferredFrameRateRange=range;
}
static void native_mtk(FixtureLink *view,SEL selector,NSInteger fps){
 if (!NSThread.isMainThread && pauseNext){pauseNext=NO;dispatch_semaphore_signal(entered);dispatch_semaphore_wait(released,DISPATCH_TIME_FOREVER);}
 view.preferredFramesPerSecond=fps;
}
int main(int argc,const char **argv){@autoreleasepool {
 previous_set_range=(IMP)native_range;
 FixtureLink *link=[FixtureLink new];mulg_links=[NSHashTable weakObjectsHashTable];[mulg_links addObject:link];
 entered=dispatch_semaphore_create(0);released=dispatch_semaphore_create(0);pauseNext=YES;
 if(argc>1 && strcmp(argv[1],"mtk")==0){
  previous_mtk_set_fps=(IMP)native_mtk;mulg_mtk_views=[NSHashTable weakObjectsHashTable];
  dispatch_group_t group=dispatch_group_create();dispatch_group_async(group,dispatch_get_global_queue(0,0),^{mulg_mtk_set_fps(link,@selector(setPreferredFramesPerSecond:),60);});
  assert(dispatch_semaphore_wait(entered,dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC))==0);
  mulg_mtk_set_fps(link,@selector(setPreferredFramesPerSecond:),30);
  dispatch_semaphore_signal(released);dispatch_group_wait(group,DISPATCH_TIME_FOREVER);
  assert(link.preferredFramesPerSecond==30);
  puts("PASS: delayed MTKView setter settles to the newest game request");return 0;
 }
 dispatch_group_t group=dispatch_group_create();dispatch_group_async(group,dispatch_get_global_queue(0,0),^{mulg_set_fps(link,@selector(setPreferredFramesPerSecond:),60);});
 assert(dispatch_semaphore_wait(entered,dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC))==0);
 if (argc>1 && strcmp(argv[1],"throttle")==0) mulg_display_set_background_throttle(10);
 else mulg_set_fps(link,@selector(setPreferredFramesPerSecond:),30);
 dispatch_semaphore_signal(released);dispatch_group_wait(group,DISPATCH_TIME_FOREVER);
 assert(link.preferredFrameRateRange.preferred==(argc>1 && strcmp(argv[1],"throttle")==0?10:30));
 mulg_display_set_background_throttle(0);
 assert(link.preferredFrameRateRange.preferred==(argc>1 && strcmp(argv[1],"throttle")==0?60:30));
 puts("PASS: delayed native rate writes settle to current request and throttle");return 0;
}}
