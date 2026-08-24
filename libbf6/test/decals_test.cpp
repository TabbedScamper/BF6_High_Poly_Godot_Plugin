/* TERRAIN DECALS: does the walk land in the right place?
 *
 * Not shipped. This container has no checksum and every failure mode produces
 * plausible numbers, so "it parsed" means nothing on its own. What it does have
 * is three invariants that are independent of the arithmetic used to find
 * anything, and this reports all three:
 *
 *   THE CHAIN     FirstIndex == prevFirstIndex + prevTriCount*3, record over
 *                 record. A tail found in the wrong place breaks it at once.
 *
 *   THE LANDMARK  the u32 4, u32 0 pair sits at vbStart + sum(VbByteSize). If
 *                 the vertex buffer were located wrongly this would not land.
 *
 *   VERTEX IN AABB  every vertex of a record must fall inside that record's own
 *                 world AABB in XZ. This is the strong one: it ties the vertex
 *                 buffer to the records through data neither of them shares,
 *                 and a wrong base makes it collapse rather than degrade.
 *
 * A fourth check is worth as much as the others: TriCount*3 must equal the
 * vertex count, because the index buffer is an identity ramp and the list is
 * non-indexed. A record where those disagree is being read at the wrong offset
 * and would render as confetti.
 *
 *   decals_test <game_dir> <level>
 */
#include "decals.h"
#include "source.h"

#include <algorithm>
#include <cctype>
#include <cstdio>
#include <string>
#include <vector>

using namespace bf6;

int main(int argc, char** argv)
{
    if (argc < 3)
    {
        std::fprintf(stderr, "usage: decals_test <game_dir> <level>\n");
        return 2;
    }
    Source src;
    std::string err;
    if (!src.open(argv[1], err)) { std::fprintf(stderr, "open: %s\n", err.c_str()); return 1; }
    if (!src.mount_level(argv[2], false, err)) { std::fprintf(stderr, "mount: %s\n", err.c_str()); return 1; }

    // BY RES TYPE, not by name - the name is a convention, the type is the
    // format. A name match is kept only as a tie-break when several exist.
    std::string want, fallback;
    std::string lvl = argv[2];
    for (char& ch : lvl) ch = (char)std::tolower((unsigned char)ch);
    for (const auto& kv : src.res())
    {
        if (kv.second.type != (int)Decals::kResType) continue;
        std::string n = kv.first;
        for (char& ch : n) ch = (char)std::tolower((unsigned char)ch);
        if (n.find(lvl) != std::string::npos) { want = kv.first; break; }
        if (fallback.empty()) fallback = kv.first;
    }
    if (want.empty()) want = fallback;
    if (want.empty()) { std::fprintf(stderr, "no TerrainDecals resource in this mount\n"); return 1; }
    std::printf("resource: %s\n", want.c_str());

    std::vector<uint8_t> res = src.get_res(want, err);
    if (res.empty()) { std::fprintf(stderr, "get_res: %s\n", err.c_str()); return 1; }
    std::printf("  %zu bytes\n", res.size());

    Decals dc;
    if (!dc.parse(std::move(res), err)) { std::fprintf(stderr, "parse: %s\n", err.c_str()); return 1; }

    std::printf("framing %s, records %zu of %u declared, %llu triangle(s), %zu slot(s)\n",
                dc.framing(), dc.records().size(), dc.declared(),
                (unsigned long long)dc.triangles(), dc.slots().size());
    std::printf("  chain %s, vb at 0x%zx (%s), span %zu, end landmark %s",
                dc.chain_ok() ? "HOLDS" : "BROKEN", dc.vb_start(),
                dc.vb_from_anchor() ? "from the landmark" : "from the page rule",
                dc.vb_size(), dc.anchor_ok() ? "found" : "MISSING");
    if (dc.truncated_at() >= 0) std::printf(", truncated at record %d", dc.truncated_at());
    std::printf("\n");

    size_t inside = 0, total = 0, bad_count = 0, empty = 0, planar = 0;
    size_t with_tex = 0, no_slot = 0;
    for (const DecalRecord& r : dc.records())
    {
        std::vector<DecalVertex> vs = dc.vertices(r);
        if (vs.empty()) { empty++; continue; }
        // The list is non-indexed, so this is an equality and not a bound.
        if (vs.size() != (size_t)r.tri_count * 3) bad_count++;
        if (Decals::is_planar(vs)) planar++;
        if (r.asset_slot < dc.slots().size() && !dc.slots()[r.asset_slot].empty()) with_tex++;
        else no_slot++;
        for (const DecalVertex& v : vs)
        {
            total++;
            if (v.x >= r.aabb_min[0] - 0.5f && v.x <= r.aabb_max[0] + 0.5f &&
                v.z >= r.aabb_min[2] - 0.5f && v.z <= r.aabb_max[2] + 0.5f)
                inside++;
        }
    }

    std::printf("  vertices %zu, inside their own record AABB in XZ: %.1f%%\n",
                total, total ? 100.0 * (double)inside / (double)total : 0.0);
    std::printf("  records with vertexCount != triCount*3 : %zu   (should be 0)\n", bad_count);
    std::printf("  records with no vertices              : %zu\n", empty);
    std::printf("  planar fills                          : %zu\n", planar);
    std::printf("  slot resolves to a decal asset        : %zu, positional (layer index) %zu\n",
                with_tex, no_slot);

    // A couple of records in full, so the numbers can be eyeballed against the
    // spec rather than only trusted in aggregate.
    std::printf("\nfirst records:\n");
    for (size_t i = 0; i < dc.records().size() && i < 4; i++)
    {
        const DecalRecord& r = dc.records()[i];
        std::printf("  #%zu first %u tris %u tiling %.2f/%.2f  aabb x %.1f..%.1f y %.1f..%.1f z %.1f..%.1f  slot %u props %zu\n",
                    i, r.first_index, r.tri_count, r.tiling0, r.tiling1,
                    r.aabb_min[0], r.aabb_max[0], r.aabb_min[1], r.aabb_max[1],
                    r.aabb_min[2], r.aabb_max[2], r.asset_slot, r.props.size());
    }
    return (dc.chain_ok() && bad_count == 0) ? 0 : 1;
}
