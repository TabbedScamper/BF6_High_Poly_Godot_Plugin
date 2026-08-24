/* DOES THE HIDDEN-PART FILTER FIRE, AND DOES IT REMOVE THE RIGHT AMOUNT?
 *
 * Not shipped. This filter has two silent failure modes and they look nothing
 * alike on screen but identical in a log:
 *
 *   it never fires        every parked car keeps its own wreck inside it
 *   it fires too widely   the car loses panels and reads as full of holes
 *
 * So the useful output is not "it worked", it is the SHARE of each prop's
 * triangles that went, next to whether that prop has a part table at all. A
 * destructible prop that loses 10-40% is behaving; one that loses 90% is a
 * category error, and one that loses 0% while carrying twin pairs means the
 * per-vertex part index is not being read.
 *
 *   destruction_test <game_dir> <level> <exe> [name_filter]
 */
#include "destruction.h"
#include "meshset.h"
#include "source.h"
#include "types.h"
#include "walk.h"

#include <algorithm>
#include <cstdio>
#include <map>
#include <set>
#include <string>
#include <vector>

using namespace bf6;

int main(int argc, char** argv)
{
    if (argc < 4)
    {
        std::fprintf(stderr, "usage: destruction_test <game_dir> <level> <exe> [filter]\n");
        return 2;
    }
    const std::string filter = argc > 4 ? argv[4] : std::string();

    Source src;
    std::string err;
    if (!src.open(argv[1], err)) { std::fprintf(stderr, "open: %s\n", err.c_str()); return 1; }
    if (!src.mount_level(argv[2], false, err)) { std::fprintf(stderr, "mount: %s\n", err.c_str()); return 1; }
    TypeDb types;
    if (!types.open(argv[3], err)) { std::fprintf(stderr, "types: %s\n", err.c_str()); return 1; }

    Walk w(src, types);
    w.build_catalog();
    if (!w.run(argv[2], err)) { std::fprintf(stderr, "walk: %s\n", err.c_str()); return 1; }

    std::map<std::string, int> placed;
    for (const WalkRow& r : w.rows())
    {
        std::string m = r.mesh;
        if (m.size() > 4 && m.compare(m.size() - 4, 4, ".ebx") == 0) m.resize(m.size() - 4);
        placed[m + "_mesh"]++;
    }

    int props = 0, with_table = 0, with_parts = 0, no_parts_but_table = 0;
    long long tris_before = 0, tris_after = 0;
    std::vector<std::pair<double, std::string> > worst;

    for (const auto& pm : placed)
    {
        const std::string& name = pm.first;
        if (!filter.empty() && name.find(filter) == std::string::npos) continue;

        std::vector<uint8_t> res = src.get_res(name, err);
        if (res.empty()) continue;
        MeshSet ms = meshset_parse(res.data(), res.size(), err);
        if (!ms.ok || ms.lods.empty()) continue;

        const std::set<uint16_t> hidden = destruction_hidden_parts(src, types, name);
        if (hidden.empty()) continue;
        with_table++;
        if (ms.mesh_type == 1) continue;   // skinned: exempt by rule
        props++;

        // The geometry, so the share removed is real rather than assumed.
        std::string e2;
        std::vector<uint8_t> ck;
        {
            // The LOD's chunk id, spelled both ways - the same fallback the
            // core uses, because a chunk id is stored one way and indexed the
            // other in places.
            char hex[33];
            const auto& id = ms.lods[0].chunk_id;
            for (int i = 0; i < 16; i++) std::snprintf(hex + i * 2, 3, "%02x", id[(size_t)i]);
            std::string fwd(hex, 32), rev;
            for (int i = 15; i >= 0; i--) { char t[3]; std::snprintf(t, 3, "%02x", id[(size_t)i]); rev += t; }
            ck = src.get_chunk(fwd, e2);
            if (ck.empty()) ck = src.get_chunk(rev, e2);
        }
        if (ck.empty()) continue;

        auto secs = meshset_read_lod(ms, 0, ck.data(), ck.size(), e2);
        if (secs.empty()) continue;

        long long before = 0, after = 0;
        bool any_parts = false;
        for (const auto& g : secs)
        {
            before += (long long)g.indices.size() / 3;
            if (g.parts.size() != g.positions.size() / 3) { after += (long long)g.indices.size() / 3; continue; }
            any_parts = true;
            for (size_t k = 0; k + 2 < g.indices.size(); k += 3)
            {
                const uint32_t v0 = g.indices[k];
                if (v0 < g.parts.size() && hidden.count(g.parts[v0])) continue;
                after++;
            }
        }
        if (any_parts) with_parts++; else no_parts_but_table++;
        tris_before += before;
        tris_after  += after;
        if (before > 0)
            worst.push_back(std::make_pair(100.0 * (double)(before - after) / (double)before, name));
    }

    std::printf("props carrying hidden twin pairs : %d\n", with_table);
    std::printf("  of those, rigid and filtered   : %d\n", props);
    std::printf("  with a per-vertex part index   : %d\n", with_parts);
    std::printf("  table but NO part index        : %d   <- filter cannot act on these\n",
                no_parts_but_table);
    std::printf("triangles %lld -> %lld  (%.1f%% removed)\n", tris_before, tris_after,
                tris_before ? 100.0 * (double)(tris_before - tris_after) / (double)tris_before : 0.0);

    std::sort(worst.rbegin(), worst.rend());
    std::printf("\nmost affected props:\n");
    for (size_t i = 0; i < worst.size() && i < 15; i++)
        std::printf("  %5.1f%%  %s\n", worst[i].first, worst[i].second.c_str());
    if (!worst.empty())
    {
        std::printf("\nleast affected (0%% here means the table found nothing to hide):\n");
        for (size_t i = worst.size() > 5 ? worst.size() - 5 : 0; i < worst.size(); i++)
            std::printf("  %5.1f%%  %s\n", worst[i].first, worst[i].second.c_str());
    }
    return 0;
}
