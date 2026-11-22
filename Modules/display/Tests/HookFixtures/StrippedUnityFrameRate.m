// Exercise the production decoder without loading or executing any game code.
#include "MulgUnityFrameRate.m"
#include <assert.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <stdio.h>

static uint32_t adrp(uintptr_t pc, uintptr_t value, unsigned reg) {
    int64_t delta = ((int64_t)(value & ~4095ULL) - (int64_t)(pc & ~4095ULL)) / 4096;
    return 0x90000000 | ((delta & 3) << 29) | (((delta >> 2) & 0x7ffff) << 5) | reg;
}
static void wrapper(uint32_t *p, const char *name, uintptr_t cache, uintptr_t resolver, BOOL setter) {
    unsigned result = setter ? 1 : 0, literal = setter ? 8 : 0;
    p[-6] = adrp((uintptr_t)(p - 6), cache, 19);
    p[-5] = 0xf9400260 | result | (((cache & 4095) / 8) << 10);
    p[-4] = 0xb4000080 | result;
    p[0] = adrp((uintptr_t)p, (uintptr_t)name, literal);
    p[1] = 0x91000000 | literal | (literal << 5) | (((uintptr_t)name & 4095) << 10);
    unsigned call = setter ? 4 : 2, store = setter ? 7 : 3;
    if (setter) { p[2] = 0xaa0003f4; p[3] = 0xaa0803e0; p[5] = 0xaa0003e1; p[6] = 0xaa1403e0; }
    p[call] = 0x94000000 | (((resolver - (uintptr_t)(p + call)) / 4) & 0x03ffffff);
    p[store] = 0xf9000260 | result | (p[-5] & 0x003ffc00);
    p[store+1] = 0xa9417bfd; p[store+2] = 0xa8c24ff4; p[store+3] = 0xd61f0000 | (result << 5);
}
int main(int argc, char **argv) { @autoreleasepool {
    size_t size = 65536;
    unsigned char *b = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0);
    assert(b != MAP_FAILED);
    UnityRange code = {(uintptr_t)b + 4096,4096}, strings = {(uintptr_t)b + 8192,4096};
    UnityRange native = {(uintptr_t)b,4096}, data = {(uintptr_t)b + 12288,4096};
    char *set = (void *)strings.start, *get = set + 128;
    strcpy(set, setterName); strcpy(get, getterName);
    uint32_t *s = (void *)(code.start + 128), *g = (void *)(code.start + 512);
    wrapper(s, set, data.start + 16, native.start + 64, YES);
    wrapper(g, get, data.start + 24, native.start + 64, NO);
    UnityCallSite a = find_call(code, strings, native, data, setterName, YES);
    UnityCallSite z = find_call(code, strings, native, data, getterName, NO);
    assert(a.resolver == native.start + 64 && a.resolver == z.resolver && a.cache == data.start + 16);
    for (int i = -6; i <= 10; ++i) {
        if (i == -3 || i == -2 || i == -1) continue;
        uint32_t old = s[i]; s[i] = 0;
        assert(!find_call(code, strings, native, data, setterName, YES).resolver);
        s[i] = old;
    }
    assert(!find_call(code, strings, (UnityRange){0}, data, setterName, YES).resolver);
    assert(!find_call(code, strings, native, (UnityRange){0}, setterName, YES).resolver);
    assert(!find_call(code, (UnityRange){strings.start, 3}, native, data, setterName, YES).resolver);
    wrapper((void *)(code.start + 1024), set, data.start + 16, native.start + 64, YES);
    assert(!find_call(code, strings, native, data, setterName, YES).resolver);
    munmap(b,size);
    assert(!mulg_display_unity_frame_rate_resolve());
    assert(mulg_display_unity_target_frame_rate() == INT32_MIN);
    assert(!mulg_display_set_unity_target_frame_rate(120));
    if (argc > 1) {
        int fd = open(argv[1], O_RDONLY); assert(fd >= 0);
        struct stat st; assert(!fstat(fd,&st));
        b = mmap(NULL, st.st_size, PROT_READ, MAP_PRIVATE, fd, 0); assert(b != MAP_FAILED); close(fd);
        const struct mach_header_64 *h = (const void *)b; assert(h->magic == MH_MAGIC_64);
        intptr_t slide = (intptr_t)b;
        code = section_range(h, slide, "il2cpp"); strings = section_range(h, slide, "__cstring");
        native = section_range(h, slide, "__text");
        const struct load_command *c = (const void *)(h+1); data = (UnityRange){0};
        for (uint32_t i=0;i<h->ncmds;i++,c=(const void *)((const char *)c+c->cmdsize))
            if(c->cmd==LC_SEGMENT_64) { const struct segment_command_64 *seg=(const void *)c;
                if(!strcmp(seg->segname,"__DATA"))data=(UnityRange){seg->vmaddr+slide,seg->vmsize}; }
        a = find_call(code, strings, native, data, setterName, YES);
        z = find_call(code, strings, native, data, getterName, NO);
        assert(a.resolver && a.resolver == z.resolver);
        printf("Player validated: two matching wrappers, resolver +0x%lx, cache +0x%lx\n", a.resolver-slide,a.cache-slide);
        munmap(b,st.st_size);
    }
    puts("Stripped Unity frame-rate regression checks passed");
} }
