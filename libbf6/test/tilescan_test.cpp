/* tilescan_test - WHICH window of a node's trailer is the colour tile.
 *
 * detect_layout decomposes a chunk as [planes][weight pages][k colour tiles]
 * and color_slices then picks, among the k aligned windows, the one that
 * SCORES best as an image. On mp_granite the pick is wrong on most fine nodes
 * and the colour map comes back as blocks of flat navy and maroon, which is
 * what a weight page looks like read as BC1. This dumps the evidence: per
 * node, every aligned candidate window with its ordering score and its decoded
 * statistics, so the discriminator can be chosen against data rather than
 * guessed.
 *
 *   tilescan_test <game_dir> <level> [--depth=N] [--limit=N]
 */
#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <map>
#include <set>
#include <string>
#include <vector>

#include "source.h"
#include "splat.h"
#include "terraincomposite.h"

using namespace bf6;

namespace {

// The BC7 discriminator color_slices uses.
double mode47(const std::vector<uint8_t>& d, size_t start)
{
    int hits = 0, n = 0;
    for (size_t b = start; b + 16 <= d.size() && n < 512; b += 64, n++)
        if (d[b] != 0 && (d[b] & 0x0F) == 0) hits++;
    return n ? (double)hits / (double)n : 0.0;
}

// How many of the sampled BLOCKS are distinct. A photograph never repeats a
// block; a constant filler raster has one or two and still scores a perfect
// 1.0 on endpoint ordering, which is the trap.
double variety(const std::vector<uint8_t>& d, size_t start, int block)
{
    std::set<uint64_t> seen;
    int n = 0;
    for (size_t b = start; b + 8 <= d.size() && n < 256; b += (size_t)block * 4, n++)
    {
        uint64_t v;
        std::memcpy(&v, d.data() + b, 8);
        seen.insert(v);
    }
    return n ? (double)seen.size() / (double)n : 0.0;
}

double ordered_frac(const std::vector<uint8_t>& d, size_t start, size_t len)
{
    int ordered = 0, n = 0;
    for (size_t b = start; b + 8 <= start + len && b + 8 <= d.size(); b += 8, n++)
    {
        uint16_t c0, c1;
        std::memcpy(&c0, d.data() + b, 2);
        std::memcpy(&c1, d.data() + b + 2, 2);
        if (c0 > c1) ordered++;
    }
    return n ? (double)ordered / (double)n : 0.0;
}

// How many DISTINCT endpoint colours the window carries, and how much the
// per-block index words vary. A photograph has thousands of endpoints; a
// weight page read as BC1 repeats a handful.
void bc1_stats(const std::vector<uint8_t>& d, size_t start, size_t len,
               int& distinct_ep, double& mean_lum, double& sd_lum, int& zero_idx)
{
    std::set<uint32_t> ep;
    double s = 0, s2 = 0;
    int n = 0;
    zero_idx = 0;
    for (size_t b = start; b + 8 <= start + len && b + 8 <= d.size(); b += 8)
    {
        uint16_t c0, c1;
        uint32_t idx;
        std::memcpy(&c0, d.data() + b, 2);
        std::memcpy(&c1, d.data() + b + 2, 2);
        std::memcpy(&idx, d.data() + b + 4, 4);
        ep.insert(((uint32_t)c0 << 16) | c1);
        if (idx == 0) zero_idx++;
        const double r = ((c0 >> 11) & 31) / 31.0, g = ((c0 >> 5) & 63) / 63.0,
                     bl = (c0 & 31) / 31.0;
        const double l = 0.299 * r + 0.587 * g + 0.114 * bl;
        s += l; s2 += l * l; n++;
    }
    distinct_ep = (int)ep.size();
    mean_lum = n ? s / n : 0.0;
    sd_lum = n ? std::sqrt(std::max(0.0, s2 / n - (s / n) * (s / n))) : 0.0;
}

}  // namespace

int main(int argc, char** argv)
{
    if (argc < 3)
    {
        std::fprintf(stderr, "usage: tilescan_test <game_dir> <level> "
                             "[--depth=N] [--limit=N]\n");
        return 2;
    }
    const std::string game = argv[1], level = argv[2];
    int want_depth = -1, limit = 40;
    for (int i = 3; i < argc; i++)
    {
        const std::string a = argv[i];
        if (a.rfind("--depth=", 0) == 0) want_depth = std::atoi(a.c_str() + 8);
        else if (a.rfind("--limit=", 0) == 0) limit = std::atoi(a.c_str() + 8);
    }

    Source src;
    std::string err;
    if (!src.open(game, err)) { std::fprintf(stderr, "open: %s\n", err.c_str()); return 1; }
    if (!src.mount_level(level, false, err))
    { std::fprintf(stderr, "mount: %s\n", err.c_str()); return 1; }

    std::string lvl = level, tree;
    for (char& c : lvl) c = (char)tolower((unsigned char)c);
    for (const auto& kv : src.res())
    {
        std::string nm = kv.first;
        for (char& c : nm) c = (char)tolower((unsigned char)c);
        if (nm.find("streamingtree") != std::string::npos &&
            nm.find(lvl) != std::string::npos) { tree = kv.first; break; }
    }
    std::vector<uint8_t> res = src.get_res(tree, err), b1;
    Splat sp;
    SplatChunkDir dir;
    if (tree.empty() || res.empty() || !Splat::find_block(res, 1, b1, err) ||
        !sp.parse(b1, err) || !Splat::read_chunk_dir(res, dir, err))
    { std::fprintf(stderr, "parse: %s\n", err.c_str()); return 1; }

    if (!sp.detect_layout(dir, err))
    {
        // A level whose layout does not decompose is exactly the level worth
        // looking at, so print the residual census rather than giving up.
        std::printf("detect_layout FAILED: %s\n", err.c_str());
        const int cand[3] = {2592, 4356, 5184};
        for (int cp : cand)
        {
            std::map<int, int> r;
            bool neg = false;
            for (const SplatNode& n : sp.nodes())
            {
                if (n.pages <= 0) continue;
                auto e = dir.find(n.key);
                if (e == dir.end() || e->second.primary_size == 0) continue;
                const int v = (int)e->second.primary_size - n.pages * cp;
                if (v < 0) neg = true;
                r[v]++;
            }
            std::printf("page %d: %zu distinct residuals%s\n", cp, r.size(),
                        neg ? " (some NEGATIVE)" : "");
            if (neg || r.size() > 40) continue;
            for (const auto& kv : r)
                std::printf("   %9d  x%-5d  /4624=%.4f /8712=%.4f /17424=%.4f "
                            "/67600=%.4f\n",
                            kv.first, kv.second, kv.first / 4624.0, kv.first / 8712.0,
                            kv.first / 17424.0, kv.first / 67600.0);
        }
        return 0;
    }

    const int ps = sp.page_size(), tb = sp.tile_bytes();
    std::printf("%s: page %d, tile %d (%d^2 %s)\n", level.c_str(), ps, tb,
                sp.tile_side(), sp.tile_is_bc1() ? "BC1" : "BC7");

    std::map<std::string, std::vector<uint8_t>> cache;
    int shown = 0;
    std::map<int, int> resid_count;
    for (const SplatNode& n : sp.nodes())
    {
        auto e = dir.find(n.key);
        if (e == dir.end() || e->second.primary.empty()) continue;
        resid_count[(int)e->second.primary_size - n.pages * ps]++;
    }
    std::printf("distinct residuals: %zu\n", resid_count.size());
    for (const auto& kv : resid_count)
        std::printf("  residual %9d  x%-5d  /tile = %.4f\n", kv.first, kv.second,
                    (double)kv.first / (double)tb);

    for (const SplatNode& n : sp.nodes())
    {
        if (shown >= limit) break;
        const int depth = Splat::depth_of(n.key);
        if (want_depth >= 0 && depth != want_depth) continue;
        auto e = dir.find(n.key);
        if (e == dir.end() || e->second.primary.empty()) continue;
        const int resid = (int)e->second.primary_size - n.pages * ps;
        if (resid < tb) continue;
        auto ci = cache.find(e->second.primary);
        if (ci == cache.end()) ci = cache.emplace(e->second.primary,
                                                  src.get_chunk(e->second.primary, err)).first;
        const std::vector<uint8_t>& d = ci->second;
        if (d.empty()) continue;
        std::printf("\nnode key %llx depth %d pages %d primary %u resid %d (%zu bytes read)\n",
                    (unsigned long long)n.key, depth, n.pages,
                    (unsigned)e->second.primary_size, resid, d.size());
        // END-ALIGNED, the way color_slices slices it: the trailer is the
        // last k*tile bytes of the chunk, so a scan from the chunk head is off
        // by the prefix and lands between tiles.
        const int nwin = (int)(d.size() / (size_t)tb);
        const int first = nwin > 24 ? nwin - 24 : 0;
        for (int w = first; w < nwin; w++)
        {
            const size_t off = d.size() - (size_t)(nwin - w) * (size_t)tb;
            if (off + (size_t)tb > d.size()) break;
            int ep = 0, zi = 0;
            double ml = 0, sl = 0;
            bc1_stats(d, off, (size_t)tb, ep, ml, sl, zi);
            const int blk = sp.tile_is_bc1() ? 8 : 16;
            const double base = sp.tile_is_bc1() ? ordered_frac(d, off, (size_t)tb)
                                                 : mode47(d, off);
            const double var = variety(d, off, blk);
            std::printf("   win %2d off %8zu  base %.3f  variety %.3f  "
                        "product %.3f  endpoints %5d  lum %.3f sd %.3f\n",
                        w, off, base, var, base * var, ep, ml, sl);
        }
        shown++;
    }
    return 0;
}
