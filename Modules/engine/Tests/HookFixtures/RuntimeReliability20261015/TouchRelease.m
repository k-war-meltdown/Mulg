#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <MulgControlsHooks.h>
#include <assert.h>
#include <math.h>
typedef NS_ENUM(NSInteger,UITouchPhase){UITouchPhaseBegan=0,UITouchPhaseMoved=1,UITouchPhaseStationary=2,UITouchPhaseEnded=3,UITouchPhaseCancelled=4};
@interface UIView:NSObject @end
@implementation UIView @end
@interface UIWindow:UIView @end
@implementation UIWindow @end
@interface UITouch:NSObject
- (void)_setIsFirstTouchForView:(BOOL)first;
@end
@implementation UITouch
- (void)_setIsFirstTouchForView:(BOOL)first{}
@end
// __CONTACTS__
static NSMutableDictionary<NSNumber*,MulgTouchContact*> *mulg_contacts;
static NSInteger mulg_next_token=1;
static BOOL mulg_source=YES;
static uint64_t mulg_rejected_count,mulg_coalesced_count;
static BOOL input_queued;
static void record_arrival(NSMutableSet *arrivals){}
static void mulg_signal(void){}
static UITouch *mulg_make_touch(CGPoint point,UIWindow *window,UIView *view,NSUInteger slot){return [UITouch new];}
// __INJECT__
// __BEGIN_ORDER__
static MulgTouchSample *next_sample(MulgTouchContact *contact){
 MulgTouchSample *sample=[MulgTouchSample new];sample.contact=contact;
 // __SNAPSHOT__
 return sample;
}
int main(void){@autoreleasepool {
 mulg_contacts=[NSMutableDictionary dictionary];
 NSInteger id=mulg_touch_inject(-1,CGPointMake(10,20),MulgTouchPhaseBegan,[UIWindow new],[UIView new]);
 MulgTouchContact *contact=mulg_contacts[@(id)];contact.beganDelivered=YES;
 mulg_touch_inject(id,CGPointMake(30,40),MulgTouchPhaseEnded,nil,nil);
 MulgTouchSample *sample=next_sample(contact);
 assert(sample.phase==UITouchPhaseEnded && CGPointEqualToPoint(sample.point,CGPointMake(30,40)));
 id=mulg_touch_inject(-1,CGPointMake(10,20),MulgTouchPhaseBegan,[UIWindow new],[UIView new]);
 contact=mulg_contacts[@(id)];contact.beganDelivered=YES;
 mulg_touch_inject(id,CGPointMake(20,30),MulgTouchPhaseMoved,nil,nil);
 mulg_touch_inject(id,CGPointMake(50,60),MulgTouchPhaseEnded,nil,nil);
 sample=next_sample(contact);assert(sample.phase==UITouchPhaseMoved && CGPointEqualToPoint(sample.point,CGPointMake(50,60)));
 contact.deliveredPoint=sample.point;sample=next_sample(contact);assert(sample.phase==UITouchPhaseEnded && CGPointEqualToPoint(sample.point,CGPointMake(50,60)));
 id=mulg_touch_inject(-1,CGPointMake(10,20),MulgTouchPhaseBegan,[UIWindow new],[UIView new]);
 contact=mulg_contacts[@(id)];contact.beganDelivered=YES;
 mulg_touch_inject(id,CGPointMake(50,60),MulgTouchPhaseMoved,nil,nil);
 mulg_touch_inject(id,CGPointMake(70,80),MulgTouchPhaseCancelled,nil,nil);
 sample=next_sample(contact);assert(sample.phase==UITouchPhaseCancelled && CGPointEqualToPoint(sample.point,CGPointMake(10,20)));
 // A camera replacement must wait until its outgoing gesture has actually ended.
 mulg_contacts=[NSMutableDictionary dictionary];
 UIWindow *window=[UIWindow new];UIView *view=[UIView new];
 NSInteger old=mulg_touch_inject(-1,CGPointMake(10,20),MulgTouchPhaseBegan,window,view);
 mulg_contacts[@(old)].beganDelivered=YES;
 mulg_touch_inject(old,CGPointMake(10,20),MulgTouchPhaseCancelled,nil,nil);
 NSInteger replacement=mulg_touch_inject(-1,CGPointMake(30,40),MulgTouchPhaseBegan,window,view);
 assert(mulg_begin_waits_for_end(mulg_contacts[@(replacement)]));
 [mulg_contacts removeObjectForKey:@(old)];
 assert(!mulg_begin_waits_for_end(mulg_contacts[@(replacement)]));
 puts("PASS: queued release uses its terminal point, while cancellation retains the delivered point");return 0;
}}
