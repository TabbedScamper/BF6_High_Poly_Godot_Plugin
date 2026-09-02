/* Validation harness for the splat module (block 1) and the material tree
 * (block 7), plus the block-8 mask.
 *
 * Not shipped. The point of this file is that the port can FAIL here rather
 * than in a renderer, so every number it prints is one the reference has
 * published somewhere and can be diffed against by hand:
 *
 *   - block 1's walk is byte-exact and its declared node/record counts are in
 *     the per-map docs, so a desynchronised record stream cannot pass;
 *   - the painted/base layer split is published per map (aftermath 25/14,
 *     dumbo 30/16, tungsten 24/11) and is a pure function of the flag bit,
 *     which is the field most likely to be read at the wrong offset;
 *   - block 7's node walk must end EXACTLY on its pair footer;
 *   - the POOLED per-node texel share of the resolved base field is the number
 *     the map docs quote to one decimal place. That is the strongest check in
 *     here: it exercises the RLE codec, the spatial base-list match, the pair
 *     table and the nibble resolution all at once, and a single wrong list
 *     shifts every percentage.
 *
 * The raster figures (grid size, per-layer coverage, zero-coverage texels, the
 * pair histogram) are what the task asks for and are printed alongside.
 *
 *   splat_test <game_dir> <level> [--size=N] [--linked=a,b,c] [--threads=N]
 *                                 [--point=x,z]
 *                                 [--textured=a,b,c] [--unionlists]
 *
 * --linked is the palette's TerrainLayerType.Linked layer list, which lives in
 * the layer-graph EBX chain and is NOT decoded by this module. Pair entries of
 * kind 2 index it; without it they fall back to the base list, which is §8's
 * own stated fallback and is what a map with no linked layers does anyway.
 */
#include "source.h"
#include "splat.h"

#include <algorithm>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <map>
#include <string>
#include <vector>

using namespace bf6;

namespace {

std::vector<int> parse_list(const char* s)
{
    std::vector<int> out;
    while (*s)
    {
        char* end = nullptr;
        const long v = std::strtol(s, &end, 10);
        if (end == s) break;
        out.push_back((int)v);
        s = end;
        while (*s == ',' || *s == ' ') s++;
    }
    std::sort(out.begin(), out.end());
    return out;
}

// The shipping plugin's own rule, reproduced so the raster size matches the
// numbers in its cache: 2 m per texel, floor 2048, ceiling 4096.
int surface_res_for(float world_size)
{
    const int want = (int)(world_size / 2.0f);
    int side = 2048;
    while (side < want && side < 4096) side *= 2;
    return side;
}

}  // namespace

int main(int argc, char** argv)
{
    if (argc < 3)
    {
        std::fprintf(stderr, "usage: splat_test <game_dir> <level> "
                             "[--size=N] [--linked=a,b,c] [--threads=N]\n");
        return 2;
    }
    const std::string game = argv[1], level = argv[2];
    int want_size = 0, threads = 0;
    float point_x = 0.f, point_z = 0.f;
    bool have_point = false, brief_point = false;
    bool union_lists = false;
    std::vector<int> linked, textured;
    for (int i = 3; i < argc; i++)
    {
        const std::string a = argv[i];
        if (a.rfind("--size=", 0) == 0)    want_size = std::atoi(a.c_str() + 7);
        else if (a.rfind("--linked=", 0) == 0) linked = parse_list(a.c_str() + 9);
        else if (a.rfind("--threads=", 0) == 0) threads = std::atoi(a.c_str() + 10);
        else if (a.rfind("--textured=", 0) == 0) textured = parse_list(a.c_str() + 11);
        else if (a.rfind("--point=", 0) == 0)
            have_point = std::sscanf(a.c_str() + 8, "%f,%f", &point_x, &point_z) == 2;
        else if (a == "--brief-point") brief_point = true;
        else if (a == "--unionlists") union_lists = true;
    }

    using clk = std::chrono::steady_clock;
    auto ms = [](clk::time_point a, clk::time_point b)
    { return std::chrono::duration<double, std::milli>(b - a).count(); };

    Source src;
    std::string err;
    if (!src.open(game, err)) { std::fprintf(stderr, "open: %s\n", err.c_str()); return 1; }
    if (!src.mount_level(level, false, err))
    { std::fprintf(stderr, "mount: %s\n", err.c_str()); return 1; }

    std::string want, lvl = level;
    for (char& c : lvl) c = (char)std::tolower((unsigned char)c);
    for (const auto& kv : src.res())
    {
        std::string n = kv.first;
        for (char& c : n) c = (char)std::tolower((unsigned char)c);
        if (n.find("streamingtree") != std::string::npos && n.find(lvl) != std::string::npos)
        { want = kv.first; break; }
    }
    if (want.empty()) { std::fprintf(stderr, "no streaming tree for %s\n", level.c_str()); return 1; }

    std::vector<uint8_t> res = src.get_res(want, err);
    if (res.empty()) { std::fprintf(stderr, "get_res: %s\n", err.c_str()); return 1; }
    std::printf("=== %s ===\ntree: %s (%zu bytes)\n", level.c_str(), want.c_str(), res.size());

    // Which typed planes this map ships. 4k maps carry {0,1,4,7,8}; 8k maps add
    // 2 (Density / DetailDisplacement) and 5.
    std::printf("blocks: ");
    for (int t = 0; t < 16; t++)   // 10+ exists: mp_isolated ships a type 10
    {
        std::vector<uint8_t> tmp;
        std::string e2;
        if (Splat::find_block(res, t, tmp, e2))
            std::printf("%d(%zu) ", t, tmp.size());
    }
    std::printf("\n");

    std::vector<uint8_t> b1;
    if (!Splat::find_block(res, 1, b1, err))
    { std::fprintf(stderr, "block 1: %s\n", err.c_str()); return 1; }

    const auto t0 = clk::now();
    Splat sp;
    if (!sp.parse(b1, err)) { std::fprintf(stderr, "block 1 parse: %s\n", err.c_str()); return 1; }
    const auto t1 = clk::now();

    size_t recs = 0;
    for (const SplatNode& n : sp.nodes()) recs += n.records.size();
    std::printf("block 1: LayerSlotCount %d, %zu nodes (declares %d), %zu records "
                "(declares %d), %zu stored pages\n",
                sp.layer_slot_count(), sp.node_count(), sp.declared_nodes(),
                recs, sp.declared_records(), sp.stored_pages());
    std::printf("world: x %.1f..%.1f  z %.1f..%.1f  (%.0f x %.0f m)\n",
                sp.root_min()[0], sp.root_max()[0], sp.root_min()[1], sp.root_max()[1],
                sp.root_max()[0] - sp.root_min()[0], sp.root_max()[1] - sp.root_min()[1]);

    std::map<int, int> painted, base;
    sp.layer_usage(painted, base);
    std::printf("layers: %zu painted / %zu base  (full list %zu, global base %zu)\n",
                painted.size(), base.size(), sp.full_list().size(), sp.global_base_list().size());
    {
        std::printf("  base list (global): ");
        for (int l : sp.global_base_list()) std::printf("L%02d ", l);
        std::printf("\n");
    }

    SplatChunkDir dir;
    if (!Splat::read_chunk_dir(res, dir, err))
    { std::fprintf(stderr, "chunk dir: %s\n", err.c_str()); return 1; }
    if (!sp.detect_layout(dir, err))
    { std::fprintf(stderr, "detect_layout: %s\n", err.c_str()); return 1; }
    std::printf("layout: page %d bytes (%dx%d), tile %d bytes (%d^2 %s)%s, dir %zu entries\n",
                sp.page_size(), sp.page_side(), sp.page_side(), sp.tile_bytes(),
                sp.tile_side(), sp.tile_is_bc1() ? "BC1" : "BC7",
                sp.no_colour() ? " [no colour raster]" : "", dir.size());

    auto fetch = [&](const std::string& g) { std::string e; return src.get_chunk(g, e); };

    // A point probe has to look BEFORE the fixed-width coverage merge. Several
    // quadtree records for one layer can touch a point, and inspecting only the
    // final top-N slots cannot distinguish max-mask from fine-page overwrite.
    // Report both interpretations, including zero-valued fine samples, then do
    // the same at a deterministic half-map-shift control point.
    if (have_point)
    {
        struct Agg { int hits = 0, max_w = 0, last_w = 0, deep = -1, deep_w = 0; };
        std::map<std::string, std::vector<uint8_t>> chunk_cache;
        std::map<uint64_t, const SplatNode*> by_key;
        std::vector<const SplatNode*> order;
        for (const SplatNode& n : sp.nodes()) { by_key[n.key] = &n; order.push_back(&n); }
        std::stable_sort(order.begin(), order.end(), [](const SplatNode* a, const SplatNode* b)
        { return a->depth < b->depth; });
        auto cached = [&](const std::string& guid) -> const std::vector<uint8_t>&
        {
            auto it = chunk_cache.find(guid);
            if (it != chunk_cache.end()) return it->second;
            return chunk_cache.emplace(guid, fetch(guid)).first->second;
        };
        auto probe = [&](const char* label, float px, float pz)
        {
            std::map<int, Agg> agg;
            int page_hits = 0, resolve_fail = 0;
            std::printf("\nPOINT-PAGE PROBE %s (%.3f, %.3f)\n", label, px, pz);
            std::printf(" depth key                layer page span(m)    sample  bounds\n");
            for (const SplatNode* np : order)
            {
                const SplatNode& n = *np;
                bool touches = false;
                for (const SplatRecord& r : n.records)
                    if (r.page >= 0 && px >= r.lo[0] && px < r.hi[0] &&
                        pz >= r.lo[1] && pz < r.hi[1]) { touches = true; break; }
                if (!touches || n.pages <= 0) continue;

                const uint8_t* base = nullptr;
                size_t avail = 0;
                auto de = dir.find(n.key);
                if (de != dir.end() && !de->second.primary.empty())
                {
                    const int off = sp.pages_offset(de->second.primary_size, n.pages);
                    if (off >= 0)
                    {
                        const std::vector<uint8_t>& d = cached(de->second.primary);
                        const size_t need = (size_t)off + (size_t)n.pages * (size_t)sp.page_size();
                        if (d.size() >= need) { base = d.data() + off; avail = d.size() - (size_t)off; }
                    }
                }
                if (!base)
                {
                    auto pe = dir.find(n.key >> 4);
                    if (pe != dir.end() && !pe->second.paired.empty())
                    {
                        const std::vector<uint8_t>& d = cached(pe->second.paired);
                        const uint64_t child = n.key & 0xF;
                        size_t off = 0;
                        for (int j = 3; j >= 0; j--)
                        {
                            if ((uint64_t)j == child) break;
                            auto si = by_key.find((n.key & ~(uint64_t)0xF) | (uint64_t)j);
                            if (si != by_key.end())
                                off += (size_t)si->second->pages * (size_t)sp.page_size();
                        }
                        const size_t need = off + (size_t)n.pages * (size_t)sp.page_size();
                        if (d.size() >= need) { base = d.data() + off; avail = d.size() - off; }
                    }
                }
                if (!base || avail < (size_t)n.pages * (size_t)sp.page_size())
                { resolve_fail++; continue; }

                for (const SplatRecord& r : n.records)
                {
                    if (r.page < 0 || r.page >= n.pages ||
                        px < r.lo[0] || px >= r.hi[0] || pz < r.lo[1] || pz >= r.hi[1]) continue;
                    std::vector<uint8_t> page((size_t)sp.page_side() * (size_t)sp.page_side());
                    if (!Splat::decode_page(base + (size_t)r.page * (size_t)sp.page_size(),
                                            sp.page_size(), page.data())) continue;
                    const float fx = std::clamp((px - r.lo[0]) / (r.hi[0] - r.lo[0]), 0.f, 1.f);
                    const float fz = std::clamp((pz - r.lo[1]) / (r.hi[1] - r.lo[1]), 0.f, 1.f);
                    const int ix = 1 + std::clamp((int)(fx * 64.f), 0, 63);
                    const int iz = 1 + std::clamp((int)(fz * 64.f), 0, 63);
                    const int w = page[(size_t)iz * 66u + (size_t)ix];
                    Agg& a = agg[(int)(r.layer & 0xFF)];
                    a.hits++; a.max_w = std::max(a.max_w, w); a.last_w = w;
                    if (n.depth >= a.deep) { a.deep = n.depth; a.deep_w = w; }
                    page_hits++;
                    if (!brief_point)
                        std::printf(" %5d 0x%016llX L%-4d %4d %8.2f %7.3f  %.1f,%.1f..%.1f,%.1f\n",
                                    n.depth, (unsigned long long)n.key, (int)(r.layer & 0xFF), r.page,
                                    r.hi[0] - r.lo[0], w / 255.0,
                                    r.lo[0], r.lo[1], r.hi[0], r.hi[1]);
                }
            }
            std::printf(" summary: %d page record(s), %d unresolved node(s)\n", page_hits, resolve_fail);
            std::printf(" layer hits  max-mask  coarse-to-fine overwrite  deepest-record\n");
            for (const auto& kv : agg)
                std::printf(" L%-4d %4d    %7.3f           %7.3f          %7.3f (d%d)\n",
                            kv.first, kv.second.hits, kv.second.max_w / 255.0,
                            kv.second.last_w / 255.0, kv.second.deep_w / 255.0, kv.second.deep);
        };
        probe("camera", point_x, point_z);
        const float sx = sp.root_max()[0] - sp.root_min()[0];
        float control_x = point_x + sx * 0.5f;
        if (control_x >= sp.root_max()[0]) control_x -= sx;
        probe("half-map-x control", control_x, point_z);
    }

    const auto t2 = clk::now();
    const std::vector<ColorSlice> tiles = sp.color_slices(dir, fetch);
    const auto t3 = clk::now();
    std::printf("colour slices: %zu\n", tiles.size());

    // ---- the splat composite ------------------------------------------------
    const int size = want_size > 0 ? want_size
                                   : surface_res_for(sp.root_max()[0] - sp.root_min()[0]);
    SplatCoverage cov;
    SplatCompositeOpts opt;
    opt.threads = threads;
    const auto t4 = clk::now();
    if (!sp.composite(dir, fetch, size, cov, err, opt))
    { std::fprintf(stderr, "composite: %s\n", err.c_str()); return 1; }
    const auto t5 = clk::now();

    const double texels = (double)cov.size * (double)cov.size;
    std::printf("\nSPLAT  grid %d x %d (%.2f m/texel), %d pages painted, %d layers present\n",
                cov.size, cov.size, (sp.root_max()[0] - sp.root_min()[0]) / (float)cov.size,
                cov.pages_painted, cov.layer_count);
    std::printf("  zero-coverage texels: %llu (%.2f%%)\n",
                (unsigned long long)cov.empty_texels, 100.0 * (double)cov.empty_texels / texels);
    {
        std::vector<std::pair<uint64_t, int>> by;
        for (int l = 0; l < 256; l++) if (cov.layer_texels[l]) by.push_back({cov.layer_texels[l], l});
        std::sort(by.rbegin(), by.rend());
        for (const auto& kv : by)
            std::printf("  L%-3d %10llu  %7.3f%%%s\n", kv.second,
                        (unsigned long long)kv.first, 100.0 * (double)kv.first / texels,
                        painted.count(kv.second) ? "" : "   (base-only layer)");
    }

    // ---- block 7 -------------------------------------------------------------
    std::vector<uint8_t> b7;
    if (!Splat::find_block(res, 7, b7, err))
    {
        std::printf("\nno block 7 on this map: %s\n", err.c_str());
        return 0;
    }
    MaterialTree mt;
    const auto t6 = clk::now();
    if (!mt.parse(b7, err))
    { std::fprintf(stderr, "block 7 parse: %s\n", err.c_str()); return 1; }
    const auto t7 = clk::now();

    int framed = 0;
    std::map<int, int> kinds;
    for (uint32_t e : mt.pairs())
        if (MaterialTree::entry_is_framed(e)) { framed++; kinds[MaterialTree::entry_list_kind(e)]++; }
    std::printf("\nBLOCK 7  %zu bytes, dim %d, levelMax %d, %zu data nodes "
                "(declares %d), %zu pairs (%d framed)\n",
                b7.size(), mt.dim(), mt.levels(), mt.nodes().size(),
                mt.declared_nodes(), mt.pairs().size(), framed);
    std::printf("  list kinds: ");
    for (const auto& kv : kinds) std::printf("%d:%d ", kv.first, kv.second);
    std::printf(" background 0x%08X\n", mt.background());
    for (size_t i = 0; i < mt.pairs().size(); i++)
    {
        const uint32_t e = mt.pairs()[i];
        if (!e) continue;
        std::printf("  pair %2zu = 0x%08X  X=0x%X%X kind=%d ylevel=%d\n", i, e,
                    MaterialTree::entry_secondary(e), MaterialTree::entry_primary(e),
                    MaterialTree::entry_list_kind(e), (int)((e >> 20) & 0xF));
    }

    if (!linked.empty())
    {
        std::printf("  linked list supplied: ");
        for (int l : linked) std::printf("L%02d ", l);
        std::printf("\n");
    }
    else std::printf("  linked list NOT supplied - kind-2 entries fall back to the base list\n");

    // ---- THE DOC-COMPARABLE NUMBER ------------------------------------------
    // The map docs quote the texel share of the resolved base field "pooled over
    // all tree levels", which means every DATA NODE contributes its own dim^2
    // texels regardless of how much world it covers - not the rasterised map.
    // Reproduced exactly, because a raster-weighted share is a different number
    // and comparing the wrong one would make a correct port look broken.
    {
        const std::vector<int> full = sp.full_list();
        const std::vector<int> gbase = sp.global_base_list();
        std::map<int, uint64_t> share, share_k1;
        uint64_t total = 0, total_k1 = 0, unresolved = 0;
        for (const MaterialNode& n : mt.nodes())
        {
            float lo[2], hi[2];
            Splat::bounds_of(n.key, mt.world_min(), mt.world_max(), lo, hi);
            // --unionlists reproduces the SUPERSEDED reading in which kind-1
            // entries index the map-global no-page list instead of the matched
            // node's own. It is here because several published per-map tables
            // predate the fix, and the only way to tell "our port is wrong" from
            // "that table is old" is to be able to compute both.
            std::vector<int> nb = union_lists
                ? gbase
                : sp.base_list_at((lo[0] + hi[0]) * 0.5f, (lo[1] + hi[1]) * 0.5f,
                                  hi[0] - lo[0]);
            if (nb.empty()) nb = gbase;
            // Resolved straight off the pair table rather than through
            // rasterize(), so this stays a check on RESOLUTION and never on
            // raster scaling: every data node contributes its own dim^2 texels.
            int lut[16], kind[16];
            for (int v = 0; v < 16; v++)
            {
                lut[v] = -1; kind[v] = -1;
                if (v < (int)mt.pairs().size())
                {
                    const uint32_t e = mt.pairs()[(size_t)v];
                    if (e && MaterialTree::entry_is_framed(e))
                    {
                        kind[v] = MaterialTree::entry_list_kind(e);
                        // Exactly rasterize()'s rule, including the fact that an
                        // EMPTY linked list leaves kind-2 entries unresolved
                        // rather than falling back: §8's fallback is for a list
                        // that is absent, and the caller always supplies three.
                        const std::vector<int>* arr =
                            kind[v] == 0 ? &full : kind[v] == 1 ? &nb : &linked;
                        if (kind[v] > 2) arr = &nb;
                        const int nib[2] = { MaterialTree::entry_primary(e),
                                             MaterialTree::entry_secondary(e) };
                        for (int k = 0; k < 2; k++)
                            if (nib[k] != 15 && nib[k] < (int)arr->size())
                            { lut[v] = (*arr)[(size_t)nib[k]]; break; }
                    }
                }
            }
            for (uint8_t r : n.rows)
            {
                const int v = r & 0xF;
                total++;
                if (kind[v] == 1) total_k1++;
                if (lut[v] < 0) { unresolved++; continue; }
                share[lut[v]]++;
                if (kind[v] == 1) share_k1[lut[v]]++;
            }
        }
        std::printf("\n  POOLED per-node texel share of the resolved base field "
                    "(%llu texels over %zu nodes):\n",
                    (unsigned long long)total, mt.nodes().size());
        std::vector<std::pair<uint64_t, int>> by;
        for (const auto& kv : share) by.push_back({kv.second, kv.first});
        std::sort(by.rbegin(), by.rend());
        for (const auto& kv : by)
            std::printf("    L%-3d %6.2f%%\n", kv.second, 100.0 * (double)kv.first / (double)total);
        if (unresolved)
            std::printf("    (unresolved %llu, %.2f%%)\n", (unsigned long long)unresolved,
                        100.0 * (double)unresolved / (double)total);
        std::printf("  kind-1 texels: %llu\n", (unsigned long long)total_k1);
        if (total_k1)
        {
            std::vector<std::pair<uint64_t, int>> b2;
            for (const auto& kv : share_k1) b2.push_back({kv.second, kv.first});
            std::sort(b2.rbegin(), b2.rend());
            std::printf("  kind-1 only share:\n");
            for (const auto& kv : b2)
                std::printf("    L%-3d %6.2f%%\n", kv.second,
                            100.0 * (double)kv.first / (double)total_k1);
        }
    }

    // ---- the rasterised material field ---------------------------------------
    MaterialRaster mr;
    const auto t8 = clk::now();
    if (!mt.rasterize(size, [&](float cx, float cz, float w)
                      { return sp.base_list_at(cx, cz, w); },
                      sp.full_list(), linked, sp.global_base_list(), mr, err))
    { std::fprintf(stderr, "rasterize: %s\n", err.c_str()); return 1; }
    const auto t9 = clk::now();

    std::printf("\n  raster %d x %d: %llu texels with no block-7 node (%.2f%%)\n",
                mr.size, mr.size, (unsigned long long)mr.unset,
                100.0 * (double)mr.unset / texels);
    std::printf("  pair histogram (raw 4-bit values over the raster):\n");
    for (int v = 0; v < 16; v++)
        if (mr.pair_hist[v])
            std::printf("    pair %2d  %10llu  %6.2f%%\n", v,
                        (unsigned long long)mr.pair_hist[v],
                        100.0 * (double)mr.pair_hist[v] / texels);
    {
        std::map<int, uint64_t> lay;
        uint64_t none = 0;
        for (uint8_t l : mr.layer) { if (l == 255) none++; else lay[l]++; }
        std::printf("  resolved base layer over the raster (%.2f%% unresolved):\n",
                    100.0 * (double)none / texels);
        std::vector<std::pair<uint64_t, int>> by;
        for (const auto& kv : lay) by.push_back({kv.second, kv.first});
        std::sort(by.rbegin(), by.rend());
        for (const auto& kv : by)
            std::printf("    L%-3d %10llu  %6.2f%%\n", kv.second,
                        (unsigned long long)kv.first, 100.0 * (double)kv.first / texels);
    }

    // ---- THE END-TO-END CHECK AGAINST THE SHIPPING PLUGIN'S OWN CACHE -------
    //
    // The plugin does one more step after the composite: where a texel's base
    // material has a texture and the painted layers covering it do not add up to
    // full strength, the base layer is merged in at the remaining weight. Its
    // cached layers.json then records the resulting per-layer texel counts.
    // Replaying that step here turns a "looks plausible" comparison into an
    // exact one - but only if the caller supplies the same textured-layer set,
    // which comes from the layer-graph palette this module does not decode.
    if (!textured.empty())
    {
        std::vector<uint8_t> istex(256, 0);
        for (int l : textured) if (l >= 0 && l < 256) istex[(size_t)l] = 1;
        uint64_t placed = 0;
        for (size_t i = 0; i < mr.layer.size() && i < (size_t)cov.size * (size_t)cov.size; i++)
        {
            const uint8_t bl = mr.layer[i];
            if (bl == 255 || !istex[bl]) continue;
            const size_t o = i * 4;
            int s_tex = 0;
            for (int k = 0; k < 4; k++)
            {
                if (cov.w[o + k] == 0) break;
                if (istex[cov.idx[o + k]]) s_tex += cov.w[o + k];
            }
            if (s_tex >= 255) continue;
            const int w = 255 - s_tex;
            // The same top-4 merge the composite uses.
            int at = -1;
            for (int k = 0; k < 4; k++) if (cov.w[o + k] > 0 && cov.idx[o + k] == bl) { at = k; break; }
            int put = -1;
            if (at >= 0) { if (w > cov.w[o + at]) { cov.w[o + at] = (uint8_t)w; put = at; } }
            else
            {
                int fs = -1;
                for (int k = 0; k < 4; k++) if (cov.w[o + k] == 0) { fs = k; break; }
                if (fs >= 0) { cov.idx[o + fs] = bl; cov.w[o + fs] = (uint8_t)w; put = fs; }
                else if (w > cov.w[o + 3]) { cov.idx[o + 3] = bl; cov.w[o + 3] = (uint8_t)w; put = 3; }
            }
            for (int k = put; k > 0 && cov.w[o + k] > cov.w[o + k - 1]; k--)
            {
                std::swap(cov.w[o + k], cov.w[o + k - 1]);
                std::swap(cov.idx[o + k], cov.idx[o + k - 1]);
            }
            placed++;
        }
        std::map<int, uint64_t> per;
        for (size_t i = 0; i < (size_t)cov.size * (size_t)cov.size; i++)
            for (int s = 0; s < 4; s++)
            {
                if (cov.w[i * 4 + s] == 0) break;
                per[cov.idx[i * 4 + s]]++;
            }
        std::printf("\nAFTER THE BASE-FIELD MERGE (%llu texels placed, %.2f%%): "
                    "%zu layers present\n", (unsigned long long)placed,
                    100.0 * (double)placed / texels, per.size());
        std::printf("  textured layers, to diff against the plugin's layers.json:\n");
        for (int l : textured)
            std::printf("    L%-3d %10llu texels\n", l, (unsigned long long)per[l]);
    }

    // ---- block 8 -------------------------------------------------------------
    std::vector<uint8_t> b8;
    if (Splat::find_block(res, 8, b8, err))
    {
        MaterialTree mk;
        std::string e8;
        if (mk.parse_mask(b8, e8))
        {
            const std::vector<uint8_t> hole = mk.hole_raster(1024);
            uint64_t off = 0;
            for (uint8_t h : hole) if (!h) off++;
            std::printf("\nBLOCK 8  %zu bytes, dim %d, levelMax %d, %zu data nodes "
                        "(declares %d); bit-0-clear region %.3f%% of a 1024^2 raster\n",
                        b8.size(), mk.dim(), mk.levels(), mk.nodes().size(),
                        mk.declared_nodes(), 100.0 * (double)off / (1024.0 * 1024.0));
        }
        else std::printf("\nblock 8 parse: %s\n", e8.c_str());
    }

    std::printf("\ntiming: b1 parse %.0f ms, colour slices %.0f ms, composite %.0f ms, "
                "b7 parse %.0f ms, b7 raster %.0f ms\n",
                ms(t0, t1), ms(t2, t3), ms(t4, t5), ms(t6, t7), ms(t8, t9));
    return 0;
}
