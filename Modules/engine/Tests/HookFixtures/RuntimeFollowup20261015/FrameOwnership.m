#import <MulgEngineHooks.h>
#include <assert.h>
BOOL mulg_engine_is_game_caller(const void *caller) { return YES; }
// __PRODUCTION__
int main(void) { @autoreleasepool {
    mulg_engine_set_frame_start_delay(0);
    __block BOOL childDrew = NO;
    BOOL parentDrew = mulg_engine_display_link_callback(NO, ^{
        childDrew = mulg_engine_display_link_callback(NO, ^{ mulg_engine_frame_presented(); });
    });
    assert(childDrew && !parentDrew);
    BOOL directDrew = mulg_engine_display_link_callback(NO, ^{ mulg_engine_frame_presented(); });
    assert(directDrew && !mulg_engine_display_link_callback(NO, ^{}));
    puts("PASS: nested rendering belongs only to the callback that submits it");
} }
