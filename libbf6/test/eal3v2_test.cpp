/* eal3v2_test - do EALayer3 v2 frames tile INSIDE each SPS 0x44 block?
 *
 * The outer chain is the SPS block layer: u8 type + u24 size ('H' 0x48 header,
 * 'D' 0x44 data, 'E' 0x45 end). Inside a 'D' block should be EALayer3 v2
 * frames, whose header per vgmstream is:
 *     bit 0     extended flag
 *     bit 1     stereo flag
 *     bits 2-3  reserved
 *     bits 4-15 FRAME SIZE (12 bits, whole frame incl. header)
 *   if extended: 2 offset_mode, 10 offset_samples, 10 pcm_samples, 10 common_size
 */
#include "source.h"
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>
#include <map>
using namespace bf6;
#include "sps_decode.inc"

static uint32_t bits_at(const uint8_t* p, size_t bit, int w)
{
    uint32_t v = 0;
    for (int i = 0; i < w; i++) { const size_t b = bit + (size_t)i;
        v = (v << 1) | ((p[b >> 3] >> (7 - (b & 7))) & 1); }
    return v;
}

int main(int argc, char** argv)
{
    if (argc < 2) { std::printf("usage: eal3v2_test <game> [level]\n"); return 2; }
    const char* level = (argc > 2) ? argv[2] : "mp_contaminated";
    Source src; std::string err;
    if (!src.open(argv[1], err)) { std::printf("open: %s\n", err.c_str()); return 1; }
    if (!src.mount_level(level, false, err)) { std::printf("mount: %s\n", err.c_str()); return 1; }

    int blocks = 0, dblocks = 0, tiled = 0, scanned = 0;
    long frames = 0, ext = 0, stereo = 0; double sum_gran = 0; int gn = 0;
    std::map<int,int> firstsizes;

    for (const auto& kv : src.loose_chunks()) {
        if (blocks >= 60 || scanned >= 4000) break;
        scanned++;
        std::string e;
        std::vector<uint8_t> b = src.get_chunk(kv.first, e);
        if (b.size() < 256) continue;
        SpsInfo s;
        if (!sps_parse(b.data(), b.size(), s) || s.codec != 0x16) continue;
        std::vector<Eal3Frame> fr;
        if (!sps_eal3_frames(b.data(), b.size(), s, fr)) continue;
        blocks++;
        long blockframes = 0;
        for (const Eal3Frame& f : fr) {
            if (f.tag != 0x44) continue;
            dblocks++;
            /* the SPS block header is 4 bytes: u8 type + u24 size */
            size_t pos = f.offset + 8;  /* u8 type + u24 size + u32 sample count */
            const size_t end = f.offset + f.size;
            bool ok = true; long n = 0;
            while (pos < end) {
                if (pos + 2 > end) { ok = false; break; }
                const uint32_t exf = bits_at(b.data() + pos, 0, 1);
                const uint32_t stf = bits_at(b.data() + pos, 1, 1);
                const uint32_t sz  = bits_at(b.data() + pos, 4, 12);
                if (sz < 2 || pos + sz > end) { ok = false; break; }
                if (n == 0) firstsizes[(int)sz]++;
                ext += exf; stereo += stf;
                pos += sz; n++; frames++; blockframes++;
                if (n > 5000) { ok = false; break; }
            }
            if (ok && pos == end) tiled++;
        }
        if (blockframes) { sum_gran += (double)s.samples / (double)blockframes; gn++; }
    }
    std::printf("  SPS blocks              : %d\n", blocks);
    std::printf("  0x44 data blocks        : %d   inner frames TILE exactly: %d\n", dblocks, tiled);
    std::printf("  EA frames parsed        : %ld   extended %ld   stereo %ld\n", frames, ext, stereo);
    std::printf("  mean samples per frame  : %.1f   (576 = one MPEG granule)\n", gn ? sum_gran / gn : 0.0);
    std::printf("  first-frame sizes seen  : %zu distinct\n", firstsizes.size());
    return (dblocks && tiled == dblocks) ? 0 : 1;
}
