/* eal3find_test - SEARCH for the EA Layer3 frame-size field rather than guess it.
 *
 * Accept criterion, stated before running: a candidate (bit offset, width,
 * units, addend) is accepted only if, walking frame by frame from the body
 * start, the frames TILE THE PAYLOAD EXACTLY on many independent blocks, and
 * the resulting frame count is consistent with samples/1152 for an MPEG Layer
 * III frame. A field that merely produces plausible numbers on one block is
 * not accepted.
 */
#include "source.h"
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>
#include <map>
using namespace bf6;
#include "sps_decode.inc"

struct Blk { std::vector<uint8_t> b; SpsInfo s; };

/* big-endian bit reader */
static uint32_t bits_at(const uint8_t* p, size_t bitpos, int w)
{
    uint32_t v = 0;
    for (int i = 0; i < w; i++) {
        const size_t bp = bitpos + (size_t)i;
        const uint8_t byte = p[bp >> 3];
        v = (v << 1) | ((byte >> (7 - (bp & 7))) & 1);
    }
    return v;
}

int main(int argc, char** argv)
{
    if (argc < 2) { std::printf("usage: eal3find_test <game> [level]\n"); return 2; }
    const char* level = (argc > 2) ? argv[2] : "mp_contaminated";
    Source src; std::string err;
    if (!src.open(argv[1], err)) { std::printf("open: %s\n", err.c_str()); return 1; }
    if (!src.mount_level(level, false, err)) { std::printf("mount: %s\n", err.c_str()); return 1; }

    std::vector<Blk> blocks;
    int scanned = 0;
    for (const auto& kv : src.loose_chunks()) {
        if (blocks.size() >= 25 || scanned >= 3000) break;
        scanned++;
        std::string e;
        std::vector<uint8_t> b = src.get_chunk(kv.first, e);
        if (b.size() < 256) continue;
        SpsInfo s;
        if (!sps_parse(b.data(), b.size(), s) || s.codec != 0x16) continue;
        blocks.push_back({std::move(b), s});
    }
    std::printf("collected %zu EA Layer3 blocks\n\n", blocks.size());
    if (blocks.empty()) return 1;

    struct Best { int off, w, unit, add, tiled; double framedelta; };
    std::vector<Best> hits;

    for (int off = 0; off <= 24; off++)
    for (int w = 9; w <= 16; w++)
    for (int unit = 1; unit <= 8; unit *= 2)      /* size in bytes, or in units of 2/4/8 */
    for (int add = 0; add <= 8; add += 4) {       /* size may exclude its own header */
        int tiled = 0; double fdsum = 0; int fdn = 0;
        for (const Blk& B : blocks) {
            const size_t start = B.s.header, end = B.b.size();
            size_t pos = start; int frames = 0; bool ok = true;
            while (pos < end) {
                if (pos + 4 > end) { ok = false; break; }
                const uint32_t f = bits_at(B.b.data() + pos, (size_t)off, w);
                const size_t sz = (size_t)f * (size_t)unit + (size_t)add;
                if (sz < 4 || sz > 4096) { ok = false; break; }
                pos += sz; frames++;
                if (frames > 20000) { ok = false; break; }
            }
            if (ok && pos == end && frames > 4) {
                tiled++;
                const double expect = (double)B.s.samples / 1152.0;
                fdsum += (double)frames / (expect > 0 ? expect : 1.0); fdn++;
            }
        }
        if (tiled >= (int)blocks.size() / 2)
            hits.push_back({off, w, unit, add, tiled, fdn ? fdsum / fdn : 0});
    }

    std::printf("candidates tiling at least half of %zu blocks EXACTLY:\n", blocks.size());
    if (hits.empty()) std::printf("  NONE. No fixed-position size field tiles the payload.\n");
    for (const Best& h : hits)
        std::printf("  bit off %2d  width %2d  unit %d  add %d  ->  tiled %d/%zu  frames/expected %.3f\n",
                    h.off, h.w, h.unit, h.add, h.tiled, blocks.size(), h.framedelta);
    return hits.empty() ? 1 : 0;
}
