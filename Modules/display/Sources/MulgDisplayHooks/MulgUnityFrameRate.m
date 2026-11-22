// Unity targetFrameRate access, including ARM64 players that strip IL2CPP exports.
#import "MulgDisplayHooks.h"
#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <string.h>
#include <stdatomic.h>

typedef void *(*ResolveInternalCall)(const char *name);
static void (*set_target_frame_rate)(int32_t);
static int32_t (*get_target_frame_rate)(void);
static const char *const setterName = "UnityEngine.Application::set_targetFrameRate(System.Int32)";
static const char *const getterName = "UnityEngine.Application::get_targetFrameRate()";

typedef struct { uintptr_t start; size_t size; } UnityRange;
typedef struct { uintptr_t resolver, cache; } UnityCallSite;
static BOOL contains(UnityRange range, uintptr_t address, size_t size) {
    return address >= range.start && size <= range.size && address - range.start <= range.size - size;
}
static uintptr_t page_address(uint32_t instruction, uintptr_t pc) {
    int64_t immediate = ((instruction >> 5) & 0x7ffff) * 4 + ((instruction >> 29) & 3);
    if (immediate & (1 << 20)) immediate -= 1 << 21;
    return (pc & ~(uintptr_t)4095) + immediate * 4096;
}

// Accept only IL2CPP's cached-call wrapper: load cache, CBZ to the literal load,
// resolve the exact signature, store the result back to the same slot, tail-call it.
// Both independent wrappers must identify the same resolver. Unknown code is left alone.
static UnityCallSite find_call(UnityRange code, UnityRange strings, UnityRange nativeCode,
                               UnityRange data, const char *name, BOOL setter) {
    UnityCallSite found = {0};
    const uint32_t *words = (const uint32_t *)code.start;
    for (size_t i = 6; i + 12 < code.size / 4; ++i) {
        const uint32_t *p = words + i;
        unsigned literalRegister = setter ? 8 : 0;
        if ((p[0] & 0x9f00001f) != (0x90000000 | literalRegister) ||
            (p[1] & 0xffc003ff) != (0x91000000 | (literalRegister << 5) | literalRegister)) continue;
        uintptr_t literal = page_address(p[0], (uintptr_t)p) + ((p[1] >> 10) & 4095);
        size_t length = strlen(name) + 1;
        if (!contains(strings, literal, length) || memcmp((const void *)literal, name, length)) continue;
        unsigned resultRegister = setter ? 1 : 0;
        // CBZ Xresult, literal-load (16 bytes forward), preceded by LDR Xresult,[X19,#slot].
        if (p[-4] != (0xb4000080 | resultRegister) ||
            (p[-5] & 0xffc003ff) != (0xf9400260 | resultRegister) ||
            (p[-6] & 0x9f00001f) != 0x90000013) continue;
        uintptr_t cache = page_address(p[-6], (uintptr_t)(p - 6)) + ((p[-5] >> 10) & 4095) * 8;
        if ((cache & 7) || !contains(data, cache, sizeof(uintptr_t))) continue;
        size_t call = setter ? 4 : 2;
        if (setter && (p[2] != 0xaa0003f4 || p[3] != 0xaa0803e0 ||
                       p[5] != 0xaa0003e1 || p[6] != 0xaa1403e0)) continue;
        if ((p[call] & 0xfc000000) != 0x94000000) continue;
        size_t store = setter ? 7 : 3;
        uint32_t expectedStore = 0xf9000260 | resultRegister | (p[-5] & 0x003ffc00);
        if (p[store] != expectedStore || p[store + 1] != 0xa9417bfd ||
            p[store + 2] != 0xa8c24ff4 || p[store + 3] != (0xd61f0000 | (resultRegister << 5))) continue;
        int64_t offset = p[call] & 0x03ffffff;
        if (offset & (1 << 25)) offset -= 1 << 26;
        uintptr_t resolver = (uintptr_t)(p + call) + offset * 4;
        if (!contains(nativeCode, resolver, 4)) continue;
        // Ambiguity is unsupported, even if another copy appears plausible.
        if (found.resolver) return (UnityCallSite){0};
        found = (UnityCallSite){ resolver, cache };
    }
    return found;
}

static UnityRange section_range(const struct mach_header_64 *header, intptr_t slide, const char *section) {
    const struct load_command *command = (const void *)(header + 1);
    for (uint32_t i = 0; i < header->ncmds; ++i) {
        if (command->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *segment = (const void *)command;
            const struct section_64 *s = (const void *)(segment + 1);
            for (uint32_t j = 0; j < segment->nsects; ++j, ++s)
                if (!strcmp(s->segname, "__TEXT") && !strcmp(s->sectname, section) &&
                    (segment->initprot & VM_PROT_READ))
                    return (UnityRange){ s->addr + slide, (size_t)s->size };
        }
        command = (const void *)((const char *)command + command->cmdsize);
    }
    return (UnityRange){0};
}

static ResolveInternalCall stripped_resolver(void) {
#if defined(__arm64__) && !defined(__arm64e__)
    // Only repeat the scan when dyld has loaded another image. Calls stay on the main thread.
    static uint32_t scannedImages;
    static UnityCallSite setter;
    static UnityRange nativeCode;
    uint32_t count = _dyld_image_count();
    if (!setter.resolver && count != scannedImages) {
        scannedImages = count;
        for (uint32_t i = 0; i < count; ++i) {
            const struct mach_header_64 *header = (const void *)_dyld_get_image_header(i);
            if (!header || header->magic != MH_MAGIC_64) continue;
            intptr_t slide = _dyld_get_image_vmaddr_slide(i);
            UnityRange code = section_range(header, slide, "il2cpp");
            if (!code.size) continue;
            UnityRange strings = section_range(header, slide, "__cstring");
            UnityRange text = section_range(header, slide, "__text");
            UnityRange data = {0};
            const struct load_command *command = (const void *)(header + 1);
            for (uint32_t j = 0; j < header->ncmds; ++j) {
                if (command->cmd == LC_SEGMENT_64) {
                    const struct segment_command_64 *segment = (const void *)command;
                    if (!strcmp(segment->segname, "__DATA") && (segment->initprot & VM_PROT_WRITE))
                        data = (UnityRange){ segment->vmaddr + slide, (size_t)segment->vmsize };
                }
                command = (const void *)((const char *)command + command->cmdsize);
            }
            UnityCallSite s = find_call(code, strings, text, data, setterName, YES);
            UnityCallSite g = find_call(code, strings, text, data, getterName, NO);
            if (s.resolver && s.resolver == g.resolver) { setter = s; nativeCode = text; break; }
        }
    }
    if (!setter.resolver) return NULL;
    // A populated game cache proves Unity has registered its calls. Do not invoke a
    // private resolver during startup or execute addresses outside this player's code.
    uintptr_t cached = atomic_load_explicit((_Atomic(uintptr_t) *)setter.cache, memory_order_relaxed);
    if (!contains(nativeCode, cached, 4)) return NULL;
    ResolveInternalCall resolve = (ResolveInternalCall)setter.resolver;
    void *set = resolve(setterName), *get = resolve(getterName);
    if ((uintptr_t)set != cached || !contains(nativeCode, (uintptr_t)get, 4)) return NULL;
    return resolve;
#else
    return NULL;
#endif
}

BOOL mulg_display_unity_frame_rate_resolve(void) {
    if (set_target_frame_rate && get_target_frame_rate) return YES;
    ResolveInternalCall resolve = (ResolveInternalCall)dlsym(RTLD_DEFAULT, "il2cpp_resolve_icall");
    if (!resolve) resolve = stripped_resolver();
    if (!resolve) return NO;
    void *set = resolve(setterName), *get = resolve(getterName);
    if (!set || !get) return NO;
    set_target_frame_rate = (void (*)(int32_t))set;
    get_target_frame_rate = (int32_t (*)(void))get;
    return YES;
}

int32_t mulg_display_unity_target_frame_rate(void) {
    return get_target_frame_rate ? get_target_frame_rate() : INT32_MIN;
}
BOOL mulg_display_set_unity_target_frame_rate(int32_t framesPerSecond) {
    if (!set_target_frame_rate) return NO;
    set_target_frame_rate(framesPerSecond);
    return YES;
}
int32_t mulg_display_unity_unlock_target(int32_t current, int32_t target) {
    if (target <= 60 || current == INT32_MIN) return 0;
    return current < target ? target : 0;
}
