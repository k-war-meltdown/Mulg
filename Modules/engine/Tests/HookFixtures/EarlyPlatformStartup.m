#import "MulgEngineHooks.h"
#include <assert.h>
#include <stdlib.h>
#include <stdio.h>

extern int dyld_get_active_platform(void);

int main(void) {
    // Link the actual interpose dylib at process startup, so libc's own initialization
    // reaches it before the runtime constructor would publish caller classification.
    assert(!mulg_engine_is_game_caller((const void *)&main));
    // Memory compatibility must work for converted app startup even before the
    // general caller cache is ready or an identity profile has been configured.
    assert(mulg_engine_is_game_memory_caller((const void *)&main) == !!TARGET_OS_MACCATALYST);
    assert(!mulg_engine_is_game_memory_caller((const void *)&calloc));
    assert(!mulg_engine_is_game_memory_caller(NULL));
    const int originalPlatform = TARGET_OS_MACCATALYST ? PLATFORM_MACCATALYST : PLATFORM_MACOS;
    assert(dyld_get_active_platform() == originalPlatform);
    void *allocation = calloc(92, 1);
    assert(allocation != NULL);
    free(allocation);
    mulg_engine_prepare_game_callers();
    mulg_engine_prepare_game_callers();
    assert(mulg_engine_is_game_caller((const void *)&main) == !!TARGET_OS_MACCATALYST);
    assert(mulg_engine_is_game_memory_caller((const void *)&main) == !!TARGET_OS_MACCATALYST);
    assert(dyld_get_active_platform() == (TARGET_OS_MACCATALYST ? PLATFORM_IOS : PLATFORM_MACOS));
    puts("PASS: early platform interpose preserves native startup and initializes caller classification later");
    return 0;
}
