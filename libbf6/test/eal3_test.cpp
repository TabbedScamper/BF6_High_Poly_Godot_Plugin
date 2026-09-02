/* eal3_test - derive EA Layer3 framing from the shipped bytes. */
#include "source.h"
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>
#include <map>
using namespace bf6;
#include "sps_decode.inc"

static void hexdump(const uint8_t* p, size_t n, size_t base)
{
    for (size_t i = 0; i < n; i += 16) {
        std::printf("    %04zx  ", base + i);
        for (size_t k = 0; k < 16; k++) if (i+k<n) std::printf("%02x ", p[i+k]); else std::printf("   ");
        std::printf(" ");
        for (size_t k = 0; k < 16 && i+k < n; k++) {
            uint8_t c = p[i+k]; std::printf("%c", (c>=32&&c<127)?(char)c:'.');
        }
        std::printf("\n");
    }
}

int main(int argc, char** argv)
{
    if (argc < 2) { std::printf("usage: eal3_test <game> [level]\n"); return 2; }
    const char* level = (argc > 2) ? argv[2] : "mp_contaminated";
    Source src; std::string err;
    if (!src.open(argv[1], err)) { std::printf("open: %s\n", err.c_str()); return 1; }
    if (!src.mount_level(level, false, err)) { std::printf("mount: %s\n", err.c_str()); return 1; }

    int shown = 0, scanned = 0;
    for (const auto& kv : src.loose_chunks()) {
        if (shown >= 3 || scanned >= 3000) break;
        scanned++;
        std::string e;
        std::vector<uint8_t> b = src.get_chunk(kv.first, e);
        if (b.size() < 64) continue;
        SpsInfo s;
        if (!sps_parse(b.data(), b.size(), s) || s.codec != 0x16) continue;
        shown++;
        std::printf("chunk %s  ch %d  %d Hz  %u samples  payload %zu B  header field 0x%X\n",
                    kv.first.substr(0,16).c_str(), s.channels, s.rate, s.samples, b.size(), s.header);
        std::printf("  samples/1152 = %.2f   samples/576 = %.2f\n",
                    s.samples / 1152.0, s.samples / 576.0);
        size_t nz=0,last=0; for (size_t i=0;i<b.size();i++) if (b[i]) { nz++; last=i; }
        std::printf("  non-zero %zu of %zu (%.1f%%)  last non-zero 0x%zx\n", nz, b.size(), 100.0*(double)nz/(double)b.size(), last);
        hexdump(b.data(), 48, 0);
        if (last > 300) { std::printf("  tail:\n"); hexdump(b.data()+last-31, 32, last-31); }
        std::printf("\n");
    }
    return shown ? 0 : 1;
}
