// Engine-owned inner resolution for stripped Unity players with a verified PostProcessLayer ABI.
#import "MulgGraphicsHooks.h"
#import "MulgNativeSceneResolution.h"
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <mach/mach.h>
#include <mach/mach_vm.h>
#include <math.h>
#include <stdbool.h>
#include <stdint.h>
#include <string.h>

typedef void *(*ObjectGetter)(void *);
typedef int32_t (*DimensionGetter)(void *);
typedef void (*DimensionSetter)(void *, int32_t);
typedef struct {
    uint32_t primaryWidth, primaryHeight, secondaryWidth, secondaryHeight;
    uint32_t multiplier;
} PresetRecord;
_Static_assert(sizeof(PresetRecord) == 20, "Unexpected preset ABI");

static struct {
    void *(*gameplayCamera)(void);
    void *(*classFromDefinition)(int32_t);
    void *(*findComponent)(void *, void *);
    bool (*isAlive)(void *);
    bool (*isActive)(void *);
    ObjectGetter camera, cameraTarget;
    DimensionGetter targetWidth, targetHeight, innerWidth, innerHeight;
    DimensionGetter secondWidth, secondHeight, finalWidth, finalHeight;
    float (*cameraAspect)(void *);
    int32_t (*screenWidth)(void);
    int32_t (*screenHeight)(void);
    void *(*outputManager)(void);
    void (*requestOutput)(void *, int32_t, int32_t, int32_t, int32_t);
    void (*outputSize)(int32_t *, int32_t *);
    uintptr_t outputState;
    bool (*fsrEnabled)(void *);
    float (*fsrScale)(void *);
    bool (*graphicsFlag)(int32_t);
    float (*presetScale)(void);
    float (*alternatePresetScale)(void);
    uint32_t (*encodePresetDimension)(int32_t);
    int32_t (*decodePresetDimension)(uint32_t);
    void (*fitPresetDimensions)(int32_t, int32_t, int32_t *, int32_t *);
    bool (*selectedPreset)(PresetRecord *);
    bool (*usesAreaPublisher)(void);
    void (*publishOrdinaryPreset)(void);
    void (*publishAreaPreset)(void);
    void (*applyPublishedPreset)(void *);
    bool (*cameraAspectOverride)(void *);
    bool (*hasGameHotfix)(int32_t);
    int32_t (*runtimePlatform)(void);
    MulgForcedSize (*sizeFromArea)(int32_t, float);
    bool (*usesAlternatePreset)(void);
    PresetRecord (*alternatePreset)(void);
    void (*setAlternatePreset)(PresetRecord);
    int32_t (*presetSetting)(int32_t);
    void *(*arrayValue)(void *, int32_t);
    void (*setArrayValue)(void *, void *, int32_t);
    void *(*unbox)(void *);
    void *(*arrayElementClass)(void *);
    DimensionSetter setInnerWidth, setInnerHeight;
    DimensionSetter setSecondWidth, setSecondHeight;
    void (*updateInnerTarget)(void *);
    void (*invalidatePipeline)(void *);
    uint32_t (*retainLayer)(void *, bool);
    void *(*handleTarget)(uint32_t);
    void (*freeHandle)(uint32_t);
    int32_t postProcessType;
} renderer;

static struct {
    uint32_t handle;
    MulgForcedSize previous, applied;
} owned;
static struct {
    uint32_t arrayHandle;
    uint32_t appliedLayerHandle;
    int32_t index;
    PresetRecord original, replacement;
    MulgForcedSize primary, secondary;
    MulgForcedSize publishedByApplyPrimary, publishedByApplySecondary;
    unsigned int inconsistentSamples;
    BOOL accepted;
    BOOL areaPublisher;
    float policyScale;
    float cameraAspect;
    BOOL alternate;
    MulgForcedSize output;
} ownedPreset;
static void *selectedPresetArray;
static BOOL selectedAlternatePreset;
static PresetRecord selectedRecord, replacementRecord;
static MulgForcedSize observedTarget, observedScreen, observedFinal;
static BOOL cameraUsesLayerSceneTarget;
static float observedCameraAspect;
static MulgForcedSize observedPrimaryPreset, observedSecondaryPreset;
static MulgForcedSize candidatePreset;
static BOOL candidateEncodingVerified;
static BOOL candidateOrdinaryFitVerified;
static BOOL candidateAreaFitVerified;
static BOOL ordinaryPresetBaselineMatches;
static BOOL usesAreaPublisher;
static NSInteger ordinaryPresetIndex = NSNotFound;
static const int32_t *publishedPreset;
static const uintptr_t *presetSettingsStorage;
static MulgForcedSize observedRawPrimary, observedRawSecondary;
static NSNumber *observedPresetScale, *observedFSRScale;
static BOOL inspected, supported, startedRendering;
static MulgNativeSceneState terminalState;
static unsigned int overrides;
static NSString *reason = @"Not requested";
static NSString *directApplyBlocker;
static BOOL directApplyAttempted;
static NSString *directApplyFailure;
static NSString *directRollbackResult;
static MulgForcedSize directPublishedPrimary, directPublishedSecondary;
static MulgForcedSize directCameraPrimary, directCameraSecondary;

static BOOL same_size(MulgForcedSize left, MulgForcedSize right) {
    return left.width == right.width && left.height == right.height;
}

static BOOL valid_size(MulgForcedSize size) {
    return size.width >= 32 && size.height >= 32 && size.width <= 16384 && size.height <= 16384;
}

// The ordinary preset calculator truncates each scaled input before fitting it.
// Accept a candidate only if the same float calculation gives the exact pixel count.
static int32_t unscaled_preset_dimension(int32_t pixels, float scale) {
    double unscaled = ceil((double)pixels / (double)scale);
    if (!isfinite(unscaled) || unscaled < 1 || unscaled > 16384) return 0;
    int32_t candidate = (int32_t)unscaled;
    // The preceding integer may already round up during the float multiply.
    float preceding = (float)(candidate - 1) * scale;
    if (candidate > 1 && preceding >= pixels && preceding < pixels + 1) return candidate - 1;
    float scaled = (float)candidate * scale;
    return scaled >= pixels && scaled < pixels + 1 ? candidate : 0;
}

static BOOL same_aspect(MulgForcedSize scene, MulgForcedSize output) {
    int32_t difference = scene.width * output.height - scene.height * output.width;
    // The engine rounds both target dimensions down to even pixels.
    return difference <= 2 * output.width && difference >= -2 * output.height;
}

static BOOL resolve_renderer(void) {
    if (inspected) return supported;
    inspected = YES;
    const struct mach_header_64 *header = (const struct mach_header_64 *)_dyld_get_image_header(0);
    if (!header || header->magic != MH_MAGIC_64 || header->cputype != CPU_TYPE_ARM64 ||
        header->filetype != MH_EXECUTE ||
        header->sizeofcmds > 1024 * 1024) return NO;
    // The stripped player's exact ABI is selected by executable UUID and entry instructions.
    // These offsets identify methods, never managed object fields or GPU resources.
    static const uint8_t profileUUID[] = {
        0x27, 0x9e, 0xe8, 0x7d, 0x35, 0xa8, 0x3f, 0x1d, 0xb3, 0xd3, 0x71, 0x1a, 0x0f, 0x79, 0x78, 0x4b
    }; // Genshin 7.2.0 (1258)
    BOOL matchesUUID = NO;
    const struct section_64 *text = NULL;
    const struct segment_command_64 *data = NULL;
    uint64_t textBase = 0;
    const uint8_t *command = (const uint8_t *)(header + 1);
    const uint8_t *end = command + header->sizeofcmds;
    for (uint32_t index = 0; index < header->ncmds; index++) {
        if ((size_t)(end - command) < sizeof(struct load_command)) return NO;
        const struct load_command *load = (const struct load_command *)command;
        if (load->cmdsize < sizeof(*load) || load->cmdsize > (size_t)(end - command)) return NO;
        if (load->cmd == LC_UUID && load->cmdsize == sizeof(struct uuid_command)) {
            const struct uuid_command *uuid = (const struct uuid_command *)command;
            matchesUUID = memcmp(uuid->uuid, profileUUID, sizeof profileUUID) == 0;
        } else if (load->cmd == LC_SEGMENT_64 && load->cmdsize >= sizeof(struct segment_command_64)) {
            const struct segment_command_64 *segment = (const struct segment_command_64 *)command;
            if (strncmp(segment->segname, "__TEXT", sizeof segment->segname) == 0 && segment->fileoff == 0) {
                if (segment->nsects > (load->cmdsize - sizeof(*segment)) / sizeof(struct section_64)) return NO;
                const struct section_64 *section = (const struct section_64 *)(segment + 1);
                for (uint32_t i = 0; i < segment->nsects; i++) {
                    if (strncmp(section[i].sectname, "__text", sizeof section[i].sectname) == 0) text = &section[i];
                }
                textBase = segment->vmaddr;
            } else if (strncmp(segment->segname, "__DATA", sizeof segment->segname) == 0) {
                data = segment;
            }
        }
        command += load->cmdsize;
    }
    if (!matchesUUID || !text || textBase != UINT64_C(0x100000000) || text->addr < textBase ||
        text->size < 8 || (text->flags & S_ATTR_PURE_INSTRUCTIONS) == 0) return NO;

    uint64_t textOffset = text->addr - textBase;
#define BIND(field, offset, first, second) do { \
    if ((offset) < textOffset || (offset) - textOffset > text->size - 8) return NO; \
    const uint32_t *entry = (const uint32_t *)((const uint8_t *)header + (offset)); \
    if (entry[0] != (first) || entry[1] != (second)) return NO; \
    renderer.field = (__typeof__(renderer.field))(uintptr_t)entry; \
} while (0)
    // Both the game's graphics configuration and its scene-size query use this camera getter.
    BIND(gameplayCamera,        0x019351b4, 0xd100c3ff, 0xa9014ff4);
    BIND(classFromDefinition,    0x0ee5f67c, 0xa9ba6ffc, 0xa90167fa);
    BIND(findComponent,          0x0eca9de4, 0x1446a550, 0xa9be4ff4);
    BIND(isAlive,                0x0eca2628, 0xb4000080, 0xf9400800);
    BIND(isActive,               0x0ec841d8, 0x14472d7d, 0x14009811);
    BIND(camera,                 0x002d3fec, 0xf9413000, 0xd65f03c0);
    BIND(cameraTarget,           0x0ec9c3d0, 0x1446d205, 0x1446d20f);
    BIND(cameraAspect,           0x0ec9c2d4, 0x1446d1bd, 0x1446d1c6);
    BIND(targetWidth,            0x0ec89db4, 0x144789b4, 0x144789cb);
    BIND(targetHeight,           0x0ec89db8, 0x144789cb, 0x144789f1);
    BIND(screenWidth,            0x0ecb0708, 0x14483cd5, 0x14483cdb);
    BIND(screenHeight,           0x0ecb070c, 0x14483cdb, 0x14483ce1);
    BIND(outputManager,          0x0f29c29c, 0xd0033f48, 0xf9441500);
    BIND(requestOutput,          0x0fe6f5b4, 0xa9be4ff4, 0xa9017bfd);
    BIND(outputSize,             0x0eff0480, 0xd003a808, 0x9128c108);
    renderer.outputState = (uintptr_t)header + 0x164f2a30;
    BIND(fsrEnabled,             0x002d3378, 0x39458000, 0xd65f03c0);
    BIND(fsrScale,               0x002d3540, 0xbd416800, 0xd65f03c0);
    BIND(graphicsFlag,           0x0448a554, 0xa9be4ff4, 0xa9017bfd);
    BIND(presetScale,            0x014c9ecc, 0xa9bf7bfd, 0x910003fd);
    BIND(alternatePresetScale,   0x0700c4e4, 0x6dbd23e9, 0xa9014ff4);
    BIND(encodePresetDimension,  0x052280d8, 0xd10083ff, 0xa9017bfd);
    BIND(decodePresetDimension,  0x0521569c, 0xd10083ff, 0xa9017bfd);
    BIND(fitPresetDimensions,    0x0700c6dc, 0xa9bc5ff8, 0xa90157f6);
    BIND(selectedPreset,         0x02075050, 0xa9bd57f6, 0xa9014ff4);
    BIND(usesAreaPublisher,      0x0700b18c, 0xa9be4ff4, 0xa9017bfd);
    BIND(publishOrdinaryPreset,  0x0700b470, 0xd10243ff, 0x6d0323e9);
    BIND(publishAreaPreset,      0x0700b2cc, 0xd10143ff, 0x6d0223e9);
    BIND(applyPublishedPreset,   0x07007fc0, 0xd10103ff, 0xa90157f6);
    BIND(cameraAspectOverride,   0x002d335c, 0x39454000, 0xd65f03c0);
    BIND(hasGameHotfix,          0x01e77f40, 0x9009f368, 0x91312908);
    BIND(runtimePlatform,        0x07d6db10, 0x15bc8285, 0x15bc8285);
    BIND(sizeFromArea,            0x04a745d4, 0xd10103ff, 0x6d0123e9);
    BIND(usesAlternatePreset,    0x013fd954, 0xa9bf7bfd, 0x910003fd);
    BIND(alternatePreset,        0x013ff83c, 0xb00a4ca9, 0x91124129);
    BIND(setAlternatePreset,     0x013ff980, 0xb9401008, 0x3dc00000);
    BIND(presetSetting,          0x0206ddbc, 0xd10103ff, 0xa90157f6);
    BIND(arrayValue,             0x0e86e4a8, 0x141692cd, 0x14169370);
    BIND(setArrayValue,          0x0e86e4ac, 0x14169370, 0x1416913c);
    BIND(unbox,                  0x0ee6d1b8, 0x91004000, 0xd65f03c0);
    BIND(arrayElementClass,      0x0ee4ec38, 0xa9be4ff4, 0xa9017bfd);
    BIND(innerWidth,            0x002d2eec, 0xb9409400, 0xd65f03c0);
    BIND(innerHeight,           0x002d2efc, 0xb9409800, 0xd65f03c0);
    BIND(setInnerWidth,         0x002d2ef4, 0xb9009401, 0xd65f03c0);
    BIND(setInnerHeight,        0x002d2f04, 0xb9009801, 0xd65f03c0);
    BIND(secondWidth,           0x002d2f0c, 0xb9409c00, 0xd65f03c0);
    BIND(setSecondWidth,        0x002d2f14, 0xb9009c01, 0xd65f03c0);
    BIND(secondHeight,          0x002d2f1c, 0xb940a000, 0xd65f03c0);
    BIND(setSecondHeight,       0x002d2f24, 0xb900a001, 0xd65f03c0);
    BIND(finalWidth,            0x002d3140, 0xa9be4ff4, 0xa9017bfd);
    BIND(finalHeight,           0x002d3184, 0xa9be4ff4, 0xa9017bfd);
    BIND(updateInnerTarget,     0x002d4d1c, 0xd10343ff, 0x6d0823e9);
    BIND(invalidatePipeline,    0x002d81c8, 0x394a4008, 0x37000068);
    BIND(retainLayer,           0x0ee0eb00, 0x14000afa, 0x14000aff);
    BIND(handleTarget,           0x0ee0eb08, 0x14000b02, 0xf9000022);
    BIND(freeHandle,             0x0ee0eb14, 0x14000b01, 0x140136ac);
#undef BIND
    // The primary-camera consumer reads four int32_t dimensions from these image
    // globals. Keep this optional and read-only, separate from the adapter's setters.
    const uint64_t firstPresetSlot = UINT64_C(0x115d9bc00);
    const uint64_t lastPresetSlot = UINT64_C(0x115d9bc44);
    const uint64_t settingsStorageSlot = UINT64_C(0x115d94488);
    if (data && (data->initprot & VM_PROT_READ) && firstPresetSlot >= data->vmaddr &&
        lastPresetSlot - data->vmaddr <= data->vmsize &&
        data->vmsize - (lastPresetSlot - data->vmaddr) >= sizeof(int32_t)) {
        publishedPreset = (const int32_t *)((uintptr_t)header + (firstPresetSlot - textBase));
    }
    if (data && (data->initprot & VM_PROT_READ) && settingsStorageSlot >= data->vmaddr &&
        data->vmsize >= sizeof(uintptr_t) &&
        settingsStorageSlot - data->vmaddr <= data->vmsize - sizeof(uintptr_t)) {
        presetSettingsStorage = (const uintptr_t *)((uintptr_t)header + (settingsStorageSlot - textBase));
    }
    renderer.postProcessType = 0x225c;
    supported = YES;
    return YES;
}

static BOOL read_selected_preset(PresetRecord *record) {
    if (!presetSettingsStorage) return NO;
    uintptr_t storage = __atomic_load_n(presetSettingsStorage, __ATOMIC_RELAXED);
    if (!storage) return NO;
    if (renderer.usesAlternatePreset()) {
        if (!renderer.selectedPreset(record)) return NO;
        PresetRecord current = renderer.alternatePreset();
        selectedAlternatePreset = memcmp(record, &current, sizeof current) == 0;
        return selectedAlternatePreset;
    }
    // The ordinary selector can throw if the key-2 dictionary is absent.
    // Use the game's selector only after its ordinary lookup is initialized.
    const uintptr_t *dictionary = (const uintptr_t *)(storage + 0x280c8);
    const uintptr_t *configuration = (const uintptr_t *)(storage + 0x28090);
    uintptr_t config = __atomic_load_n(configuration, __ATOMIC_RELAXED);
    if (!config || !__atomic_load_n(dictionary, __ATOMIC_RELAXED)) return NO;
    const uintptr_t *resolutionArray = (const uintptr_t *)(config + 0x40);
    uintptr_t array = __atomic_load_n(resolutionArray, __ATOMIC_RELAXED);
    if (!array || !renderer.selectedPreset(record)) return NO;
    if (renderer.usesAlternatePreset()) return NO;
    int64_t index = (int64_t)renderer.presetSetting(2) - 1;
    if (__atomic_load_n(presetSettingsStorage, __ATOMIC_RELAXED) != storage ||
        __atomic_load_n(configuration, __ATOMIC_RELAXED) != config ||
        __atomic_load_n(resolutionArray, __ATOMIC_RELAXED) != array) return YES;
    // Match the selector's key-2 clamp, 20-byte stride and 0x20 array header.
    // Require agreement with the complete engine-returned record before using the index.
    uintptr_t length = *(const uintptr_t *)(array + 0x18);
    if (length == 0 || length > INT32_MAX) return YES;
    if (index < 0) index = 0;
    if ((uint64_t)index >= length) index = (int64_t)length - 1;
    const void *entry = (const void *)(array + 0x20 + (uintptr_t)index * sizeof(*record));
    if (memcmp(record, entry, sizeof(*record)) == 0) {
        ordinaryPresetIndex = (NSInteger)index;
        selectedPresetArray = (void *)array;
    }
    return YES;
}

static MulgForcedSize fit_ordinary_preset_pair(MulgForcedSize raw, float scale) {
    MulgForcedSize fitted = {0};
    if (!valid_size(raw)) return fitted;
    float width = (float)raw.width * scale;
    float height = (float)raw.height * scale;
    if (!(width >= 1 && width <= 16384 && height >= 1 && height <= 16384)) return fitted;
    renderer.fitPresetDimensions((int32_t)width, (int32_t)height, &fitted.width, &fitted.height);
    if (!valid_size(fitted)) return (MulgForcedSize){0};
    return (MulgForcedSize){fitted.width & ~1, fitted.height & ~1};
}

static MulgForcedSize fit_area_preset_pair(MulgForcedSize raw, float scale) {
    if (!valid_size(raw) || !valid_size(observedScreen)) return (MulgForcedSize){0};
    float width = (float)raw.width * scale;
    float height = (float)raw.height * scale;
    if (!(width >= 1 && width <= 16384 && height >= 1 && height <= 16384)) return (MulgForcedSize){0};
    MulgForcedSize fitted = {(int32_t)width, (int32_t)height};
    int32_t platform = renderer.runtimePlatform();
    if (platform == 7 || platform == 11 || platform == 8 || platform == 35) {
        int32_t area = MIN(fitted.width * fitted.height, observedScreen.width * observedScreen.height);
        fitted = renderer.sizeFromArea(area, (float)observedScreen.width / (float)observedScreen.height);
    }
    fitted.width &= ~1;
    fitted.height &= ~1;
    if (!valid_size(fitted) || fitted.width > observedScreen.width || fitted.height > observedScreen.height)
        return (MulgForcedSize){0};
    return fitted;
}

static BOOL prepare_preset(PresetRecord original, MulgForcedSize raw, PresetRecord *candidate) {
    *candidate = original;
    candidate->primaryWidth = renderer.encodePresetDimension(raw.width);
    candidate->primaryHeight = renderer.encodePresetDimension(raw.height);
    return renderer.decodePresetDimension(candidate->primaryWidth) == raw.width &&
           renderer.decodePresetDimension(candidate->primaryHeight) == raw.height;
}

static const PresetRecord *preset_entry(void *array, int32_t index) {
    if (!array || index < 0) return NULL;
    const uint8_t *bytes = array;
    if ((uintptr_t)index >= *(const uintptr_t *)(bytes + 0x18)) return NULL;
    return (const PresetRecord *)(bytes + 0x20 + (uintptr_t)index * sizeof(PresetRecord));
}

static BOOL replace_preset(void *array, int32_t index, PresetRecord expected, PresetRecord replacement) {
    const PresetRecord *entry = preset_entry(array, index);
    if (!entry || memcmp(entry, &expected, sizeof expected) != 0) return NO;
    // GetValueImpl multiplies the index by the runtime array class's element stride.
    // Its non-value-type branch returns an existing reference rather than a fresh box.
    const uint8_t *arrayClass = *(const uint8_t *const *)array;
    if (!arrayClass || *(const uint16_t *)(arrayClass + 0xc4) != sizeof(PresetRecord) ||
        index > INT32_MAX / (int32_t)sizeof(PresetRecord)) return NO;
    const uint8_t *elementClass = renderer.arrayElementClass((void *)arrayClass);
    if (!elementClass || !(elementClass[0xd3] & 1)) return NO;
    void *boxed = renderer.arrayValue(array, index);
    if (!boxed || *(const void *const *)boxed != elementClass) return NO;
    void *payload = renderer.unbox(boxed);
    if (memcmp(payload, &expected, sizeof expected) != 0) return NO;
    memcpy(payload, &replacement, sizeof replacement);
    renderer.setArrayValue(array, boxed, index);
    entry = preset_entry(array, index);
    return entry && memcmp(entry, &replacement, sizeof replacement) == 0;
}

static BOOL original_primary_pair(PresetRecord current, PresetRecord *restored) {
    if (current.primaryWidth != ownedPreset.replacement.primaryWidth ||
        current.primaryHeight != ownedPreset.replacement.primaryHeight) return NO;
    *restored = current;
    restored->primaryWidth = ownedPreset.original.primaryWidth;
    restored->primaryHeight = ownedPreset.original.primaryHeight;
    return YES;
}

static void restore_published_preset(void);

static BOOL restore_preset(void) {
    if (ownedPreset.alternate) {
        PresetRecord current = renderer.alternatePreset();
        PresetRecord restored;
        if (original_primary_pair(current, &restored)) {
            renderer.setAlternatePreset(restored);
            current = renderer.alternatePreset();
            if (current.primaryWidth != restored.primaryWidth ||
                current.primaryHeight != restored.primaryHeight) return NO;
        }
        restore_published_preset();
        memset(&ownedPreset, 0, sizeof ownedPreset);
        return YES;
    }
    if (!ownedPreset.arrayHandle) return YES;
    void *array = renderer.handleTarget(ownedPreset.arrayHandle);
    const PresetRecord *entry = preset_entry(array, ownedPreset.index);
    if (entry) {
        PresetRecord current = *entry;
        PresetRecord restored;
        if (original_primary_pair(current, &restored) &&
            !replace_preset(array, ownedPreset.index, current, restored)) return NO;
    }
    renderer.freeHandle(ownedPreset.arrayHandle);
    restore_published_preset();
    memset(&ownedPreset, 0, sizeof ownedPreset);
    return YES;
}

static MulgForcedSize inner_size(void *layer) {
    return (MulgForcedSize){ renderer.innerWidth(layer), renderer.innerHeight(layer) };
}

static MulgForcedSize second_size(void *layer) {
    return (MulgForcedSize){ renderer.secondWidth(layer), renderer.secondHeight(layer) };
}

static NSString *published_preset_apply_blocker(void *layer) {
    // This consumer clears the aspect flag, so require it already be clear.
    // The verified platform-8 path has no platform-specific apply callback.
    if (renderer.runtimePlatform() != 8) return @"Unprofiled camera apply platform";
    if (renderer.cameraAspectOverride(layer)) return @"Gameplay layer has an active aspect override";
    if (renderer.hasGameHotfix(0x495eb) || renderer.hasGameHotfix(0x495ea))
        return @"The game hotfixed its camera apply routine";
    if (renderer.hasGameHotfix(0x95033)) return @"The game hotfixed its post-apply callback";
    if (renderer.hasGameHotfix(usesAreaPublisher ? 0x49615 : 0x49607))
        return @"The game hotfixed its preset publisher";
    return nil;
}

static void read_published_pairs(MulgForcedSize *primary, MulgForcedSize *secondary) {
    *primary = (MulgForcedSize){
        __atomic_load_n(publishedPreset + 0x40 / 4, __ATOMIC_RELAXED),
        __atomic_load_n(publishedPreset + 0x44 / 4, __ATOMIC_RELAXED)
    };
    *secondary = (MulgForcedSize){
        __atomic_load_n(publishedPreset, __ATOMIC_RELAXED),
        __atomic_load_n(publishedPreset + 0x10 / 4, __ATOMIC_RELAXED)
    };
}

static BOOL publish_and_apply_preset(void *layer, MulgForcedSize primary, MulgForcedSize secondary,
                                     BOOL recordPublication) {
    if (!publishedPreset || published_preset_apply_blocker(layer)) return NO;
    if (usesAreaPublisher) renderer.publishAreaPreset();
    else renderer.publishOrdinaryPreset();
    MulgForcedSize publishedPrimary, publishedSecondary;
    read_published_pairs(&publishedPrimary, &publishedSecondary);
    if (recordPublication) {
        ownedPreset.publishedByApplyPrimary = publishedPrimary;
        ownedPreset.publishedByApplySecondary = publishedSecondary;
        directPublishedPrimary = publishedPrimary;
        directPublishedSecondary = publishedSecondary;
    }
    if (!same_size(publishedPrimary, primary) || !same_size(publishedSecondary, secondary)) {
        if (recordPublication) directApplyFailure = @"The publisher did not produce the expected resolution pairs";
        return NO;
    }
    // Return address immediately after the profiled camera texture allocation.
    uintptr_t allocator = (uintptr_t)_dyld_get_image_header(0) + 0x002d50a0;
    uintptr_t previousScope = mulg_graphics_set_scene_apply_allocator(allocator);
    renderer.applyPublishedPreset(renderer.camera(layer));
    mulg_graphics_set_scene_apply_allocator(previousScope);
    MulgForcedSize actualPrimary = inner_size(layer), actualSecondary = second_size(layer);
    if (recordPublication) {
        directCameraPrimary = actualPrimary;
        directCameraSecondary = actualSecondary;
    }
    if (!same_size(actualPrimary, primary)) {
        if (recordPublication) directApplyFailure = @"The camera did not adopt the published primary size";
        return NO;
    }
    // The profiled SetInnerResolution stores its first pair in both slots.
    // Its allocator reads the first pair only. Restore the game's secondary
    // pair before returning to the render loop, using its existing accessors.
    if (!same_size(actualSecondary, secondary) && same_size(actualSecondary, primary)) {
        renderer.setSecondWidth(layer, secondary.width);
        renderer.setSecondHeight(layer, secondary.height);
    }
    BOOL secondaryMatches = same_size(second_size(layer), secondary);
    if (!secondaryMatches && recordPublication)
        directApplyFailure = @"The camera did not retain the original secondary size";
    return secondaryMatches;
}

static void restore_published_preset(void) {
    if (!ownedPreset.appliedLayerHandle) return;
    void *layer = renderer.handleTarget(ownedPreset.appliedLayerHandle);
    MulgForcedSize primary = {0}, secondary = {0};
    if (publishedPreset) read_published_pairs(&primary, &secondary);
    directRollbackResult = @"Waiting for the game to refresh its graphics preset";
    if (publishedPreset && same_size(primary, ownedPreset.primary) &&
        same_size(secondary, ownedPreset.secondary) && renderer.isAlive(layer) &&
        same_size(inner_size(layer), ownedPreset.primary) &&
        same_size(second_size(layer), ownedPreset.secondary)) {
        directRollbackResult = @"The published and camera sizes already match the original preset";
    } else if (publishedPreset && same_size(primary, ownedPreset.publishedByApplyPrimary) &&
        same_size(secondary, ownedPreset.publishedByApplySecondary) &&
        (!same_size(primary, ownedPreset.primary) || !same_size(secondary, ownedPreset.secondary)) &&
        renderer.isAlive(layer) && renderer.isActive(layer) &&
        renderer.gameplayCamera() == renderer.camera(layer) &&
        renderer.screenWidth() == ownedPreset.output.width && renderer.screenHeight() == ownedPreset.output.height &&
        renderer.usesAreaPublisher() == ownedPreset.areaPublisher &&
        renderer.usesAlternatePreset() == ownedPreset.alternate &&
        (same_size(inner_size(layer), primary) || same_size(inner_size(layer), ownedPreset.primary))) {
        usesAreaPublisher = ownedPreset.areaPublisher;
        if (publish_and_apply_preset(layer, ownedPreset.primary, ownedPreset.secondary, NO)) {
            void *target = renderer.cameraTarget(renderer.camera(layer));
            if (renderer.isAlive(target) && renderer.targetWidth(target) == ownedPreset.primary.width &&
                renderer.targetHeight(target) == ownedPreset.primary.height)
                directRollbackResult = @"The original gameplay camera target was restored";
        }
    }
    renderer.freeHandle(ownedPreset.appliedLayerHandle);
}

static BOOL matches_inner_sizes(void *layer, MulgForcedSize size) {
    return same_size(inner_size(layer), size) && same_size(second_size(layer), size);
}

static void set_inner_sizes(void *layer, MulgForcedSize size, BOOL primary, BOOL secondary) {
    // Use the resize and invalidation methods directly. RefreshInnerResolution also
    // resets the camera's forceIntoRenderTexture flag and cached screen dimensions.
    if (primary) {
        renderer.setInnerWidth(layer, size.width);
        renderer.setInnerHeight(layer, size.height);
    }
    if (secondary) {
        renderer.setSecondWidth(layer, size.width);
        renderer.setSecondHeight(layer, size.height);
    }
    if (!primary && !secondary) return;
    void *camera = renderer.camera(layer);
    if (renderer.isActive(layer) && renderer.isAlive(camera)) {
        renderer.updateInnerTarget(layer);
        renderer.invalidatePipeline(layer);
    }
}

static MulgForcedSize target_size(void *camera) {
    if (!renderer.isAlive(camera)) return (MulgForcedSize){ 0, 0 };
    void *target = renderer.cameraTarget(camera);
    if (!renderer.isAlive(target)) return (MulgForcedSize){ 0, 0 };
    return (MulgForcedSize){ renderer.targetWidth(target), renderer.targetHeight(target) };
}

static void restore(BOOL rollback) {
    if (!owned.handle) return;
    void *layer = renderer.handleTarget(owned.handle);
    if (renderer.isAlive(layer)) {
        BOOL primary = rollback || same_size(inner_size(layer), owned.applied);
        BOOL secondary = rollback || same_size(second_size(layer), owned.applied);
        set_inner_sizes(layer, owned.previous, primary, secondary);
    }
    renderer.freeHandle(owned.handle);
    memset(&owned, 0, sizeof owned);
}

static MulgNativeSceneState find_main_layer(void **result, MulgForcedSize *requested) {
    observedTarget = (MulgForcedSize){ 0, 0 };
    cameraUsesLayerSceneTarget = NO;
    observedCameraAspect = 0;
    observedScreen = (MulgForcedSize){ 0, 0 };
    observedFinal = (MulgForcedSize){ 0, 0 };
    observedPrimaryPreset = (MulgForcedSize){ 0, 0 };
    observedSecondaryPreset = (MulgForcedSize){ 0, 0 };
    observedRawPrimary = observedRawSecondary = (MulgForcedSize){0};
    candidatePreset = (MulgForcedSize){ 0, 0 };
    candidateEncodingVerified = NO;
    candidateOrdinaryFitVerified = NO;
    candidateAreaFitVerified = NO;
    ordinaryPresetBaselineMatches = NO;
    ordinaryPresetIndex = NSNotFound;
    selectedPresetArray = NULL;
    selectedAlternatePreset = NO;
    usesAreaPublisher = NO;
    observedPresetScale = nil;
    observedFSRScale = nil;
    if (!resolve_renderer()) {
        reason = @"No verified PostProcessLayer ABI for this executable";
        return MulgNativeSceneUnsupported;
    }
    if (!startedRendering) startedRendering = mulg_graphics_has_game_drawable();
    if (!startedRendering) {
        reason = @"Waiting for Unity to render a frame";
        return MulgNativeSceneWaiting;
    }

    *requested = mulg_graphics_forced_target();
    if (!valid_size(*requested)) {
        reason = @"Waiting for valid output dimensions";
        return MulgNativeSceneUnsupported;
    }
    observedScreen = (MulgForcedSize){ renderer.screenWidth(), renderer.screenHeight() };
    CGSize output = mulg_graphics_main_drawable_size();
    if (!CGSizeEqualToSize(output, CGSizeMake(requested->width, requested->height))) {
        reason = @"Waiting for the main drawable to reach the requested size";
        return MulgNativeSceneWaiting;
    }
    if (!same_size(observedScreen, *requested)) {
        reason = @"Waiting for Unity screen dimensions to match the drawable";
        return MulgNativeSceneWaiting;
    }

    void *camera = renderer.gameplayCamera();
    if (!renderer.isAlive(camera) || !renderer.isActive(camera)) {
        reason = @"Waiting for the game's active gameplay camera";
        return MulgNativeSceneWaiting;
    }
    void *type = renderer.classFromDefinition(renderer.postProcessType);
    void *layer = type ? renderer.findComponent(camera, type) : NULL;
    if (!renderer.isAlive(layer) || !renderer.isActive(layer) || renderer.camera(layer) != camera) {
        reason = @"Waiting for the main camera's PostProcessLayer";
        return MulgNativeSceneWaiting;
    }
    if (publishedPreset) read_published_pairs(&observedPrimaryPreset, &observedSecondaryPreset);
    // Both preset calculators select the scale through this graphics flag.
    float presetScale = renderer.graphicsFlag(3214) ? renderer.alternatePresetScale() : renderer.presetScale();
    if (isfinite(presetScale) && presetScale > 0) {
        observedPresetScale = @(presetScale);
        candidatePreset = (MulgForcedSize){
            unscaled_preset_dimension(requested->width, presetScale),
            unscaled_preset_dimension(requested->height, presetScale)
        };
        // A published preset indicates the game's dimension codec is initialized.
        // Check the candidate through that codec without modifying the record.
        PresetRecord record = {0};
        if (valid_size(observedPrimaryPreset) && read_selected_preset(&record)) {
            usesAreaPublisher = renderer.usesAreaPublisher();
            observedRawPrimary = (MulgForcedSize){ renderer.decodePresetDimension(record.primaryWidth),
                renderer.decodePresetDimension(record.primaryHeight) };
            observedRawSecondary = (MulgForcedSize){ renderer.decodePresetDimension(record.secondaryWidth),
                renderer.decodePresetDimension(record.secondaryHeight) };
        }
        if (valid_size(observedRawPrimary) && valid_size(observedRawSecondary) &&
            candidatePreset.width > 0 && candidatePreset.height > 0) {
            selectedRecord = record;
            candidateEncodingVerified = prepare_preset(record, candidatePreset, &replacementRecord);
            if (candidateEncodingVerified) {
                ordinaryPresetBaselineMatches = valid_size(observedSecondaryPreset) &&
                    same_size(fit_ordinary_preset_pair(observedRawPrimary, presetScale), observedPrimaryPreset) &&
                    same_size(fit_ordinary_preset_pair(observedRawSecondary, presetScale), observedSecondaryPreset);
                MulgForcedSize candidatePrimary = { renderer.decodePresetDimension(replacementRecord.primaryWidth),
                    renderer.decodePresetDimension(replacementRecord.primaryHeight) };
                candidateOrdinaryFitVerified = !usesAreaPublisher && ordinaryPresetBaselineMatches &&
                    same_size(fit_ordinary_preset_pair(candidatePrimary, presetScale), *requested);
                candidateAreaFitVerified = usesAreaPublisher && valid_size(observedSecondaryPreset) &&
                    same_size(fit_area_preset_pair(observedRawPrimary, presetScale), observedPrimaryPreset) &&
                    same_size(fit_area_preset_pair(observedRawSecondary, presetScale), observedSecondaryPreset) &&
                    same_size(fit_area_preset_pair(candidatePrimary, presetScale), *requested);
            }
        }
    }
    BOOL fsrEnabled = renderer.fsrEnabled(layer);
    float fsrScale = fsrEnabled ? renderer.fsrScale(layer) : 1.0f;
    if (isfinite(fsrScale) && fsrScale > 0) observedFSRScale = @(fsrScale);
    observedFinal = (MulgForcedSize){ renderer.finalWidth(layer), renderer.finalHeight(layer) };
    if (!same_size(observedFinal, *requested)) {
        reason = @"Waiting for the gameplay camera's final target to match the requested size";
        return MulgNativeSceneWaiting;
    }
    observedTarget = target_size(camera);
    observedCameraAspect = renderer.cameraAspect(camera);
    // The matched allocator stores its newly created RenderTexture at 0xb8
    // before assigning that same managed object to Camera.targetTexture.
    void *layerTarget = *(void *const *)((const uint8_t *)layer + 0xb8);
    cameraUsesLayerSceneTarget = layerTarget && renderer.cameraTarget(camera) == layerTarget;
    if (!valid_size(observedTarget)) {
        reason = @"Waiting for the main camera to own a render target";
        return MulgNativeSceneWaiting;
    }
    if (fsrScale != 1.0f) {
        reason = @"The main camera uses a game-owned FSR factor other than 1.0";
        return MulgNativeSceneWaiting;
    }
    *result = layer;
    return MulgNativeSceneReady;
}

static MulgNativeSceneState check_baseline(void *layer, MulgForcedSize requested, MulgForcedSize previous) {
    if (same_size(observedTarget, requested)) return MulgNativeSceneReady;
    if (!valid_size(previous) || !valid_size(observedTarget) ||
        observedTarget.width > requested.width || observedTarget.height > requested.height ||
        !same_size(observedTarget, (MulgForcedSize){ previous.width & ~1, previous.height & ~1 }) ||
        !same_aspect(observedTarget, requested)) {
        reason = @"The game has no smaller explicit main-camera target to replace";
        return MulgNativeSceneWaiting;
    }
    if (!same_size(previous, second_size(layer))) {
        reason = @"The game uses separate primary and secondary scene sizes";
        return MulgNativeSceneWaiting;
    }
    // UpdateInnerTarget can reapply the final target's aspect. Only resize a camera
    // whose current projection already uses that aspect.
    if (renderer.cameraAspect(renderer.camera(layer)) != (float)observedFinal.width / (float)observedFinal.height) {
        reason = @"Waiting for the gameplay camera to use its normal output aspect";
        return MulgNativeSceneWaiting;
    }
    return MulgNativeSceneReady;
}

// The verified iOS ScreenManager request owns the normal surface resize. Its
// width/height sentinel is -1/-1 initially; zero restores the natural surface.
static struct {
    BOOL owned, restoring, acknowledged, yielded, readable;
    MulgForcedSize original, applied, observed, resolved;
    unsigned requests, restorations, conflicts, waiting;
    MulgNativeSceneState state;
} playerOutput;
static NSString *playerOutputReason = @"Not requested";
static BOOL output_read(uintptr_t address, void *result, size_t size) {
    mach_vm_size_t copied = 0;
    return address && mach_vm_read_overwrite(mach_task_self(), address, size,
        (mach_vm_address_t)result, &copied) == KERN_SUCCESS && copied == size;
}
static BOOL output_native(MulgForcedSize size) {
    return same_size(size, (MulgForcedSize){0, 0}) || same_size(size, (MulgForcedSize){-1, -1});
}
static BOOL output_same(MulgForcedSize a, MulgForcedSize b) {
    return same_size(a, b) || (output_native(a) && output_native(b));
}
static MulgNativeSceneState output_result(MulgNativeSceneState state, NSString *message) {
    playerOutput.state = state; playerOutputReason = message; return state;
}
BOOL mulg_post_process_output_owns_values(void) { return playerOutput.owned; }

MulgNativeSceneState mulg_post_process_output_update(BOOL enabled) {
    if (!resolve_renderer()) return output_result(MulgNativeSceneUnsupported, @"No verified native Unity output API");
    if (!enabled && !playerOutput.owned) {
        playerOutput.yielded = NO; playerOutput.conflicts = 0;
        return output_result(MulgNativeSceneRestored, @"No native output request is owned");
    }
    if (!mulg_graphics_has_game_drawable())
        return output_result(MulgNativeSceneWaiting, @"Waiting for the game's normal drawable acquisition");
    void *manager = renderer.outputManager();
    uintptr_t vtable = 0, requestMethod = 0;
    int32_t policy[2];
    if (!output_read((uintptr_t)manager, &vtable, sizeof vtable) ||
        !output_read(vtable + 0x10, &requestMethod, sizeof requestMethod) ||
        requestMethod != (uintptr_t)renderer.requestOutput ||
        !output_read((uintptr_t)manager + 0x10, policy, sizeof policy))
        return output_result(MulgNativeSceneWaiting, @"Waiting for the verified iOS screen manager");
    playerOutput.readable = output_read(renderer.outputState + 0x3c, &playerOutput.observed, sizeof playerOutput.observed);
    if (!playerOutput.readable)
        return output_result(MulgNativeSceneWaiting, @"Waiting for readable rendering-resolution state");
    MulgForcedSize current = playerOutput.observed;
    renderer.outputSize(&playerOutput.resolved.width, &playerOutput.resolved.height);
    if (!output_native(current) && !valid_size(current))
        return output_result(MulgNativeSceneFailed, @"The verified player has an unrecognized rendering request");
    MulgForcedSize wanted = mulg_graphics_forced_target();
    if (enabled && !valid_size(wanted))
        return output_result(MulgNativeSceneWaiting, @"Waiting for the selected output dimensions");
    // Restore the outgoing scene policy before an ordinary surface-size change.
    if ((!enabled || !same_size(wanted, playerOutput.applied)) && mulg_post_process_scene_owns_values() &&
        mulg_post_process_scene_update(NO) != MulgNativeSceneRestored)
        return output_result(MulgNativeSceneWaiting, @"Waiting to restore the outgoing scene policy");
    if (!enabled) {
        playerOutput.yielded = NO; playerOutput.conflicts = 0;
        if (!output_same(current, playerOutput.applied) && !output_same(current, playerOutput.original)) {
            playerOutput.owned = NO;
            return output_result(MulgNativeSceneRestored, @"The game's newer rendering request was preserved");
        }
        if (playerOutput.restoring && output_same(current, playerOutput.original)) {
            playerOutput.owned = NO; playerOutput.restoring = NO;
            return output_result(MulgNativeSceneRestored, @"Unity restored its original rendering policy");
        }
        if (!playerOutput.restoring) {
            MulgForcedSize restore = output_native(playerOutput.original) ? (MulgForcedSize){0, 0} : playerOutput.original;
            renderer.requestOutput(manager, restore.width, restore.height, policy[0], policy[1]);
            playerOutput.restoring = YES; playerOutput.restorations++; playerOutput.waiting = 0;
        }
        return output_result(++playerOutput.waiting > 30 ? MulgNativeSceneFailed : MulgNativeSceneWaiting,
                             @"Waiting for Unity to restore its original rendering request");
    }
    if (!same_size(wanted, playerOutput.applied)) { playerOutput.yielded = NO; playerOutput.conflicts = 0; }
    if (playerOutput.yielded) return output_result(MulgNativeSceneOverridden, @"The game repeatedly replaced the rendering request");
    if (same_size(current, wanted)) {
        playerOutput.acknowledged = YES;
        playerOutput.applied = wanted; playerOutput.restoring = NO;
        return output_result(MulgNativeSceneApplied, @"Unity accepted the selected rendering dimensions");
    }
    if (playerOutput.owned && !playerOutput.restoring && same_size(wanted, playerOutput.applied)) {
        if (!playerOutput.acknowledged && output_same(current, playerOutput.original))
            return output_result(++playerOutput.waiting > 30 ? MulgNativeSceneFailed : MulgNativeSceneWaiting,
                                 @"Waiting for Unity to acknowledge the rendering request");
        playerOutput.owned = NO;
        if (++playerOutput.conflicts >= 3) {
            playerOutput.yielded = YES;
            return output_result(MulgNativeSceneOverridden, @"The game's newer rendering request was preserved");
        }
    }
    if (!playerOutput.owned) playerOutput.original = current;
    playerOutput.owned = YES; playerOutput.restoring = NO; playerOutput.acknowledged = NO;
    playerOutput.applied = wanted; playerOutput.waiting = 0;
    renderer.requestOutput(manager, wanted.width, wanted.height, policy[0], policy[1]); playerOutput.requests++;
    return output_result(MulgNativeSceneWaiting, @"Unity was asked to render at the selected dimensions");
}

NSDictionary *mulg_post_process_output_report(void) {
    return @{@"supported": @(supported), @"state": @(playerOutput.state), @"reason": playerOutputReason,
        @"ownsEngineValues": @(playerOutput.owned), @"stateReadable": @(playerOutput.readable),
        @"acknowledged": @(playerOutput.acknowledged), @"requests": @(playerOutput.requests),
        @"restorations": @(playerOutput.restorations),
        @"originalWidth": @(playerOutput.original.width), @"originalHeight": @(playerOutput.original.height),
        @"requestedWidth": @(playerOutput.applied.width), @"requestedHeight": @(playerOutput.applied.height),
        @"observedRequestWidth": @(playerOutput.observed.width), @"observedRequestHeight": @(playerOutput.observed.height),
        @"resolvedWidth": @(playerOutput.resolved.width), @"resolvedHeight": @(playerOutput.resolved.height)};
}

MulgNativeSceneState mulg_post_process_scene_probe(void) {
    void *layer = NULL;
    MulgForcedSize requested;
    MulgNativeSceneState state = find_main_layer(&layer, &requested);
    return state;
}

static MulgNativeSceneState update_upstream_preset(void *layer, MulgForcedSize requested) {
    int32_t platform = renderer.runtimePlatform();
    // These two platform values take a different camera apply path that
    // computes a display-derived size instead of using the published pairs.
    if (platform == 7 || platform == 2) {
        if (!restore_preset()) return MulgNativeSceneFailed;
        reason = @"The game uses a platform-specific camera resolution policy";
        return MulgNativeSceneUnsupported;
    }
    // Allow the same two-pixel rounding tolerance used for the target pairs.
    float aspectTolerance = 2.0f / (float)requested.height;
    if (ownedPreset.arrayHandle || ownedPreset.alternate) {
        BOOL sameStorage = ownedPreset.alternate ? selectedAlternatePreset :
            renderer.handleTarget(ownedPreset.arrayHandle) == selectedPresetArray &&
            ordinaryPresetIndex == ownedPreset.index;
        if (!sameStorage || usesAreaPublisher != ownedPreset.areaPublisher ||
            observedPresetScale.floatValue != ownedPreset.policyScale ||
            memcmp(&selectedRecord, &ownedPreset.replacement, sizeof selectedRecord) != 0) {
            reason = @"The game changed its resolution preset";
            return restore_preset() ? MulgNativeSceneOverridden : MulgNativeSceneFailed;
        }
        BOOL framingMatches = fabsf(observedCameraAspect - ownedPreset.cameraAspect) <= aspectTolerance;
        if (framingMatches && cameraUsesLayerSceneTarget &&
            same_size(observedPrimaryPreset, requested) && same_size(inner_size(layer), requested) &&
            same_size(observedTarget, requested) &&
            same_size(observedSecondaryPreset, ownedPreset.secondary) &&
            same_size(second_size(layer), ownedPreset.secondary)) {
            ownedPreset.inconsistentSamples = 0;
            ownedPreset.accepted = YES;
            reason = @"The game applied the upstream preset to the main camera target";
            return MulgNativeSceneApplied;
        }
        BOOL publicationChanged = !same_size(observedPrimaryPreset, ownedPreset.primary) ||
            !same_size(observedSecondaryPreset, ownedPreset.secondary);
        if (publicationChanged || ownedPreset.accepted) {
            // Publishing and reallocating can straddle a sample. Only roll back
            // when subsequent main-thread observations still disagree.
            if (++ownedPreset.inconsistentSamples >= 3) {
                if (!restore_preset()) {
                    reason = @"The game has not restored the original resolution preset";
                    return MulgNativeSceneFailed;
                }
                reason = framingMatches ? @"The published preset and gameplay camera targets disagreed" :
                    @"The gameplay camera aspect changed after the preset was published";
                return MulgNativeSceneOverridden;
            }
        } else {
            ownedPreset.inconsistentSamples = 0;
        }
        reason = directApplyAttempted ? @"Waiting to verify the game's resolution apply" :
            @"Waiting for the game to reapply its graphics preset";
        return MulgNativeScenePresetStaged;
    }
    if (cameraUsesLayerSceneTarget && same_size(observedTarget, requested) && same_size(inner_size(layer), requested)) {
        reason = @"The main camera already owns a target at the requested size";
        return MulgNativeSceneApplied;
    }
    float outputAspect = (float)requested.width / (float)requested.height;
    if (!(fabsf(observedCameraAspect - outputAspect) <= aspectTolerance)) {
        reason = @"Waiting for the gameplay camera to match the output aspect";
        return MulgNativeSceneWaiting;
    }
    if (!(candidateOrdinaryFitVerified || candidateAreaFitVerified) ||
        (!selectedPresetArray && !selectedAlternatePreset) ||
        !cameraUsesLayerSceneTarget ||
        !same_size(observedPrimaryPreset, observedTarget) ||
        !same_size(observedSecondaryPreset, second_size(layer)) ||
        !same_aspect(observedTarget, requested)) {
        reason = @"Waiting for a matching game resolution preset";
        return MulgNativeSceneWaiting;
    }
    if (selectedAlternatePreset) {
        PresetRecord current = renderer.alternatePreset();
        if (!renderer.usesAlternatePreset() || memcmp(&current, &selectedRecord, sizeof current) != 0) {
            reason = @"The game changed its alternate resolution preset";
            return MulgNativeSceneWaiting;
        }
        renderer.setAlternatePreset(replacementRecord);
        current = renderer.alternatePreset();
        if (memcmp(&current, &replacementRecord, sizeof current) != 0) {
            reason = @"The game did not retain the alternate replacement preset";
            return MulgNativeSceneFailed;
        }
        ownedPreset.alternate = YES;
    } else {
        int32_t index = (int32_t)ordinaryPresetIndex;
        uint32_t handle = renderer.retainLayer(selectedPresetArray, false);
        if (!handle) {
            reason = @"Could not retain the game's preset array";
            return MulgNativeSceneFailed;
        }
        if (!replace_preset(renderer.handleTarget(handle), index, selectedRecord, replacementRecord)) {
            renderer.freeHandle(handle);
            reason = @"The game did not retain the replacement preset";
            return MulgNativeSceneFailed;
        }
        ownedPreset.arrayHandle = handle;
        ownedPreset.index = index;
    }
    ownedPreset.original = selectedRecord;
    ownedPreset.replacement = replacementRecord;
    ownedPreset.primary = observedPrimaryPreset;
    ownedPreset.secondary = observedSecondaryPreset;
    ownedPreset.areaPublisher = usesAreaPublisher;
    ownedPreset.policyScale = observedPresetScale.floatValue;
    ownedPreset.cameraAspect = observedCameraAspect;
    ownedPreset.output = requested;
    directApplyBlocker = published_preset_apply_blocker(layer);
    directApplyAttempted = NO;
    directApplyFailure = nil;
    directRollbackResult = nil;
    directPublishedPrimary = directPublishedSecondary = (MulgForcedSize){0};
    directCameraPrimary = directCameraSecondary = (MulgForcedSize){0};
    if (!directApplyBlocker) {
        ownedPreset.appliedLayerHandle = renderer.retainLayer(layer, false);
        directApplyAttempted = ownedPreset.appliedLayerHandle != 0;
        if (!directApplyAttempted) directApplyBlocker = @"Could not retain the gameplay layer";
        if (directApplyAttempted && !publish_and_apply_preset(layer, requested, ownedPreset.secondary, YES)) {
            if (restore_preset()) {
                reason = @"The game's resolution apply rejected the staged preset";
                return MulgNativeSceneOverridden;
            }
            reason = @"The game has not restored the original resolution preset";
            return MulgNativeSceneFailed;
        }
    }
    reason = ownedPreset.appliedLayerHandle ? @"Waiting to verify the game's resolution apply" :
        @"Waiting for the game to reapply its graphics preset";
    return MulgNativeScenePresetStaged;
}

MulgNativeSceneState mulg_post_process_scene_update(BOOL enabled) {
    if (!enabled) {
        if (!restore_preset()) {
            reason = @"The game has not restored the original resolution preset";
            return MulgNativeSceneFailed;
        }
        restore(NO);
        observedTarget = (MulgForcedSize){ 0, 0 };
        cameraUsesLayerSceneTarget = NO;
        observedCameraAspect = 0;
        observedScreen = (MulgForcedSize){ 0, 0 };
        observedFinal = (MulgForcedSize){ 0, 0 };
        observedPrimaryPreset = (MulgForcedSize){ 0, 0 };
        observedSecondaryPreset = (MulgForcedSize){ 0, 0 };
        observedRawPrimary = observedRawSecondary = (MulgForcedSize){0};
        candidatePreset = (MulgForcedSize){ 0, 0 };
        candidateEncodingVerified = NO;
        candidateOrdinaryFitVerified = NO;
        candidateAreaFitVerified = NO;
        ordinaryPresetBaselineMatches = NO;
        ordinaryPresetIndex = NSNotFound;
        usesAreaPublisher = NO;
        observedPresetScale = nil;
        observedFSRScale = nil;
        directApplyBlocker = nil;
        directApplyAttempted = NO;
        directApplyFailure = nil;
        overrides = 0;
        terminalState = MulgNativeSceneUnsupported;
        reason = @"Not requested";
        return MulgNativeSceneRestored;
    }
    if (terminalState != MulgNativeSceneUnsupported) return terminalState;

    if ((ownedPreset.arrayHandle || ownedPreset.alternate) &&
        !same_size(ownedPreset.output, mulg_graphics_forced_target()) && !restore_preset()) {
        reason = @"The outgoing resolution preset has not been restored";
        return MulgNativeSceneFailed;
    }

    void *layer = NULL;
    MulgForcedSize requested;
    MulgNativeSceneState state = find_main_layer(&layer, &requested);
    if (state != MulgNativeSceneReady) {
        if (!restore_preset()) return MulgNativeSceneFailed;
        if (owned.handle) {
            restore(NO);
            observedTarget = (MulgForcedSize){ 0, 0 };
        }
        return state;
    }
    // Every output size uses the upstream graphics preset. Do not recreate a
    // camera target independently of the game's lighting/post-process policy.
    restore(NO);
    state = update_upstream_preset(layer, requested);
    if (state == MulgNativeSceneOverridden) terminalState = state;
    return state;
}

BOOL mulg_post_process_scene_owns_values(void) {
    return owned.handle != 0 || ownedPreset.arrayHandle != 0 || ownedPreset.alternate;
}

NSDictionary<NSString *, id> *mulg_post_process_scene_report(void) {
    return @{
        @"adapter": @"Unity PostProcessLayer",
        @"reason": reason,
        @"ownsDimensions": @(mulg_post_process_scene_owns_values()),
        @"ownsUpstreamPreset": @(ownedPreset.arrayHandle != 0 || ownedPreset.alternate),
        @"directPresetApplyAttempted": @(directApplyAttempted),
        @"directPresetApplyBlocker": directApplyBlocker ?: NSNull.null,
        @"directPresetApplyFailure": directApplyFailure ?: NSNull.null,
        @"directPresetRollbackResult": directRollbackResult ?: NSNull.null,
        @"directPublishedPrimaryWidth": @(directPublishedPrimary.width),
        @"directPublishedPrimaryHeight": @(directPublishedPrimary.height),
        @"directPublishedSecondaryWidth": @(directPublishedSecondary.width),
        @"directPublishedSecondaryHeight": @(directPublishedSecondary.height),
        @"directCameraPrimaryWidth": @(directCameraPrimary.width),
        @"directCameraPrimaryHeight": @(directCameraPrimary.height),
        @"directCameraSecondaryWidth": @(directCameraSecondary.width),
        @"directCameraSecondaryHeight": @(directCameraSecondary.height),
        @"ownsAlternateUpstreamPreset": @(ownedPreset.alternate),
        @"unityScreenWidth": @(observedScreen.width),
        @"unityScreenHeight": @(observedScreen.height),
        @"finalTargetWidth": @(observedFinal.width),
        @"finalTargetHeight": @(observedFinal.height),
        @"cameraTargetWidth": @(observedTarget.width),
        @"cameraTargetHeight": @(observedTarget.height),
        @"cameraUsesLayerSceneTarget": @(cameraUsesLayerSceneTarget),
        @"gameplayCameraAspect": isfinite(observedCameraAspect) && observedCameraAspect > 0 ?
            @(observedCameraAspect) : NSNull.null,
        @"upstreamPresetScale": observedPresetScale ?: NSNull.null,
        @"publishedPrimaryPresetWidth": @(observedPrimaryPreset.width),
        @"publishedPrimaryPresetHeight": @(observedPrimaryPreset.height),
        @"publishedSecondaryPresetWidth": @(observedSecondaryPreset.width),
        @"publishedSecondaryPresetHeight": @(observedSecondaryPreset.height),
        @"selectedPrimaryPresetWidth": @(observedRawPrimary.width),
        @"selectedPrimaryPresetHeight": @(observedRawPrimary.height),
        @"selectedSecondaryPresetWidth": @(observedRawSecondary.width),
        @"selectedSecondaryPresetHeight": @(observedRawSecondary.height),
        @"candidateUnscaledPresetWidth": @(candidatePreset.width),
        @"candidateUnscaledPresetHeight": @(candidatePreset.height),
        @"candidatePresetEncodingVerified": @(candidateEncodingVerified),
        @"ordinaryPresetBaselineMatchesPublished": @(ordinaryPresetBaselineMatches),
        @"ordinaryPresetIndex": ordinaryPresetIndex == NSNotFound ? NSNull.null : @(ordinaryPresetIndex),
        @"usesAreaPresetPublisher": @(usesAreaPublisher),
        @"candidateOrdinaryPresetFitVerified": @(candidateOrdinaryFitVerified),
        @"candidateAreaPresetFitVerified": @(candidateAreaFitVerified),
        @"effectiveFSRScale": observedFSRScale ?: NSNull.null,
        @"gameOverrides": @(overrides)
    };
}
