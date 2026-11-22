#import "MulgEngineHooks.h"
#include <assert.h>
#include <dlfcn.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
BOOL mulg_engine_is_game_caller(const void *caller) { return NO; }
MulgSwizzleResult mulg_swizzle_checked_owned(const char *owner, Class cls, SEL selector,
    IMP replacement, IMP *previous, const char *returnType, NSArray<NSString *> *arguments) {
    return MulgSwizzleResultMethodMissing;
}
int main(void) {
    @autoreleasepool {
        Dl_info oldProvider, provider;
        assert(dladdr((const void *)NSGetSizeAndAlignment, &oldProvider));
        assert(dladdr((const void *)NSHomeDirectoryForUser, &provider));
        printf("Old anchor: %s\nStorage provider: %s\n", oldProvider.dli_fname, provider.dli_fname);
        fflush(stdout);
        void *native = dlopen(provider.dli_fname, RTLD_LAZY | RTLD_NOLOAD | RTLD_FIRST);
        assert(native);
        NSString *(*home)(void) = dlsym(native, "NSHomeDirectory");
        NSString *(*temporary)(void) = dlsym(native, "NSTemporaryDirectory");
        NSArray *(*search)(NSSearchPathDirectory, NSSearchPathDomainMask, BOOL) = dlsym(native, "NSSearchPathForDirectoriesInDomains");
        assert(home && temporary && search);
        assert([NSHomeDirectory() isEqual:home()]);
        assert([NSTemporaryDirectory() isEqual:temporary()]);
        assert([NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES)
            isEqual:search(NSDocumentDirectory, NSUserDomainMask, YES)]);
        assert(setenv("MULG_STORAGE_PROVIDER_PROBE", "native", 1) == 0);
        assert(strcmp(getenv("MULG_STORAGE_PROVIDER_PROBE"), "native") == 0);
        assert(unsetenv("MULG_STORAGE_PROVIDER_PROBE") == 0);
        assert(getenv("MULG_STORAGE_PROVIDER_PROBE") == NULL);
        // Exercise the exact production exports and their native passthrough, including
        // first-call lookup, create modes, directory calls, errors and joined paths.
        void *system = dlopen("/usr/lib/libSystem.B.dylib", RTLD_LAZY | RTLD_NOLOAD | RTLD_FIRST);
        assert(system);
        DIR *(*systemOpenDirectory)(const char *) = dlsym(system, "opendir");
        assert(systemOpenDirectory && systemOpenDirectory != opendir);
        char folder[] = "/tmp/mulg-file-providers-XXXXXX";
        assert(mkdtemp(folder));
        char file[1024], moved[1024], directory[1024], joined[2048];
        snprintf(file, sizeof(file), "%s/file", folder);
        snprintf(moved, sizeof(moved), "%s/moved", folder);
        snprintf(directory, sizeof(directory), "%s/dir", folder);
        mode_t oldMask = umask(0);
        int fd = open(file, O_CREAT | O_WRONLY | O_TRUNC, 0640);
        umask(oldMask);
        assert(fd >= 0 && write(fd, "x", 1) == 1 && close(fd) == 0);
        struct stat info;
        assert(stat(file, &info) == 0 && (info.st_mode & 0777) == 0640);
        assert(lstat(file, &info) == 0 && info.st_size == 1);
        assert(access(file, R_OK) == 0);
        assert(rename(file, moved) == 0);
        FILE *stream = fopen(moved, "r");
        assert(stream && fgetc(stream) == 'x' && fclose(stream) == 0);
        assert(mkdir(directory, 0700) == 0);
        DIR *listing = opendir(directory);
        assert(listing && closedir(listing) == 0);
        // The SDK/native provider keeps its original address; game adapters retain
        // the Unreal path correction without process-wide interposition.
        // A real home on one volume and moved game data on another must both work.
        // Configuring only the real home left these external joined paths broken.
        mulg_engine_configure_unreal_paths(@[@"/Users/fixture", @(folder)]);
        snprintf(joined, sizeof(joined), "/missing-container/%s/dir", folder);
        listing = opendir(joined);
        assert(listing && closedir(listing) == 0);
        errno = 0;
        assert(systemOpenDirectory(joined) == NULL && errno == ENOENT);
        snprintf(joined, sizeof(joined), "/missing-container/%s/moved", folder);
        fd = open(joined, O_RDONLY);
        assert(fd >= 0 && close(fd) == 0);
        assert(stat(joined, &info) == 0 && info.st_size == 1);
        assert(lstat(joined, &info) == 0 && info.st_size == 1);
        assert(access(joined, R_OK) == 0);
        stream = fopen(joined, "r");
        assert(stream && fgetc(stream) == 'x' && fclose(stream) == 0);
        char joinedFile[2048];
        snprintf(joinedFile, sizeof(joinedFile), "/missing-container/%s/file", folder);
        assert(rename(joined, joinedFile) == 0 && rename(joinedFile, joined) == 0);
        // Single-slash form observed under relocated iOS Documents. Metadata
        // and real reads must agree on the canonical target, without creating
        // the malformed parent tree. No game identifier or fixed volume name.
        char single[4096];
        mulg_engine_configure_game_path_roots(@[@"/Users/fixture", @(folder)], NO);
        snprintf(single, sizeof(single), "%s/Documents%s/moved", folder, folder);
        assert(stat(single, &info) == 0 && info.st_size == 1);
        fd = open(single, O_RDONLY); assert(fd >= 0 && close(fd) == 0);
        stream = fopen(single, "r"); assert(stream && fgetc(stream) == 'x' && fclose(stream) == 0);
        snprintf(single, sizeof(single), "%s/Documents%s/new-dir", folder, folder);
        assert(mkdir(single, 0700) == 0);
        listing = opendir(single); assert(listing && closedir(listing) == 0);
        assert(rmdir(single) == 0);
        mulg_engine_configure_unreal_paths(@[@"/Users/fixture", @(folder)]);
        assert(unlink(joined) == 0);
        assert(rmdir(directory) == 0 && rmdir(folder) == 0);
        mulg_engine_configure_unreal_path_fix(NULL);
        errno = 0;
        assert(open(moved, O_RDONLY) == -1 && errno == ENOENT);
        puts("File adapter passthrough, native isolation and path correction passed.");

        puts("Native storage passthrough passed.");
    }
}
