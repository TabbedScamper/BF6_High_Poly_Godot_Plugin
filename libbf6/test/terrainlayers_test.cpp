/* Validation harness for the terrain layer palette.
 *
 * Not shipped. There is no reference dump to diff against, so the checks are
 * the ones the FORMAT makes falsifiable, plus the anchors prior work recorded:
 *
 *  - the record table is pinned arithmetically, by a 16-byte header marker and
 *    a 20-byte footer that must BOTH agree, so a wrong offset fails loudly
 *    instead of returning plausible layers. Every populated layer's key then
 *    resolving in the depot is the independent third confirmation, and it is
 *    printed rather than assumed;
 *  - MD5("") marks an unauthored layer, so empty-vs-populated is checkable;
 *  - ShaderBlockKeys are content-addressed, so the SAME authored layer must
 *    carry the same key on two different maps - run with two levels and the
 *    harness counts the overlap.
 *
 * Anchors: mp_dumbo has 47 layers, mp_aftermath 40, and ten of dumbo's layers
 * share a ShaderBlockKey with an aftermath layer. A disagreement is REPORTED,
 * never accommodated - hence the overlap being counted three ways rather than
 * whichever way happens to hit 10.
 *
 * Blocks 1/7/8 belong to splat.h and are validated by splat_test; the seam
 * between the two - this table's linked list - is printed at the end of each
 * level.
 *
 *   terrainlayers_test <game_dir> <level> [more levels...]
 */
#include <algorithm>
#include <cstdio>
#include <map>
#include <set>
#include <string>
#include <vector>

#include "source.h"
#include "terrainlayers.h"

using namespace bf6;

namespace {


// A texture FILE guid -> the asset name, with the .ebx dropped. The pixels are
// the RES of the same path without the extension; the partition index names the
// EBX, so the trim is what makes the two line up.
std::string asset_name(const std::map<std::string, std::string>& pidx, const std::string& guid)
{
    if (guid.empty()) return "";
    auto it = pidx.find(guid);
    if (it == pidx.end()) return "<unresolved " + guid + ">";
    std::string n = it->second;
    if (n.size() > 4 && n.compare(n.size() - 4, 4, ".ebx") == 0) n.resize(n.size() - 4);
    return n;
}

std::string leaf(const std::string& p)
{
    const size_t s = p.find_last_of('/');
    return s == std::string::npos ? p : p.substr(s + 1);
}

struct LevelResult {
    std::string level;
    std::vector<uint64_t> keys;        // populated layers only
    std::vector<uint64_t> all_keys;    // including the unauthored ones
    size_t count = 0;
};

void report_material(const TerrainLayer& l, const std::map<std::string, std::string>& pidx)
{
    const TerrainLayerMaterial& m = l.material;
    std::printf("  L%02u key %016llx  hash %016llx%s%s\n", l.index,
        (unsigned long long)l.shader_block_key, (unsigned long long)l.content_hash,
        l.empty ? "  EMPTY" : "", m.resolved ? "" : "  [no depot record]");
    if (l.link >= 0) std::printf("        link %d\n", l.link);

    const TerrainMaterialSet* sets[3] = { &m.set_a, &m.set_b, &m.set_c };
    const char* names[3] = { "A", "B", "C" };
    for (int i = 0; i < 3; i++)
    {
        if (sets[i]->empty()) continue;
        std::printf("        set %s  base=%s\n", names[i],
            leaf(asset_name(pidx, sets[i]->base_color)).c_str());
        if (!sets[i]->normal_height.empty())
            std::printf("               nrm+h=%s\n",
                leaf(asset_name(pidx, sets[i]->normal_height)).c_str());
        if (!sets[i]->third.empty())
            std::printf("               third=%s\n",
                leaf(asset_name(pidx, sets[i]->third)).c_str());
    }
    for (const auto& kv : m.other_textures)
    {
        const char* rn = TerrainLayers::role_name(kv.first);
        char fallback[16];
        if (!rn) { std::snprintf(fallback, sizeof(fallback), "u%08x", kv.first); rn = fallback; }
        std::printf("        aux %-14s %s\n", rn, leaf(asset_name(pidx, kv.second)).c_str());
    }

    std::printf("       ");
    if (m.uv_tiling_set)       std::printf(" tiling=%.4f(%.2fm/rep)", m.uv_tiling, m.metres_per_repeat());
    if (m.uv_rotation_deg_set) std::printf(" rot=%.1f", m.uv_rotation_deg);
    if (m.uv_offset_set)       std::printf(" off=(%.3f,%.3f)", m.uv_offset[0], m.uv_offset[1]);
    if (m.coord_scale_set)     std::printf(" scale=(%.3f,%.3f)", m.coord_scale[0], m.coord_scale[1]);
    if (m.displace_range_set)  std::printf(" disp=%.3f", m.displace_range);
    if (m.tint_set)            std::printf(" tint=(%.3f,%.3f,%.3f)", m.tint[0], m.tint[1], m.tint[2]);
    if (m.overlay_strength_set)std::printf(" overlay=%.3f", m.overlay_strength);
    if (m.mask_ramp_exp_set)   std::printf(" ramp=%.3f", m.mask_ramp_exp);
    if (m.height_blend_set)    std::printf(" hblend=%.3f", m.height_blend);
    if (m.base_height_set)     std::printf(" baseh=%.3f", m.base_height);
    if (m.surface_class_set)   std::printf(" surf=%d", m.surface_class);
    std::printf("\n");
}

bool run_level(const std::string& game, const std::string& level, LevelResult& out)
{
    Source src;
    std::string err;
    if (!src.open(game, err)) { std::fprintf(stderr, "open: %s\n", err.c_str()); return false; }
    if (!src.mount_level(level, false, err))
    { std::fprintf(stderr, "mount %s: %s\n", level.c_str(), err.c_str()); return false; }

    std::printf("\n================ %s ================\n", level.c_str());

    TerrainLayers tl;
    if (!tl.load(src, level, err))
    { std::printf("PALETTE FAILED: %s\n", err.c_str()); return false; }

    std::printf("layer graphs : %s\n", tl.layergraph_res().c_str());
    std::printf("depot        : %s  (%s, %zu layer-graph depots visible)\n",
        leaf(tl.depot_res()).c_str(),
        tl.depot_matched_level() ? "belongs to this level"
                                 : "DOES NOT NAME THIS LEVEL - keys may be colliding",
        tl.depots_seen());
    std::printf("table id     : %016llx   surface key %016llx\n",
        (unsigned long long)tl.table_id(), (unsigned long long)tl.surface_key());
    std::printf("record offset: %zu\n", tl.record_offset());

    const size_t n = tl.layer_count();
    std::printf("\nLAYERS  %zu total | %zu empty (MD5 of nothing) | %zu populated\n",
        n, tl.empty_count(), n - tl.empty_count());
    std::printf("        %zu resolve a depot record | %zu yield a base colour\n",
        tl.resolved_count(), tl.with_base_color_count());

    // Every populated layer must resolve. "The table parsed and nothing binds"
    // is exactly what a wrong offset or a borrowed depot looks like, so it is
    // called out as a failure rather than printed as a percentage.
    size_t pop_unresolved = 0;
    for (const TerrainLayer& l : tl.layers())
        if (!l.empty && !l.material.resolved) pop_unresolved++;
    if (pop_unresolved)
        std::printf("        !! %zu POPULATED layers found no depot record\n", pop_unresolved);

    // THE EVALUATOR CONSTANTS, counted rather than sampled. The height blend is
    // what turns the splat MASK into coverage, so "how many layers author it"
    // decides whether the ground can be decisive at all. Absent is not zero-ish:
    // the depot record simply does not carry the parameter for that layer.
    size_t hb_set = 0, hb_nonzero = 0, ramp_set = 0, disp_set = 0, pop = 0;
    double hb_sum = 0;
    for (const TerrainLayer& l : tl.layers())
    {
        if (l.empty) continue;
        pop++;
        if (l.material.height_blend_set)
        {
            hb_set++;
            if (l.material.height_blend != 0.f) { hb_nonzero++; hb_sum += l.material.height_blend; }
        }
        if (l.material.mask_ramp_exp_set) ramp_set++;
        if (l.material.displace_range_set) disp_set++;
    }
    std::printf("        height_blend authored on %zu of %zu populated (%zu non-zero, "
                "mean %.2f) | mask_ramp %zu | displace %zu\n",
                hb_set, pop, hb_nonzero, hb_nonzero ? hb_sum / (double)hb_nonzero : 0.0,
                ramp_set, disp_set);

    // Layers sharing a content hash are the same authored material: the depot
    // is content-deduplicated, so this is the format working.
    std::map<uint64_t, int> by_hash;
    for (const TerrainLayer& l : tl.layers()) if (!l.empty) by_hash[l.content_hash]++;
    size_t shared = 0;
    for (const auto& kv : by_hash) if (kv.second > 1) shared++;
    std::printf("        %zu distinct authored materials, %zu of them used by 2+ layers\n",
        by_hash.size(), shared);

    const std::map<std::string, std::string>& pidx = src.partition_index();
    std::printf("        partition index: %zu names\n", pidx.size());

    // A few named layers in full. The first populated ones, plus any that bind
    // two material sets - the two-material case is what defeats classifying
    // terrain textures by filename suffix, so it is worth seeing.
    std::printf("\nSAMPLE LAYERS\n");
    int shown = 0;
    for (const TerrainLayer& l : tl.layers())
    {
        const bool dual = !l.material.set_b.empty() || !l.material.set_c.empty();
        if (l.empty) continue;
        if (shown >= 6 && !dual) continue;
        if (shown >= 10) break;
        report_material(l, pidx);
        shown++;
    }

    // A compact roll of every populated layer's base colour, which is the line
    // that makes a wrong palette obvious at a glance.
    std::printf("\nBASE COLOUR ROLL\n");
    for (const TerrainLayer& l : tl.layers())
    {
        if (l.empty) continue;
        const std::string bc = asset_name(pidx, l.material.base_color());
        std::printf("  L%02u  %-46s  %s\n", l.index,
            bc.empty() ? "(shader-computed - no colour sheet)" : leaf(bc).c_str(),
            l.material.uv_tiling_set ? "" : "(no tiling authored)");
    }

    for (const TerrainLayer& l : tl.layers())
    {
        out.all_keys.push_back(l.shader_block_key);
        if (!l.empty) out.keys.push_back(l.shader_block_key);
    }
    out.level = level;
    out.count = n;

    // ---- the palette's half of the block-7 seam ----------------------------
    //
    // splat.h's MaterialTree resolves a kind-2 pair entry against the LINKED
    // list, which only this table can produce. Reported here because a nibble
    // index means nothing without the list's exact contents and order.
    const std::vector<int> linked = tl.linked_list();
    const std::vector<int> groups = tl.link_groups();
    std::printf("\nLINKED SET (splat.h MaterialTree::rasterize `linked` argument)\n");
    std::printf("  %zu link group(s):", groups.size());
    for (int g : groups) std::printf(" %d", g);
    std::printf("\n  list (%zu, ascending):", linked.size());
    for (int i : linked) std::printf(" L%d", i);
    std::printf("\n");
    // A nibble indexes this list, so more than 15 members would be unreachable
    // past the sentinel - worth saying out loud rather than discovering later.
    if (linked.size() > 15)
        std::printf("  !! %zu members: a 4-bit index cannot reach past 14\n", linked.size());
    if (groups.size() > 1)
        std::printf("  !! more than one linked set - resolution needs a choice this "
                    "module does not make\n");
    return true;
}

}  // namespace

int main(int argc, char** argv)
{
    if (argc < 3)
    {
        std::fprintf(stderr, "usage: terrainlayers_test <game_dir> <level> [more levels...]\n");
        return 2;
    }
    const std::string game = argv[1];

    std::vector<LevelResult> results;
    for (int i = 2; i < argc; i++)
    {
        LevelResult r;
        if (run_level(game, argv[i], r)) results.push_back(std::move(r));
    }

    // ShaderBlockKeys are content-addressed and shared between maps. This is the
    // check that says so out loud: if two levels' palettes share no keys at all,
    // either the keys are per-level after all or a depot was borrowed.
    if (results.size() >= 2)
    {
        // Counted three ways on purpose. "Layers that share a key" and "distinct
        // shared keys" are different numbers whenever one level reuses a key,
        // and quoting one against an anchor recorded as the other is how a
        // correct decode gets adjusted until it is wrong.
        std::printf("\n================ CROSS-LEVEL KEY SHARING ================\n");
        for (size_t a = 0; a < results.size(); a++)
            for (size_t b = a + 1; b < results.size(); b++)
            {
                const LevelResult& A = results[a];
                const LevelResult& B = results[b];
                std::set<uint64_t> pa(A.keys.begin(), A.keys.end());
                std::set<uint64_t> aa(A.all_keys.begin(), A.all_keys.end());

                std::set<uint64_t> distinct;
                size_t b_layers = 0;
                for (uint64_t k : B.keys) if (pa.count(k)) { b_layers++; distinct.insert(k); }
                size_t a_layers = 0;
                for (uint64_t k : A.keys) if (distinct.count(k)) a_layers++;

                std::set<uint64_t> distinct_all;
                size_t b_layers_all = 0;
                for (uint64_t k : B.all_keys)
                    if (aa.count(k)) { b_layers_all++; distinct_all.insert(k); }

                std::printf("  %s (%zu layers) vs %s (%zu layers)\n",
                    A.level.c_str(), A.count, B.level.c_str(), B.count);
                std::printf("      populated only : %zu distinct keys | %zu %s layers | %zu %s layers\n",
                    distinct.size(), a_layers, A.level.c_str(), b_layers, B.level.c_str());
                std::printf("      including empty: %zu distinct keys | %zu %s layers\n",
                    distinct_all.size(), b_layers_all, B.level.c_str());
            }
    }
    return 0;
}
