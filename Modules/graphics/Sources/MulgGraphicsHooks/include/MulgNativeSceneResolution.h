#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, MulgNativeSceneState) {
    MulgNativeSceneUnsupported = 0,
    MulgNativeSceneWaiting = 1,
    MulgNativeSceneReady = 2,
    MulgNativeSceneApplied = 3,
    MulgNativeSceneRestored = 4,
    MulgNativeSceneFailed = 5,
    MulgNativeSceneOverridden = 6,
    MulgNativeScenePresetStaged = 7,
};

/// Main-thread engine API adapters. Probe only inspects metadata and reads engine state.
/// Adapters use engine methods and make no direct writes to GPU resources, camera state or game files.
MulgNativeSceneState mulg_native_scene_probe(void);
MulgNativeSceneState mulg_native_scene_update(BOOL enabled);
BOOL mulg_native_scene_owns_values(void);
NSDictionary<NSString *, id> *mulg_native_scene_report(void);

/// Stripped Unity players with a verified PostProcessLayer ABI.
MulgNativeSceneState mulg_post_process_scene_probe(void);
MulgNativeSceneState mulg_post_process_scene_update(BOOL enabled);
BOOL mulg_post_process_scene_owns_values(void);
NSDictionary<NSString *, id> *mulg_post_process_scene_report(void);
MulgNativeSceneState mulg_post_process_output_update(BOOL enabled);
BOOL mulg_post_process_output_owns_values(void);
NSDictionary<NSString *, id> *mulg_post_process_output_report(void);

/// Stripped Unity custom renderers with a verified mobile-resolution preset publisher.
MulgNativeSceneState mulg_mobile_preset_scene_probe(void);
MulgNativeSceneState mulg_mobile_preset_scene_update(BOOL enabled);
BOOL mulg_mobile_preset_scene_owns_values(void);
NSDictionary<NSString *, id> *mulg_mobile_preset_scene_report(void);
/// Main Unity surface request for the verified stripped player. Zero restores native size.
MulgNativeSceneState mulg_mobile_preset_output_update(BOOL enabled);
BOOL mulg_mobile_preset_output_owns_values(void);
NSDictionary<NSString *, id> *mulg_mobile_preset_output_report(void);

NS_ASSUME_NONNULL_END
