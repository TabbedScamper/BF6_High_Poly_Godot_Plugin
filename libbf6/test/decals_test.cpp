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
#include <cmath>
#include <cstdio>
#include <map>
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
    std::map<uint32_t, size_t> asset_slot_uses;
    for (const DecalRecord& r : dc.records()) asset_slot_uses[r.asset_slot]++;
    std::printf("  asset slots used:");
    for (const auto& kv : asset_slot_uses)
        std::printf(" %u(%zu)", kv.first, kv.second);
    std::printf("\n");
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
    // WHICH TEXTURE SLOTS ACTUALLY RESOLVE.
    //
    // A decal whose colour slot resolves to nothing draws as a WHITE PLANE,
    // because the material instance leaves the parameter at the parent's
    // default. So the interesting number is not how many records parse, it is
    // how many carry a texture guid that the partition index can turn into an
    // asset.
    {
        const uint64_t SLOT_CV  = 0x399AC0336ACFE03Cull;
        const uint64_t SLOT_OP  = 0x3810287D4CE70B49ull;
        const uint64_t SLOT_NHS = 0x567A9BC35CCBB1B2ull;
        const std::map<std::string, std::string>& gi = src.partition_index();
        size_t haveCv = 0, haveOp = 0, haveNhs = 0, anyTex = 0, resolvedCv = 0;
        std::map<std::string, size_t> byName;
        for (const bf6::DecalRecord& r : dc.records()) {
            bool cv = false, op = false, nhs = false, any = false;
            for (const bf6::DecalProp& pr : r.props) {
                if (pr.kind != bf6::DecalProp::Kind::Texture) continue;
                any = true;
                { char nb[32]; std::snprintf(nb, sizeof(nb), "%016llX", (unsigned long long)pr.name); byName[nb]++; }
                if (pr.name == SLOT_CV) {
                    cv = true;
                    if (gi.find(pr.guid) != gi.end()) resolvedCv++;
                }
                if (pr.name == SLOT_OP)  op = true;
                if (pr.name == SLOT_NHS) nhs = true;
            }
            if (cv) haveCv++;
            if (op) haveOp++;
            if (nhs) haveNhs++;
            if (any) anyTex++;
        }
        const size_t n = dc.records().size();
        std::printf("\ntexture slots resolve (of %zu records)\n", n);
        std::printf("  any texture prop at all : %zu\n", anyTex);
        std::printf("  colour  slot present    : %zu   (guid resolves: %zu)\n", haveCv, resolvedCv);
        std::printf("  opacity slot present    : %zu\n", haveOp);
        std::printf("  normal  slot present    : %zu\n", haveNhs);
        std::printf("  distinct texture slot names seen: %zu\n", byName.size());
        // WHAT EACH SLOT ACTUALLY IS.
        //
        // The asset name suffix names the role, the same convention the
        // terrain sheets and the prop depot use: _cv colour, _op coverage,
        // _nhs normal/height/smoothness, _ao, _mxx. A slot used by more
        // records than the colour slot, and never read, is a slot we are
        // dropping on the floor.
        std::printf("  a resolved asset per slot:\n");
        for (std::map<std::string, size_t>::const_iterator kv = byName.begin();
             kv != byName.end(); ++kv) {
            int shownHere = 0;
            for (size_t ri = 0; ri < dc.records().size() && shownHere < 2; ri++) {
                const bf6::DecalRecord& r2 = dc.records()[ri];
                for (size_t pi = 0; pi < r2.props.size() && shownHere < 2; pi++) {
                    const bf6::DecalProp& pr = r2.props[pi];
                    if (pr.kind != bf6::DecalProp::Kind::Texture) continue;
                    char nb[32];
                    std::snprintf(nb, sizeof(nb), "%016llX", (unsigned long long)pr.name);
                    if (kv->first != nb) continue;
                    std::map<std::string, std::string>::const_iterator it = gi.find(pr.guid);
                    if (it == gi.end()) continue;
                    std::printf("    %s -> %s\n", nb, it->second.c_str());
                    shownHere++;
                }
            }
        }
        size_t shown = 0;
        for (const auto& kv : byName) {
            std::printf("    slot %s used by %zu record(s)\n", kv.first.c_str(), kv.second);
            if (++shown >= 12) break;
        }
    }

    std::printf("\nfirst records:\n");
    for (size_t i = 0; i < dc.records().size() && i < 4; i++)
    {
        const DecalRecord& r = dc.records()[i];
        std::printf("  #%zu first %u tris %u tiling %.2f/%.2f  aabb x %.1f..%.1f y %.1f..%.1f z %.1f..%.1f  slot %u props %zu\n",
                    i, r.first_index, r.tri_count, r.tiling0, r.tiling1,
                    r.aabb_min[0], r.aabb_max[0], r.aabb_min[1], r.aabb_max[1],
                    r.aabb_min[2], r.aabb_max[2], r.asset_slot, r.props.size());
    }

    // Point/radius diagnosis: identify what the user is actually looking at
    // from the compiled runtime records, rather than guessing from a screenshot.
    if (argc >= 6)
    {
        const float qx = (float)std::atof(argv[3]);
        const float qz = (float)std::atof(argv[4]);
        const float qr = (float)std::atof(argv[5]);
        struct Hit { float d; size_t i; };
        std::vector<Hit> hits;
        for (size_t i = 0; i < dc.records().size(); i++)
        {
            const DecalRecord& r = dc.records()[i];
            const float dx = qx < r.aabb_min[0] ? r.aabb_min[0] - qx
                           : qx > r.aabb_max[0] ? qx - r.aabb_max[0] : 0.f;
            const float dz = qz < r.aabb_min[2] ? r.aabb_min[2] - qz
                           : qz > r.aabb_max[2] ? qz - r.aabb_max[2] : 0.f;
            const float d = std::sqrt(dx * dx + dz * dz);
            if (d <= qr) hits.push_back({ d, i });
        }
        std::sort(hits.begin(), hits.end(), [](const Hit& a, const Hit& b)
                  { return a.d < b.d; });
        std::printf("\n%zu decal record(s) whose AABB is within %.1f m of (%.1f, %.1f):\n",
                    hits.size(), qr, qx, qz);
        const uint64_t slots[] = { 0x399AC0336ACFE03Cull, 0x3810287D4CE70B49ull,
                                   0x567A9BC35CCBB1B2ull };
        const char* labels[] = { "cv", "op", "nhs" };
        for (size_t hi = 0; hi < hits.size(); hi++)
        {
            const DecalRecord& r = dc.records()[hits[hi].i];
            std::vector<DecalVertex> vs = dc.vertices(r);
            float u0 = 1e30f, u1 = -1e30f, v0 = 1e30f, v1 = -1e30f;
            float a0 = 1e30f, a1 = -1e30f;
            for (const DecalVertex& v : vs)
            {
                u0 = std::min(u0, v.u); u1 = std::max(u1, v.u);
                v0 = std::min(v0, v.v); v1 = std::max(v1, v.v);
                a0 = std::min(a0, v.a); a1 = std::max(a1, v.a);
            }
            std::string cls;
            if (r.asset_slot < dc.slots().size())
            {
                const std::string& guid = dc.slots()[r.asset_slot];
                const auto it = src.partition_index().find(guid);
                cls = it == src.partition_index().end() ? guid : it->second;
            }
            std::printf("  #%zu d %.1f tris %u %s aabb x %.1f..%.1f y %.1f..%.1f z %.1f..%.1f class %s",
                        hits[hi].i, hits[hi].d, r.tri_count,
                        Decals::is_planar(vs) ? "PLANAR" : "uv",
                        r.aabb_min[0], r.aabb_max[0], r.aabb_min[1], r.aabb_max[1],
                        r.aabb_min[2], r.aabb_max[2], cls.c_str());
            for (int si = 0; si < 3; si++)
                for (const DecalProp& p : r.props)
                    if (p.kind == DecalProp::Kind::Texture && p.name == slots[si])
                    {
                        const auto it = src.partition_index().find(p.guid);
                        std::printf(" %s=%s", labels[si],
                                    it == src.partition_index().end() ? p.guid.c_str() : it->second.c_str());
                    }
            std::printf(" uv %.2f..%.2f/%.2f..%.2f alpha %.3f..%.3f",
                        u0, u1, v0, v1, a0, a1);
            for (const DecalProp& p : r.props)
            {
                if (p.kind == DecalProp::Kind::Vec3 && p.values.size() >= 3)
                    std::printf(" vec3[%016llX]=(%.4f,%.4f,%.4f)",
                        (unsigned long long)p.name, p.values[0], p.values[1], p.values[2]);
                else if (p.kind == DecalProp::Kind::Float && !p.values.empty())
                    std::printf(" float[%016llX]=%.4f",
                        (unsigned long long)p.name, p.values[0]);
                else if (p.kind == DecalProp::Kind::Vec2 && p.values.size() >= 2)
                    std::printf(" vec2[%016llX]=(%.4f,%.4f)",
                        (unsigned long long)p.name, p.values[0], p.values[1]);
                else if (p.kind == DecalProp::Kind::Int && !p.ints.empty())
                    std::printf(" int[%016llX]=%d",
                        (unsigned long long)p.name, p.ints[0]);
            }
            std::printf("\n");
        }
    }
    return (dc.chain_ok() && bad_count == 0) ? 0 : 1;
}
