#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import <MulgEngineHooks.h>
#import <MulgDisplayHooks.h>
#include <assert.h>

BOOL mulg_engine_display_link_callback(BOOL drivesFrames, void (^callback)(void)) {
    callback();
    return drivesFrames;
}

#include "../../Sources/MulgDisplayHooks/MulgFrameRateHooks.m"

@interface FrameTarget : NSObject
- (void)tick:(CADisplayLink *)link;
@end
@implementation FrameTarget
- (void)tick:(CADisplayLink *)link {}
@end

int main(void) {
    @autoreleasepool {
        MulgDisplayHook attempted = 0;
        MulgDisplayHook installed = mulg_display_install_frame_rate_hooks(&attempted);
        assert(installed & MulgDisplayHookDisplayLinkRate);
        assert(installed & MulgDisplayHookDisplayLinkCreation);
        CADisplayLink *link = [CADisplayLink displayLinkWithTarget:[FrameTarget new] selector:@selector(tick:)];
        // Use the real QuartzCore setter: a fake property accepts ranges that macOS rejects.
        const NSInteger gameRates[] = {30, 60, 90, 120, 144};
        for (NSUInteger index = 0; index < sizeof(gameRates) / sizeof(gameRates[0]); index++) {
            NSInteger fps = gameRates[index];
            link.preferredFramesPerSecond = fps;
            assert(link.preferredFrameRateRange.minimum > 0);
            assert(link.preferredFrameRateRange.preferred == fps);
            mulg_display_set_background_throttle(10);
            assert(link.preferredFrameRateRange.preferred == 10);
            mulg_display_set_background_throttle(0);
            assert(link.preferredFrameRateRange.preferred == fps);
        }
        // Changing the game's FPS option while hidden must replace the old
        // request, rather than restore the previous setting when visible again.
        mulg_display_set_background_throttle(10);
        link.preferredFramesPerSecond = 30;
        assert(link.preferredFrameRateRange.preferred == 10);
        mulg_display_set_background_throttle(0);
        assert(link.preferredFrameRateRange.preferred == 30);
        link.preferredFramesPerSecond = 60;
        assert(link.preferredFrameRateRange.preferred == 60);
        MulgDisplayConfig unlock = { .uncapFrameRate = 1, .targetFramesPerSecond = 120 };
        mulg_display_configure(unlock);
        link.preferredFramesPerSecond = 30;
        assert(link.preferredFrameRateRange.preferred == 30);
        link.preferredFramesPerSecond = 60;
        assert(link.preferredFrameRateRange.preferred == 120);
        mulg_display_configure((MulgDisplayConfig){0});
        link.preferredFramesPerSecond = 0;
        assert(CAFrameRateRangeIsEqualToRange(link.preferredFrameRateRange, CAFrameRateRangeDefault));
        MulgDisplayConfig config = { .capAtTarget = 1, .targetFramesPerSecond = 30 };
        mulg_display_configure(config);
        mulg_display_set_background_throttle(0);
        assert(link.preferredFrameRateRange.minimum > 0 && link.preferredFrameRateRange.preferred == 30);
        link.preferredFrameRateRange = CAFrameRateRangeMake(24, 60, 30);
        config = (MulgDisplayConfig){0};
        mulg_display_configure(config);
        mulg_display_set_background_throttle(10);
        mulg_display_set_background_throttle(0);
        assert(CAFrameRateRangeIsEqualToRange(link.preferredFrameRateRange, CAFrameRateRangeMake(24, 60, 30)));
        [link invalidate];
        puts("PASS: real Catalyst display links accept legacy FPS, default caps and visibility transitions");
    }
}
