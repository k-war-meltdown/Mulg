// Reversible upstream scene-resolution presets for stripped Unity custom renderers.
// Only the game's in-memory preset is changed. Its publisher and normal camera update
// retain ownership of scene, depth, lighting, post-processing and projection resources.
#import "MulgNativeSceneResolution.h"
#import "MulgGraphicsHooks.h"
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <mach/mach.h>
#include <mach/mach_vm.h>
#include <math.h>
#include <stdbool.h>
#include <stdint.h>
#include <string.h>

static struct {
    void *(*deviceSettings)(void);
    void *(*graphicsSettings)(void);
    void *(*classFromDefinition)(int32_t);
    int32_t (*quality)(void), (*platform)(void), (*width)(void), (*height)(void);
    bool (*lowerResolution)(void), (*hasPatch)(int32_t), (*metalFX)(void);
    float (*userScale)(void), (*dynamicWidth)(void), (*dynamicHeight)(void);
    void (*publish)(void);
    void (*requestOutput)(uint32_t, uint32_t);
    void (*renderingSize)(int32_t *, int32_t *);
    void *(*screenManager)(void);
    uint32_t (*retain)(void *);
    void *(*target)(uint32_t);
    void (*release)(uint32_t);
    uintptr_t metadata, classes, globals, dynamicFunctions, rendererClass, screenClass, outputState;
} mobile;
static struct {
    BOOL owned, restoring, yielded, sceneSynchronized, acknowledged, stateReadable;
    MulgForcedSize original, applied, observed, resolved, natural;
    unsigned int requests, restorations, conflicts, waiting;
    MulgNativeSceneState state;
} mobileOutput;
static NSString *mobileOutputReason = @"Not requested";
static struct {
    uint32_t record, settings;
    MulgForcedSize original, replacement;
    float originalScale;
} mobileOwned;
static BOOL mobileResolved, mobileSupported, mobileYielded, mobileFailed;
static unsigned int mobileApplications, mobileRestorations;
static unsigned int mobileConflicts;
static float mobileObservedScale;
static MulgForcedSize mobileObservedScreen;
static NSString *mobileReason = @"Not requested";

// Read volatile managed references without trusting an arbitrary pointer chain.
static BOOL mobile_read(const void *source, void *destination, size_t size) {
    if (!source) return NO;
    mach_vm_size_t copied = 0;
    return mach_vm_read_overwrite(mach_task_self(), (mach_vm_address_t)source, size,
        (mach_vm_address_t)destination, &copied) == KERN_SUCCESS && copied == size;
}
static void *mobile_reference(const void *object, size_t offset) {
    void *value = NULL;
    if (object) mobile_read((const uint8_t *)object + offset, &value, sizeof value);
    return value;
}
static BOOL mobile_equal(MulgForcedSize a, MulgForcedSize b) {
    return a.width == b.width && a.height == b.height;
}
static BOOL mobile_valid(MulgForcedSize size) {
    return size.width >= 32 && size.height >= 32 && size.width <= 16384 && size.height <= 16384;
}
// Unity initializes the explicit rendering request to -1/-1. Its getter uses
// the natural surface for either -1/-1 or 0/0; only positive values override it.
// Keep the raw snapshot for diagnostics, but use the API's 0/0 native request
// for restoration: passing unsigned -1 would request an enormous resolution.
static BOOL mobile_native_request(MulgForcedSize size) {
    return mobile_equal(size, (MulgForcedSize){-1, -1}) || mobile_equal(size, (MulgForcedSize){0, 0});
}
static BOOL mobile_same_request(MulgForcedSize a, MulgForcedSize b) {
    return mobile_equal(a, b) || (mobile_native_request(a) && mobile_native_request(b));
}
static BOOL mobile_close(float a, float b) {
    return isfinite(a) && isfinite(b) && fabsf(a - b) < 0.0001f;
}
static BOOL mobile_record(void *record, MulgForcedSize *size) {
    return record && mobile_reference(record, 0) == mobile.classFromDefinition(0x4755) &&
        mobile_read((uint8_t *)record + 0x10, size, sizeof *size) && mobile_valid(*size);
}
static BOOL mobile_scale(void *settings, float *value) {
    return settings && mobile_reference(settings, 0) == mobile.classFromDefinition(0x9581) &&
        mobile_read((uint8_t *)settings + 0x20, value, sizeof *value) &&
        isfinite(*value) && *value >= 0.1f && *value <= 2.0f;
}

static BOOL mobile_resolve(void) {
    if (mobileResolved) return mobileSupported;
    // A framework can load after the first probe, so do not cache a missing image.
    static const uint8_t uuid[16] = {
        0xa5, 0x86, 0xe7, 0xd6, 0xde, 0x70, 0x38, 0x24,
        0x90, 0x3e, 0x93, 0x6f, 0xfe, 0x2a, 0x79, 0x22
    }; // Installed Star Rail UnityFramework. Addresses are unslid image offsets.
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        const struct mach_header_64 *header = (const void *)_dyld_get_image_header(i);
        if (!header || header->magic != MH_MAGIC_64 || header->cputype != CPU_TYPE_ARM64 ||
            header->filetype != MH_DYLIB || header->sizeofcmds > 1024 * 1024) continue;
        BOOL match = NO;
        uintptr_t textStart = 0, textEnd = 0;
        const uint8_t *cursor = (const void *)(header + 1), *end = cursor + header->sizeofcmds;
        for (uint32_t n = 0; n < header->ncmds; n++) {
            if (cursor + sizeof(struct load_command) > end) break;
            const struct load_command *command = (const void *)cursor;
            if (command->cmdsize < sizeof *command || cursor + command->cmdsize > end) break;
            if (command->cmd == LC_UUID && command->cmdsize >= sizeof(struct uuid_command))
                match = memcmp(((const struct uuid_command *)command)->uuid, uuid, sizeof uuid) == 0;
            if (command->cmd == LC_SEGMENT_64 && command->cmdsize >= sizeof(struct segment_command_64)) {
                const struct segment_command_64 *segment = (const void *)command;
                if (!strncmp(segment->segname, "__TEXT", 16)) {
                    textStart = segment->vmaddr; textEnd = textStart + segment->vmsize;
                }
            }
            cursor += command->cmdsize;
        }
        if (!match) continue;
        mobileResolved = YES;
        intptr_t slide = _dyld_get_image_vmaddr_slide(i);
#define MOBILE_BIND(field, offset, first, second) do { \
    if ((offset) < textStart || (offset) + 8 > textEnd) return NO; \
    const uint32_t *entry = (const void *)(slide + (offset)); \
    if (entry[0] != (first) || entry[1] != (second)) return NO; \
    mobile.field = (void *)entry; \
} while (0)
        MOBILE_BIND(deviceSettings, 0x21311cc, 0x900a2928, 0x91260108);
        MOBILE_BIND(graphicsSettings, 0xd619624, 0xa9be4ff4, 0xa9017bfd);
        MOBILE_BIND(classFromDefinition, 0xf307c00, 0xa9ba6ffc, 0xa90167fa);
        MOBILE_BIND(quality, 0x21306e4, 0xa9bf7bfd, 0x910003fd);
        MOBILE_BIND(platform, 0x2130cfc, 0xa9bf7bfd, 0x910003fd);
        MOBILE_BIND(width, 0x22da030, 0xa9be4ff4, 0xa9017bfd);
        MOBILE_BIND(height, 0x22da0f4, 0xa9be4ff4, 0xa9017bfd);
        MOBILE_BIND(lowerResolution, 0x21351fc, 0xd10103ff, 0xa90157f6);
        MOBILE_BIND(hasPatch, 0x7656d4c, 0xd00779c8, 0x910fa108);
        MOBILE_BIND(userScale, 0x2130624, 0xa9bf7bfd, 0x910003fd);
        MOBILE_BIND(metalFX, 0x2130a44, 0xa9bf7bfd, 0x910003fd);
        MOBILE_BIND(dynamicWidth, 0xf13979c, 0xd003a888, 0x913c6108);
        MOBILE_BIND(dynamicHeight, 0xf1397ac, 0xd003a888, 0x913c6108);
        MOBILE_BIND(publish, 0x2134ff0, 0x6dbb23e9, 0xa9015ff8);
        MOBILE_BIND(requestOutput, 0x10ba2864, 0xd100c3ff, 0xa9014ff4);
        MOBILE_BIND(renderingSize, 0x10ba28cc, 0x9002b268, 0x9108c108);
        MOBILE_BIND(screenManager, 0x1037b568, 0x90030a88, 0xf9401100);
        MOBILE_BIND(retain, 0xcf53a7c, 0x52800001, 0x52800042);
        MOBILE_BIND(target, 0xf2db184, 0x17ffb93d, 0x17ffb99d);
        MOBILE_BIND(release, 0xf2db110, 0x17ffb988, 0xa9be4ff4);
#undef MOBILE_BIND
        mobile.metadata = slide + 0x162b5490;
        mobile.classes = slide + 0x162b54a8;
        mobile.globals = slide + 0x16655980;
        mobile.dynamicFunctions = slide + 0x16650a60;
        mobile.rendererClass = slide + 0x1666f928;
        mobile.screenClass = slide + 0x1666f798;
        mobile.outputState = slide + 0x161ee230;
        return mobileSupported = YES;
    }
    return NO;
}

typedef struct { void *record, *settings; MulgForcedSize size, screen; float scale; } MobileCandidate;

static BOOL mobile_metadata_ready(void) {
    return mobile_reference((void *)mobile.metadata, 0) && mobile_reference((void *)mobile.classes, 0) &&
        mobile_reference((void *)mobile.globals, 0) && mobile_reference((void *)mobile.rendererClass, 0) &&
        mobile_reference((void *)mobile.screenClass, 0);
}

BOOL mulg_mobile_preset_output_owns_values(void) {
    return mobileOutput.owned || mulg_post_process_output_owns_values();
}

static MulgNativeSceneState mobile_output_result(MulgNativeSceneState state, NSString *reason) {
    mobileOutput.state = state; mobileOutputReason = reason; return state;
}

MulgNativeSceneState mulg_mobile_preset_output_update(BOOL enabled) {
    if (!mobile_resolve()) return mulg_post_process_output_update(enabled);
    if (!enabled && !mobileOutput.owned) {
        mobileOutput.yielded = NO; mobileOutput.conflicts = 0;
        return mobile_output_result(MulgNativeSceneRestored, @"No native output request is owned");
    }
    if (!mobile_metadata_ready()) return mobile_output_result(MulgNativeSceneWaiting, @"Waiting for the initialized Unity player");
    void *manager = mobile.screenManager();
    if (!manager || !mobile_reference(mobile_reference(manager, 0), 0x10))
        return mobile_output_result(MulgNativeSceneWaiting, @"Waiting for Unity's screen manager");
    MulgForcedSize natural = {0, 0}, current = {0, 0};
    BOOL naturalRead = mobile_read((void *)(mobile.outputState + 8), &natural, sizeof natural);
    BOOL currentRead = mobile_read((void *)(mobile.outputState + 0x24), &current, sizeof current);
    mobileOutput.stateReadable = naturalRead && currentRead;
    mobileOutput.natural = natural;
    mobileOutput.observed = current;
    if (!mobileOutput.stateReadable)
        return mobile_output_result(MulgNativeSceneWaiting, @"The engine rendering-resolution state is not readable yet");
    mobile.renderingSize(&mobileOutput.resolved.width, &mobileOutput.resolved.height);
    if (!mobile_native_request(current) && !mobile_valid(current))
        return mobile_output_result(MulgNativeSceneUnsupported, @"The engine has an unrecognized explicit resolution request");
    // A zero natural size is the verified image's initial state. The initialized
    // ScreenManager accepts the first explicit request before that fallback is
    // populated; requiring it here prevents the very request that initializes it.
    if (!mobile_valid(natural) && !mobile_equal(natural, (MulgForcedSize){0, 0}) && !mobile_valid(current))
        return mobile_output_result(MulgNativeSceneUnsupported, @"The engine has an unrecognized natural resolution");
    if (!enabled) {
        mobileOutput.yielded = NO; mobileOutput.conflicts = 0;
        if (!mobileOutput.owned) return mobile_output_result(MulgNativeSceneRestored, @"No native output request is owned");
        if (!mobile_same_request(current, mobileOutput.applied) && !mobile_same_request(current, mobileOutput.original)) {
            mobileOutput.owned = NO; mobileOutput.restoring = NO;
            return mobile_output_result(MulgNativeSceneRestored, @"The game's newer output request was preserved");
        }
        if (!mobileOutput.restoring) {
            // This platform API explicitly supports 0x0 ("Requesting Native Resolution").
            // It queues the ordinary ScreenManager request; no display, texture or camera field is written.
            MulgForcedSize restore = mobile_native_request(mobileOutput.original)
                ? (MulgForcedSize){0, 0} : mobileOutput.original;
            mobile.requestOutput(restore.width, restore.height);
            mobileOutput.restoring = YES; mobileOutput.waiting = 0; mobileOutput.restorations++;
            return mobile_output_result(MulgNativeSceneWaiting, @"Unity was asked to restore its original rendering request");
        }
        if (mobile_same_request(current, mobileOutput.original)) {
            // Recompute the original scene policy for the restored surface, rather than
            // retaining the previous output's scale while waiting for a game UI event.
            float scale;
            if (!mulg_mobile_preset_scene_owns_values() && !mobile.hasPatch(0x9b471) &&
                mobile_scale(mobile.graphicsSettings(), &scale)) mobile.publish();
            mobileOutput.owned = NO; mobileOutput.restoring = NO;
            return mobile_output_result(MulgNativeSceneRestored, @"Unity restored its original rendering request");
        }
        return mobile_output_result(++mobileOutput.waiting > 30 ? MulgNativeSceneFailed : MulgNativeSceneWaiting,
                                    @"Waiting for Unity to acknowledge output restoration");
    }
    MulgForcedSize wanted = mulg_graphics_forced_target();
    if (!mobile_valid(wanted)) return mobile_output_result(MulgNativeSceneWaiting, @"Waiting for the selected output dimensions");
    if (mobileOutput.yielded && mobile_equal(wanted, mobileOutput.applied))
        return mobile_output_result(MulgNativeSceneOverridden, @"The game repeatedly replaced the native output request");
    if (!mobile_equal(wanted, mobileOutput.applied)) { mobileOutput.yielded = NO; mobileOutput.conflicts = 0; }
    if (mobileOutput.owned && !mobileOutput.restoring && mobile_equal(wanted, mobileOutput.applied)) {
        if (mobile_equal(current, wanted)) {
            mobileOutput.acknowledged = YES;
            return mobile_output_result(MulgNativeSceneApplied, @"Unity accepted the selected rendering dimensions");
        }
        if (!mobileOutput.acknowledged && mobile_same_request(current, mobileOutput.original))
            return mobile_output_result(++mobileOutput.waiting > 30 ? MulgNativeSceneFailed : MulgNativeSceneWaiting,
                                        @"Waiting for Unity to acknowledge the selected rendering dimensions");
        // A game-owned request changed. Bound retries instead of creating an endless resize loop.
        mobileOutput.owned = NO;
        if (++mobileOutput.conflicts >= 3) {
            mobileOutput.yielded = YES;
            return mobile_output_result(MulgNativeSceneOverridden, @"The game's newer output request was preserved");
        }
    }
    if (!mobileOutput.owned && mobile_equal(current, wanted)) {
        mobileOutput.applied = wanted;
        return mobile_output_result(MulgNativeSceneApplied, @"The game already requests the selected rendering dimensions");
    }
    if (!mobileOutput.owned) mobileOutput.original = current;
    // Changing 4K to 5K retains the original snapshot, including native -1/-1 or 0/0.
    mobileOutput.owned = YES; mobileOutput.restoring = NO;
    mobileOutput.sceneSynchronized = NO; mobileOutput.acknowledged = NO;
    mobileOutput.applied = wanted; mobileOutput.waiting = 0;
    mobile.requestOutput(wanted.width, wanted.height); mobileOutput.requests++;
    return mobile_output_result(MulgNativeSceneWaiting, @"Unity was asked to render at the selected dimensions");
}

NSDictionary *mulg_mobile_preset_output_report(void) {
    if (!mobileSupported) return mulg_post_process_output_report();
    return @{@"supported": @(mobileSupported), @"state": @(mobileOutput.state), @"reason": mobileOutputReason,
        @"ownsEngineValues": @(mobileOutput.owned), @"requests": @(mobileOutput.requests),
        @"restorations": @(mobileOutput.restorations),
        @"stateReadable": @(mobileOutput.stateReadable), @"acknowledged": @(mobileOutput.acknowledged),
        @"naturalWidth": @(mobileOutput.natural.width), @"naturalHeight": @(mobileOutput.natural.height),
        @"originalWidth": @(mobileOutput.original.width), @"originalHeight": @(mobileOutput.original.height),
        @"requestedWidth": @(mobileOutput.applied.width), @"requestedHeight": @(mobileOutput.applied.height),
        @"observedRequestWidth": @(mobileOutput.observed.width), @"observedRequestHeight": @(mobileOutput.observed.height),
        @"resolvedWidth": @(mobileOutput.resolved.width), @"resolvedHeight": @(mobileOutput.resolved.height)};
}

static void *mobile_selected_record(int32_t platform) {
    void *device = mobile.deviceSettings();
    void *array = mobile_reference(device, 0x18);
    uint32_t count = 0;
    if (!array || !mobile_read((uint8_t *)array + 0x18, &count, sizeof count) || !count || count > 32) return NULL;
    int32_t index = MAX(0, MIN(mobile.quality() - 1, (int32_t)count - 1));
    if (platform == 3 && index == 4 && mobile.lowerResolution()) index = 3;
    return mobile_reference(array, 0x20 + (size_t)index * sizeof(void *));
}

static MulgNativeSceneState mobile_candidate(MobileCandidate *candidate) {
    memset(candidate, 0, sizeof *candidate);
    if (!mobile_resolve()) {
        mobileReason = @"No verified mobile scene-preset publisher for this engine build";
        return MulgNativeSceneUnsupported;
    }
    if (!mobile_metadata_ready() ||
        !mobile_reference((void *)mobile.dynamicFunctions, 0) ||
        !mobile_reference((void *)mobile.dynamicFunctions, 8)) {
        mobileReason = @"Waiting for engine metadata and graphics settings";
        return MulgNativeSceneWaiting;
    }
    // Patches can replace the publisher, quality selection, platform, dimensions or scale.
    static const int32_t methods[] = {0x9b471, 0x9b475, 0x9b492, 0x9b448, 0x9b490,
                                      0x88bcb, 0x88bcc, 0x88bca, 0x9b4a6};
    for (size_t i = 0; i < sizeof methods / sizeof *methods; i++) if (mobile.hasPatch(methods[i])) {
        mobileReason = @"The game has replaced part of the verified resolution calculation";
        return MulgNativeSceneUnsupported;
    }
    int32_t platform = mobile.platform();
    if (platform != 2 && platform != 3) {
        mobileReason = @"The active renderer does not use the mobile scene-preset publisher";
        return MulgNativeSceneUnsupported;
    }
    void *device = mobile.deviceSettings();
    candidate->settings = mobile.graphicsSettings();
    if (!device || !candidate->settings) {
        mobileReason = @"Waiting for the active custom renderer";
        return MulgNativeSceneWaiting;
    }
    candidate->record = mobile_selected_record(platform);
    if (!candidate->record) {
        mobileReason = @"The device scene-resolution presets are unavailable";
        return MulgNativeSceneWaiting;
    }
    candidate->screen = (MulgForcedSize){mobile.width(), mobile.height()};
    mobileObservedScreen = candidate->screen;
    if (!mobile_record(candidate->record, &candidate->size) ||
        !mobile_scale(candidate->settings, &candidate->scale)) {
        mobileReason = @"The scene-preset or renderer-settings type does not match the verified ABI";
        return MulgNativeSceneUnsupported;
    }
    mobileObservedScale = candidate->scale;
    MulgForcedSize requested = mulg_graphics_forced_target();
    if (!mulg_graphics_forced_resolution_enabled() || !mobile_valid(requested) ||
        !mobile_equal(requested, candidate->screen)) {
        mobileReason = @"Waiting for the selected output dimensions to reach the engine screen adapter";
        return MulgNativeSceneWaiting;
    }
    if (mobile.metalFX() || !mobile_close(mobile.userScale(), 1) || !mobile_close(mobile.dynamicWidth(), 1) ||
        !mobile_close(mobile.dynamicHeight(), 1)) {
        mobileReason = @"Another game-owned render-scale or dynamic-resolution request is active";
        return MulgNativeSceneUnsupported;
    }
    // The custom pipeline also has its own dynamic-resolution controller, independent
    // of Unity's ScalableBufferManager. Never disable that feature behind the user's back.
    void *dynamic = mobile_reference(candidate->settings, 0x30);
    uint8_t dynamicEnabled = 0;
    float maximumScale = 0;
    if (!dynamic || mobile_reference(dynamic, 0) != mobile.classFromDefinition(0x9587) ||
        !mobile_read((uint8_t *)dynamic + 0x10, &dynamicEnabled, sizeof dynamicEnabled) || dynamicEnabled ||
        !mobile_read((uint8_t *)candidate->settings + 0x24, &maximumScale, sizeof maximumScale) ||
        !isfinite(maximumScale) || maximumScale < 1) {
        mobileReason = @"The custom renderer has an active or unverified scene-resolution limit";
        return MulgNativeSceneUnsupported;
    }
    mobileReason = @"Verified mobile scene-preset publisher available";
    return MulgNativeSceneReady;
}

BOOL mulg_mobile_preset_scene_owns_values(void) { return mobileOwned.record != 0; }

static void mobile_release(void) {
    if (mobileOwned.record) mobile.release(mobileOwned.record);
    if (mobileOwned.settings) mobile.release(mobileOwned.settings);
    memset(&mobileOwned, 0, sizeof mobileOwned);
}

static BOOL mobile_restore(void) {
    if (!mobileOwned.record) return YES;
    if (!mobile_metadata_ready()) return NO;
    void *record = mobile.target(mobileOwned.record);
    MulgForcedSize current;
    if (!mobile_record(record, &current)) return NO;
    // Restore each still-owned scalar; do not overwrite a game change to the other side.
    if (current.width == mobileOwned.replacement.width)
        memcpy((uint8_t *)record + 0x10, &mobileOwned.original.width, sizeof current.width);
    if (current.height == mobileOwned.replacement.height)
        memcpy((uint8_t *)record + 0x14, &mobileOwned.original.height, sizeof current.height);
    mobile.publish();
    // In the unchanged scene, verify the game actually returns to the original scale.
    // A quality/output change instead uses that scene's current game-owned policy.
    if (mobile.graphicsSettings() == mobile.target(mobileOwned.settings) &&
        mobile.width() == mobileOwned.replacement.width && mobile.height() == mobileOwned.replacement.height &&
        mobile_selected_record(mobile.platform()) == record &&
        mobile_record(record, &current) && mobile_equal(current, mobileOwned.original)) {
        float restored = 0;
        if (!mobile_scale(mobile.target(mobileOwned.settings), &restored) ||
            !mobile_close(restored, mobileOwned.originalScale)) return NO;
    }
    mobileRestorations++;
    mobile_release();
    return YES;
}

MulgNativeSceneState mulg_mobile_preset_scene_probe(void) {
    MobileCandidate candidate;
    return mobile_candidate(&candidate);
}

MulgNativeSceneState mulg_mobile_preset_scene_update(BOOL enabled) {
    if (!enabled) {
        if (!mobile_restore()) { mobileReason = @"Scene-preset restoration is pending"; return MulgNativeSceneFailed; }
        mobileYielded = mobileFailed = NO; mobileConflicts = 0;
        mobileReason = @"The original scene preset was restored through the game publisher";
        return MulgNativeSceneRestored;
    }
    if (mobileYielded) return MulgNativeSceneOverridden;
    if (mobileFailed) return MulgNativeSceneFailed;
    MobileCandidate candidate;
    MulgNativeSceneState availability = mobile_candidate(&candidate);
    if (availability != MulgNativeSceneReady) {
        if (!mobile_restore()) return MulgNativeSceneFailed;
        return availability;
    }
    if (mobileOwned.record) {
        BOOL same = candidate.record == mobile.target(mobileOwned.record) &&
            candidate.settings == mobile.target(mobileOwned.settings) &&
            mobile_equal(candidate.screen, mobileOwned.replacement);
        if (same && mobile_equal(candidate.size, mobileOwned.replacement) && mobile_close(candidate.scale, 1)) {
            mobileReason = @"The game publisher accepted native scene scale; GPU scene-size verification is pending";
            return MulgNativeSceneApplied;
        }
        if (same && ++mobileConflicts >= 3) mobileYielded = YES;
        if (!mobile_restore()) return MulgNativeSceneFailed;
        if (mobileYielded) { mobileReason = @"The game repeatedly replaced the scene request; the original preset was restored"; return MulgNativeSceneOverridden; }
        availability = mobile_candidate(&candidate);
        if (availability != MulgNativeSceneReady) return availability;
    }
    // A native output resize changes the publisher's denominator. Refresh its original
    // preset once the managed screen actually reaches that size, before taking a snapshot.
    if (mobileOutput.owned && mobileOutput.state == MulgNativeSceneApplied && !mobileOutput.sceneSynchronized &&
        mobile_equal(candidate.screen, mobileOutput.applied)) {
        mobile.publish();
        if (mobile.graphicsSettings() != candidate.settings || !mobile_scale(candidate.settings, &candidate.scale)) {
            mobileReason = @"The renderer changed while synchronizing its resolution policy";
            return MulgNativeSceneWaiting;
        }
        mobileOutput.sceneSynchronized = YES;
    }
    // Refuse an unexplained baseline. This mirrors RefreshMobileRenderScale's fit and clamp.
    float expected = fminf((float)candidate.size.width / candidate.screen.width,
                          (float)candidate.size.height / candidate.screen.height);
    if (mobile.platform() == 3 && (float)candidate.screen.width / candidate.screen.height < 1.4f)
        expected = sqrtf(((float)candidate.size.width * candidate.size.height) /
                         ((float)candidate.screen.width * candidate.screen.height));
    expected = fminf(1, fmaxf(0.1f, expected));
    if (!mobile_close(expected, candidate.scale)) {
        mobileReason = @"The renderer scale does not match its scene preset; leaving it untouched";
        return MulgNativeSceneUnsupported;
    }
    mobileOwned.record = mobile.retain(candidate.record);
    mobileOwned.settings = mobile.retain(candidate.settings);
    if (!mobileOwned.record || !mobileOwned.settings) {
        mobile_release(); mobileReason = @"Could not retain the scene-preset owners"; return MulgNativeSceneFailed;
    }
    mobileOwned.original = candidate.size; mobileOwned.replacement = candidate.screen;
    mobileOwned.originalScale = candidate.scale;
    void *record = mobile.target(mobileOwned.record);
    MulgForcedSize retainedSize;
    if (record != candidate.record || mobile.target(mobileOwned.settings) != candidate.settings ||
        !mobile_record(record, &retainedSize) || !mobile_equal(retainedSize, candidate.size)) {
        mobile_release(); mobileReason = @"The retained scene preset changed before publication";
        return MulgNativeSceneFailed;
    }
    memcpy((uint8_t *)record + 0x10, &candidate.screen, sizeof candidate.screen);
    mobile.publish();
    float published = 0;
    BOOL accepted = mobile.graphicsSettings() == mobile.target(mobileOwned.settings) &&
        mobile_scale(mobile.target(mobileOwned.settings), &published) && mobile_close(published, 1);
    mobileObservedScale = published;
    if (!accepted) {
        mobileFailed = YES;
        mobile_restore();
        mobileReason = @"The game did not accept native scene scale; restoration was requested";
        return MulgNativeSceneFailed;
    }
    mobileApplications++;
    mobileReason = @"The game publisher accepted native scene scale; GPU scene-size verification is pending";
    return MulgNativeSceneApplied;
}

NSDictionary *mulg_mobile_preset_scene_report(void) {
    return @{@"adapter": @"unityMobileScenePreset", @"reason": mobileReason,
        @"ownsEngineValues": @(mulg_mobile_preset_scene_owns_values()),
        @"nativeSceneVerified": @NO, @"publishedScale": @(mobileObservedScale),
        @"scaleBefore": @(mobileOwned.originalScale),
        @"engineScreenWidth": @(mobileObservedScreen.width), @"engineScreenHeight": @(mobileObservedScreen.height),
        @"presetWidthBefore": @(mobileOwned.original.width), @"presetHeightBefore": @(mobileOwned.original.height),
        @"presetWidthRequested": @(mobileOwned.replacement.width), @"presetHeightRequested": @(mobileOwned.replacement.height),
        @"requestsAccepted": @(mobileApplications), @"restorations": @(mobileRestorations),
        @"gameFilesModified": @NO, @"gpuResourcesRewritten": @NO};
}
