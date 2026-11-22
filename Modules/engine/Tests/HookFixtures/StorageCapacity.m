#import "MulgEngineHooks.h"
#import "MulgGameDataHooks.h"
#import <objc/runtime.h>
#include <assert.h>
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <sys/mount.h>
#include <sys/statvfs.h>
#include <unistd.h>
#include <string.h>
#include <stdio.h>

static BOOL game, failCapacity;
static uint64_t available = 524288000000ULL;
static NSString *dataRoot;
static IMP nativeAttributes;
static void *mainImage;
BOOL mulg_engine_is_game_caller(const void *caller) {
    Dl_info info;
    return game && dladdr(caller, &info) && info.dli_fbase == mainImage;
}
static NSDictionary *capacityFixture(id self, SEL selector, NSString *path, NSError **error) {
    if ([path isEqualToString:@"/var"] || [path isEqualToString:@"/private/var"]) { if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:EACCES userInfo:nil]; return nil; }
    if ([path isEqualToString:@"/"]) return @{NSFileSystemSize: @1000, NSFileSystemFreeSize: @0};
    if ([path isEqualToString:dataRoot]) {
        if (failCapacity) { if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:EACCES userInfo:nil]; return nil; }
        return @{NSFileSystemSize: @(1023999787008ULL), NSFileSystemFreeSize: @(available)};
    }
    return ((NSDictionary *(*)(id,SEL,NSString *,NSError **))nativeAttributes)(self,selector,path,error);
}
int main(int argc, char **argv) { @autoreleasepool {
    Dl_info own; assert(dladdr((const void *)main, &own)); mainImage = own.dli_fbase;
    NSString *originalHome = NSHomeDirectory();
    char temporary[] = "/tmp/mulg-storage-capacity-XXXXXX"; assert(mkdtemp(temporary));
    dataRoot = argc > 1 ? @(argv[1]) : @(temporary);
    void *system = dlopen("/usr/lib/libSystem.B.dylib", RTLD_LAZY | RTLD_NOLOAD | RTLD_FIRST); assert(system);
    int (*nativeFS)(const char *,struct statfs *) = dlsym(system,"statfs"); assert(nativeFS && nativeFS != statfs);
    int (*nativeVFS)(const char *,struct statvfs *) = dlsym(system,"statvfs"); assert(nativeVFS && nativeVFS != statvfs);
    Method attributes = class_getInstanceMethod(NSFileManager.class, @selector(attributesOfFileSystemForPath:error:));
    nativeAttributes = method_setImplementation(attributes, (IMP)capacityFixture);
    // Reproduce a root probe reporting no writable space while the real data
    // destination has ample capacity. The adapter must choose that destination.
    game = YES;
    assert([[NSFileManager.defaultManager attributesOfFileSystemForPath:@"/" error:NULL][NSFileSystemFreeSize] unsignedLongLongValue] == 0);
    game = NO;
    NSString *nativeDocuments = [dataRoot stringByAppendingPathComponent:@"Documents"];
    NSString *nativeTarget = [dataRoot stringByAppendingPathComponent:@"Documents/download with spaces.bin"];
    NSURL *nativeBuiltURL = [[NSURL fileURLWithPath:nativeDocuments isDirectory:YES] URLByAppendingPathComponent:nativeTarget isDirectory:NO];
    assert(mulg_engine_set_game_data_root(dataRoot.fileSystemRepresentation));
    mulg_engine_configure_game_path_roots(@[originalHome, dataRoot], NO);
    game = YES;
    // Foundation builders must agree with the existing C file adapter. These
    // exact single-slash joins produced Documents/Volumes/... in the live data.
    NSString *documents = [dataRoot stringByAppendingPathComponent:@"Documents"];
    NSString *target = [dataRoot stringByAppendingPathComponent:@"Documents/download with spaces.bin"];
    NSString *literal = [NSString stringWithFormat:@"%@%@", documents, target];
    assert([[documents stringByAppendingPathComponent:target] isEqualToString:target]);
    for (NSString *base in @[documents, [NSString stringWithFormat:@"%@", documents], [documents mutableCopy]]) {
        assert([[base stringByAppendingPathComponent:target] isEqualToString:target]);
    }
    if (argc == 1) {
        // A real Foundation write and a C read of the old malformed form must
        // reach the same file, without making a nested download tree.
        NSFileManager *files = NSFileManager.defaultManager;
        assert([files createDirectoryAtPath:documents withIntermediateDirectories:YES attributes:nil error:NULL]);
        NSString *ownedDestination = [documents stringByAppendingPathComponent:@"shader-output"];
        NSString *badDirectory = [NSString stringWithFormat:@"%@%@/Documents/shader-output", documents, dataRoot];
        assert([files createDirectoryAtPath:badDirectory withIntermediateDirectories:YES attributes:nil error:NULL]);
        BOOL isDirectory = NO; assert([files fileExistsAtPath:ownedDestination isDirectory:&isDirectory] && isDirectory);
        assert(![files fileExistsAtPath:badDirectory]);
        assert(rmdir(ownedDestination.fileSystemRepresentation) == 0);
        NSURL *badURL = [NSURL fileURLWithPath:badDirectory isDirectory:YES];
        assert([files createDirectoryAtURL:badURL withIntermediateDirectories:YES attributes:nil error:NULL]);
        assert([files fileExistsAtPath:ownedDestination isDirectory:&isDirectory] && isDirectory);
        assert(rmdir(ownedDestination.fileSystemRepresentation) == 0);
        NSData *payload = [@"shared download" dataUsingEncoding:NSUTF8StringEncoding];
        assert([payload writeToFile:[documents stringByAppendingPathComponent:target] options:NSDataWritingAtomic error:NULL]);
        assert([files fileExistsAtPath:target]);
        int fd = open(literal.fileSystemRepresentation, O_RDONLY);
        char bytes[32] = {0};
        assert(fd >= 0 && read(fd, bytes, sizeof(bytes)) == (ssize_t)payload.length && close(fd) == 0);
        assert(memcmp(bytes, payload.bytes, payload.length) == 0);
        assert(unlink(target.fileSystemRepresentation) == 0);
        assert(rmdir(documents.fileSystemRepresentation) == 0);
    }
    NSURL *documentURL = [NSURL fileURLWithPath:documents isDirectory:YES];
    assert([[documentURL URLByAppendingPathComponent:target].path isEqualToString:target]);
    assert([[documentURL URLByAppendingPathComponent:target isDirectory:NO].path isEqualToString:target]);
    assert([documentURL URLByAppendingPathComponent:dataRoot isDirectory:YES].hasDirectoryPath);
    NSURLComponents *withQuery = [NSURLComponents componentsWithURL:documentURL resolvingAgainstBaseURL:NO];
    withQuery.query = @"mode=fixture";
    NSURL *queried = [withQuery.URL URLByAppendingPathComponent:target isDirectory:NO];
    assert([queried.path isEqualToString:target] && [queried.query isEqualToString:@"mode=fixture"]);
    assert([[documents stringByAppendingPathComponent:@"ordinary.bin"] isEqualToString:[documents stringByAppendingString:@"/ordinary.bin"]]);
    NSString *archive = [dataRoot stringByAppendingPathComponent:@"Archive"];
    assert([[archive stringByAppendingPathComponent:target] isEqualToString:[archive stringByAppendingString:target]]);
    NSURL *remote = [NSURL URLWithString:@"https://example.invalid/Documents/"];
    assert([[remote URLByAppendingPathComponent:target].host isEqualToString:@"example.invalid"]);
    game = NO;
    assert([[documents stringByAppendingPathComponent:target] isEqualToString:literal]);
    assert([[documentURL URLByAppendingPathComponent:target isDirectory:NO] isEqual:nativeBuiltURL]);
    game = YES;
    assert(strcmp(mulg_engine_storage_capacity_path("/"),dataRoot.fileSystemRepresentation)==0);
    assert(strcmp(mulg_engine_storage_capacity_path(originalHome.fileSystemRepresentation),dataRoot.fileSystemRepresentation)==0);
    NSString *future = [dataRoot stringByAppendingPathComponent:@"not-created/downloads"];
    assert(strcmp(mulg_engine_storage_capacity_path(future.fileSystemRepresentation),dataRoot.fileSystemRepresentation)==0);
    NSString *sibling = [dataRoot stringByAppendingString:@".other"];
    assert(strcmp(mulg_engine_storage_capacity_path(sibling.fileSystemRepresentation),sibling.fileSystemRepresentation)==0);
    for (NSString *alias in @[@"/var", @"/var/", @"/private/var", @"/private/var//"]) {
        assert(strcmp(mulg_engine_storage_capacity_path(alias.fileSystemRepresentation),dataRoot.fileSystemRepresentation)==0);
        assert([[NSFileManager.defaultManager attributesOfFileSystemForPath:alias error:NULL][NSFileSystemFreeSize] unsignedLongLongValue] == available);
    }
    for (NSString *literal in @[@"/variable", @"/var/mobile", @"/private/variable", @"/private/var/db", @"relative/var"]) {
        const char *bytes = literal.fileSystemRepresentation;
        assert(mulg_engine_storage_capacity_path(bytes) == bytes);
    }
    const char *unrelated = "/private/unrelated-storage-probe";
    assert(mulg_engine_storage_capacity_path(unrelated) == unrelated);
    assert(mulg_engine_storage_capacity_path(NULL) == NULL);
    NSDictionary *values = [NSFileManager.defaultManager attributesOfFileSystemForPath:@"/" error:NULL];
    assert([values[NSFileSystemFreeSize] unsignedLongLongValue] == available);
    assert([values[NSFileSystemSize] unsignedLongLongValue] == 1023999787008ULL);
    values = [NSFileManager.defaultManager attributesOfFileSystemForPath:future error:NULL];
    assert([values[NSFileSystemFreeSize] unsignedLongLongValue] == available);
    game = NO;
    assert([[NSFileManager.defaultManager attributesOfFileSystemForPath:@"/" error:NULL][NSFileSystemFreeSize] unsignedLongLongValue] == 0);
    NSError *nativeError = nil;
    assert([NSFileManager.defaultManager attributesOfFileSystemForPath:@"/var" error:&nativeError] == nil && nativeError.code == EACCES);
    game = YES;
    available = 0;
    assert([[NSFileManager.defaultManager attributesOfFileSystemForPath:@"/" error:NULL][NSFileSystemFreeSize] unsignedLongLongValue] == 0);
    failCapacity = YES; NSError *error = nil;
    assert([NSFileManager.defaultManager attributesOfFileSystemForPath:@"/" error:&error] == nil && error.code == EACCES);
    failCapacity = NO;
    struct statfs root={0}, mapped={0}, native={0};
    assert(nativeFS(dataRoot.fileSystemRepresentation,&native)==0);
    assert(statfs("/",&root)==0 && statfs(future.fileSystemRepresentation,&mapped)==0);
    assert(root.f_blocks==native.f_blocks && root.f_bsize==native.f_bsize && root.f_fsid.val[0]==native.f_fsid.val[0]);
    assert(mapped.f_fsid.val[0]==native.f_fsid.val[0]);
    assert(statfs("/var",&mapped)==0 && mapped.f_fsid.val[0]==native.f_fsid.val[0]);
    assert(statfs("/private/var/",&mapped)==0 && mapped.f_fsid.val[0]==native.f_fsid.val[0]);
    struct statvfs vfs={0}, expectedVFS={0}; assert(statvfs("/",&vfs)==0);
    assert(nativeVFS(dataRoot.fileSystemRepresentation,&expectedVFS)==0);
    assert(vfs.f_blocks==expectedVFS.f_blocks && vfs.f_bsize==expectedVFS.f_bsize);
    assert(statvfs("/var/",&vfs)==0 && vfs.f_blocks==expectedVFS.f_blocks && vfs.f_bsize==expectedVFS.f_bsize);
    errno=0; assert(statfs(unrelated,&mapped)==-1 && errno==ENOENT);
    NSURL *url=[NSURL fileURLWithPath:@"/"], *destination=[NSURL fileURLWithPath:dataRoot];
    game=NO; NSNumber *total=nil; assert([destination getResourceValue:&total forKey:NSURLVolumeTotalCapacityKey error:NULL]);
    NSDictionary *mixedBefore=[url resourceValuesForKeys:@[NSURLNameKey,NSURLVolumeTotalCapacityKey] error:NULL];
    game=YES; NSNumber *reported=nil;
    assert([url getResourceValue:&reported forKey:NSURLVolumeTotalCapacityKey error:NULL]);
    if (![total isEqual:reported]) NSLog(@"capacity expected=%@ reported=%@ URLClass=%@ hooks=%@", total, reported, object_getClass(url), mulg_hook_installation_reports());
    assert([total isEqual:reported]);
    for (NSString *alias in @[@"/var", @"/private/var/"]) {
        NSURL *volume = [NSURL fileURLWithPath:alias];
        reported = nil;
        assert([volume getResourceValue:&reported forKey:NSURLVolumeTotalCapacityKey error:NULL] && [reported isEqual:total]);
        NSDictionary *aliasBatch = [volume resourceValuesForKeys:@[NSURLVolumeTotalCapacityKey] error:NULL];
        assert([aliasBatch[NSURLVolumeTotalCapacityKey] isEqual:total]);
    }
    NSDictionary *batch=[url resourceValuesForKeys:@[NSURLVolumeAvailableCapacityKey,NSURLVolumeTotalCapacityKey] error:NULL];
    assert([batch[NSURLVolumeTotalCapacityKey] isEqual:total]);
    NSDictionary *mixedAfter=[url resourceValuesForKeys:@[NSURLNameKey,NSURLVolumeTotalCapacityKey] error:NULL];
    assert([mixedBefore[NSURLNameKey] isEqual:mixedAfter[NSURLNameKey]]);
    assert([mixedAfter[NSURLVolumeTotalCapacityKey] isEqual:total]);
    game=NO;
    printf("Storage capacity checks passed: exact roots, future paths, 64-bit values, real zero/error, native isolation, statfs/statvfs and NSURL (data=%s)\n",dataRoot.UTF8String);
    assert(rmdir(temporary)==0);
} }
