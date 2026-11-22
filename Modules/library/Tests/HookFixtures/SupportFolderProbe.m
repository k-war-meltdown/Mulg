#import <UIKit/UIKit.h>
#import <Metal/Metal.h>
#import <MulgEngineHooks.h>
#import <stdlib.h>

// Link the actual runtime bootstrap Swift source into a signed Catalyst app. Container
// Manager initializes its sandbox before main; verify normal game APIs write through it.
@interface MulgGameDataBootstrap : NSObject
+ (BOOL)prepareWithBundle:(NSBundle *)bundle error:(NSError **)error;
@end
@interface MulgStorageAtomicProbe : NSObject
+ (BOOL)writeToURL:(NSURL *)url error:(NSError **)error;
@end
int main(int argc, char **argv) {
    @autoreleasepool {
        mulg_engine_prepare_game_callers();
        NSString *processTemporary = getenv("TMPDIR") ? @(getenv("TMPDIR")) : nil;
        NSError *error = nil;
        BOOL bootstrap = [MulgGameDataBootstrap prepareWithBundle:NSBundle.mainBundle error:&error];
        NSString *bootstrapError = error.description ?: @"";
        NSString *root = [NSBundle.mainBundle objectForInfoDictionaryKey:@"MulgGameDataRoot"];
        NSMutableArray *checks = [NSMutableArray new];
        for (NSNumber *directory in @[@(NSDocumentDirectory), @(NSLibraryDirectory)]) {
            NSString *local = NSSearchPathForDirectoriesInDomains(directory.integerValue, NSUserDomainMask, YES).firstObject;
            NSString *file = [local stringByAppendingPathComponent:@"in-game-update.bin"];
            BOOL wrote = [@"game download bytes" writeToFile:file atomically:YES encoding:NSUTF8StringEncoding error:&error];
            NSString *external = [[root stringByAppendingPathComponent:@"Data"] stringByAppendingPathComponent:local.lastPathComponent];
            BOOL matched = [[NSString stringWithContentsOfFile:[external stringByAppendingPathComponent:@"in-game-update.bin"] encoding:NSUTF8StringEncoding error:nil] isEqualToString:@"game download bytes"];
            [checks addObject:@{ @"directory": local.lastPathComponent, @"passed": @(wrote && matched), @"path": local }];
        }
        [NSUserDefaults.standardUserDefaults setInteger:144 forKey:@"SelectedGameFPS"];
        BOOL preferences = [NSUserDefaults.standardUserDefaults synchronize];
        NSString *expectedHome = [root stringByAppendingPathComponent:@"Data"];
        NSURL *homeURL = [NSFileManager.defaultManager valueForKey:@"homeDirectoryForCurrentUser"];
        BOOL home = [NSHomeDirectory() isEqualToString:expectedHome] && [homeURL.path isEqualToString:expectedHome];
        BOOL temporary = [NSFileManager.defaultManager.temporaryDirectory.path isEqualToString:[expectedHome stringByAppendingPathComponent:@"tmp"]];
        BOOL nativeTemporary = processTemporary == nil ? getenv("TMPDIR") == NULL : [processTemporary isEqualToString:@(getenv("TMPDIR"))];
        NSURL *libraryURL = [NSFileManager.defaultManager URLsForDirectory:NSLibraryDirectory inDomains:NSUserDomainMask].firstObject;
        BOOL fileManager = [libraryURL.path isEqualToString:[expectedHome stringByAppendingPathComponent:@"Library"]];
        // Runtime state stays on the Mac even when game data and game temporary files
        // live on another volume. Foundation and Metal must still replace local files.
        NSURL *localCache = [NSURL fileURLWithPath:[NSBundle.mainBundle objectForInfoDictionaryKey:@"MulgProbeLocalCache"] isDirectory:YES];
        BOOL localDirectory = [NSFileManager.defaultManager createDirectoryAtURL:localCache withIntermediateDirectories:YES attributes:nil error:&error];
        NSData *localBytes = [@"local wrapper state" dataUsingEncoding:NSUTF8StringEncoding];
        NSURL *localFile = [localCache URLByAppendingPathComponent:@"startup.json"];
        BOOL localAtomic = localDirectory && [MulgStorageAtomicProbe writeToURL:localFile error:&error]
            && [[NSData dataWithContentsOfURL:localFile] isEqualToData:localBytes];
        NSString *localError = error.description ?: @"";
        error = nil;
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        id<MTLLibrary> library = [device newLibraryWithSource:@"#include <metal_stdlib>\nusing namespace metal; kernel void storage_probe(device uint *value [[buffer(0)]]) { value[0] = 144; }" options:nil error:&error];
        MTLComputePipelineDescriptor *pipeline = [MTLComputePipelineDescriptor new];
        pipeline.computeFunction = [library newFunctionWithName:@"storage_probe"];
        id<MTLBinaryArchive> archive = [device newBinaryArchiveWithDescriptor:[MTLBinaryArchiveDescriptor new] error:&error];
        BOOL shaderArchive = library != nil && archive != nil && [archive addComputePipelineFunctionsWithDescriptor:pipeline error:&error]
            && [archive serializeToURL:[localCache URLByAppendingPathComponent:@"cache.metallib"] error:&error];
        NSError *archiveFailure = nil;
        BOOL shaderFailureHandled = shaderArchive && ![archive serializeToURL:[localCache URLByAppendingPathComponent:@"missing-parent/cache.metallib"] error:&archiveFailure] && archiveFailure != nil;
        BOOL passed = bootstrap && preferences && home && temporary && nativeTemporary && fileManager && localAtomic && shaderArchive && shaderFailureHandled;
        for (NSDictionary *check in checks) passed &= [check[@"passed"] boolValue];
        NSDictionary *report = @{ @"passed": @(passed), @"bootstrap": @(bootstrap), @"preferences": @(preferences), @"home": @(home), @"temporary": @(temporary), @"fileManager": @(fileManager), @"checks": checks,
                                  @"localAtomic": @(localAtomic), @"localError": localError, @"shaderArchive": @(shaderArchive),
                                  @"shaderFailureHandled": @(shaderFailureHandled),
                                  @"nativeTemporary": @(nativeTemporary),
                                  @"bootstrapError": bootstrapError, @"error": error.description ?: @"" };
        NSData *json = [NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:nil];
        [json writeToFile:[root stringByAppendingPathComponent:@"sandbox-probe.json"] atomically:YES];
        fwrite(json.bytes, 1, json.length, stdout);
        return passed ? 0 : 1;
    }
}
