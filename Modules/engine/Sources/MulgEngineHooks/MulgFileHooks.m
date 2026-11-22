//
//  MulgFileHooks.m
//  engine module: file-call hooks for the Unreal Engine path fix.
//
//  Fixes two upstream problems in MulgLoader.m (PLAN.md §16.2):
//   E1. open() dropped the permission argument unless the flags were exactly O_CREAT, so
//       the common O_CREAT | O_WRONLY | O_TRUNC created files with an undefined mode.
//   E2. every file call in every game rebuilt the Unreal pattern with getlogin_r(). Now the
//       pattern is built once, from the real home folder, and non-Unreal games only pay
//       one atomic load per call.
//
//  Unreal Engine games sometimes join two absolute paths, producing paths such as
//  "/Users/a/Library/Containers/x/Data//Users/a/Documents/file". The fix keeps the part
//  from the last "//<home>" on.
//
//  These hooks replace upstream's versions and must never be loaded into the same game as
//  upstream MulgKit's MulgLoader.m.
//

#import "MulgEngineHooks.h"
#import "MulgGameDataHooks.h"

#include <dirent.h>
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/mount.h>
#include <sys/statvfs.h>
#include <unistd.h>

// File adapters are explicitly linked by the installer. Global interposition also
// changed SDK and native framework imports, even when the path fix was disabled.
// Resolve passthrough from libSystem itself, once, so these exports cannot recurse.
static void *nativeFileFunction(const char *name) {
    int savedErrno = errno;
    static void *system;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ system = dlopen("/usr/lib/libSystem.B.dylib", RTLD_LAZY | RTLD_NOLOAD | RTLD_FIRST); });
    void *function = system ? dlsym(system, name) : NULL;
    if (!function) {
        fprintf(stderr, "Mulg: native file API unavailable: %s\n", name);
        _exit(78);
    }
    errno = savedErrno;
    return function;
}
#define MULG_NATIVE_FILE(name) \
    static __typeof__(&name) native_##name(void) { \
        static __typeof__(&name) function; \
        static dispatch_once_t once; \
        dispatch_once(&once, ^{ function = nativeFileFunction(#name); }); \
        return function; \
    }

// Immutable snapshots keep worker-thread file calls independent of configuration.
// Four roots cover real home, sandbox home, bundle and relocated game data. Keep old
// snapshots alive, as readers can still be using them after a new publication.
typedef struct {
    size_t count;
    BOOL repairDoubleSlash;
    char *patterns[4];
    /// strlen(patterns[i] + 1), fixed with the snapshot: the hot path never measures a root again.
    size_t lengths[4];
} MulgUnrealPaths;
static _Atomic(const MulgUnrealPaths *) mulg_unreal_paths;

void mulg_engine_configure_game_path_roots(NSArray<NSString *> *roots, BOOL legacyUnreal) {
    if (roots.count == 0) {
        atomic_store_explicit(&mulg_unreal_paths, NULL, memory_order_release);
        return;
    }
    MulgUnrealPaths *next = calloc(1, sizeof(*next));
    if (!next) return; // Keep the last complete configuration on allocation failure.
    next->repairDoubleSlash = legacyUnreal;
    for (NSString *root in roots) {
        const char *path = root.UTF8String;
        if (!path || path[0] != '/') continue;
        size_t length = strlen(path);
        while (length > 1 && path[length - 1] == '/') --length;
        // "/" would match every doubled slash, including unrelated resource paths.
        if (length <= 1) continue;
        BOOL duplicate = NO;
        for (size_t i = 0; i < next->count; ++i)
            if (next->lengths[i] == length &&
                memcmp(next->patterns[i] + 1, path, length) == 0) duplicate = YES;
        if (duplicate) continue;
        if (next->count == 4) break;
        char *pattern = malloc(length + 2);
        if (!pattern) {
            for (size_t i = 0; i < next->count; ++i) free(next->patterns[i]);
            free(next);
            return;
        }
        pattern[0] = '/'; memcpy(pattern + 1, path, length); pattern[length + 1] = '\0';
        next->lengths[next->count] = length;
        next->patterns[next->count++] = pattern;
    }
    if (next->count == 0) { free(next); next = NULL; }
    atomic_store_explicit(&mulg_unreal_paths, next, memory_order_release);
}

void mulg_engine_configure_unreal_paths(NSArray<NSString *> *roots) {
    mulg_engine_configure_game_path_roots(roots, YES);
}

void mulg_engine_configure_unreal_path_fix(const char *homeDirectory) {
    NSString *home = homeDirectory ? [NSString stringWithUTF8String:homeDirectory] : nil;
    mulg_engine_configure_unreal_paths(home ? @[home] : nil);
}

// Unreal sometimes removes the leading slash before appending an already
// absolute path to Documents/Library. Accept that form only immediately under
// a configured game-owned root and a standard writable directory. An arbitrary
// backup such as <data>/Archive/Volumes/... must keep its literal meaning.
static BOOL owned_directory_prefix(const char *base, const char *end, const MulgUnrealPaths *paths) {
    if (!base || end <= base) return NO;
    while (end > base && end[-1] == '/') --end;
    static const char *const directories[] = { "/Documents", "/Library", "/Library/Caches", "/Library/Application Support", "/tmp" };
    static const size_t directoryLengths[] = { sizeof("/Documents") - 1, sizeof("/Library") - 1, sizeof("/Library/Caches") - 1,
        sizeof("/Library/Application Support") - 1, sizeof("/tmp") - 1 };
    size_t length = (size_t)(end - base);
    for (size_t i = 0; i < paths->count; ++i) {
        const char *root = paths->patterns[i] + 1;
        size_t rootLength = paths->lengths[i];
        if (rootLength >= length || memcmp(base, root, rootLength)) continue;
        for (size_t j = 0; j < sizeof(directories) / sizeof(*directories); ++j) {
            size_t suffixLength = directoryLengths[j];
            if (length == rootLength + suffixLength &&
                memcmp(base + rootLength, directories[j], suffixLength) == 0) return YES;
        }
    }
    return NO;
}

const char *mulg_engine_fix_path(const char *path) {
    const MulgUnrealPaths *paths = path ? atomic_load_explicit(&mulg_unreal_paths, memory_order_acquire) : NULL;
    if (paths == NULL) return path;
    const char *last = NULL;
    // Scan left-to-right so repeated joins are independent of root ordering.
    for (const char *cursor = path + (path[0] != '\0'); *cursor; ++cursor) {
        if (*cursor != '/') continue;
        for (size_t i = 0; i < paths->count; ++i) {
            const char *root = paths->patterns[i] + 1;
            size_t length = paths->lengths[i];
            // Roots start with '/' like the cursor: their second byte rejects almost every slash at once.
            if (cursor[1] != root[1] || strncmp(cursor, root, length)) continue;
            char boundary = cursor[length];
            if (boundary != '/' && boundary != '\0') continue;
            if ((paths->repairDoubleSlash && cursor[-1] == '/') || owned_directory_prefix(path, cursor, paths)
                || owned_directory_prefix(last, cursor, paths)) last = cursor;
        }
    }
    return last != NULL ? last : path;
}

// MARK: - Replacements

// Explicit game imports only; native frameworks retain their own API providers.
MULG_NATIVE_FILE(statfs)
__attribute__((visibility("default"))) int statfs(const char *path, struct statfs *buffer) {
    return native_statfs()(mulg_engine_storage_capacity_path(mulg_engine_fix_path(path)), buffer);
}

MULG_NATIVE_FILE(statvfs)
__attribute__((visibility("default"))) int statvfs(const char *path, struct statvfs *buffer) {
    return native_statvfs()(mulg_engine_storage_capacity_path(mulg_engine_fix_path(path)), buffer);
}

MULG_NATIVE_FILE(open)
__attribute__((visibility("default"))) int open(const char *path, int flags, ...) {
    path = mulg_engine_fix_path(path);
    if (flags & O_CREAT) {
        // E1: the mode must be passed whenever O_CREAT is set, whatever else is set.
        va_list arguments;
        va_start(arguments, flags);
        int mode = va_arg(arguments, int);
        va_end(arguments);
        return native_open()(path, flags, mode);
    }
    // A plain pass-through, as in build 864. Build 865 also recorded every read-only game open
    // here (a dladdr per call site on game threads) while warming the game's own asset blocks;
    // Genshin then livelocked when its world finished loading. Never add work to this path.
    return native_open()(path, flags);
}

MULG_NATIVE_FILE(stat)
__attribute__((visibility("default"))) int stat(const char *path, struct stat *buffer) {
    return native_stat()(mulg_engine_fix_path(path), buffer);
}

MULG_NATIVE_FILE(access)
__attribute__((visibility("default"))) int access(const char *path, int mode) {
    return native_access()(mulg_engine_fix_path(path), mode);
}

MULG_NATIVE_FILE(rename)
__attribute__((visibility("default"))) int rename(const char *oldPath, const char *newPath) {
    return native_rename()(mulg_engine_fix_path(oldPath), mulg_engine_fix_path(newPath));
}

MULG_NATIVE_FILE(unlink)
__attribute__((visibility("default"))) int unlink(const char *path) {
    return native_unlink()(mulg_engine_fix_path(path));
}

// Unreal creates, lists and removes save and cache folders with these; a joined path failed
// here while open() on the same path was fixed.
MULG_NATIVE_FILE(mkdir)
__attribute__((visibility("default"))) int mkdir(const char *path, mode_t mode) {
    return native_mkdir()(mulg_engine_fix_path(path), mode);
}

MULG_NATIVE_FILE(rmdir)
__attribute__((visibility("default"))) int rmdir(const char *path) {
    return native_rmdir()(mulg_engine_fix_path(path));
}

MULG_NATIVE_FILE(lstat)
__attribute__((visibility("default"))) int lstat(const char *path, struct stat *buffer) {
    return native_lstat()(mulg_engine_fix_path(path), buffer);
}

MULG_NATIVE_FILE(opendir)
__attribute__((visibility("default"))) DIR * opendir(const char *path) {
    return native_opendir()(mulg_engine_fix_path(path));
}

// fopen can reach the kernel without passing through the open() hook.
MULG_NATIVE_FILE(fopen)
__attribute__((visibility("default"))) FILE * fopen(const char *path, const char *mode) {
    return native_fopen()(mulg_engine_fix_path(path), mode);
}
