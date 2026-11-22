#import "MulgGameDataHooks.h"
#import "MulgEngineHooks.h"
#import <objc/runtime.h>
#include <dlfcn.h>
#include <stdio.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static NSString *originalHome;
static NSString *originalHomePrefix;
static NSString *storageHome;
static NSString *storageTemporaryPath, *storageTemporaryDirectory;
static NSArray<NSURL *> *containerScratch;  // container folders for replacement folders (see mulg_engine_replacement_base)
static char *storageHomeBytes;
static char *originalHomeBytes, *storageVolumeBytes;
static size_t originalHomeByteLength, storageHomeByteLength;
static _Atomic(bool) storageReady;
static IMP originalURLs, originalURL, originalHomeURL, originalTemporaryURL;
static IMP originalFilesystemAttributes, originalResourceValue, originalResourceValues;
static IMP originalAppendPath, originalAppendStoredPath, originalAppendURL, originalAppendDirectoryURL;
static IMP originalCreateDirectoryPath, originalCreateDirectoryURL;

// NSGetSizeAndAlignment lives in CoreFoundation; the unmodified home-for-user API
// identifies Foundation itself for the three native storage functions.
// Explicitly linked game storage adapters, not global interposes. Native framework
// imports keep their providers; explicit handles keep passthrough from calling us.
static void *nativeStorageFunction(const void *anchor, const char *symbol) {
    Dl_info provider;
    void *handle = dladdr(anchor, &provider) ? dlopen(provider.dli_fname, RTLD_LAZY | RTLD_NOLOAD | RTLD_FIRST) : NULL;
    void *function = handle ? dlsym(handle, symbol) : NULL;
    if (!function) {
        fprintf(stderr, "Mulg: native storage API unavailable: %s\n", symbol);
        _exit(78);
    }
    return function; // The provider remains loaded for the process lifetime.
}
static NSString *nativeHome(void) {
    static NSString *(*function)(void);
    static dispatch_once_t once;
    dispatch_once(&once, ^{ function = nativeStorageFunction((const void *)NSHomeDirectoryForUser, "NSHomeDirectory"); });
    return function();
}
static NSString *nativeTemporary(void) {
    static NSString *(*function)(void);
    static dispatch_once_t once;
    dispatch_once(&once, ^{ function = nativeStorageFunction((const void *)NSHomeDirectoryForUser, "NSTemporaryDirectory"); });
    return function();
}

static NSString *mappedPath(NSString *path) {
    if (!atomic_load_explicit(&storageReady, memory_order_acquire)) return path;
    if ([path isEqualToString:originalHome]) return storageHome;
    if ([path hasPrefix:originalHomePrefix])
        return [storageHome stringByAppendingString:[path substringFromIndex:originalHome.length]];
    return path;
}

static bool pathWithin(const char *path, const char *root, size_t length) {
    if (!path || !root) return false;
    return strncmp(path, root, length) == 0 && (path[length] == '/' || path[length] == '\0');
}

// /var is the iOS writable data volume. On macOS it names the Mac's
// internal data volume instead, even when the game's data is on another disk.
// Match only the volume root (with optional trailing slashes), never its children.
static bool isMobileDataVolume(const char *path) {
    const char *suffix = NULL;
    if (strncmp(path, "/var", 4) == 0) suffix = path + 4;
    else if (strncmp(path, "/private/var", 12) == 0) suffix = path + 12;
    if (!suffix) return false;
    while (*suffix == '/') ++suffix;
    return *suffix == '\0';
}

const char *mulg_engine_storage_capacity_path(const char *path) {
    if (!path || !atomic_load_explicit(&storageReady, memory_order_acquire)) return path;
    // iOS games treat root, container and data as one writable filesystem. Probe
    // the actual data root after relocation, even before a download subfolder
    // exists. All capacity, full-disk, read-only and error values remain native.
    if (strcmp(path, "/") == 0 || isMobileDataVolume(path)
        || pathWithin(path, originalHomeBytes, originalHomeByteLength)
        || pathWithin(path, storageHomeBytes, storageHomeByteLength)
        || (storageVolumeBytes && strcmp(path, storageVolumeBytes) == 0)) return storageHomeBytes;
    return path;
}

static NSString *capacityPath(NSString *path) {
    if (!path) return path;
    const char *bytes = path.UTF8String;
    return mulg_engine_storage_capacity_path(bytes) != bytes ? storageHome : path;
}

// Use the same owned-root rule at Foundation's path-building boundary as the C
// file adapters. Otherwise Foundation can create a literal Documents/Volumes/...
// tree while C reads the canonical path, splitting downloads from their metadata.
static NSString *fixedGamePath(NSString *path) {
    if (!path) return path;
    // A pure-ASCII string's own bytes are its file-system representation: no autoreleased copy for the
    // common case on this per-append path. Anything else takes Foundation's conversion.
    const char *bytes = CFStringGetCStringPtr((__bridge CFStringRef)path, kCFStringEncodingASCII) ?: path.fileSystemRepresentation;
    const char *fixed = mulg_engine_fix_path(bytes);
    return fixed != bytes ? [[NSFileManager defaultManager] stringWithFileSystemRepresentation:fixed length:strlen(fixed)] : path;
}

static NSURL *fixedGameURL(NSURL *url) {
    if (!url.isFileURL) return url;
    NSString *path = url.path, *fixed = fixedGamePath(path);
    if (fixed == path) return url;
    // Preserve URL query/fragment and directory intent, including escaped spaces.
    NSURLComponents *components = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    NSURL *file = [NSURL fileURLWithPath:fixed isDirectory:url.hasDirectoryPath];
    components.percentEncodedPath = [NSURLComponents componentsWithURL:file resolvingAgainstBaseURL:NO].percentEncodedPath;
    return components.URL ?: url;
}

@interface NSString (MulgGamePath)
- (NSString *)mulg_gameAppendingPathComponent:(NSString *)component;
- (NSString *)mulg_gameAppendingStoredPathComponent:(NSString *)component;
@end
@implementation NSString (MulgGamePath)
- (NSString *)mulg_gameAppendingStoredPathComponent:(NSString *)component {
    NSString *result = ((NSString *(*)(id, SEL, NSString *))originalAppendStoredPath)(self, @selector(stringByAppendingPathComponent:), component);
    return mulg_engine_is_game_caller(__builtin_return_address(0)) ? fixedGamePath(result) : result;
}
- (NSString *)mulg_gameAppendingPathComponent:(NSString *)component {
    NSString *result = ((NSString *(*)(id, SEL, NSString *))originalAppendPath)(self, @selector(stringByAppendingPathComponent:), component);
    return mulg_engine_is_game_caller(__builtin_return_address(0)) ? fixedGamePath(result) : result;
}
@end

@interface NSURL (MulgGamePath)
- (NSURL *)mulg_gameAppendingPathComponent:(NSString *)component;
- (NSURL *)mulg_gameAppendingPathComponent:(NSString *)component isDirectory:(BOOL)directory;
@end
@implementation NSURL (MulgGamePath)
- (NSURL *)mulg_gameAppendingPathComponent:(NSString *)component {
    NSURL *result = ((NSURL *(*)(id, SEL, NSString *))originalAppendURL)(self, @selector(URLByAppendingPathComponent:), component);
    return mulg_engine_is_game_caller(__builtin_return_address(0)) ? fixedGameURL(result) : result;
}
- (NSURL *)mulg_gameAppendingPathComponent:(NSString *)component isDirectory:(BOOL)directory {
    NSURL *result = ((NSURL *(*)(id, SEL, NSString *, BOOL))originalAppendDirectoryURL)(self, @selector(URLByAppendingPathComponent:isDirectory:), component, directory);
    return mulg_engine_is_game_caller(__builtin_return_address(0)) ? fixedGameURL(result) : result;
}
@end

static BOOL capacityKey(NSURLResourceKey key) {
    return [key isEqual:NSURLVolumeAvailableCapacityKey] || [key isEqual:NSURLVolumeTotalCapacityKey]
        || [key isEqual:NSURLVolumeAvailableCapacityForImportantUsageKey]
        || [key isEqual:NSURLVolumeAvailableCapacityForOpportunisticUsageKey];
}

@interface NSURL (MulgStorageCapacity)
- (BOOL)mulg_storageGetResourceValue:(id __autoreleasing *)value forKey:(NSURLResourceKey)key error:(NSError **)error;
- (NSDictionary *)mulg_storageResourceValuesForKeys:(NSArray<NSURLResourceKey> *)keys error:(NSError **)error;
@end
@implementation NSURL (MulgStorageCapacity)
- (BOOL)mulg_storageGetResourceValue:(id __autoreleasing *)value forKey:(NSURLResourceKey)key error:(NSError **)error {
    NSURL *target = self;
    if (self.isFileURL && capacityKey(key) && mulg_engine_is_game_caller(__builtin_return_address(0))) {
        NSString *path = self.path, *mapped = capacityPath(path);
        if (mapped != path) target = [NSURL fileURLWithPath:mapped isDirectory:YES];
    }
    return ((BOOL (*)(id, SEL, id __autoreleasing *, NSURLResourceKey, NSError **))originalResourceValue)(target,
        @selector(getResourceValue:forKey:error:), value, key, error);
}
- (NSDictionary *)mulg_storageResourceValuesForKeys:(NSArray<NSURLResourceKey> *)keys error:(NSError **)error {
    if (self.isFileURL && mulg_engine_is_game_caller(__builtin_return_address(0))) {
        BOOL requestsCapacity = NO;
        for (NSURLResourceKey key in keys) {
            if (capacityKey(key)) { requestsCapacity = YES; break; }
        }
        if (!requestsCapacity) {
            // Names, dates and file sizes never need the relocated volume's capacity.
            // Keep the original URL/keys and avoid path conversion and partition arrays.
            return ((NSDictionary *(*)(id, SEL, NSArray *, NSError **))originalResourceValues)(self,
                @selector(resourceValuesForKeys:error:), keys, error);
        }
        NSString *path = self.path, *mapped = capacityPath(path);
        if (mapped != path) {
            NSMutableArray *capacity = [NSMutableArray new], *other = [NSMutableArray new];
            for (NSURLResourceKey key in keys) [(capacityKey(key) ? capacity : other) addObject:key];
            if (capacity.count) {
                // Match individual-key behavior: only capacity properties move.
                // Names and all other URL metadata retain their native receiver.
                NSDictionary *native = other.count
                    ? ((NSDictionary *(*)(id, SEL, NSArray *, NSError **))originalResourceValues)(self,
                        @selector(resourceValuesForKeys:error:), other, error) : @{};
                if (!native) return nil;
                NSDictionary *space = ((NSDictionary *(*)(id, SEL, NSArray *, NSError **))originalResourceValues)(
                    [NSURL fileURLWithPath:mapped isDirectory:YES], @selector(resourceValuesForKeys:error:), capacity, error);
                if (!space) return nil;
                NSMutableDictionary *result = [native mutableCopy];
                [result addEntriesFromDictionary:space];
                return result;
            }
        }
    }
    return ((NSDictionary *(*)(id, SEL, NSArray *, NSError **))originalResourceValues)(self,
        @selector(resourceValuesForKeys:error:), keys, error);
}
@end

// Preserve environ for Foundation/CFPreferences while supporting games that use C HOME.
__attribute__((visibility("default"))) char *getenv(const char *name) {
    static char *(*function)(const char *);
    static dispatch_once_t once;
    dispatch_once(&once, ^{ function = nativeStorageFunction((const void *)setenv, "getenv"); });
    if (atomic_load_explicit(&storageReady, memory_order_acquire) && name
        && strcmp(name, "HOME") == 0 && mulg_engine_is_game_caller(__builtin_return_address(0)))
        return storageHomeBytes;
    return function(name);
}
__attribute__((visibility("default"))) NSString *NSHomeDirectory(void) {
    return atomic_load_explicit(&storageReady, memory_order_acquire)
        && mulg_engine_is_game_caller(__builtin_return_address(0)) ? storageHome : nativeHome();
}
__attribute__((visibility("default"))) NSString *NSTemporaryDirectory(void) {
    // Foundation and Metal also call this while replacing local wrapper files. Their
    // scratch files must stay local; only direct game requests use the game data volume.
    return atomic_load_explicit(&storageReady, memory_order_acquire)
        && mulg_engine_is_game_caller(__builtin_return_address(0))
        ? storageTemporaryDirectory : nativeTemporary();
}
__attribute__((visibility("default"))) NSArray<NSString *> *NSSearchPathForDirectoriesInDomains(NSSearchPathDirectory directory, NSSearchPathDomainMask domains, BOOL expand) {
    static NSArray<NSString *> *(*function)(NSSearchPathDirectory, NSSearchPathDomainMask, BOOL);
    static dispatch_once_t once;
    dispatch_once(&once, ^{ function = nativeStorageFunction((const void *)NSHomeDirectoryForUser, "NSSearchPathForDirectoriesInDomains"); });
    NSArray<NSString *> *native = function(directory, domains, expand);
    if (!atomic_load_explicit(&storageReady, memory_order_acquire)
        || !mulg_engine_is_game_caller(__builtin_return_address(0))) return native;
    NSMutableArray *result = [NSMutableArray arrayWithCapacity:native.count];
    for (NSString *path in native) [result addObject:mappedPath(path)];
    return result;
}

BOOL mulg_engine_same_volume(NSURL *first, NSURL *second) {
    if (!first.isFileURL || !second.isFileURL) return NO;
    id a = nil, b = nil;
    if (![first getResourceValue:&a forKey:NSURLVolumeIdentifierKey error:NULL]
        || ![second getResourceValue:&b forKey:NSURLVolumeIdentifierKey error:NULL]) return NO;
    return a != nil && [a isEqual:b];
}

/// Where a replacement folder for a save into `parent` goes when macOS's own is on another volume. With moved
/// game data the container's tmp, Library/Caches and other folders may be links to the data volume (new
/// installs), so every save to the Mac's disk failed with a cross-device rename: safe-mode marker, login key,
/// diagnostics and control profiles saved from the in-game editor (Endfield, 2026-10-17). The first container
/// folder on `parent`'s volume is used (the game may write in its container; Mulg's folder allows only the
/// game's own files, never a folder beside them). Without one the folder goes beside the destination, as for
/// saves into the moved data.
NSURL *mulg_engine_replacement_base(NSURL *parent, NSArray<NSURL *> *candidates) {
    for (NSURL *candidate in candidates) {
        if (mulg_engine_same_volume(candidate, parent)) return candidate;
    }
    return parent;
}

/// Fallback replacement folders left empty by callers, older than ten minutes (one in use is newer or holds a file).
void mulg_engine_remove_stale_replacements(NSFileManager *files, NSURL *parent) {
    NSArray<NSURL *> *items = [files contentsOfDirectoryAtURL:parent includingPropertiesForKeys:@[NSURLCreationDateKey]
                                                      options:0 error:NULL];
    for (NSURL *item in items) {
        if (![item.lastPathComponent hasPrefix:@".mulg-replacement-"]) continue;
        NSDate *created = nil;
        [item getResourceValue:&created forKey:NSURLCreationDateKey error:NULL];
        if (!created || -created.timeIntervalSinceNow < 600) continue;
        rmdir(item.fileSystemRepresentation); // Fails, and keeps it, unless empty.
    }
}

@interface NSFileManager (MulgGameData)
- (BOOL)mulg_createDirectoryAtPath:(NSString *)path withIntermediateDirectories:(BOOL)intermediate attributes:(NSDictionary *)attributes error:(NSError **)error;
- (BOOL)mulg_createDirectoryAtURL:(NSURL *)url withIntermediateDirectories:(BOOL)intermediate attributes:(NSDictionary *)attributes error:(NSError **)error;- (NSDictionary *)mulg_storageFilesystemAttributes:(NSString *)path error:(NSError **)error;
- (NSURL *)mulg_storageHomeDirectory;
- (NSURL *)mulg_storageTemporaryDirectory;
- (NSArray<NSURL *> *)mulg_storageURLsForDirectory:(NSSearchPathDirectory)directory inDomains:(NSSearchPathDomainMask)domains;
- (NSURL *)mulg_storageURLForDirectory:(NSSearchPathDirectory)directory inDomain:(NSSearchPathDomainMask)domain appropriateForURL:(NSURL *)url create:(BOOL)create error:(NSError **)error;
@end
@implementation NSFileManager (MulgGameData)
- (BOOL)mulg_createDirectoryAtPath:(NSString *)path withIntermediateDirectories:(BOOL)intermediate attributes:(NSDictionary *)attributes error:(NSError **)error {
    NSString *target = mulg_engine_is_game_caller(__builtin_return_address(0)) ? fixedGamePath(path) : path;
    return ((BOOL (*)(id, SEL, NSString *, BOOL, NSDictionary *, NSError **))originalCreateDirectoryPath)(self, @selector(createDirectoryAtPath:withIntermediateDirectories:attributes:error:), target, intermediate, attributes, error);
}
- (BOOL)mulg_createDirectoryAtURL:(NSURL *)url withIntermediateDirectories:(BOOL)intermediate attributes:(NSDictionary *)attributes error:(NSError **)error {
    NSURL *target = mulg_engine_is_game_caller(__builtin_return_address(0)) ? fixedGameURL(url) : url;
    return ((BOOL (*)(id, SEL, NSURL *, BOOL, NSDictionary *, NSError **))originalCreateDirectoryURL)(self, @selector(createDirectoryAtURL:withIntermediateDirectories:attributes:error:), target, intermediate, attributes, error);
}- (NSDictionary *)mulg_storageFilesystemAttributes:(NSString *)path error:(NSError **)error {
    NSString *target = mulg_engine_is_game_caller(__builtin_return_address(0)) ? capacityPath(path) : path;
    return ((NSDictionary *(*)(id, SEL, NSString *, NSError **))originalFilesystemAttributes)(self,
        @selector(attributesOfFileSystemForPath:error:), target, error);
}
- (NSURL *)mulg_storageHomeDirectory {
    if (atomic_load_explicit(&storageReady, memory_order_acquire)
        && mulg_engine_is_game_caller(__builtin_return_address(0))) return [NSURL fileURLWithPath:storageHome isDirectory:YES];
    return ((NSURL *(*)(id, SEL))originalHomeURL)(self, @selector(homeDirectoryForCurrentUser));
}
- (NSURL *)mulg_storageTemporaryDirectory {
    if (atomic_load_explicit(&storageReady, memory_order_acquire) && mulg_engine_is_game_caller(__builtin_return_address(0))) return [NSURL fileURLWithPath:storageTemporaryPath isDirectory:YES];
    return ((NSURL *(*)(id, SEL))originalTemporaryURL)(self, @selector(temporaryDirectory));
}
- (NSArray<NSURL *> *)mulg_storageURLsForDirectory:(NSSearchPathDirectory)directory inDomains:(NSSearchPathDomainMask)domains {
    NSArray<NSURL *> *native = ((NSArray *(*)(id, SEL, NSSearchPathDirectory, NSSearchPathDomainMask))originalURLs)(self, @selector(URLsForDirectory:inDomains:), directory, domains);
    if (!atomic_load_explicit(&storageReady, memory_order_acquire)
        || !mulg_engine_is_game_caller(__builtin_return_address(0))) return native;
    NSMutableArray *result = [NSMutableArray arrayWithCapacity:native.count];
    for (NSURL *url in native) [result addObject:url.isFileURL ? [NSURL fileURLWithPath:mappedPath(url.path) isDirectory:YES] : url];
    return result;
}
- (NSURL *)mulg_storageURLForDirectory:(NSSearchPathDirectory)directory inDomain:(NSSearchPathDomainMask)domain appropriateForURL:(NSURL *)url create:(BOOL)create error:(NSError **)error {
    if (atomic_load_explicit(&storageReady, memory_order_acquire) && directory == NSItemReplacementDirectory && url.isFileURL) {
        // appropriateForURL is already a physical destination; the replacement folder must be on its
        // volume, never the game's unrelated temporary folder. macOS's own folder is used when it is:
        // callers (Metal's shader archives) never remove the folder they get, and only macOS cleans its own.
        NSURL *parent = [NSURL fileURLWithPath:url.path].URLByDeletingLastPathComponent;
        NSURL *native = ((NSURL *(*)(id, SEL, NSSearchPathDirectory, NSSearchPathDomainMask, NSURL *, BOOL, NSError **))originalURL)(self, @selector(URLForDirectory:inDomain:appropriateForURL:create:error:), directory, domain, url, create, NULL);
        if (mulg_engine_same_volume(native, parent)) return native;
        if (native) [self removeItemAtURL:native error:NULL];
        NSURL *base = mulg_engine_replacement_base(parent, containerScratch);
        mulg_engine_remove_stale_replacements(self, base);
        NSURL *folder = [base URLByAppendingPathComponent:[@".mulg-replacement-" stringByAppendingString:NSUUID.UUID.UUIDString] isDirectory:YES];
        return [self createDirectoryAtURL:folder withIntermediateDirectories:NO attributes:nil error:error] ? folder : nil;
    }
    NSURL *native = ((NSURL *(*)(id, SEL, NSSearchPathDirectory, NSSearchPathDomainMask, NSURL *, BOOL, NSError **))originalURL)(self, @selector(URLForDirectory:inDomain:appropriateForURL:create:error:), directory, domain, url, create, error);
    if (!native.isFileURL || !mulg_engine_is_game_caller(__builtin_return_address(0))) return native;
    NSURL *mapped = [NSURL fileURLWithPath:mappedPath(native.path) isDirectory:YES];
    if (create && ![mapped.path isEqualToString:native.path] && ![self createDirectoryAtURL:mapped withIntermediateDirectories:YES attributes:nil error:error]) return nil;
    return mapped;
}
@end

bool mulg_engine_set_game_data_root(const char *path) {
    static dispatch_once_t once;
    static bool installed;
    dispatch_once(&once, ^{
        originalHome = [NSHomeDirectory() copy];
        originalHomePrefix = [originalHome stringByAppendingString:@"/"];
        // Caches first (macOS cleans it), then Library and the container itself, which installs do not link.
        containerScratch = @[[NSURL fileURLWithPath:[originalHome stringByAppendingPathComponent:@"Library/Caches"] isDirectory:YES],
                             [NSURL fileURLWithPath:[originalHome stringByAppendingPathComponent:@"Library"] isDirectory:YES],
                             [NSURL fileURLWithPath:originalHome isDirectory:YES]];
        storageHome = [[NSString stringWithUTF8String:path] copy];
        storageHomeBytes = strdup(path);
        originalHomeBytes = strdup(originalHome.fileSystemRepresentation);
        if (!storageHomeBytes || !originalHomeBytes) return;
        // Immutable storage configuration: publish these with storageReady below.
        // Keep Foundation's own path joining and the C API's trailing slash.
        storageTemporaryPath = [storageHome stringByAppendingPathComponent:@"tmp"];
        storageTemporaryDirectory = [storageTemporaryPath stringByAppendingString:@"/"];
        originalHomeByteLength = strlen(originalHomeBytes);
        storageHomeByteLength = strlen(storageHomeBytes);
        NSURL *volume = nil;
        [[NSURL fileURLWithPath:storageHome isDirectory:YES] getResourceValue:&volume forKey:NSURLVolumeURLKey error:NULL];
        if (volume.isFileURL) storageVolumeBytes = strdup(volume.path.fileSystemRepresentation);
        Class cls = NSFileManager.class;
        Method urls = class_getInstanceMethod(cls, @selector(mulg_storageURLsForDirectory:inDomains:));
        Method url = class_getInstanceMethod(cls, @selector(mulg_storageURLForDirectory:inDomain:appropriateForURL:create:error:));
        installed = mulg_swizzle_checked_owned("engine", cls, @selector(URLsForDirectory:inDomains:), method_getImplementation(urls), &originalURLs, "@", @[@(@encode(NSSearchPathDirectory)), @(@encode(NSSearchPathDomainMask))]) == MulgSwizzleResultReplaced;
        installed &= mulg_swizzle_checked_owned("engine", cls, @selector(URLForDirectory:inDomain:appropriateForURL:create:error:), method_getImplementation(url), &originalURL, "@", @[@(@encode(NSSearchPathDirectory)), @(@encode(NSSearchPathDomainMask)), @"@", @(@encode(BOOL)), @"^@"]) == MulgSwizzleResultReplaced;
        installed &= mulg_swizzle_checked_owned("engine", cls, @selector(homeDirectoryForCurrentUser), class_getMethodImplementation(cls, @selector(mulg_storageHomeDirectory)), &originalHomeURL, "@", @[]) == MulgSwizzleResultReplaced;
        installed &= mulg_swizzle_checked_owned("engine", cls, @selector(temporaryDirectory), class_getMethodImplementation(cls, @selector(mulg_storageTemporaryDirectory)), &originalTemporaryURL, "@", @[]) == MulgSwizzleResultReplaced;
        if (installed) atomic_store_explicit(&storageReady, true, memory_order_release);
        // Checked independently: unsupported platform methods retain native behavior.
        mulg_swizzle_checked_owned("engine", NSString.class, @selector(stringByAppendingPathComponent:),
            class_getMethodImplementation(NSString.class, @selector(mulg_gameAppendingPathComponent:)),
            &originalAppendPath, "@", @[@"@"]);
        // Foundation's path objects override NSString's builder. Obtain their
        // concrete class through the public constructor. Use a distinct IMP so
        // a native override calling super retains both original method chains.
        Class pathClass = object_getClass([NSString pathWithComponents:@[@"/", @"mulg"]]);
        if (pathClass != NSString.class && class_getMethodImplementation(pathClass, @selector(stringByAppendingPathComponent:))
            != class_getMethodImplementation(NSString.class, @selector(stringByAppendingPathComponent:))) {
            mulg_swizzle_checked_owned("engine", pathClass, @selector(stringByAppendingPathComponent:),
                class_getMethodImplementation(NSString.class, @selector(mulg_gameAppendingStoredPathComponent:)),
                &originalAppendStoredPath, "@", @[@"@"]);
        }
        mulg_swizzle_checked_owned("engine", NSURL.class, @selector(URLByAppendingPathComponent:),
            class_getMethodImplementation(NSURL.class, @selector(mulg_gameAppendingPathComponent:)),
            &originalAppendURL, "@", @[@"@"]);
        mulg_swizzle_checked_owned("engine", NSURL.class, @selector(URLByAppendingPathComponent:isDirectory:),
            class_getMethodImplementation(NSURL.class, @selector(mulg_gameAppendingPathComponent:isDirectory:)),
            &originalAppendDirectoryURL, "@", @[@"@", @(@encode(BOOL))]);
        // Foundation performs recursive mkdir inside its own image, bypassing the
        // game's explicitly linked C adapter. Normalize at the public boundary.
        mulg_swizzle_checked_owned("engine", cls, @selector(createDirectoryAtPath:withIntermediateDirectories:attributes:error:),
            class_getMethodImplementation(cls, @selector(mulg_createDirectoryAtPath:withIntermediateDirectories:attributes:error:)),
            &originalCreateDirectoryPath, @encode(BOOL), @[@"@", @(@encode(BOOL)), @"@", @"^@"]);
        mulg_swizzle_checked_owned("engine", cls, @selector(createDirectoryAtURL:withIntermediateDirectories:attributes:error:),
            class_getMethodImplementation(cls, @selector(mulg_createDirectoryAtURL:withIntermediateDirectories:attributes:error:)),
            &originalCreateDirectoryURL, @encode(BOOL), @[@"@", @(@encode(BOOL)), @"@", @"^@"]);
        // Capacity hook failures remain independent of existing directory hooks.
        mulg_swizzle_checked_owned("engine", cls, @selector(attributesOfFileSystemForPath:error:),
            class_getMethodImplementation(cls, @selector(mulg_storageFilesystemAttributes:error:)),
            &originalFilesystemAttributes, "@", @[@"@", @"^@"]);
        mulg_swizzle_checked_owned("engine", NSURL.class, @selector(getResourceValue:forKey:error:),
            class_getMethodImplementation(NSURL.class, @selector(mulg_storageGetResourceValue:forKey:error:)),
            &originalResourceValue, @encode(BOOL), @[@"o^@", @"@", @"o^@"]);
        mulg_swizzle_checked_owned("engine", NSURL.class, @selector(resourceValuesForKeys:error:),
            class_getMethodImplementation(NSURL.class, @selector(mulg_storageResourceValuesForKeys:error:)),
            &originalResourceValues, "@", @[@"@", @"^@"]);
    });
    return installed;
}
