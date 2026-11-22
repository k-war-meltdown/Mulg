//
//  MulgCameraHooks.h
//  camera module: reads and writes the game's own memory for Camera reach.
//
//  No hooks: the camera module finds the game's zoom limit by value, not by code address, so a
//  game update cannot break it. Every read goes through mach_vm_read_overwrite, which fails
//  instead of crashing when memory disappears between two steps; writes are compare-and-swap.
//
//  Scratch memory is tagged (MULG_CAMERA_MEMORY_TAG) and skipped by every scan, so a search
//  never finds its own copies.
//

#ifndef MULG_CAMERA_HOOKS_H
#define MULG_CAMERA_HOOKS_H

#include <CoreFoundation/CFAvailability.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#pragma clang assume_nonnull begin

#ifdef __cplusplus
extern "C" {
#endif

/// A search in progress: every 32-bit float in a range, then narrowed step by step.
typedef struct MulgCameraScan MulgCameraScan;

typedef CF_ENUM(int32_t, MulgCameraScanStatus) {
    MulgCameraScanStatusOK = 0,
    /// More matching values than the limit; nothing was kept.
    MulgCameraScanStatusTooMany = 1,
    /// Scratch memory could not be reserved.
    MulgCameraScanStatusNoMemory = 2,
};

typedef CF_ENUM(int32_t, MulgCameraFilter) {
    /// Keep values now below the first value by at least `ratio`; the current value is kept as
    /// the second value.
    MulgCameraFilterDecreased = 0,
    /// Keep values now exactly (bit for bit) equal to the first value.
    MulgCameraFilterEqualsFirst = 1,
    /// Keep values now exactly equal to the second value.
    MulgCameraFilterEqualsSecond = 2,
};

/// Records every 4-byte-aligned positive float in [low, high] in the game's private writable
/// memory. Returns NULL with `status` set when there are more than `limit` of them or scratch
/// memory is unavailable.
MulgCameraScan *_Nullable mulg_camera_scan_create(float low, float high, uint64_t limit,
                                                  MulgCameraScanStatus *status);
/// Re-reads every remaining value and keeps those passing `filter`; returns how many remain.
uint64_t mulg_camera_scan_filter(MulgCameraScan *scan, MulgCameraFilter filter, float ratio);
uint64_t mulg_camera_scan_count(const MulgCameraScan *scan);
/// Copies up to `capacity` remaining addresses with their first and second values (bit
/// patterns). Returns how many were copied.
uint64_t mulg_camera_scan_results(const MulgCameraScan *scan, uint64_t *addresses, uint32_t *first,
                                  uint32_t *second, uint64_t capacity);
void mulg_camera_scan_free(MulgCameraScan *_Nullable scan);

/// A farthest limit at `address` with its nearest limit `offset` bytes away.
typedef struct {
    uint64_t address;
    int32_t offset;
} MulgCameraPair;

/// Finds every word equal to `farBits` whose neighbour equals `nearBits`: at one of `offsets`
/// (bytes) when given, otherwise anywhere within ±`window` bytes, nearest first. Addresses in
/// `excluded` are skipped. Copies up to `capacity` pairs and returns how many exist in all.
uint64_t mulg_camera_find_pairs(uint32_t farBits, uint32_t nearBits,
                                const int32_t *_Nullable offsets, size_t offsetCount, int32_t window,
                                const uint64_t *_Nullable excluded, size_t excludedCount,
                                MulgCameraPair *_Nullable pairs, uint64_t capacity);

/// A farthest limit of set `set` at `address`, its nearest limit `offset` bytes away.
typedef struct {
    uint64_t address;
    int32_t offset;
    int32_t set;
} MulgCameraSetPair;

/// `mulg_camera_find_pairs` for several (farthest, nearest) sets in one pass over memory. Sets
/// whose nearest value is 0 are skipped (zeros sit beside almost anything). `totals[set]` receives
/// how many pairs each set has; up to `capacity` pairs are copied. Returns the number of pairs.
uint64_t mulg_camera_find_pair_sets(const uint32_t *farBits, const uint32_t *nearBits, size_t setCount,
                                    int32_t window, const uint64_t *_Nullable excluded, size_t excludedCount,
                                    MulgCameraSetPair *_Nullable pairs, uint64_t capacity, uint64_t *totals);

/// The VM region holding `address`: its tag (VM_MEMORY_*), start and size, for diagnostics.
bool mulg_camera_region(uint64_t address, uint32_t *tag, uint64_t *start, uint64_t *size);

/// Reads one word. Returns false when the address is not readable.
bool mulg_camera_read(uint64_t address, uint32_t *bits);

/// Replaces `expected` with `replacement` through the kernel (a freed page fails instead of crashing
/// the game). Returns 1 when swapped, 0 when the word holds something else (left alone), -1 when the
/// address is not writable memory.
int32_t mulg_camera_swap(uint64_t address, uint32_t expected, uint32_t replacement);

#ifdef __cplusplus
}
#endif

#pragma clang assume_nonnull end

#endif
