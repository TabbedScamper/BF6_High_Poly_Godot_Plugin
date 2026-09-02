/* eal3walk_test - characterise the EA Layer3 block framing found by search.
 *
 * The search established: a frame is [u8 tag][u8][u16 big-endian SIZE][...],
 * and walking `pos += size` from the SPS header tiles the payload EXACTLY on
 * 25 of 25 blocks. This measures what the frames look like.
 */
#include "source.h"
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>
#include <map>
using namespace bf6;
#include "sps_decode.inc"

int main(int argc, char** argv)
{
    if (argc < 2) { std::printf("usage: eal3walk_test <game> [level]\n"); return 2; }
    const char* level = (argc > 2) ? argv[2] : "mp_contaminated";
    Source src; std::string err;
    if (!src.open(argv[1], err)) { std::printf("open: %s\n", err.c_str()); return 1; }
    if (!src.mount_level(level, false, err)) { std::printf("mount: %s\n", err.c_str()); return 1; }

    std::map<uint8_t,int> tag0, tag1, lasttag;
    std::map<int,int> sizes;
    int blocks = 0, tiled = 0, scanned = 0;
    long totframes = 0; double ratio_sum = 0;
    int firstshown = 0;

    for (const auto& kv : src.loose_chunks()) {
        if (blocks >= 200 || scanned >= 6000) break;
        scanned++;
        std::string e;
        std::vector<uint8_t> b = src.get_chunk(kv.first, e);
        if (b.size() < 256) continue;
        SpsInfo s;
        if (!sps_parse(b.data(), b.size(), s) || s.codec != 0x16) continue;
        blocks++;

        size_t pos = s.header; int frames = 0; uint8_t lt = 0; bool ok = true;
        while (pos < b.size()) {
            if (pos + 4 > b.size()) { ok = false; break; }
            const uint8_t t0 = b[pos], t1 = b[pos + 1];
            const int sz = (b[pos + 2] << 8) | b[pos + 3];
            if (sz < 4 || pos + (size_t)sz > b.size()) { ok = false; break; }
            tag0[t0]++; tag1[t1]++; sizes[sz]++;
            lt = t0; pos += (size_t)sz; frames++;
            if (firstshown < 2 && frames <= 4)
                std::printf("   frame %d: tag %02x %02x size %d\n", frames, t0, t1, sz);
        }
        if (ok && pos == b.size()) {
            tiled++; totframes += frames; lasttag[lt]++;
            ratio_sum += (double)s.samples / (double)frames;
        }
        if (firstshown < 2) { std::printf("  ^ chunk %s samples %u\n", kv.first.substr(0,12).c_str(), s.samples); firstshown++; }
    }

    std::printf("\n  EA Layer3 blocks     : %d   tiled exactly: %d\n", blocks, tiled);
    std::printf("  total frames         : %ld\n", totframes);
    std::printf("  mean samples/frame   : %.1f\n", tiled ? ratio_sum / tiled : 0.0);
    std::printf("  frame tag byte 0     : ");
    for (auto& k : tag0) std::printf("0x%02X x%d  ", k.first, k.second);
    std::printf("\n  LAST frame's tag     : ");
    for (auto& k : lasttag) std::printf("0x%02X x%d  ", k.first, k.second);
    std::printf("\n  frame sizes          : %zu distinct, min %d max %d\n",
                sizes.size(), sizes.empty()?0:sizes.begin()->first,
                sizes.empty()?0:sizes.rbegin()->first);
    return (tiled == blocks && blocks > 0) ? 0 : 1;
}
