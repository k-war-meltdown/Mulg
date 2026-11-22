//
//  MulgCameraMemory.m
//  camera module: value search over the game's own memory (Camera reach).
//
//  Walks the private, writable, non-executable regions of this process, reading only resident
//  pages: never-touched pages would grow the game's memory and compressed ones would have to be
//  decompressed (camera values are used every frame, so they are always resident).
//
//  Reads use mach_vm_read_overwrite, so memory freed by the game while a scan runs makes one read
//  fail instead of crashing the game, and they go ONE PAGE AT A TIME: for larger reads the kernel
//  does not copy but marks the game's own pages copy-on-write, and every later write by the game
//  to any of them then faults and copies the page. Build 892 read 4 MB at a time and that made
//  the game crawl. Under two pages the kernel copies through a buffer and the game's mappings are
//  left alone. The walk also pauses briefly every 16 MB so it never competes with the game for
//  memory bandwidth.
//

#import "MulgCameraHooks.h"

#include <mach/mach.h>
#include <mach/mach_vm.h>
#include <mach/vm_statistics.h>
#include <sys/param.h>
#include <unistd.h>
#include <stdlib.h>
#include <string.h>

/// Scratch memory carries this tag; scans skip it, so they never find their own copies.
#define MULG_CAMERA_MEMORY_TAG VM_MEMORY_APPLICATION_SPECIFIC_16
/// Pages read per region step: 4 MB with 16 KB pages.
#define MULG_CAMERA_CHUNK_PAGES 256
/// Bytes read between two short pauses, and the pause.
#define MULG_CAMERA_PAUSE_BYTES (16u << 20)
#define MULG_CAMERA_PAUSE_MICROSECONDS 3000

// MARK: - Scratch memory

static void *tagged_allocate(size_t size) {
    mach_vm_address_t address = 0;
    if (mach_vm_allocate(mach_task_self(), &address, size,
                         VM_FLAGS_ANYWHERE | VM_MAKE_TAG(MULG_CAMERA_MEMORY_TAG)) != KERN_SUCCESS) {
        return NULL;
    }
    return (void *)(uintptr_t)address;
}

static void tagged_free(void *pointer, size_t size) {
    if (pointer && size) mach_vm_deallocate(mach_task_self(), (mach_vm_address_t)(uintptr_t)pointer, size);
}

static size_t page_rounded(size_t size) {
    return (size + vm_page_size - 1) & ~(vm_page_size - 1);
}

// MARK: - Walking memory

/// Where game data can live: private, readable and writable, not code, not stacks, not GPU or
/// window-server memory, and with at least one page that holds data.
static bool scannable(const vm_region_submap_info_data_64_t *info) {
    if ((info->protection & (VM_PROT_READ | VM_PROT_WRITE)) != (VM_PROT_READ | VM_PROT_WRITE)) return false;
    if (info->protection & VM_PROT_EXECUTE) return false;
    switch (info->share_mode) {
    case SM_SHARED: case SM_TRUESHARED: case SM_SHARED_ALIASED: return false;
    default: break;
    }
    switch (info->user_tag) {
    case MULG_CAMERA_MEMORY_TAG:
    case VM_MEMORY_STACK: case VM_MEMORY_GUARD: case VM_MEMORY_IOKIT:
    case VM_MEMORY_IOSURFACE: case VM_MEMORY_IOACCELERATOR:
        return false;
    default: break;
    }
    return info->pages_resident > 0;
}

/// Called with each stretch of readable words. Return false to stop the walk.
typedef bool (^MulgRunVisitor)(uint64_t address, const uint32_t *words, size_t count);

/// Visits every resident page in scannable regions, in address order, in stretches of
/// consecutive pages. Pages are read one at a time (see the top of the file).
static bool walk_memory(MulgRunVisitor visitor) {
    const mach_port_t task = mach_task_self();
    const size_t page = vm_page_size;
    const size_t chunkBytes = page * MULG_CAMERA_CHUNK_PAGES;
    const size_t dispositionBytes = page_rounded(sizeof(int) * MULG_CAMERA_CHUNK_PAGES);
    uint32_t *buffer = tagged_allocate(chunkBytes);
    int *dispositions = tagged_allocate(dispositionBytes);
    if (!buffer || !dispositions) {
        tagged_free(buffer, chunkBytes);
        tagged_free(dispositions, dispositionBytes);
        return false;
    }
    bool keepGoing = true;
    size_t sincePause = 0;
    mach_vm_address_t address = 0;
    natural_t depth = 0;
    while (keepGoing) {
        mach_vm_size_t size = 0;
        vm_region_submap_info_data_64_t info;
        mach_msg_type_number_t infoCount = VM_REGION_SUBMAP_INFO_COUNT_64;
        if (mach_vm_region_recurse(task, &address, &size, &depth, (vm_region_recurse_info_t)&info,
                                   &infoCount) != KERN_SUCCESS) break;
        if (info.is_submap) { depth++; continue; }
        if (scannable(&info)) {
            const mach_vm_address_t end = address + size;
            for (mach_vm_address_t chunk = address; keepGoing && chunk < end; chunk += chunkBytes) {
                const mach_vm_size_t length = MIN((mach_vm_size_t)chunkBytes, end - chunk);
                mach_vm_size_t pages = length / page;
                if (mach_vm_page_range_query(task, chunk, length, (mach_vm_address_t)(uintptr_t)dispositions,
                                             &pages) != KERN_SUCCESS) continue;
                mach_vm_size_t index = 0;
                while (keepGoing && index < pages) {
                    if (!(dispositions[index] & VM_PAGE_QUERY_PAGE_PRESENT)) { index++; continue; }
                    const mach_vm_address_t stretch = chunk + index * page;
                    size_t filled = 0;
                    while (index < pages && (dispositions[index] & VM_PAGE_QUERY_PAGE_PRESENT)) {
                        mach_vm_size_t read = 0;
                        const kern_return_t result = mach_vm_read_overwrite(task, chunk + index * page, page,
                            (mach_vm_address_t)(uintptr_t)((char *)buffer + filled), &read);
                        index++;
                        if (result != KERN_SUCCESS || read != page) break; // Freed meanwhile.
                        filled += page;
                    }
                    if (filled > 0) {
                        keepGoing = visitor(stretch, buffer, filled / sizeof(uint32_t));
                        sincePause += filled;
                    }
                    if (sincePause >= MULG_CAMERA_PAUSE_BYTES) {
                        sincePause = 0;
                        usleep(MULG_CAMERA_PAUSE_MICROSECONDS);
                    }
                }
            }
        }
        address += size;
    }
    tagged_free(buffer, chunkBytes);
    tagged_free(dispositions, dispositionBytes);
    return true;
}

// MARK: - Single words

bool mulg_camera_read(uint64_t address, uint32_t *bits) {
    if (address & 3) return false;
    uint32_t value = 0;
    mach_vm_size_t read = 0;
    if (mach_vm_read_overwrite(mach_task_self(), address, sizeof(value), (mach_vm_address_t)(uintptr_t)&value,
                               &read) != KERN_SUCCESS || read != sizeof(value)) return false;
    *bits = value;
    return true;
}

int32_t mulg_camera_swap(uint64_t address, uint32_t expected, uint32_t replacement) {
    if (address & 3) return -1;
    mach_vm_address_t region = address;
    mach_vm_size_t size = 0;
    vm_region_basic_info_data_64_t info;
    mach_msg_type_number_t count = VM_REGION_BASIC_INFO_COUNT_64;
    mach_port_t object = MACH_PORT_NULL;
    kern_return_t result = mach_vm_region(mach_task_self(), &region, &size, VM_REGION_BASIC_INFO_64,
                                          (vm_region_info_t)&info, &count, &object);
    if (object != MACH_PORT_NULL) mach_port_deallocate(mach_task_self(), object);
    if (result != KERN_SUCCESS || region > address || address + sizeof(uint32_t) > region + size) return -1;
    if ((info.protection & (VM_PROT_READ | VM_PROT_WRITE)) != (VM_PROT_READ | VM_PROT_WRITE)
        || (info.protection & VM_PROT_EXECUTE)) return -1;
    // Through the kernel, never a plain store: the game may free this memory between the check above and
    // the write, and a store would then crash the game where a kernel call only fails. The value is compared
    // first; the game changing it in the instant between compare and write leaves our value, which is the
    // same outcome as the game writing just before.
    uint32_t current = 0;
    if (!mulg_camera_read(address, &current)) return -1;
    if (current != expected) return 0;
    if (mach_vm_write(mach_task_self(), address, (vm_offset_t)(uintptr_t)&replacement, sizeof(replacement)) != KERN_SUCCESS) {
        return -1;
    }
    return 1;
}

// MARK: - Value search

/// Candidates are kept per stretch of memory as 32-bit word indices from the stretch's base, so
/// each costs 8 bytes (12 once a second value is kept) instead of 16.
typedef struct {
    uint64_t base;
    uint64_t first;
    uint64_t count;
} MulgCameraStretch;

struct MulgCameraScan {
    MulgCameraStretch *stretches;
    uint64_t stretchCount, stretchCapacity;
    uint32_t *indices;
    uint32_t *firstValues;
    uint32_t *secondValues;
    uint64_t count, capacity;
    size_t indicesBytes, firstBytes, secondBytes, stretchBytes;
};

static bool add_stretch(MulgCameraScan *scan, uint64_t base) {
    if (scan->stretchCount == scan->stretchCapacity) {
        const uint64_t capacity = scan->stretchCapacity ? scan->stretchCapacity * 2 : 4096;
        const size_t bytes = page_rounded((size_t)capacity * sizeof(MulgCameraStretch));
        MulgCameraStretch *grown = tagged_allocate(bytes);
        if (!grown) return false;
        if (scan->stretches) memcpy(grown, scan->stretches, (size_t)scan->stretchCount * sizeof(MulgCameraStretch));
        tagged_free(scan->stretches, scan->stretchBytes);
        scan->stretches = grown;
        scan->stretchBytes = bytes;
        scan->stretchCapacity = capacity;
    }
    scan->stretches[scan->stretchCount++] = (MulgCameraStretch){ base, scan->count, 0 };
    return true;
}

static uint32_t float_bits(float value) {
    uint32_t bits;
    memcpy(&bits, &value, sizeof(bits));
    return bits;
}

MulgCameraScan *mulg_camera_scan_create(float low, float high, uint64_t limit, MulgCameraScanStatus *status) {
    *status = MulgCameraScanStatusNoMemory;
    if (!(low > 0) || !(high >= low) || limit == 0) return NULL;
    MulgCameraScan *scan = calloc(1, sizeof(MulgCameraScan));
    if (!scan) return NULL;
    scan->capacity = limit;
    scan->indicesBytes = page_rounded((size_t)limit * sizeof(uint32_t));
    scan->firstBytes = scan->indicesBytes;
    // Reserved, not used: only the pages written to cost memory.
    scan->indices = tagged_allocate(scan->indicesBytes);
    scan->firstValues = tagged_allocate(scan->firstBytes);
    if (!scan->indices || !scan->firstValues) { mulg_camera_scan_free(scan); return NULL; }

    // Positive floats order like their bit patterns, so the range check is one unsigned compare.
    const uint32_t lowBits = float_bits(low), span = float_bits(high) - lowBits;
    __block bool overflow = false, failed = false;
    __block uint64_t stretchBase = UINT64_MAX;
    const bool walked = walk_memory(^bool(uint64_t address, const uint32_t *words, size_t count) {
        for (size_t i = 0; i < count; i++) {
            const uint32_t word = words[i];
            if (word - lowBits > span) continue;
            const uint64_t wordAddress = address + i * sizeof(uint32_t);
            if (stretchBase == UINT64_MAX || wordAddress < stretchBase
                || (wordAddress - stretchBase) / sizeof(uint32_t) > UINT32_MAX) {
                if (!add_stretch(scan, wordAddress)) { failed = true; return false; }
                stretchBase = wordAddress;
            }
            if (scan->count == scan->capacity) { overflow = true; return false; }
            scan->indices[scan->count] = (uint32_t)((wordAddress - stretchBase) / sizeof(uint32_t));
            scan->firstValues[scan->count] = word;
            scan->count++;
            scan->stretches[scan->stretchCount - 1].count++;
        }
        return true;
    });
    if (!walked || failed || overflow) {
        mulg_camera_scan_free(scan);
        *status = overflow ? MulgCameraScanStatusTooMany : MulgCameraScanStatusNoMemory;
        return NULL;
    }
    *status = MulgCameraScanStatusOK;
    return scan;
}

uint64_t mulg_camera_scan_count(const MulgCameraScan *scan) {
    return scan->count;
}

uint64_t mulg_camera_scan_filter(MulgCameraScan *scan, MulgCameraFilter filter, float ratio) {
    if (filter == MulgCameraFilterDecreased && !scan->secondValues && scan->count > 0) {
        scan->secondBytes = page_rounded((size_t)scan->count * sizeof(uint32_t));
        scan->secondValues = tagged_allocate(scan->secondBytes);
        if (!scan->secondValues) { scan->secondBytes = 0; return scan->count; }
    }
    if (filter == MulgCameraFilterEqualsSecond && !scan->secondValues) {
        scan->count = 0;
        return 0;
    }
    const size_t pageBytes = vm_page_size;
    uint32_t *page = tagged_allocate(pageBytes);
    if (!page) return scan->count;
    uint64_t cachedPage = UINT64_MAX;
    uint64_t pagesRead = 0;
    bool cachedReadable = false;
    uint64_t kept = 0;
    for (uint64_t s = 0; s < scan->stretchCount; s++) {
        MulgCameraStretch *stretch = &scan->stretches[s];
        const uint64_t first = stretch->first, end = first + stretch->count;
        stretch->first = kept;
        for (uint64_t c = first; c < end; c++) {
            const uint64_t address = stretch->base + (uint64_t)scan->indices[c] * sizeof(uint32_t);
            const uint64_t pageAddress = address & ~((uint64_t)pageBytes - 1);
            if (pageAddress != cachedPage) {
                mach_vm_size_t read = 0;
                cachedPage = pageAddress;
                if (++pagesRead % (MULG_CAMERA_PAUSE_BYTES / pageBytes) == 0) usleep(MULG_CAMERA_PAUSE_MICROSECONDS);
                cachedReadable = mach_vm_read_overwrite(mach_task_self(), pageAddress, pageBytes,
                                                        (mach_vm_address_t)(uintptr_t)page, &read) == KERN_SUCCESS
                    && read == pageBytes;
            }
            if (!cachedReadable) continue;
            const uint32_t now = page[(address - pageAddress) / sizeof(uint32_t)];
            const uint32_t before = scan->firstValues[c];
            bool keep;
            switch (filter) {
            case MulgCameraFilterDecreased: {
                float nowValue, beforeValue;
                memcpy(&nowValue, &now, sizeof(nowValue));
                memcpy(&beforeValue, &before, sizeof(beforeValue));
                // Exactly 0 counts too: a normalised zoom level (0 = all the way in) ends there.
                keep = nowValue >= 0 && nowValue < beforeValue && (nowValue == 0 || beforeValue >= nowValue * ratio);
                if (keep) scan->secondValues[kept] = now;
                break;
            }
            case MulgCameraFilterEqualsFirst:
                keep = now == before;
                if (keep && scan->secondValues) scan->secondValues[kept] = scan->secondValues[c];
                break;
            case MulgCameraFilterEqualsSecond:
                keep = now == scan->secondValues[c];
                if (keep) scan->secondValues[kept] = scan->secondValues[c];
                break;
            default:
                keep = false;
            }
            if (!keep) continue;
            scan->indices[kept] = scan->indices[c];
            scan->firstValues[kept] = before;
            kept++;
        }
        stretch->count = kept - stretch->first;
    }
    tagged_free(page, pageBytes);
    scan->count = kept;
    return kept;
}

uint64_t mulg_camera_scan_results(const MulgCameraScan *scan, uint64_t *addresses, uint32_t *first,
                                  uint32_t *second, uint64_t capacity) {
    uint64_t copied = 0;
    for (uint64_t s = 0; s < scan->stretchCount && copied < capacity; s++) {
        const MulgCameraStretch *stretch = &scan->stretches[s];
        for (uint64_t c = stretch->first; c < stretch->first + stretch->count && copied < capacity; c++) {
            addresses[copied] = stretch->base + (uint64_t)scan->indices[c] * sizeof(uint32_t);
            first[copied] = scan->firstValues[c];
            second[copied] = scan->secondValues ? scan->secondValues[c] : 0;
            copied++;
        }
    }
    return copied;
}

void mulg_camera_scan_free(MulgCameraScan *scan) {
    if (!scan) return;
    tagged_free(scan->indices, scan->indicesBytes);
    tagged_free(scan->firstValues, scan->firstBytes);
    tagged_free(scan->secondValues, scan->secondBytes);
    tagged_free(scan->stretches, scan->stretchBytes);
    free(scan);
}

// MARK: - Limit pairs

static bool is_excluded(uint64_t address, const uint64_t *excluded, size_t count) {
    for (size_t i = 0; i < count; i++) if (excluded[i] == address) return true;
    return false;
}

/// The neighbour `offset` bytes from word `index` of the current run, read separately when it
/// lies outside the run.
static bool neighbour(uint64_t runAddress, const uint32_t *words, size_t count, size_t index, int32_t offset,
                      uint32_t *bits) {
    const int64_t target = (int64_t)index + offset / (int32_t)sizeof(uint32_t);
    if (target >= 0 && (uint64_t)target < count) { *bits = words[target]; return true; }
    const uint64_t address = runAddress + index * sizeof(uint32_t) + (int64_t)offset;
    return mulg_camera_read(address, bits);
}

uint64_t mulg_camera_find_pairs(uint32_t farBits, uint32_t nearBits, const int32_t *offsets, size_t offsetCount,
                                int32_t window, const uint64_t *excluded, size_t excludedCount,
                                MulgCameraPair *pairs, uint64_t capacity) {
    if (farBits == nearBits || farBits == 0) return 0;
    window = window < 4 ? 4 : (window > 1024 ? 1024 : window);
    __block uint64_t found = 0;
    walk_memory(^bool(uint64_t address, const uint32_t *words, size_t count) {
        for (size_t i = 0; i < count; i++) {
            if (words[i] != farBits) continue;
            const uint64_t wordAddress = address + i * sizeof(uint32_t);
            if (excluded && is_excluded(wordAddress, excluded, excludedCount)) continue;
            int32_t match = 0;
            uint32_t bits = 0;
            if (offsets && offsetCount > 0) {
                for (size_t o = 0; o < offsetCount && !match; o++) {
                    const int32_t offset = offsets[o];
                    if (offset == 0 || (offset & 3)) continue;
                    if (neighbour(address, words, count, i, offset, &bits) && bits == nearBits) match = offset;
                }
            } else {
                for (int32_t distance = 4; distance <= window && !match; distance += 4) {
                    if (neighbour(address, words, count, i, distance, &bits) && bits == nearBits) match = distance;
                    else if (neighbour(address, words, count, i, -distance, &bits) && bits == nearBits) match = -distance;
                }
            }
            if (!match) continue;
            if (pairs && found < capacity) pairs[found] = (MulgCameraPair){ wordAddress, match };
            found++;
        }
        return true;
    });
    return found;
}

// MARK: - Several limit pairs in one pass

uint64_t mulg_camera_find_pair_sets(const uint32_t *farBits, const uint32_t *nearBits, size_t setCount, int32_t window,
                                    const uint64_t *excluded, size_t excludedCount,
                                    MulgCameraSetPair *pairs, uint64_t capacity, uint64_t *totals) {
    if (setCount == 0) return 0;
    window = window < 4 ? 4 : (window > 1024 ? 1024 : window);
    // Most words are rejected by one bit test on their top 16 bits (sign, exponent, 7 mantissa bits).
    uint64_t *filter = calloc(1024, sizeof(uint64_t));
    if (!filter) return 0;
    for (size_t s = 0; s < setCount; s++) {
        totals[s] = 0;
        const uint32_t high = farBits[s] >> 16;
        filter[high >> 6] |= 1ull << (high & 63);
    }
    __block uint64_t found = 0;
    walk_memory(^bool(uint64_t address, const uint32_t *words, size_t count) {
        for (size_t i = 0; i < count; i++) {
            const uint32_t word = words[i], high = word >> 16;
            if (!(filter[high >> 6] & (1ull << (high & 63)))) continue;
            for (size_t s = 0; s < setCount; s++) {
                if (word != farBits[s] || nearBits[s] == 0 || nearBits[s] == farBits[s]) continue;
                const uint64_t wordAddress = address + i * sizeof(uint32_t);
                if (excluded && is_excluded(wordAddress, excluded, excludedCount)) continue;
                int32_t match = 0;
                uint32_t bits = 0;
                for (int32_t distance = 4; distance <= window && !match; distance += 4) {
                    if (neighbour(address, words, count, i, distance, &bits) && bits == nearBits[s]) match = distance;
                    else if (neighbour(address, words, count, i, -distance, &bits) && bits == nearBits[s]) match = -distance;
                }
                if (!match) continue;
                totals[s]++;
                if (pairs && found < capacity) pairs[found] = (MulgCameraSetPair){ wordAddress, match, (int32_t)s };
                found++;
            }
        }
        return true;
    });
    free(filter);
    return found;
}

// MARK: - Diagnostics

bool mulg_camera_region(uint64_t address, uint32_t *tag, uint64_t *start, uint64_t *size) {
    mach_vm_address_t region = address;
    mach_vm_size_t length = 0;
    natural_t depth = 0;
    vm_region_submap_info_data_64_t info;
    mach_msg_type_number_t count = VM_REGION_SUBMAP_INFO_COUNT_64;
    for (;;) {
        if (mach_vm_region_recurse(mach_task_self(), &region, &length, &depth, (vm_region_recurse_info_t)&info,
                                   &count) != KERN_SUCCESS) return false;
        if (!info.is_submap) break;
        depth++;
        count = VM_REGION_SUBMAP_INFO_COUNT_64;
    }
    if (region > address || address >= region + length) return false;
    *tag = info.user_tag;
    *start = region;
    *size = length;
    return true;
}
