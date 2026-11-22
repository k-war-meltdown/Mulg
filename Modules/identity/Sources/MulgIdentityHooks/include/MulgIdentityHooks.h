//
//  MulgIdentityHooks.h
//  identity module: sysctl and uname replacements (PLAN.md §3.4, §16.2 E3).
//

#ifndef MULG_IDENTITY_HOOKS_H
#define MULG_IDENTITY_HOOKS_H

#include <CoreFoundation/CoreFoundation.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Sets the identity the hooks report. Copies both strings once; the hooks then use the
/// copies without calling back into Swift or Objective-C (§16.2 E3).
/// Passing NULL for either value switches the identity module off: every hook then
/// passes straight through to the real function (§1.5 rule 4).
void mulg_identity_configure(const char *_Nullable machine, const char *_Nullable board_id);

/// Whether an identity is currently configured.
int mulg_identity_is_active(void);

/// Required model/board copies exist, including during the launch-time staging barrier.
/// Configuration failure keeps native answers; this does not publish or query the profile.
_Bool mulg_identity_has_configured_profile(void);

/// Launch-time staging barrier, owned by IdentityGameModule. Device-profile getters pass
/// through while configuration is open; finish publishes the prepared profile with release
/// ordering. Pair on the main thread even on failure. This is never a live-setting toggle.
/// Existing standalone configure APIs retain immediate-answer behavior outside the barrier.
void mulg_identity_begin_profile_configuration(void);
void mulg_identity_finish_profile_configuration(void);

/// What a real iPad answers where a Mac answers differently: MobileGestalt's DeviceClass and
/// DeviceName ("iPad") and machdep.cpu.brand_string. NULL passes the Mac's answer through.
void mulg_identity_configure_platform(const char *_Nullable deviceClass, const char *_Nullable cpuBrand);

/// The host name the game reads through uname's nodename, kern.hostname and gethostname
/// ("iPad") instead of the Mac's, which names the player. NULL passes the Mac's through.
void mulg_identity_configure_host_name(const char *_Nullable name);

/// The device's SoC platform ("t8142" for the M5): MobileGestalt's HardwarePlatform, and the
/// SoC at the end of the kernel version the game reads (uname's version, kern.version).
/// NULL passes the Mac's through.
void mulg_identity_configure_hardware_platform(const char *_Nullable platform);

/// `real` with the SoC after "RELEASE_ARM64_" replaced by `platform` in capitals, or NULL when
/// `real` has no such marker. The caller frees the result.
char *_Nullable mulg_identity_kernel_version(const char *_Nullable real, const char *_Nullable platform);

/// The string sysctlbyname reports for `name` with the current identity, or NULL for the real
/// value: hw.machine, hw.product, hw.model, hw.target, hw.targettype, machdep.cpu.brand_string,
/// kern.hostname, kern.version.
const char *_Nullable mulg_identity_sysctl_value(const char *_Nullable name);

/// The string MGCopyAnswer reports for `question` to the game, or NULL for the real answer:
/// ProductType, HWModelStr, DeviceClass and DeviceName, plain or obfuscated, HardwarePlatform,
/// and UserAssignedDeviceName (the generic host name).
const char *_Nullable mulg_identity_gestalt_value(CFStringRef _Nullable question);

/// The device's native panel in portrait pixels (2064 × 2752 for the iPad Pro 13-inch) and its
/// scale, for MobileGestalt's main-screen-width, -height and -scale. Zeros pass the Mac's through.
void mulg_identity_configure_screen(int32_t width, int32_t height, double scale);

/// The number MGCopyAnswer reports for `question` to the game: ChipID (from the hardware
/// platform, 0x8142 for "t8142"), DeviceClassNumber (3 for an iPad) and main-screen-width,
/// -height and -scale. Returns 1 for an integer, 2 for a floating-point value (the scale) and
/// 0 for the real answer.
int mulg_identity_gestalt_number(CFStringRef _Nullable question, double *_Nullable value);

/// What the device-tree root (IOKit's IOPlatformExpertDevice) holds for `key` on the device:
/// "model" ("iPad17,3"), "compatible" ("J820AP", "iPad17,3", "AppleARM"), "target-type"
/// ("J820") and "platform-name" ("t8142"), as NUL-terminated strings back to back. Returns the
/// bytes written, or 0 to keep the Mac's value.
size_t mulg_identity_platform_expert_value(CFStringRef _Nullable key, char *_Nullable out, size_t capacity);

/// 1 when this build interposes IORegistryEntryCreateCFProperty, IORegistryEntrySearchCFProperty
/// and IORegistryEntryCreateCFProperties (only where IOKit exists).
int mulg_identity_iokit_hooked(void);

/// The device's CPU as game callers see it: cores per performance level (3 and 6 for the 9-core
/// M5), XNU's hw.cpufamily (0x1d5a87e8 for the M5) and hw.cpusubfamily. A zero performance count
/// passes the Mac's through; a zero family leaves both family answers native. With a known
/// family, zero is a valid subfamily and is reported as zero.
void mulg_identity_configure_cpu(uint32_t performance, uint32_t efficiency, uint32_t family, uint32_t subfamily);

/// The number sysctlbyname reports for `name` with the configured CPU: the core counts (hw.ncpu,
/// hw.activecpu, hw.physicalcpu, hw.logicalcpu and their _max forms, machdep.cpu.core_count and
/// thread_count), hw.nperflevels, hw.perflevel0/1 core counts, hw.cpufamily and hw.cpusubfamily.
/// Returns 1 and sets `value`, or 0 for the real value.
int mulg_identity_cpu_number(const char *_Nullable name, uint32_t *_Nullable value);

/// The core count `caller` should see: the device's for the game's own code, 0 (the real count)
/// for Apple's frameworks or when no CPU is configured.
uint32_t mulg_identity_cpu_count_for_caller(const void *_Nullable caller);

/// Makes NSProcessInfo.processorCount and activeProcessorCount follow the configured CPU for game
/// callers. Returns the number of methods replaced (0–2).
int mulg_identity_install_cpu_count_hooks(void);

/// Makes NSProcessInfo.hostName report the generic host name (kern.hostname's answer) while one
/// is configured. Returns 1 when installed.
int mulg_identity_install_host_name_hook(void);

/// What NSProcessInfo.isiOSAppOnMac answers: YES (upstream) or NO, as on a real iPad.
void mulg_identity_set_reports_mac(_Bool onMac);

/// The opt-in coherent preset confines legacy machine/model/RAM answers to game
/// callers too. Apple/wrapper code continues to use the actual Mac hardware.
void mulg_identity_set_game_only_answers(_Bool enabled);
_Bool mulg_identity_game_only_answers(void);

/// Opt-in mobile interface identity for direct game/SDK callers only. Apple and wrapper
/// callers retain their real idiom. 0 is iPhone, 1 is iPad; returns matched hooks (0–2).
int mulg_identity_install_mobile_ui_hooks(int32_t idiom);

/// UIDevice.model and localizedModel ("iPad") and systemName ("iPadOS") as the spoofed device
/// reports them. ABI checked; missing targets are retried on later calls. Returns total
/// installed methods (0–3). Opt-in game-only scope preserves native framework answers.
int mulg_identity_install_device_strings(const char *_Nonnull model, const char *_Nonnull systemName);

/// Diagnostic readback of the configured UIDevice name/model/localizedModel/systemName
/// table, not a call to the game's SDK or a claim that the corresponding getter installed.
/// Returns 1 after a complete UTF-8 copy; 0 for inactive/missing values or insufficient space.
int mulg_identity_copy_device_string(const char *_Nonnull property, char *_Nullable buffer, size_t capacity);

/// Diagnostic readback of configured NSProcessInfo platform flags and the UIDevice /
/// UITraitCollection mobile idiom. Returns 1 with an available value, otherwise 0.
int mulg_identity_platform_number(const char *_Nonnull property, int32_t *_Nullable value);

/// Caps the memory the game sees (hw.memsize and NSProcessInfo.physicalMemory) at `bytes`, the
/// spoofed device's RAM; 0 removes the cap. It never raises the figure (PLAN.md §3.7).
void mulg_identity_configure_memory_limit(uint64_t bytes);

/// What the game sees for a real memory size with the current cap.
uint64_t mulg_identity_limited_memory(uint64_t real);
/// What os_proc_available_memory answers: the device memory left after the game's footprint, but
/// never more than the kernel's memory level (percent of `physical` macOS can make available).
uint64_t mulg_identity_available_memory(uint64_t limit, uint64_t footprint, uint64_t physical, int level);

/// Makes NSProcessInfo.physicalMemory follow the memory cap. Returns 1 when installed.
/// Opt-in game-only scope leaves Apple/framework callers uncapped.
int mulg_identity_install_memory_hook(void);

/// Makes UIDevice.name report `name` (a real iPad reports "iPad" to apps) instead of the Mac's
/// name, which also identifies the player. ABI checked and retryable. Returns 1 when installed;
/// opt-in game-only scope preserves native framework answers.
int mulg_identity_install_device_name_hook(const char *_Nonnull name);

/// Reports `name` as the Metal device's name (MTLDevice.name) instead of the Mac's GPU. Only
/// active identity's game callers see the name; GPU features stay native (PLAN.md §3.7).
/// Metadata-only setup creates no device. Native factory discovery installs late driver hooks
/// before devices reach their caller. Returns 1 for actual discovered coverage, 0 while pending.
int mulg_identity_install_gpu_name_hook(const char *_Nonnull name);

/// Diagnostic UTF-8 copy of the configured GPU name. GPU capabilities remain native.
/// Returns 1 for a complete copy, otherwise 0; does not create a Metal device.
int mulg_identity_copy_gpu_name(char *_Nullable buffer, size_t capacity);

/// Makes NSProcessInfo report the game as an iOS app on a Mac rather than a Mac Catalyst
/// app, as upstream MulgKit always did (MulgInfo.swift), or as mobile when reports_mac is false.
/// ABI checked, active-identity game callers only. Returns total installed methods (0–2).
int mulg_identity_install_platform_hooks(void);

/// Device state upstream reported to every game (BatteryLevel.m): battery monitoring on, the
/// battery full and finished charging, so games don't cut their frame rate or show low-battery
/// warnings. Returns the number of methods replaced (0–3).
int mulg_identity_install_battery_hooks(void);

/// Media volume (upstream MediaVolume.m): the game reads a fixed output volume instead of the
/// 0 an iOS app sees on a Mac (which makes some games think they are muted), and can't change
/// the Mac's volume through MPVolumeSlider or MPMusicPlayerController. Classes that are not
/// loaded yet are skipped; calling again later installs those. Returns the methods replaced
/// so far (0–6).
int mulg_identity_install_volume_hooks(void);

/// Answers for APIs an iOS app on a Mac can't use (from upstream's device-compatibility file): App Tracking
/// Transparency reports "denied" at once, and Wuthering Waves' age-range request is reported
/// unavailable. Frameworks loaded later are picked up by calling again. Returns methods replaced.
int mulg_identity_install_compat_answers(void);

/// Whether upstream's USE_EXTRA_ANTIJB=1 environment variable asks for the jailbreak bypass.
int mulg_identity_jailbreak_bypass_requested(void);

/// Answers third-party SDKs' jailbreak checks with "not jailbroken" (upstream).
/// Per game, off by default: call only when the game's environment compatibility or `bypass` setting is on or
/// `mulg_identity_jailbreak_bypass_requested()`. SDKs loaded later are picked up by calling
/// again. Returns the number of checks answered so far.
int mulg_identity_install_jailbreak_bypass(void);

/// Number of SDK checks the bypass knows (for diagnostics).
int mulg_identity_jailbreak_bypass_entry_count(void);

/// Arknights: Endfield only (upstream): alerts the game presents are dropped, so
/// its jailbreak warning does not stop it. Returns 1 when installed.
int mulg_identity_install_endfield_alert_fix(const char *_Nullable bundleIdentifier);

/// The output volume games read.
extern const float mulg_identity_reported_volume;

/// Copies a NUL-terminated string into a sysctl-style output buffer with the real
/// sysctl(3) contract (§3.4 bugs b, c, e):
///  - buffer NULL: stores the required length (including the NUL) in *length, returns 0;
///  - *length too small: leaves the buffer untouched, stores zero in *length,
///    sets errno to ENOMEM and returns -1 (XNU's user-space scalar/string transfer);
///  - otherwise: copies the string and its NUL, stores the copied length, returns 0.
/// A NULL length with a non-NULL buffer sets errno to EINVAL and returns -1.
int mulg_sysctl_copy_string(const char *_Nonnull value,
                            void *_Nullable buffer,
                            size_t *_Nullable length);

#ifdef __cplusplus
}
#endif

#endif
