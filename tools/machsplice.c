// machsplice -- add or remove an LC_LOAD_DYLIB entry in a Mach-O file.
//
// This is how the payload gets loaded at process start: dyld only honours a
// __DATA,__interpose section for images present at launch, and Geode loads its
// mods with dlopen() well into GD's runtime, far too late. Splicing a load
// command into a library GD already links is the same trick Geode's own macOS
// installer uses on libfmod.dylib.
//
// The new command is written into the padding between the end of the load
// commands and the first section's file offset, so nothing in the file moves
// and fat-header offsets stay valid. Existing code signatures are invalidated
// by design -- re-sign afterwards.
//
// Deliberately dependency-free: the alternative (Python + LIEF) is a heavy ask
// for users who just want to double-click an installer.

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

#define LC_SEGMENT_64  0x19
#define LC_LOAD_DYLIB  0x0C
#define MH_MAGIC_64    0xfeedfacf
#define FAT_MAGIC      0xcafebabe
#define FAT_MAGIC_64   0xcafebabf

static uint32_t be32(const uint8_t *p) {
    return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) | ((uint32_t)p[2] << 8) | p[3];
}
static uint64_t be64(const uint8_t *p) { return ((uint64_t)be32(p) << 32) | be32(p + 4); }
static uint32_t rd32(const uint8_t *p) { uint32_t v; memcpy(&v, p, 4); return v; }
static void     wr32(uint8_t *p, uint32_t v) { memcpy(p, &v, 4); }

struct slice { size_t off; };

static int collect_slices(uint8_t *d, size_t n, struct slice *out, int max) {
    if (n < 8) return 0;
    uint32_t magic = be32(d);
    if (magic == FAT_MAGIC || magic == FAT_MAGIC_64) {
        uint32_t cnt = be32(d + 4);
        int wide = (magic == FAT_MAGIC_64);
        size_t esz = wide ? 32 : 20;
        int k = 0;
        for (uint32_t i = 0; i < cnt && k < max; i++) {
            const uint8_t *a = d + 8 + i * esz;
            if ((size_t)(a - d) + esz > n) break;
            out[k++].off = wide ? (size_t)be64(a + 8) : (size_t)be32(a + 8);
        }
        return k;
    }
    if (rd32(d) == MH_MAGIC_64) { out[0].off = 0; return 1; }
    return 0;
}

// Lowest non-zero section file offset -- the ceiling for header growth.
static size_t first_section_off(uint8_t *d, size_t base) {
    uint32_t ncmds = rd32(d + base + 16);
    size_t p = base + 32, best = 0;
    for (uint32_t i = 0; i < ncmds; i++) {
        uint32_t cmd = rd32(d + p), cmdsize = rd32(d + p + 4);
        if (!cmdsize) break;
        if (cmd == LC_SEGMENT_64) {
            uint32_t nsects = rd32(d + p + 64);
            size_t q = p + 72;
            for (uint32_t s = 0; s < nsects; s++, q += 80) {
                uint32_t soff = rd32(d + q + 48);
                if (soff && (!best || soff < best)) best = soff;
            }
        }
        p += cmdsize;
    }
    return best;
}

static int has_dylib(uint8_t *d, size_t base, const char *path) {
    uint32_t ncmds = rd32(d + base + 16);
    size_t p = base + 32;
    for (uint32_t i = 0; i < ncmds; i++) {
        uint32_t cmd = rd32(d + p), cmdsize = rd32(d + p + 4);
        if (!cmdsize) break;
        if (cmd == LC_LOAD_DYLIB) {
            uint32_t noff = rd32(d + p + 8);
            if (noff < cmdsize && !strcmp((char *)(d + p + noff), path)) return 1;
        }
        p += cmdsize;
    }
    return 0;
}

static int add_dylib(uint8_t *d, size_t n, size_t base, const char *path) {
    if (has_dylib(d, base, path)) return 0;             // already present

    uint32_t ncmds      = rd32(d + base + 16);
    uint32_t sizeofcmds = rd32(d + base + 20);
    size_t   end_lc     = base + 32 + sizeofcmds;

    size_t len     = strlen(path) + 1;
    size_t cmdsize = (24 + len + 7) & ~(size_t)7;       // 8-byte aligned

    size_t ceiling = first_section_off(d, base);
    if (!ceiling) { fprintf(stderr, "machsplice: no sections found\n"); return -1; }
    if (end_lc + cmdsize > base + ceiling) {
        fprintf(stderr, "machsplice: not enough header padding (%zu needed, %zu free)\n",
                cmdsize, base + ceiling - end_lc);
        return -1;
    }
    if (end_lc + cmdsize > n) { fprintf(stderr, "machsplice: truncated file\n"); return -1; }

    uint8_t *c = d + end_lc;
    memset(c, 0, cmdsize);
    wr32(c + 0,  LC_LOAD_DYLIB);
    wr32(c + 4,  (uint32_t)cmdsize);
    wr32(c + 8,  24);            // name offset within the command
    wr32(c + 12, 0);             // timestamp
    wr32(c + 16, 0x10000);       // current_version 1.0.0
    wr32(c + 20, 0x10000);       // compatibility_version 1.0.0
    memcpy(c + 24, path, len);

    wr32(d + base + 16, ncmds + 1);
    wr32(d + base + 20, sizeofcmds + (uint32_t)cmdsize);
    return 1;
}

static int remove_dylib(uint8_t *d, size_t base, const char *path) {
    uint32_t ncmds      = rd32(d + base + 16);
    uint32_t sizeofcmds = rd32(d + base + 20);
    size_t   end_lc     = base + 32 + sizeofcmds;
    size_t   p          = base + 32;

    for (uint32_t i = 0; i < ncmds; i++) {
        uint32_t cmd = rd32(d + p), cmdsize = rd32(d + p + 4);
        if (!cmdsize) break;
        if (cmd == LC_LOAD_DYLIB) {
            uint32_t noff = rd32(d + p + 8);
            if (noff < cmdsize && !strcmp((char *)(d + p + noff), path)) {
                memmove(d + p, d + p + cmdsize, end_lc - (p + cmdsize));
                memset(d + end_lc - cmdsize, 0, cmdsize);
                wr32(d + base + 16, ncmds - 1);
                wr32(d + base + 20, sizeofcmds - cmdsize);
                return 1;
            }
        }
        p += cmdsize;
    }
    return 0;
}

int main(int argc, char **argv) {
    int removing = 0, argi = 1;
    if (argc > 1 && !strcmp(argv[1], "--remove")) { removing = 1; argi = 2; }
    if (argc - argi != 2) {
        fprintf(stderr, "usage: machsplice [--remove] <macho-file> <dylib-path>\n");
        return 2;
    }
    const char *file = argv[argi], *path = argv[argi + 1];

    FILE *f = fopen(file, "rb");
    if (!f) { perror(file); return 1; }
    fseek(f, 0, SEEK_END);
    long n = ftell(f);
    fseek(f, 0, SEEK_SET);
    uint8_t *d = malloc((size_t)n);
    if (!d || fread(d, 1, (size_t)n, f) != (size_t)n) { fprintf(stderr, "read failed\n"); return 1; }
    fclose(f);

    struct slice sl[16];
    int ns = collect_slices(d, (size_t)n, sl, 16);
    if (!ns) { fprintf(stderr, "machsplice: not a 64-bit Mach-O\n"); return 1; }

    int changed = 0;
    for (int i = 0; i < ns; i++) {
        if (rd32(d + sl[i].off) != MH_MAGIC_64) continue;   // skip non-64-bit slices
        int r = removing ? remove_dylib(d, sl[i].off, path)
                         : add_dylib(d, (size_t)n, sl[i].off, path);
        if (r < 0) return 1;
        changed += r;
    }

    if (changed) {
        f = fopen(file, "wb");
        if (!f) { perror(file); return 1; }
        if (fwrite(d, 1, (size_t)n, f) != (size_t)n) { fprintf(stderr, "write failed\n"); return 1; }
        fclose(f);
    }
    printf("%s %d of %d slice(s)\n", removing ? "cleaned" : "spliced", changed, ns);
    free(d);
    return 0;
}
