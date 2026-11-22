#import "MulgGraphicsHooks.h"
#import <MulgEngineHooks.h>
#import <TargetConditionals.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <os/log.h>
#include <math.h>
#include <stdatomic.h>
#include <string.h>

#if TARGET_OS_IPHONE
#import <UIKit/UIKit.h>
#import <MetalKit/MetalKit.h>

// Only the selected game's backing view is changed. Window bounds, transforms, and
// UIKit's screen scale remain native, so resolution does not enlarge the window.
static __weak UIView *renderView;
static CGFloat savedViewScale;
static CGFloat savedLayerScale;
static CGSize lastBounds;
static CGFloat lastScale;
static BOOL updating;
static NSString *adapter = @"none";

static BOOL unity_resize_available(UIView *view) {
    Class unity = NSClassFromString(@"UnityView");
    if (!unity || ![view isKindOfClass:unity]) return NO;
    NSMethodSignature *signature = [view methodSignatureForSelector:@selector(onUpdateSurfaceSize:)];
    return signature && signature.numberOfArguments == 3
        && strcmp(signature.methodReturnType, @encode(void)) == 0
        && strcmp([signature getArgumentTypeAtIndex:2], @encode(CGSize)) == 0;
}

static void notify_renderer(UIView *view) {
    if (unity_resize_available(view)) {
        // UnityView's normal resize entry point reports bounds * contentScaleFactor to
        // the engine AND sets the Metal drawable. layoutSubviews alone may skip scale-only
        // changes because the logical bounds did not change. Let Unity rebuild its own
        // attachments during its next render loop; never mutate engine ivars or GPU targets.
        adapter = @"UnityView.onUpdateSurfaceSize";
        ((void (*)(id, SEL, CGSize))objc_msgSend)(view, @selector(onUpdateSurfaceSize:), view.bounds.size);
    } else if ([view isKindOfClass:MTKView.class]) {
        adapter = @"MTKView.drawableSize";
        CGSize bounds = view.bounds.size;
        CGFloat scale = view.contentScaleFactor;
        // Use MTKView's setter, which also updates its depth/MSAA attachments and delegate.
        ((MTKView *)view).drawableSize = CGSizeMake(floor(bounds.width * scale), floor(bounds.height * scale));
    } else {
        adapter = @"UIView.layout";
    }
    [view setNeedsLayout];
}

void mulg_graphics_update_render_surface(CAMetalLayer *layer, int pixelHeight) {
    NSCAssert(NSThread.isMainThread, @"Render view updates require the main thread");
    if (updating) return;
    UIView *view = [layer.delegate isKindOfClass:UIView.class] ? (UIView *)layer.delegate : nil;
    // Zero is an explicit release. Otherwise wait for an attached render view rather
    // than undoing the current size while UIKit is changing window visibility.
    if (pixelHeight == 0) {
        view = nil;
    } else if (view.layer != layer || !view.window || view.window.hidden) {
        return;
    }
    updating = YES;
    @try {
        if (renderView && renderView != view) {
            UIView *old = renderView;
            old.contentScaleFactor = savedViewScale;
            old.layer.contentsScale = savedLayerScale;
            if (old.window && !old.window.hidden) notify_renderer(old);
            renderView = nil;
            lastBounds = CGSizeZero;
            lastScale = 0;
        }
        if (!view) { adapter = @"none"; return; }
        CGSize bounds = view.bounds.size;
        if (!isfinite(bounds.width) || !isfinite(bounds.height) || bounds.width <= 0 || bounds.height <= 0) return;
        // Unity truncates points * scale to integer pixels. nextafter avoids losing a row
        // to floating point roundoff (2159 instead of 2160).
        CGFloat scale = pixelHeight < 0 ? 1 : nextafter((double)pixelHeight / bounds.height, INFINITY);
        if (!isfinite(scale) || bounds.width * scale > 16384 || bounds.height * scale > 16384) return;
        if (renderView != view) {
            renderView = view;
            savedViewScale = view.contentScaleFactor;
            savedLayerScale = view.layer.contentsScale;
            lastBounds = CGSizeZero;
            lastScale = 0;
        }
        if (CGSizeEqualToSize(lastBounds, bounds) && fabs(lastScale - scale) < 1e-9
            && fabs(view.contentScaleFactor - scale) < 1e-9 && fabs(layer.contentsScale - scale) < 1e-9) return;
        lastBounds = bounds;
        lastScale = scale;
        view.contentScaleFactor = scale;
        layer.contentsScale = scale;
        notify_renderer(view);
    } @finally {
        updating = NO;
    }
}

// MARK: - Full resolution (graphics.fullResolution)

// Engines may pick a lower view scale than the screen's from their own device tables (Unreal's
// r.MobileContentScaleFactor gave 1.5 on a 2x Mac), which renders below full resolution with
// nothing in Mulg switched on. While the guard is on, a Metal-backed view never goes below the
// screen's native scale, and the selected resolution's scale replaces the engine's on that view.
static IMP previous_set_content_scale;
static _Atomic(int) full_resolution_guard = 1;
static _Atomic(int) raised_count;

static void mulg_view_set_content_scale(UIView *self, SEL _cmd, CGFloat scale) {
    CGFloat wanted = scale;
    if (!updating && isfinite(scale) && scale > 0 && [self.layer isKindOfClass:CAMetalLayer.class]) {
        if (self == renderView && lastScale > 0) {
            // Keep the latest external request for when fixed resolution is released.
            // Ignore echoes of our own scale and our updating/restoration calls.
            if (fabs(scale - lastScale) >= 1e-9) {
                savedViewScale = scale;
                savedLayerScale = scale;
            }
            wanted = lastScale;
        } else if (atomic_load_explicit(&full_resolution_guard, memory_order_relaxed)) {
            UIScreen *screen = self.window.screen ?: UIScreen.mainScreen;
            CGFloat native = screen.nativeScale;
            if (isfinite(native) && native > scale) wanted = native;
        }
        if (wanted != scale && atomic_fetch_add(&raised_count, 1) == 0) {
            os_log_t log = os_log_create("io.mulg", "graphics");
            os_log(log, "%{public}@ asked for view scale %.2f, using %.2f (full resolution)",
                   NSStringFromClass(self.class), scale, wanted);
        }
    }
    ((void (*)(id, SEL, CGFloat))previous_set_content_scale)(self, _cmd, wanted);
}

BOOL mulg_graphics_install_full_resolution_hook(void) {
    __unsafe_unretained Class view = objc_lookUpClass("UIView");
    return mulg_swizzle_checked_owned("graphics", view, @selector(setContentScaleFactor:),
        (IMP)mulg_view_set_content_scale, &previous_set_content_scale, @encode(void),
        @[@(@encode(CGFloat))]) == MulgSwizzleResultReplaced;
}

void mulg_graphics_set_full_resolution(BOOL enabled) {
    atomic_store(&full_resolution_guard, enabled ? 1 : 0);
}

int mulg_graphics_full_resolution_raises(void) {
    return atomic_load(&raised_count);
}

NSDictionary *mulg_graphics_render_surface_report(CAMetalLayer *layer) {
    UIView *view = [layer.delegate isKindOfClass:UIView.class] ? (UIView *)layer.delegate : nil;
    return @{@"renderViewClass": view ? NSStringFromClass(view.class) : @"none",
        @"viewContentScale": @(view.contentScaleFactor), @"layerContentsScale": @(layer.contentsScale),
        @"resolutionAdapter": adapter ?: @"none",
        @"requestedViewPixelWidth": @(floor(view.bounds.size.width * view.contentScaleFactor)),
        @"requestedViewPixelHeight": @(floor(view.bounds.size.height * view.contentScaleFactor))};
}
#else
BOOL mulg_graphics_install_full_resolution_hook(void) { return NO; }
void mulg_graphics_set_full_resolution(BOOL enabled) {}
int mulg_graphics_full_resolution_raises(void) { return 0; }
void mulg_graphics_update_render_surface(CAMetalLayer *layer, int pixelHeight) {}
NSDictionary *mulg_graphics_render_surface_report(CAMetalLayer *layer) { return @{}; }
#endif
