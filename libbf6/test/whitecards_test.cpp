/* whitecards_test - which vegetation sections resolve NO base colour, and
 * what their depot records bind instead. The white-card diagnostic: a card is
 * white exactly when the albedo chain comes up empty, so the fix is whatever
 * slot hash dominates here.
 *
 *   whitecards_test <game_dir> <level> [filter=vegetation] [max=2000]
 */
#include <algorithm>
#include <cstdio>
#include <map>
#include <set>
#include <string>
#include <vector>

#include "depot.h"
#include "meshset.h"
#include "source.h"

using namespace bf6;

// bf6_core.cpp's chain, duplicated for the diagnostic. If this drifts from
// albedo_slot_of the report lies, so compare when editing either.
static const uint32_t kChain[] = {
    0x54BBCD30, 0x54BBCD36, 0x21F3F4E1, 0xEA026FC7, 0xA4415059,
    0x691A5E17, 0x691BEAB4, 0x39DA140E, 0xA17E658F, 0x365B13EF, 0x1C5FA3EE,
};

static bool chain_hits(const MaterialBinding& mb)
{
    for (uint32_t h : kChain)
        if (mb.textures.count(h)) return true;
    // the wrap-slot fallback, with its carpaint guard
    if (mb.textures.count(0x54BBCD22) && !mb.textures.count(0xA11011B8)) return true;
    return false;
}

static std::string suffix_of(const std::string& asset)
{
    const size_t slash = asset.find_last_of('/');
    const std::string leaf = slash == std::string::npos ? asset : asset.substr(slash + 1);
    const size_t us = leaf.find_last_of('_');
    return us == std::string::npos ? std::string("?") : leaf.substr(us);
}

int main(int argc, char** argv)
{
    if (argc < 3) { std::fprintf(stderr, "usage: whitecards_test <game_dir> <level> [filter] [max]\n"); return 2; }
    const std::string filter = argc > 3 ? argv[3] : std::string("vegetation");
    const int limit = argc > 4 ? std::atoi(argv[4]) : 2000;

    Source src;
    std::string err;
    if (!src.open(argv[1], err)) { std::fprintf(stderr, "open: %s\n", err.c_str()); return 1; }
    if (!src.mount_level(argv[2], false, err)) { std::fprintf(stderr, "mount: %s\n", err.c_str()); return 1; }
    const std::map<std::string, std::string>& gi = src.partition_index();

    std::vector<std::string> meshes;
    for (const auto& kv : src.res())
        if (kv.first.size() > 5 && kv.first.compare(kv.first.size() - 5, 5, "_mesh") == 0 &&
            kv.first.find(filter) != std::string::npos)
            meshes.push_back(kv.first);
    std::sort(meshes.begin(), meshes.end());
    std::fprintf(stderr, "%zu %s meshes\n", meshes.size(), filter.c_str());

    std::map<std::string, Depot> depot_cache;
    std::map<std::string, std::vector<uint8_t>> depot_bytes;

    int n = 0, sections = 0, misses = 0;
    // slot hash -> (bindings on MISSING sections, suffix histogram)
    std::map<uint32_t, std::map<std::string, int>> miss_slots;
    std::set<std::string> miss_meshes;

    for (const std::string& mname : meshes)
    {
        if (n >= limit) break;
        std::vector<uint8_t> mres = src.get_res(mname, err);
        if (mres.empty()) continue;
        MeshSet ms = meshset_parse(mres.data(), mres.size(), err);
        if (!ms.ok || ms.lods.empty()) continue;
        n++;

        const std::string dname = src.depot_for_res(mname);
        if (dname.empty()) continue;
        if (!depot_cache.count(dname))
        {
            std::vector<uint8_t> db = src.get_res(dname, err);
            Depot dp;
            std::string e;
            if (db.empty() || !dp.parse(db, e)) continue;
            depot_bytes[dname] = std::move(db);
            depot_cache[dname] = std::move(dp);
        }
        Depot& dep = depot_cache[dname];
        const std::vector<uint8_t>& db = depot_bytes[dname];

        for (const MeshSection& s : ms.lods[0].sections)
        {
            if (!s.state_key) continue;
            if (!dep.has_key(s.state_key)) continue;
            sections++;
            MaterialBinding mb = dep.textures_for(s.state_key, db);
            if (!mb.valid || chain_hits(mb)) continue;
            misses++;
            miss_meshes.insert(mname + std::string("  [") + s.material + std::string("]"));
            for (const auto& kv : mb.textures)
            {
                auto ait = gi.find(kv.second);
                const std::string asset = ait == gi.end() ? std::string("?") : ait->second;
                miss_slots[kv.first][suffix_of(asset)]++;
            }
        }
    }

    std::printf("%d meshes, %d keyed sections, %d with NO base colour (%.1f%%), %zu distinct meshes affected\n",
        n, sections, misses, sections ? 100.0 * misses / sections : 0.0, miss_meshes.size());
    std::printf("\nslots bound on the missing sections (hash: suffix histogram):\n");
    for (const auto& kv : miss_slots)
    {
        int total = 0;
        for (const auto& s : kv.second) total += s.second;
        if (total < 5) continue;
        std::printf("  %08x  %4d :", kv.first, total);
        // top suffixes
        std::vector<std::pair<int, std::string>> top;
        for (const auto& s : kv.second) top.push_back({ s.second, s.first });
        std::sort(top.rbegin(), top.rend());
        for (size_t i = 0; i < top.size() && i < 4; i++)
            std::printf("  %s=%d", top[i].second.c_str(), top[i].first);
        std::printf("\n");
    }
    std::printf("\nfirst affected meshes:\n");
    int shown = 0;
    for (const std::string& m : miss_meshes) { std::printf("  %s\n", m.c_str()); if (++shown >= 12) break; }
    return 0;
}
