#import <Foundation/Foundation.h>
#include <assert.h>
#include "MulgMobilePresetSceneResolution.m"
MulgNativeSceneState mulg_post_process_output_update(BOOL enabled) { return MulgNativeSceneUnsupported; }
BOOL mulg_post_process_output_owns_values(void) { return NO; }
NSDictionary *mulg_post_process_output_report(void) { return @{}; }

typedef struct { void *klass, *monitor; MulgForcedSize size; } Record;
typedef struct { void *klass, *monitor; uint8_t enabled; } Dynamic;
typedef struct { void *klass, *monitor, *native, *padding; float scale, maximum, capture, threshold; Dynamic *dynamic; } Settings;
typedef struct { void *klass, *monitor, *bounds; uintptr_t count; Record *items[5]; } Records;
typedef struct { void *klass, *monitor, *padding; Records *records; } Device;
static int recordClass, settingsClass, dynamicClass, initialized;
static Record first = {&recordClass, NULL, {1728, 1080}};
static Record second = {&recordClass, NULL, {1440, 900}};
static Records records = {NULL, NULL, NULL, 2, {&first, &second}};
static Device device = {NULL, NULL, NULL, &records};
static Dynamic dynamic = {&dynamicClass, NULL, 0};
static Settings settings = {&settingsClass, NULL, NULL, NULL, 0.6f, 2, 1, 0, &dynamic};
static MulgForcedSize output = {2880, 1800}, screen = {2880, 1800};
static float userScale = 1, dynamicScale = 1;
static int quality = 1;
static BOOL patched, rejectPublish, rejectRestore, failRetain;
static void *roots[16];
static void *ready = &initialized;
static void *dynamicReady[2] = {&initialized, &initialized};
static uint8_t engineOutputState[64];
static MulgForcedSize queuedOutput;
static unsigned int outputRequests;
static void *fakeScreenVtable[3] = {NULL, NULL, &initialized};
static void **fakeScreen = fakeScreenVtable;
static BOOL screenManagerReady;
static void *screenManager(void) { return screenManagerReady ? &fakeScreen : NULL; }

MulgForcedSize mulg_graphics_forced_target(void) { return output; }
BOOL mulg_graphics_forced_resolution_enabled(void) { return YES; }
static void *getDevice(void) { return &device; }
static void *getSettings(void) { return &settings; }
static void *getClass(int32_t index) { return index == 0x4755 ? &recordClass : index == 0x9581 ? &settingsClass : index == 0x9587 ? &dynamicClass : NULL; }
static int32_t getQuality(void) { return quality; }
static int32_t getPlatform(void) { return 3; }
static int32_t getWidth(void) { return screen.width; }
static int32_t getHeight(void) { return screen.height; }
static bool lowerResolution(void) { return false; }
static bool hasPatch(int32_t method) { (void)method; return patched; }
static float getUserScale(void) { return userScale; }
static float getDynamicScale(void) { return dynamicScale; }
static void publish(void) {
    Record *record = records.items[MAX(0, MIN(quality - 1, (int)records.count - 1))];
    if (rejectPublish && record->size.width == screen.width) return;
    if (rejectRestore && record->size.width != screen.width) return;
    settings.scale = fminf(1, fmaxf(0.1f, fminf((float)record->size.width / screen.width,
                                              (float)record->size.height / screen.height)));
}
static uint32_t retain(void *value) {
    if (failRetain) return 0;
    for (uint32_t i = 1; i < 16; i++) if (!roots[i]) { roots[i] = value; return i; }
    return 0;
}
static void *target(uint32_t handle) { assert(handle < 16); return roots[handle]; }
static void release(uint32_t handle) { assert(handle && handle < 16 && roots[handle]); roots[handle] = NULL; }
static void requestOutput(uint32_t width, uint32_t height) {
    queuedOutput = (MulgForcedSize){width, height}; outputRequests++;
}
static void renderingSize(int32_t *width, int32_t *height) {
    MulgForcedSize requested, natural;
    memcpy(&requested, engineOutputState + 0x24, sizeof requested);
    memcpy(&natural, engineOutputState + 8, sizeof natural);
    *width = requested.width > 0 ? requested.width : natural.width;
    *height = requested.height > 0 ? requested.height : natural.height;
}
static void outputFrame(void) {
    memcpy(engineOutputState + 0x24, &queuedOutput, sizeof queuedOutput);
    renderingSize(&screen.width, &screen.height);
}

int main(void) { @autoreleasepool {
    assert(mulg_mobile_preset_scene_probe() == MulgNativeSceneUnsupported);
    mobileResolved = mobileSupported = YES;
    mobile.deviceSettings = getDevice; mobile.graphicsSettings = getSettings;
    mobile.classFromDefinition = getClass; mobile.quality = getQuality; mobile.platform = getPlatform;
    mobile.width = getWidth; mobile.height = getHeight; mobile.lowerResolution = lowerResolution;
    mobile.hasPatch = hasPatch; mobile.userScale = getUserScale;
    mobile.metalFX = lowerResolution;
    mobile.dynamicWidth = mobile.dynamicHeight = getDynamicScale;
    mobile.publish = publish; mobile.retain = retain; mobile.target = target; mobile.release = release;
    mobile.metadata = mobile.classes = mobile.globals = (uintptr_t)&ready;
    mobile.rendererClass = mobile.screenClass = (uintptr_t)&ready;
    mobile.dynamicFunctions = (uintptr_t)&dynamicReady;
    mobile.outputState = (uintptr_t)&engineOutputState;
    mobile.requestOutput = requestOutput; mobile.renderingSize = renderingSize;
    mobile.screenManager = screenManager;
    // Both native sentinels must work, including the binary's -1/-1 initializer
    // before the natural fallback size is populated. No unsigned -1 API request.
    for (int initial = 0; initial < 4; initial++) {
    MulgForcedSize raw = initial & 1 ? (MulgForcedSize){-1, -1} : (MulgForcedSize){0, 0};
    memset(&mobileOutput, 0, sizeof mobileOutput);
    memset(engineOutputState, 0, sizeof engineOutputState);
    memcpy(engineOutputState + 0x24, &raw, sizeof raw);
    if (initial & 2) memcpy(engineOutputState + 8, &screen, sizeof screen);
    outputRequests = 0; screenManagerReady = NO;

    // The platform API queues an engine request; a display/trampoline write is insufficient.
    output = (MulgForcedSize){3840, 2160};
    assert(mulg_mobile_preset_output_update(YES) == MulgNativeSceneWaiting && outputRequests == 0);
    screenManagerReady = YES;
    assert(mulg_mobile_preset_output_update(YES) == MulgNativeSceneWaiting);
    assert(outputRequests == 1 && mobileOutput.owned && mobileOutput.original.width == raw.width);
    NSDictionary *report = mulg_mobile_preset_output_report();
    assert([report[@"stateReadable"] boolValue] && [report[@"observedRequestWidth"] intValue] == raw.width);
    assert([report[@"naturalWidth"] intValue] == (initial & 2 ? 2880 : 0));
    assert(mulg_mobile_preset_output_update(YES) == MulgNativeSceneWaiting && outputRequests == 1);
    // The engine supplies the natural surface during its ordinary resize.
    memcpy(engineOutputState + 8, &screen, sizeof screen);
    outputFrame();
    assert(mulg_mobile_preset_output_update(YES) == MulgNativeSceneApplied && mobileOutput.acknowledged);
    // Scale is deliberately stale until the scene adapter refreshes the game's own publisher.
    assert(mulg_mobile_preset_scene_update(YES) == MulgNativeSceneApplied && settings.scale == 1);
    assert(mulg_mobile_preset_scene_update(NO) == MulgNativeSceneRestored);
    output = (MulgForcedSize){5120, 2880};
    assert(mulg_mobile_preset_output_update(YES) == MulgNativeSceneWaiting && mobileOutput.original.width == raw.width);
    outputFrame();
    assert(mulg_mobile_preset_output_update(YES) == MulgNativeSceneApplied);
    assert(mulg_mobile_preset_scene_update(YES) == MulgNativeSceneApplied && first.size.width == 5120);
    assert(mulg_mobile_preset_scene_update(NO) == MulgNativeSceneRestored);
    assert(mulg_mobile_preset_output_update(NO) == MulgNativeSceneWaiting);
    assert(queuedOutput.width == 0 && queuedOutput.height == 0);
    outputFrame();
    assert(mulg_mobile_preset_output_update(NO) == MulgNativeSceneRestored && !mobileOutput.owned);
    assert(screen.width == 2880 && screen.height == 1800);
    assert(settings.scale == 0.6f); // Policy follows the restored surface without a UI event.
    }

    // Malformed requests remain distinct from the recognized native sentinels.
    const MulgForcedSize invalid[] = {{-2, -2}, {-1, 0}, {3840, 0}, {20000, 20000}};
    for (unsigned int i = 0; i < sizeof invalid / sizeof *invalid; i++) {
        memset(&mobileOutput, 0, sizeof mobileOutput);
        memcpy(engineOutputState + 0x24, &invalid[i], sizeof invalid[i]);
        unsigned int before = outputRequests;
        assert(mulg_mobile_preset_output_update(YES) == MulgNativeSceneUnsupported && outputRequests == before);
        assert(mobileOutput.observed.width == invalid[i].width);
    }
    MulgForcedSize raw = {0, 0};
    memcpy(engineOutputState + 0x24, &raw, sizeof raw);
    // Reset to the original native size after acknowledgement is a game override,
    // not an unacknowledged first request. Retries must remain bounded.
    output = (MulgForcedSize){3840, 2160};
    for (int attempt = 0; attempt < 3; attempt++) {
        assert(mulg_mobile_preset_output_update(YES) == MulgNativeSceneWaiting);
        outputFrame();
        assert(mulg_mobile_preset_output_update(YES) == MulgNativeSceneApplied);
        memcpy(engineOutputState + 0x24, &raw, sizeof raw);
    }
    unsigned int before = outputRequests;
    assert(mulg_mobile_preset_output_update(YES) == MulgNativeSceneOverridden && outputRequests == before);
    assert(mulg_mobile_preset_output_update(NO) == MulgNativeSceneRestored);
    assert(!mobileOutput.yielded && mobileOutput.conflicts == 0);
    assert(mulg_mobile_preset_output_update(YES) == MulgNativeSceneWaiting && outputRequests == before + 1);
    outputFrame();
    assert(mulg_mobile_preset_output_update(YES) == MulgNativeSceneApplied);
    assert(mulg_mobile_preset_output_update(NO) == MulgNativeSceneWaiting);
    outputFrame();
    assert(mulg_mobile_preset_output_update(NO) == MulgNativeSceneRestored);
    before = outputRequests;
    uintptr_t stateAddress = mobile.outputState;
    mobile.outputState = 1;
    assert(mulg_mobile_preset_output_update(YES) == MulgNativeSceneWaiting);
    assert(![mulg_mobile_preset_output_report()[@"stateReadable"] boolValue] && outputRequests == before);
    mobile.outputState = stateAddress;
    memset(&mobileOutput, 0, sizeof mobileOutput);
    screen = (MulgForcedSize){2880, 1800};
    output = screen; publish();
    assert(mulg_mobile_preset_scene_probe() == MulgNativeSceneReady);
    assert(first.size.width == 1728 && settings.scale == 0.6f); // Probe does not change the game.
    assert(mulg_mobile_preset_scene_update(YES) == MulgNativeSceneApplied);
    assert(first.size.width == 2880 && first.size.height == 1800 && settings.scale == 1);
    assert(![mulg_mobile_preset_scene_report()[@"nativeSceneVerified"] boolValue]);
    assert(mulg_mobile_preset_scene_update(NO) == MulgNativeSceneRestored);
    assert(first.size.width == 1728 && first.size.height == 1080 && settings.scale == 0.6f);

    // A rejected rollback must retain ownership until the engine accepts restoration.
    assert(mulg_mobile_preset_scene_update(YES) == MulgNativeSceneApplied);
    rejectRestore = YES;
    assert(mulg_mobile_preset_scene_update(NO) == MulgNativeSceneFailed && mobileOwned.record);
    rejectRestore = NO;
    assert(mulg_mobile_preset_scene_update(NO) == MulgNativeSceneRestored && !mobileOwned.record);

    // Changing quality restores the outgoing preset before publishing the incoming one.
    assert(mulg_mobile_preset_scene_update(YES) == MulgNativeSceneApplied);
    quality = 2;
    assert(mulg_mobile_preset_scene_update(YES) == MulgNativeSceneApplied);
    assert(first.size.width == 1728 && second.size.width == 2880 && settings.scale == 1);
    assert(mulg_mobile_preset_scene_update(NO) == MulgNativeSceneRestored);
    assert(second.size.width == 1440 && settings.scale == 0.5f);
    quality = 1; publish();

    // Never fight another scale request, an unknown layout, or a patched publisher.
    dynamicScale = 0.8f;
    assert(mulg_mobile_preset_scene_update(YES) == MulgNativeSceneUnsupported);
    dynamicScale = 1; dynamic.enabled = 1;
    assert(mulg_mobile_preset_scene_update(YES) == MulgNativeSceneUnsupported);
    dynamic.enabled = 0; userScale = 2;
    assert(mulg_mobile_preset_scene_update(YES) == MulgNativeSceneUnsupported);
    userScale = 1; patched = YES;
    assert(mulg_mobile_preset_scene_update(YES) == MulgNativeSceneUnsupported);
    patched = NO; first.klass = &settingsClass;
    assert(mulg_mobile_preset_scene_update(YES) == MulgNativeSceneUnsupported);
    first.klass = &recordClass; output.width = 2816;
    assert(mulg_mobile_preset_scene_update(YES) == MulgNativeSceneWaiting);
    output.width = 2880;
    settings.scale = 0.75f;
    assert(mulg_mobile_preset_scene_update(YES) == MulgNativeSceneUnsupported);
    publish();

    // A failed publication and a failed root allocation leave the preset unchanged.
    rejectPublish = YES;
    assert(mulg_mobile_preset_scene_update(YES) == MulgNativeSceneFailed);
    assert(first.size.width == 1728 && settings.scale == 0.6f && !mobileOwned.record);
    assert(mulg_mobile_preset_scene_update(NO) == MulgNativeSceneRestored);
    rejectPublish = NO; failRetain = YES;
    assert(mulg_mobile_preset_scene_update(YES) == MulgNativeSceneFailed && first.size.width == 1728);
    failRetain = NO;

    // Repeated game overrides relinquish the request instead of continually writing.
    assert(mulg_mobile_preset_scene_update(YES) == MulgNativeSceneApplied);
    for (int i = 0; i < 3; i++) {
        settings.scale = 0.6f;
        MulgNativeSceneState state = mulg_mobile_preset_scene_update(YES);
        assert(state == (i < 2 ? MulgNativeSceneApplied : MulgNativeSceneOverridden));
    }
    assert(!mobileOwned.record && first.size.width == 1728);
    assert(mulg_mobile_preset_scene_update(NO) == MulgNativeSceneRestored);

    // Output selection is not limited to the original 2880x1800 implementation.
    // Engine-owned allocation may align an odd viewport; that is not grounds to refuse it.
    for (int i = 0; i < 3; i++) {
        MulgForcedSize selected[] = {{3840, 2160}, {5120, 2880}, {4151, 2160}};
        output = screen = selected[i];
        publish();
        assert(mulg_mobile_preset_scene_update(YES) == MulgNativeSceneApplied);
        assert(mobile_equal(first.size, selected[i]) && settings.scale == 1);
        assert(mulg_mobile_preset_scene_update(NO) == MulgNativeSceneRestored);
        assert(first.size.width == 1728 && first.size.height == 1080);
    }
    output = screen = (MulgForcedSize){2880, 1800}; publish();

    // Partial external edits survive rollback, while still-owned dimensions restore.
    publish();
    assert(mulg_mobile_preset_scene_update(YES) == MulgNativeSceneApplied);
    first.size.width = 1920;
    assert(mulg_mobile_preset_scene_update(NO) == MulgNativeSceneRestored);
    assert(first.size.width == 1920 && first.size.height == 1080);
    for (int i = 1; i < 16; i++) assert(!roots[i]);
} }
