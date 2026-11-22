#import <Foundation/Foundation.h>
#include <assert.h>
#include "MulgPostProcessSceneResolution.m"

static int cameraObject, layerObject, targetObject;
static MulgForcedSize requested = {3840, 2160}, surface = {1920, 1080}, primary = {1920, 1080}, secondary = {960, 540};
static uint8_t nativeState[80];
static struct { uintptr_t *vtable; int32_t width, height, mode, rate; } manager;
static uintptr_t vtable[3];
static BOOL acquired;
static int32_t published[18];
static PresetRecord record = {1920, 1080, 960, 540, 1};
static void *roots[8];
static unsigned requests, applies;
BOOL mulg_graphics_has_game_drawable(void) { return acquired; }
MulgForcedSize mulg_graphics_forced_target(void) { return requested; }
BOOL mulg_graphics_forced_resolution_enabled(void) { return YES; }
CGSize mulg_graphics_main_drawable_size(void) { return CGSizeMake(surface.width, surface.height); }
uintptr_t mulg_graphics_set_scene_apply_allocator(uintptr_t value) { return 0; }
static void *getManager(void) { return &manager; }
static void request(void *value, int32_t w, int32_t h, int32_t mode, int32_t rate) {
    assert(value == &manager && mode == manager.mode && rate == manager.rate);
    MulgForcedSize size = {w, h};
    assert((w == 0 && h == 0) || valid_size(size));
    memcpy(nativeState + 0x3c, &size, sizeof size); requests++;
}
static void outputSize(int32_t *w, int32_t *h) {
    MulgForcedSize size; memcpy(&size, nativeState + 0x3c, sizeof size);
    *w = size.width > 0 ? size.width : 1920; *h = size.height > 0 ? size.height : 1080;
}
static void *camera(void *layer) { assert(layer == &layerObject); return &cameraObject; }
static void *gameplay(void) { return &cameraObject; }
static void *missingCamera(void) { return NULL; }
static void *target(void *value) { assert(value == &cameraObject); return &targetObject; }
static bool alive(void *value) { return value != NULL; }
static int32_t innerWidth(void *value) { return primary.width; }
static int32_t innerHeight(void *value) { return primary.height; }
static int32_t secondWidth(void *value) { return secondary.width; }
static int32_t secondHeight(void *value) { return secondary.height; }
static int32_t targetWidth(void *value) { return primary.width; }
static int32_t targetHeight(void *value) { return primary.height; }
static int32_t screenWidth(void) { return surface.width; }
static int32_t screenHeight(void) { return surface.height; }
static void setSecondWidth(void *value, int32_t w) { secondary.width = w; }
static void setSecondHeight(void *value, int32_t h) { secondary.height = h; }
static int32_t platform(void) { return 8; }
static bool flag(void) { return false; }
static bool alternate(void) { return true; }
static bool aspectOverride(void *value) { return false; }
static bool hotfix(int32_t value) { return false; }
static PresetRecord getRecord(void) { return record; }
static void setRecord(PresetRecord value) { record = value; }
static uint32_t retain(void *value, bool pinned) {
    for (uint32_t i = 1; i < 8; i++) if (!roots[i]) { roots[i] = value; return i; }
    return 0;
}
static void *handleTarget(uint32_t handle) { return roots[handle]; }
static void release(uint32_t handle) { assert(roots[handle]); roots[handle] = NULL; }
static void publish(void) {
    published[16] = record.primaryWidth; published[17] = record.primaryHeight;
    published[0] = record.secondaryWidth; published[4] = record.secondaryHeight;
}
static void apply(void *value) {
    assert(value == &cameraObject); applies++;
    primary = secondary = (MulgForcedSize){published[16], published[17]};
}
int main(void) { @autoreleasepool {
    inspected = supported = YES;
    renderer.screenWidth = screenWidth; renderer.screenHeight = screenHeight;
    renderer.gameplayCamera = missingCamera; renderer.isAlive = alive; renderer.isActive = alive;
    void *layer = NULL; MulgForcedSize desired;
    assert(find_main_layer(&layer, &desired) == MulgNativeSceneWaiting);
    assert([reason containsString:@"render a frame"]);
    acquired = YES; surface = requested;
    assert(find_main_layer(&layer, &desired) == MulgNativeSceneWaiting);
    assert([reason containsString:@"active gameplay camera"]);
    acquired = NO;
    renderer.outputManager = getManager; renderer.requestOutput = request; renderer.outputSize = outputSize;
    renderer.outputState = (uintptr_t)nativeState;
    vtable[2] = (uintptr_t)request; manager.vtable = vtable; manager.mode = 1; manager.rate = -1;
    MulgForcedSize native = {-1, -1}; memcpy(nativeState + 0x3c, &native, sizeof native);
    assert(mulg_post_process_output_update(YES) == MulgNativeSceneWaiting && requests == 0);
    acquired = YES;
    assert(mulg_post_process_output_update(YES) == MulgNativeSceneWaiting && requests == 1);
    assert(mulg_post_process_output_update(YES) == MulgNativeSceneApplied && requests == 1);
    requested = (MulgForcedSize){5120, 2880};
    assert(mulg_post_process_output_update(YES) == MulgNativeSceneWaiting);
    assert(playerOutput.original.width == -1);
    assert(mulg_post_process_output_update(YES) == MulgNativeSceneApplied);
    assert(mulg_post_process_output_update(NO) == MulgNativeSceneWaiting);
    assert(mulg_post_process_output_update(NO) == MulgNativeSceneRestored);
    assert(!playerOutput.owned && playerOutput.observed.width == 0);

    renderer.camera = camera; renderer.gameplayCamera = gameplay; renderer.cameraTarget = target;
    renderer.isAlive = alive; renderer.isActive = alive;
    renderer.innerWidth = innerWidth; renderer.innerHeight = innerHeight;
    renderer.secondWidth = secondWidth; renderer.secondHeight = secondHeight;
    renderer.targetWidth = targetWidth; renderer.targetHeight = targetHeight;
    renderer.screenWidth = screenWidth; renderer.screenHeight = screenHeight;
    renderer.setSecondWidth = setSecondWidth; renderer.setSecondHeight = setSecondHeight;
    renderer.runtimePlatform = platform; renderer.cameraAspectOverride = aspectOverride; renderer.hasGameHotfix = hotfix;
    renderer.usesAreaPublisher = flag; renderer.usesAlternatePreset = alternate;
    renderer.alternatePreset = getRecord; renderer.setAlternatePreset = setRecord;
    renderer.retainLayer = retain; renderer.handleTarget = handleTarget; renderer.freeHandle = release;
    renderer.publishOrdinaryPreset = publish; renderer.applyPublishedPreset = apply;
    publishedPreset = published;
    const MulgForcedSize sizes[] = {{2880, 1800}, {3840, 2160}, {5120, 2880}};
    for (unsigned i = 0; i < sizeof sizes / sizeof *sizes; i++) {
        requested = surface = sizes[i];
        primary = (MulgForcedSize){1920, 1080}; secondary = (MulgForcedSize){960, 540};
        record = (PresetRecord){1920, 1080, 960, 540, 1}; publish();
        selectedRecord = record; replacementRecord = record;
        replacementRecord.primaryWidth = requested.width; replacementRecord.primaryHeight = requested.height;
        selectedAlternatePreset = YES; candidateOrdinaryFitVerified = YES;
        observedPresetScale = @1; observedCameraAspect = (float)requested.width / requested.height;
        cameraUsesLayerSceneTarget = YES; observedTarget = observedPrimaryPreset = primary;
        observedSecondaryPreset = secondary;
        // The original engine preset must have the output aspect, as in gameplay.
        if (i == 0) { primary = observedTarget = observedPrimaryPreset = (MulgForcedSize){1728, 1080};
            record.primaryWidth = selectedRecord.primaryWidth = 1728; publish(); }
        assert(update_upstream_preset(&layerObject, requested) == MulgNativeScenePresetStaged);
        assert(same_size(primary, requested) && secondary.width == 960 && secondary.height == 540);
        assert(applies == i * 2 + 1);
        if (i == 1) {
            // A live 4K -> 5K output request must restore the outgoing scene
            // policy before the engine's normal surface resize is requested.
            playerOutput.applied = requested; playerOutput.owned = YES;
            memcpy(nativeState + 0x3c, &requested, sizeof requested);
            requested = (MulgForcedSize){5120, 2880};
            assert(mulg_post_process_output_update(YES) == MulgNativeSceneWaiting);
            assert(!mulg_post_process_scene_owns_values() && primary.width == 1920 && applies == 4);
            assert(mulg_post_process_output_update(YES) == MulgNativeSceneApplied);
            assert(mulg_post_process_output_update(NO) == MulgNativeSceneWaiting);
            assert(mulg_post_process_output_update(NO) == MulgNativeSceneRestored);
            requested = surface;
        }
        assert(restore_preset());
        assert(primary.width == (i == 0 ? 1728 : 1920) && primary.height == 1080);
        assert(secondary.width == 960 && secondary.height == 540 && applies == (i + 1) * 2);
    }
} return 0; }
