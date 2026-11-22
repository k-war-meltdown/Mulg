//
//  MulgPlatformInterpose.m
//  engine module: the platform dyld reports to the game (upstream MulgLoader.m).
//
//  Libraries ask dyld which platform the process runs as and change behaviour for Mac Catalyst
//  or iOS-on-Mac. Upstream answered "iOS" for every game, and games and their engines have been
//  tested against that answer, so the engine keeps it.
//

#import "MulgEngineHooks.h"

#include <mach-o/loader.h>

#define MULG_INTERPOSE(replacement, original)                                            \
    __attribute__((used)) static const struct {                                          \
        const void *replacement_function;                                                \
        const void *original_function;                                                   \
    } mulg_interpose_##original __attribute__((section("__DATA,__interpose"))) = {       \
        (const void *)(unsigned long)&replacement, (const void *)(unsigned long)&original \
    };

// Private dyld function (mach-o/dyld_priv.h), declared here as upstream did.
extern int dyld_get_active_platform(void);

int mulg_engine_reported_platform(void) {
    return PLATFORM_IOS;
}

static int mulg_dyld_get_active_platform(void) {
    return mulg_engine_is_game_caller(__builtin_return_address(0)) ? PLATFORM_IOS : dyld_get_active_platform();
}

MULG_INTERPOSE(mulg_dyld_get_active_platform, dyld_get_active_platform)
