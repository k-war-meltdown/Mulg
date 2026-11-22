//
//  MulgDisplayConfig.m
//  display module: the configuration shared by all display hooks.
//

#import "MulgDisplayHooks.h"
#import "MulgDisplayInternal.h"

#include <os/lock.h>
#include <sys/resource.h>
#include <unistd.h>
#include <math.h>

static MulgDisplayConfig mulg_display_config = {
    .screenMode = MulgScreenModeOff,
    .width = 0, .height = 0, .scale = 1,
};
static os_unfair_lock mulg_display_config_lock = OS_UNFAIR_LOCK_INIT;

static __weak id window_screen;
static CGRect window_bounds;
static double window_scale;
static double render_height;

void mulg_display_set_render_height(double pixels) {
    os_unfair_lock_lock(&mulg_display_config_lock);
    render_height = isfinite(pixels) && pixels >= 1 && pixels <= 16384 ? pixels : 0;
    os_unfair_lock_unlock(&mulg_display_config_lock);
}

double mulg_display_render_height(void) {
    os_unfair_lock_lock(&mulg_display_config_lock);
    double pixels = render_height;
    os_unfair_lock_unlock(&mulg_display_config_lock);
    return pixels;
}

void mulg_display_set_window_geometry(id screen, CGRect bounds, double nativeScale) {
    BOOL valid = screen && isfinite(bounds.size.width) && isfinite(bounds.size.height)
        && bounds.size.width > 0 && bounds.size.height > 0 && isfinite(nativeScale) && nativeScale > 0;
    os_unfair_lock_lock(&mulg_display_config_lock);
    window_screen = valid ? screen : nil;
    window_bounds = valid ? CGRectMake(0, 0, bounds.size.width, bounds.size.height) : CGRectMake(0, 0, 0, 0);
    window_scale = valid ? nativeScale : 0;
    os_unfair_lock_unlock(&mulg_display_config_lock);
}

BOOL mulg_display_window_geometry(id screen, CGRect *bounds, double *nativeScale) {
    os_unfair_lock_lock(&mulg_display_config_lock);
    BOOL valid = screen && screen == window_screen && mulg_display_config.screenMode == MulgScreenModeResizable;
    if (valid) {
        *bounds = window_bounds;
        double configured = mulg_display_config.scale;
        *nativeScale = isfinite(configured) && configured > 0 ? configured : window_scale;
    }
    os_unfair_lock_unlock(&mulg_display_config_lock);
    return valid;
}

void mulg_display_configure(MulgDisplayConfig config) {
    os_unfair_lock_lock(&mulg_display_config_lock);
    mulg_display_config = config;
    os_unfair_lock_unlock(&mulg_display_config_lock);
}

MulgDisplayConfig mulg_display_current_config(void) {
    os_unfair_lock_lock(&mulg_display_config_lock);
    MulgDisplayConfig copy = mulg_display_config;
    os_unfair_lock_unlock(&mulg_display_config_lock);
    return copy;
}

CAFrameRateRange mulg_display_apply_rules(CAFrameRateRange range, MulgDisplayConfig config) {
    float target = (float)config.targetFramesPerSecond;
    if (target <= 0) {
        return range;
    }
    // Uncap (§4.2): a request topping out at 60 is the game assuming a 60 Hz device.
    if (config.uncapFrameRate && range.maximum >= 59 && range.maximum <= 61) {
        range.maximum = target;
        range.preferred = target;
    }
    // Cap below refresh (§6.1): "as fast as possible" (0) or faster than the target.
    if (config.capAtTarget) {
        if (range.maximum == 0 || range.maximum > target) {
            range.maximum = target;
        }
        if (range.preferred == 0 || range.preferred > target) {
            range.preferred = target;
        }
    }
    // Capping the all-zero default turns it into an explicit range. QuartzCore
    // rejects zero minimum once maximum/preferred specify a positive FPS.
    if (range.minimum == 0 && range.maximum > 0) {
        range.minimum = 1;
    }
    if (range.minimum > range.maximum && range.maximum > 0) {
        range.minimum = range.maximum;
    }
    if (range.preferred > 0 && range.preferred < range.minimum) {
        range.preferred = range.minimum;
    }
    return range;
}

void mulg_display_transform_range(MulgDisplayConfig config, float *minimum, float *maximum, float *preferred) {
    CAFrameRateRange range = CAFrameRateRangeMake(*minimum, *maximum, *preferred);
    range = mulg_display_apply_rules(range, config);
    *minimum = range.minimum;
    *maximum = range.maximum;
    *preferred = range.preferred;
}

// libproc.h is not in the iOS SDK, but the game always runs on macOS, where libSystem exports it.
extern int proc_pid_rusage(int pid, int flavor, rusage_info_t *buffer);

uint64_t mulg_display_bytes_written(void) {
    struct rusage_info_v4 info;
    if (proc_pid_rusage(getpid(), RUSAGE_INFO_V4, (rusage_info_t *)&info) != 0) {
        return 0;
    }
    return info.ri_diskio_byteswritten;
}
