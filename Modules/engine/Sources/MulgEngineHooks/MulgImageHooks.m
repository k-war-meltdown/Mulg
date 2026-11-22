#import "MulgEngineHooks.h"
#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <string.h>
#include <stdlib.h>
#include <stdatomic.h>
#include <os/lock.h>
#include <mach/vm_prot.h>

static const char *game_bundle;
/// The bundle folder as the executable path names it, before links are resolved. dyld names loaded
/// images by the path it was given: a game reached through a linked folder (a volume or folder alias)
/// matched neither, and every game call counted as not the game's, so game-only hooks stopped applying.
static const char *game_bundle_given;
static _Atomic(_Bool) game_callers_ready;

BOOL mulg_engine_is_game_image(const char *image, const char *bundle) {
    size_t length = strlen(bundle);
    return length > 0 && strncmp(image, bundle, length) == 0 && image[length] == '/'
        && strstr(image, "/MulgRuntime.framework/") == NULL
        && strstr(image, "/MulgKit.framework/") == NULL
        && strstr(image, "/MulgKit.dylib") == NULL
        && strstr(image, "/MulgBridge.bundle/") == NULL
        && strstr(image, "/MulgAppKit.bundle/") == NULL;
}

BOOL mulg_engine_image_uses_ios_platform(const struct mach_header *header) {
    if (header == NULL || (header->magic != MH_MAGIC_64 && header->magic != MH_MAGIC)) return NO;
    size_t offset = header->magic == MH_MAGIC_64 ? sizeof(struct mach_header_64) : sizeof(struct mach_header);
    const uint8_t *cursor = (const uint8_t *)header + offset;
    size_t remaining = header->sizeofcmds;
    for (uint32_t i = 0; i < header->ncmds; i++) {
        if (remaining < sizeof(struct load_command)) return NO;
        const struct load_command *command = (const struct load_command *)cursor;
        if (command->cmdsize < sizeof(*command) || command->cmdsize > remaining) return NO;
        if (command->cmd == LC_BUILD_VERSION && command->cmdsize >= sizeof(struct build_version_command)) {
            uint32_t platform = ((const struct build_version_command *)command)->platform;
            return platform == PLATFORM_IOS || platform == PLATFORM_MACCATALYST;
        }
        if (command->cmd == LC_VERSION_MIN_IPHONEOS) return YES;
        if (command->cmd == LC_VERSION_MIN_MACOSX) return NO;
        remaining -= command->cmdsize;
        cursor += command->cmdsize;
    }
    return NO;
}

// MARK: - Caller classification

// Hooks ask "is this call from the game?" on hot paths (screen metrics, controller reads,
// identity, Keychain, graphics). dladdr searches the image's symbol table, which is slow in
// a 300 MB stripped game binary, so each image's code range is classified once and then found
// by a lock-free binary search. Snapshots are immutable and never freed: readers may still hold
// one, and there are only as many as images that ever call a hook (bounded by kMaxRanges).

typedef struct { uintptr_t start, end; bool game; } MulgCodeRange;
typedef struct { size_t count; MulgCodeRange ranges[]; } MulgCodeRanges;

enum { kMaxRanges = 256 };
static const MulgCodeRanges no_ranges = { 0 };
static _Atomic(const MulgCodeRanges *) code_ranges = &no_ranges;
static _Atomic(unsigned) ranges_generation;
static os_unfair_lock ranges_lock = OS_UNFAIR_LOCK_INIT;
static bool any_platform_for_testing;

static bool ranges_overlap(uintptr_t start, uintptr_t end, uintptr_t otherStart, uintptr_t otherEnd) {
    return start < otherEnd && otherStart < end;
}

/// The executable segments of a still-mapped image (dyld calls the remove callback before unmapping).
static size_t executable_segments(const struct mach_header *header, uintptr_t starts[], uintptr_t ends[], size_t capacity) {
    if (header == NULL || header->magic != MH_MAGIC_64) return 0;
    intptr_t slide = 0;
    bool haveText = false;
    size_t found = 0;
    for (uint32_t pass = 0; pass < 2; pass++) {
        const uint8_t *cursor = (const uint8_t *)header + sizeof(struct mach_header_64);
        size_t remaining = header->sizeofcmds;
        for (uint32_t i = 0; i < header->ncmds; i++) {
            if (remaining < sizeof(struct load_command)) return found;
            const struct load_command *command = (const struct load_command *)cursor;
            if (command->cmdsize < sizeof(*command) || command->cmdsize > remaining) return found;
            if (command->cmd == LC_SEGMENT_64 && command->cmdsize >= sizeof(struct segment_command_64)) {
                const struct segment_command_64 *segment = (const struct segment_command_64 *)command;
                if (pass == 0 && strncmp(segment->segname, "__TEXT", 16) == 0) {
                    slide = (intptr_t)header - (intptr_t)segment->vmaddr;
                    haveText = true;
                } else if (pass == 1 && (segment->initprot & VM_PROT_EXECUTE) && found < capacity) {
                    starts[found] = (uintptr_t)((intptr_t)segment->vmaddr + slide);
                    ends[found] = starts[found] + (uintptr_t)segment->vmsize;
                    found++;
                }
            }
            remaining -= command->cmdsize;
            cursor += command->cmdsize;
        }
        if (!haveText) return 0;
    }
    return found;
}

/// An unloaded image's range may be reused by another image, so its ranges are dropped. Only its own: the
/// whole cache used to be discarded, and rebuilding it allocated one snapshot per range (snapshots are never
/// freed, readers may hold them), so every unload leaked the square of the cached ranges, up to ~0.8 MB.
/// Without a readable header (or from the test hook, header NULL) everything is forgotten, as before.
static void image_removed(const struct mach_header *header, intptr_t slide) {
    (void)slide;
    atomic_fetch_add_explicit(&ranges_generation, 1, memory_order_acq_rel);
    uintptr_t starts[16], ends[16];
    size_t segments = executable_segments(header, starts, ends, 16);
    os_unfair_lock_lock(&ranges_lock);
    const MulgCodeRanges *current = atomic_load_explicit(&code_ranges, memory_order_acquire);
    const MulgCodeRanges *next = &no_ranges;
    // A full list may be missing segments, whose stale ranges a later image at that address would inherit:
    // then everything is forgotten, as for an unreadable header.
    if (segments > 0 && segments < 16 && current->count > 0) {
        MulgCodeRanges *kept = malloc(sizeof(MulgCodeRanges) + current->count * sizeof(MulgCodeRange));
        if (kept) {
            size_t count = 0;
            for (size_t i = 0; i < current->count; i++) {
                bool removed = false;
                for (size_t s = 0; s < segments && !removed; s++) {
                    removed = ranges_overlap(current->ranges[i].start, current->ranges[i].end, starts[s], ends[s]);
                }
                if (!removed) kept->ranges[count++] = current->ranges[i];
            }
            kept->count = count;
            if (count == current->count) { free(kept); next = current; } // Nothing of it was cached.
            else if (count == 0) { free(kept); }
            else { next = kept; }
        }
    }
    atomic_store_explicit(&code_ranges, next, memory_order_release);
    os_unfair_lock_unlock(&ranges_lock);
}

void mulg_engine_prepare_game_callers(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // Called by the runtime constructor after libSystem's allocator has initialized.
        uint32_t size = 0;
        _NSGetExecutablePath(NULL, &size);
        char *path = calloc(size + 1, 1);
        if (path && _NSGetExecutablePath(path, &size) == 0) {
            char *given = strdup(path);
            if (given) {
                char *slash = strrchr(given, '/');
                if (slash) *slash = 0;
            }
            game_bundle_given = given ? given : "";
            char *resolved = realpath(path, NULL);
            if (resolved) { free(path); path = resolved; }
            char *end = strrchr(path, '/');
            if (end) *end = 0;
            game_bundle = path;
        } else { free(path); game_bundle = ""; game_bundle_given = ""; }
        _dyld_register_func_for_remove_image(image_removed);
        atomic_store_explicit(&game_callers_ready, 1, memory_order_release);
    });
}

void mulg_engine_set_game_callers_for_testing(const char *bundle, BOOL anyPlatform) {
    mulg_engine_prepare_game_callers();
    game_bundle = strdup(bundle);
    game_bundle_given = game_bundle;
    any_platform_for_testing = anyPlatform;
    image_removed(NULL, 0);
}

BOOL mulg_engine_code_range(const struct mach_header *header, const void *address,
                            uintptr_t *start, uintptr_t *end) {
    if (header == NULL || header->magic != MH_MAGIC_64) return NO;
    const uint8_t *cursor = (const uint8_t *)header + sizeof(struct mach_header_64);
    // Segments move by one slide, also when the shared cache places them far apart.
    intptr_t slide = 0;
    bool haveText = false;
    for (uint32_t pass = 0; pass < 2; pass++) {
        cursor = (const uint8_t *)header + sizeof(struct mach_header_64);
        size_t remaining = header->sizeofcmds;
        for (uint32_t i = 0; i < header->ncmds; i++) {
            if (remaining < sizeof(struct load_command)) return NO;
            const struct load_command *command = (const struct load_command *)cursor;
            if (command->cmdsize < sizeof(*command) || command->cmdsize > remaining) return NO;
            if (command->cmd == LC_SEGMENT_64 && command->cmdsize >= sizeof(struct segment_command_64)) {
                const struct segment_command_64 *segment = (const struct segment_command_64 *)command;
                if (pass == 0 && strncmp(segment->segname, "__TEXT", 16) == 0) {
                    slide = (intptr_t)header - (intptr_t)segment->vmaddr;
                    haveText = true;
                } else if (pass == 1 && (segment->initprot & VM_PROT_EXECUTE)) {
                    uintptr_t low = (uintptr_t)((intptr_t)segment->vmaddr + slide);
                    if ((uintptr_t)address >= low && (uintptr_t)address - low < segment->vmsize) {
                        *start = low;
                        *end = low + (uintptr_t)segment->vmsize;
                        return YES;
                    }
                }
            }
            remaining -= command->cmdsize;
            cursor += command->cmdsize;
        }
        if (!haveText) return NO;
    }
    return NO;
}

/// -1 unknown, else whether `address` lies in a game image's code.
static int cached_answer(const MulgCodeRanges *ranges, uintptr_t address) {
    size_t low = 0, high = ranges->count;
    while (low < high) {
        size_t middle = low + (high - low) / 2;
        const MulgCodeRange *range = &ranges->ranges[middle];
        if (address < range->start) high = middle;
        else if (address >= range->end) low = middle + 1;
        else return range->game;
    }
    return -1;
}

/// Publishes a snapshot with one more range, unless an image was unloaded since `generation`.
static void remember_range(uintptr_t start, uintptr_t end, bool game, unsigned generation) {
    os_unfair_lock_lock(&ranges_lock);
    const MulgCodeRanges *current = atomic_load_explicit(&code_ranges, memory_order_acquire);
    if (atomic_load_explicit(&ranges_generation, memory_order_acquire) == generation
        && current->count < kMaxRanges && cached_answer(current, start) < 0) {
        MulgCodeRanges *next = malloc(sizeof(MulgCodeRanges) + (current->count + 1) * sizeof(MulgCodeRange));
        if (next) {
            size_t insert = 0;
            while (insert < current->count && current->ranges[insert].start < start) insert++;
            memcpy(next->ranges, current->ranges, insert * sizeof(MulgCodeRange));
            next->ranges[insert] = (MulgCodeRange){ start, end, game };
            memcpy(next->ranges + insert + 1, current->ranges + insert, (current->count - insert) * sizeof(MulgCodeRange));
            next->count = current->count + 1;
            // An unload between the check and here wins: its empty snapshot stays.
            if (!atomic_compare_exchange_strong_explicit(&code_ranges, &current, next,
                                                         memory_order_acq_rel, memory_order_acquire)) free(next);
            // The swap also succeeds when the unload replaced the shared empty snapshot with itself;
            // the unload bumps the generation first, so a changed one means this range is stale.
            else if (atomic_load_explicit(&ranges_generation, memory_order_acquire) != generation)
                atomic_store_explicit(&code_ranges, &no_ranges, memory_order_release);
        }
    }
    os_unfair_lock_unlock(&ranges_lock);
}

/// dladdr, outside any lock of ours: a dyld initializer can call a hook while dyld's lock is held.
static BOOL classify_caller(const void *caller) {
    unsigned generation = atomic_load_explicit(&ranges_generation, memory_order_acquire);
    Dl_info info;
    if (dladdr(caller, &info) == 0 || info.dli_fname == NULL || info.dli_fbase == NULL) return NO;
    const struct mach_header *header = (const struct mach_header *)info.dli_fbase;
    BOOL inBundle = mulg_engine_is_game_image(info.dli_fname, game_bundle)
        || (game_bundle_given && mulg_engine_is_game_image(info.dli_fname, game_bundle_given));
    if (!inBundle && strncmp(info.dli_fname, "/System/", 8) != 0 && strncmp(info.dli_fname, "/usr/lib/", 9) != 0) {
        // Once per image (the answer is cached by range): the image's own path with links resolved.
        // Apple's libraries are skipped: never the game, and most are in the shared cache, not on disk.
        char *resolved = realpath(info.dli_fname, NULL);
        if (resolved) {
            inBundle = mulg_engine_is_game_image(resolved, game_bundle);
            free(resolved);
        }
    }
    BOOL game = inBundle && (any_platform_for_testing || mulg_engine_image_uses_ios_platform(header));
    uintptr_t start, end;
    if (mulg_engine_code_range(header, caller, &start, &end)) remember_range(start, end, game, generation);
    return game;
}

BOOL mulg_engine_is_game_caller(const void *caller) {
    // dyld interposes this even during libSystem initialization. Do not touch malloc,
    // dispatch, thread-local storage or loader APIs until the constructor publishes readiness.
    if (!atomic_load_explicit(&game_callers_ready, memory_order_acquire) || caller == NULL) return NO;
    // One cached call site per thread, valid until an image is unloaded.
    static __thread const void *last;
    static __thread BOOL answer;
    static __thread unsigned lastGeneration;
    unsigned generation = atomic_load_explicit(&ranges_generation, memory_order_relaxed);
    if (last == caller && lastGeneration == generation) return answer;
    int cached = cached_answer(atomic_load_explicit(&code_ranges, memory_order_acquire), (uintptr_t)caller);
    answer = cached >= 0 ? cached : classify_caller(caller);
    last = caller;
    lastGeneration = generation;
    return answer;
}

BOOL mulg_engine_is_game_memory_caller(const void *caller) {
    if (caller == NULL) return NO;
    if (atomic_load_explicit(&game_callers_ready, memory_order_acquire))
        return mulg_engine_is_game_caller(caller);

    // os_proc_available_memory can be called from a game's +load before our C
    // constructor. Its libSystem call has already returned, but the general caller
    // cache is deliberately not ready. Inspect existing loader metadata only here;
    // do not relax the early guard on allocation/dispatch/platform/Keychain hooks.
    const struct mach_header *main = _dyld_get_image_header(0);
    if (!mulg_engine_image_uses_ios_platform(main)) return NO;
    uintptr_t start, end;
    if (mulg_engine_code_range(main, caller, &start, &end)) return YES;
    const char *executable = _dyld_get_image_name(0);
    if (executable == NULL) return NO;
    const char *slash = strrchr(executable, '/');
    if (slash == NULL) return NO;
    size_t length = (size_t)(slash - executable);
    uint32_t count = _dyld_image_count();
    for (uint32_t i = 1; i < count; i++) {
        const struct mach_header *header = _dyld_get_image_header(i);
        if (!mulg_engine_code_range(header, caller, &start, &end)) continue;
        const char *image = _dyld_get_image_name(i);
        return image != NULL && strncmp(image, executable, length) == 0
            && image[length] == '/' && mulg_engine_image_uses_ios_platform(header)
            && strstr(image, "/MulgRuntime.framework/") == NULL
            && strstr(image, "/MulgKit.framework/") == NULL
            && strstr(image, "/MulgKit.dylib") == NULL
            && strstr(image, "/MulgBridge.bundle/") == NULL
            && strstr(image, "/MulgAppKit.bundle/") == NULL;
    }
    return NO;
}

static dispatch_source_t image_source;
static void image_added(const struct mach_header *header, intptr_t slide) {
    // dyld holds its loader lock here: only enqueue work, never inspect classes or swizzle.
    dispatch_source_merge_data(image_source, 1);
}

void mulg_engine_observe_images(void (^handler)(void)) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        image_source = dispatch_source_create(DISPATCH_SOURCE_TYPE_DATA_OR, 0, 0, dispatch_get_main_queue());
        dispatch_source_set_event_handler(image_source, handler);
        dispatch_resume(image_source);
        _dyld_register_func_for_add_image(image_added);
    });
}
