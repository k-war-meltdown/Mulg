//
//  MulgDisplayInternal.h
//  display module: shared between the hook files, not exported.
//

#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import "MulgDisplayHooks.h"

/// Applies the uncap and cap rules to a frame-rate request.
CAFrameRateRange mulg_display_apply_rules(CAFrameRateRange range, MulgDisplayConfig config);

/// Installs the screen hooks; returns what was installed and adds attempts to `attempted`.
MulgDisplayHook mulg_display_install_screen_hooks(MulgDisplayConfig config, MulgDisplayHook *attempted);

/// Installs the display-link and MetalKit hooks.
MulgDisplayHook mulg_display_install_frame_rate_hooks(MulgDisplayHook *attempted);
