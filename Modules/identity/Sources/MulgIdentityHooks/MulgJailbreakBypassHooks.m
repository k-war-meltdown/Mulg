//
//  MulgJailbreakBypassHooks.m
//  identity module: the jailbreak-detection bypass from upstream's device-compatibility file (see CREDITS.md).
//
//  An iOS app re-signed and running on a Mac with an injected runtime looks jailbroken to
//  many third-party SDKs, and some games refuse to start because of it. This answers those
//  SDKs' "is this device jailbroken?" methods with "no". Nothing on the Mac is jailbroken or
//  changed; only the answers inside the game process are.
//
//  Per game and off by default (PLAN.md §15 rule 5): on with the game's "Jailbreak bypass"
//  setting (`bypass`, the same toggle upstream used for its sandbox rules), the opt-in
//  identity.environmentBypass mode, or with upstream's
//  USE_EXTRA_ANTIJB=1 environment variable.
//
//  Changes from upstream:
//  - upstream added its pm_* replacement methods to NSObject, so every object in the game had
//    them, and it added missing methods to classes that never had them; this only replaces
//    methods that exist;
//  - upstream pointed two entries (is_rooted, jailbroken) at a replacement that did not exist;
//    they now return nil like the other "no" answers;
//  - one table instead of 58 copies of the same call, so entries are easy to add;
//  - SDKs loaded after start-up are picked up by calling again once the scene is active.
//
//  All the answers are "zero" (NO, false, 0, nil), "one" or an empty string, which on arm64
//  are all returned in x0, so three replacement functions cover every entry.
//

#import "MulgIdentityHooks.h"
#import <Foundation/Foundation.h>
#import <MulgEngineHooks.h>
#include <TargetConditionals.h>

static id mulg_answer_zero(id self, SEL _cmd) {
    return nil;
}

static NSInteger mulg_answer_one(id self, SEL _cmd) {
    return 1;
}

static NSString *mulg_answer_empty_string(id self, SEL _cmd) {
    return @"";
}

typedef enum { MulgAnswerZero, MulgAnswerOne, MulgAnswerEmptyString } MulgAnswer;

typedef struct {
    const char *className;
    const char *selector;
    BOOL classMethod;
    MulgAnswer answer;
    BOOL installed;
} MulgBypassEntry;

#define INSTANCE(cls, sel, answer) { cls, sel, NO, answer, NO }
#define CLASS(cls, sel, answer) { cls, sel, YES, answer, NO }

static MulgBypassEntry bypass_entries[] = {
    // Device information SDKs
    INSTANCE("UIDevice", "platform", MulgAnswerEmptyString),
    INSTANCE("UIDevice", "hwModel", MulgAnswerEmptyString),
    INSTANCE("RNDeviceInfo", "getDeviceType", MulgAnswerOne),
    // Jailbreak checks
    CLASS("UIDevice", "isJailbroken", MulgAnswerZero),
    INSTANCE("UIDevice", "isJailBreak", MulgAnswerZero),
    INSTANCE("UIDevice", "isJailBroken", MulgAnswerZero),
    INSTANCE("JailbreakDetectionVC", "isJailbroken", MulgAnswerZero),
    CLASS("DTTJailbreakDetection", "isJailbroken", MulgAnswerZero),
    INSTANCE("ANSMetadata", "computeIsJailbroken", MulgAnswerZero),
    INSTANCE("ANSMetadata", "isJailbroken", MulgAnswerZero),
    CLASS("AppsFlyerUtils", "isJailBreakon", MulgAnswerZero),
    CLASS("AppsFlyerUtils", "isJailbroken", MulgAnswerZero),
    CLASS("AppsFlyerUtils", "isJailbrokenWithSkipAdvancedJailbreakValidation:", MulgAnswerZero),
    CLASS("jailBreak", "isJailBreak", MulgAnswerZero),
    INSTANCE("GBDeviceInfo", "isJailbroken", MulgAnswerZero),
    INSTANCE("CMARAppRestrictionsDelegate", "isDeviceNonCompliant", MulgAnswerZero),
    CLASS("ADYSecurityChecks", "isDeviceJailbroken", MulgAnswerZero),
    INSTANCE("UBReportMetadataDevice", "is_rooted", MulgAnswerZero),
    CLASS("UtilitySystem", "isJailbreak", MulgAnswerZero),
    CLASS("GemaltoConfiguration", "isJailbreak", MulgAnswerZero),
    INSTANCE("CPWRDeviceInfo", "isJailbroken", MulgAnswerZero),
    INSTANCE("CPWRSessionInfo", "isJailbroken", MulgAnswerZero),
    CLASS("KSSystemInfo", "isJailbroken", MulgAnswerZero),
    INSTANCE("EMDSKPPConfiguration", "jailBroken", MulgAnswerZero),
    INSTANCE("EnrollParameters", "jailbroken", MulgAnswerZero),
    INSTANCE("EMDskppConfigurationBuilder", "jailbreakStatus", MulgAnswerZero),
    INSTANCE("FCRSystemMetadata", "isJailbroken", MulgAnswerZero),
    INSTANCE("v_VDMap", "isJailbrokenDetected", MulgAnswerZero),
    INSTANCE("v_VDMap", "isJailBrokenDetectedByVOS", MulgAnswerZero),
    INSTANCE("v_VDMap", "isDFPHookedDetecedByVOS", MulgAnswerZero),
    INSTANCE("v_VDMap", "isCodeInjectionDetectedByVOS", MulgAnswerZero),
    INSTANCE("v_VDMap", "isDebuggerCheckDetectedByVOS", MulgAnswerZero),
    INSTANCE("v_VDMap", "isAppSignerCheckDetectedByVOS", MulgAnswerZero),
    INSTANCE("v_VDMap", "v_checkAModified", MulgAnswerZero),
    INSTANCE("v_VDMap", "isRuntimeTamperingDetected", MulgAnswerZero),
    INSTANCE("SDMUtils", "isJailBroken", MulgAnswerZero),
    CLASS("OneSignalJailbreakDetection", "isJailbroken", MulgAnswerZero),
    INSTANCE("DigiPassHandler", "rootedDeviceTestResult", MulgAnswerZero),
    INSTANCE("AWMyDeviceGeneralInfo", "isCompliant", MulgAnswerOne),
    INSTANCE("DTXSessionInfo", "isJailbroken", MulgAnswerZero),
    INSTANCE("DTXDeviceInfo", "isJailbroken", MulgAnswerZero),
    INSTANCE("JailbreakDetection", "jailbroken", MulgAnswerZero),
    INSTANCE("jailBrokenJudge", "isJailBreak", MulgAnswerZero),
    INSTANCE("jailBrokenJudge", "isCydiaJailBreak", MulgAnswerZero),
    INSTANCE("jailBrokenJudge", "isApplicationsJailBreak", MulgAnswerZero),
    INSTANCE("jailBrokenJudge", "ischeckCydiaJailBreak", MulgAnswerZero),
    INSTANCE("jailBrokenJudge", "isPathJailBreak", MulgAnswerZero),
    INSTANCE("jailBrokenJudge", "boolIsjailbreak", MulgAnswerZero),
    INSTANCE("FBAdBotDetector", "isJailBrokenDevice", MulgAnswerZero),
    CLASS("TNGDeviceTool", "isJailBreak", MulgAnswerZero),
    CLASS("TNGDeviceTool", "isJailBreak_file", MulgAnswerZero),
    CLASS("TNGDeviceTool", "isJailBreak_cydia", MulgAnswerZero),
    CLASS("TNGDeviceTool", "isJailBreak_appList", MulgAnswerZero),
    CLASS("TNGDeviceTool", "isJailBreak_env", MulgAnswerZero),
    CLASS("DTDeviceInfo", "isJailbreak", MulgAnswerZero),
    CLASS("SecVIDeviceUtil", "isJailbreak", MulgAnswerZero),
    INSTANCE("RVPBridgeExtension4Jailbroken", "isJailbroken", MulgAnswerZero),
    CLASS("ZDetection", "isRootedOrJailbroken", MulgAnswerZero),
};

#undef INSTANCE
#undef CLASS

static IMP answer_implementation(MulgAnswer answer) {
    switch (answer) {
        case MulgAnswerOne: return (IMP)mulg_answer_one;
        case MulgAnswerEmptyString: return (IMP)mulg_answer_empty_string;
        case MulgAnswerZero:
        default: return (IMP)mulg_answer_zero;
    }
}

/// Whether `answer` can stand in for `method`: all three are returned in x0, so the method must return an
/// integer, BOOL, pointer or object (or nothing), never a float (d0) or a struct (memory), and "one" never
/// stands in for an object (the game would get the pointer 0x1) nor "empty string" for a number. SDKs change
/// their signatures between versions; a method that no longer fits keeps its real answer instead of crashing.
static BOOL answer_fits(Method method, MulgAnswer answer) {
    if (method == NULL) return NO;
    char type[32] = {0};
    method_getReturnType(method, type, sizeof type);
    const char *t = type;
    while (*t != '\0' && strchr("rnNoORVA", *t) != NULL) t++;  // Type qualifiers (const, oneway, atomic…).
    if (*t == '\0') return NO;
    switch (answer) {
        case MulgAnswerEmptyString: return *t == '@';
        case MulgAnswerOne: return strchr("cCBsSiIlLqQ", *t) != NULL;
        case MulgAnswerZero:
        default: return *t == 'v' || strchr("cCBsSiIlLqQ@#:^*", *t) != NULL;
    }
}

int mulg_identity_jailbreak_bypass_requested(void) {
    const char *value = getenv("USE_EXTRA_ANTIJB");
    return value != NULL && strcmp(value, "1") == 0;
}

int mulg_identity_install_jailbreak_bypass(void) {
    // Main thread only: called at prepare and again once the scene is active.
    int count = 0;
    for (size_t index = 0; index < sizeof(bypass_entries) / sizeof(bypass_entries[0]); index++) {
        MulgBypassEntry *entry = &bypass_entries[index];
        if (!entry->installed) {
            Class cls = objc_getClass(entry->className);
            if (cls != Nil) {
                SEL selector = sel_registerName(entry->selector);
                Method method = entry->classMethod ? class_getClassMethod(cls, selector) : class_getInstanceMethod(cls, selector);
                if (method != NULL && !answer_fits(method, entry->answer)) continue;
                IMP replacement = answer_implementation(entry->answer);
                MulgSwizzleResult result = entry->classMethod
                    ? mulg_swizzle_class_owned("identity", cls, selector, replacement, NULL)
                    : mulg_swizzle_instance_owned("identity", cls, selector, replacement, NULL);
                entry->installed = result == MulgSwizzleResultReplaced;
            }
        }
        count += entry->installed ? 1 : 0;
    }
    return count;
}

int mulg_identity_jailbreak_bypass_entry_count(void) {
    return (int)(sizeof(bypass_entries) / sizeof(bypass_entries[0]));
}

// MARK: - Arknights: Endfield

#if TARGET_OS_IPHONE
#import <UIKit/UIKit.h>

typedef void (*PresentFunction)(id, SEL, UIViewController *, BOOL, void (^)(void));
static IMP previous_present;

/// Endfield shows a jailbreak alert on a Mac and stops; upstream drops every alert it presents.
static void mulg_endfield_present(UIViewController *self, SEL _cmd, UIViewController *presented, BOOL animated,
                                  void (^completion)(void)) {
    if ([presented isKindOfClass:[UIAlertController class]]) {
        if (completion != nil) {
            completion();
        }
        return;
    }
    ((PresentFunction)previous_present)(self, _cmd, presented, animated, completion);
}
#endif

int mulg_identity_install_endfield_alert_fix(const char *bundleIdentifier) {
#if TARGET_OS_IPHONE
    if (bundleIdentifier == NULL) {
        return 0;
    }
    if (strcmp(bundleIdentifier, "com.gryphline.endfield.ios") != 0 && strcmp(bundleIdentifier, "com.hypergryph.endfield") != 0) {
        return 0;
    }
    static int installed = -1;
    if (installed < 0) {
        installed = mulg_swizzle_instance_owned("identity", [UIViewController class], @selector(presentViewController:animated:completion:),
                                          (IMP)mulg_endfield_present, &previous_present) == MulgSwizzleResultReplaced;
    }
    return installed;
#else
    return 0;
#endif
}
