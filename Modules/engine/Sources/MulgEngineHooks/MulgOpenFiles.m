//
//  MulgOpenFiles.m
//  engine module: which big files the game holds open, for the learned read-ahead order.
//

#import "MulgEngineHooks.h"
#include <libproc.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

NSArray<NSString *> *mulg_engine_open_files(NSArray<NSString *> *roots, int64_t minimumSize, NSUInteger limit) {
    if (roots.count == 0 || limit == 0) return @[];
    NSMutableArray<NSString *> *result = [NSMutableArray new];
    pid_t pid = getpid();
    int bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, NULL, 0);
    if (bytes <= 0) return result;
    // Room for descriptors opened between the two calls; extra ones are simply not listed.
    bytes += 64 * (int)sizeof(struct proc_fdinfo);
    struct proc_fdinfo *fds = malloc((size_t)bytes);
    if (!fds) return result;
    NSMutableSet<NSString *> *seen = [NSMutableSet new];
    NSUInteger rootCount = roots.count;
    const char *prefixes[rootCount > 0 ? rootCount : 1];
    size_t lengths[rootCount > 0 ? rootCount : 1];
    for (NSUInteger r = 0; r < rootCount; ++r) {
        prefixes[r] = roots[r].fileSystemRepresentation;
        lengths[r] = strlen(prefixes[r]);
    }
    bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, fds, bytes);
    int count = bytes > 0 ? bytes / (int)sizeof(struct proc_fdinfo) : 0;
    for (int i = 0; i < count && result.count < limit; ++i) {
        if (fds[i].proc_fdtype != PROX_FDTYPE_VNODE) continue;
        struct vnode_fdinfowithpath info;
        // A descriptor closed since the listing fails here and is skipped.
        if (proc_pidfdinfo(pid, fds[i].proc_fd, PROC_PIDFDVNODEPATHINFO, &info, sizeof info) != sizeof info) continue;
        const struct vinfo_stat *st = &info.pvip.vip_vi.vi_stat;
        if ((st->vst_mode & S_IFMT) != S_IFREG || st->vst_size < minimumSize) continue;
        const char *path = info.pvip.vip_path;
        for (NSUInteger r = 0; r < rootCount; ++r) {
            if (strncmp(path, prefixes[r], lengths[r]) != 0) continue;
            NSString *found = @(path);
            // Keep descriptor order in the result, without rescanning every earlier
            // pathname for repeated descriptors of the same asset.
            if (found && ![seen containsObject:found]) {
                [seen addObject:found];
                [result addObject:found];
            }
            break;
        }
    }
    free(fds);
    return result;
}
