/* variation_test - do variation keys RESOLVE, and does merging change the
 * binding? The livery proof: with the wrong hash every derived key missed and
 * fell back to base silently; with the right one the variant records - the
 * livery overlays and colour tables - must actually be found.
 *
 *   variation_test <game_dir> <level> <exe> [max_pairs]
 */
#include <algorithm>
#include <cstdio>
#include <cstring>
#include <map>
#include <set>
#include <string>
#include <vector>

#include "depot.h"
#include "meshset.h"
#include "source.h"
#include "types.h"
#include "walk.h"

using namespace bf6;

// The XOR djb2, same as the core (kept in step by hand).
static uint64_t djb2_lower(const std::string& s)
{
    uint32_t h = 5381;
    for (unsigned char c : s) {
        unsigned char l = (c >= 'A' && c <= 'Z') ? (unsigned char)(c + 32) : c;
        h = (h * 33u) ^ l;
    }
    return (uint64_t)h;
}

int main(int argc, char** argv)
{
    if (argc < 4) { std::fprintf(stderr, "usage: variation_test <game_dir> <level> <exe> [max_pairs]\n"); return 2; }
    const int limit = argc > 4 ? std::atoi(argv[4]) : 400;

    Source src;
    std::string err;
    if (!src.open(argv[1], err)) { std::fprintf(stderr, "open: %s\n", err.c_str()); return 1; }
    if (!src.mount_level(argv[2], false, err)) { std::fprintf(stderr, "mount: %s\n", err.c_str()); return 1; }
    TypeDb types;
    if (!types.open(argv[3], err)) { std::fprintf(stderr, "types: %s\n", err.c_str()); return 1; }
    src.partition_index();

    Walk w(src, types);
    w.build_catalog();
    if (!w.run(argv[2], err)) { std::fprintf(stderr, "walk: %s\n", err.c_str()); return 1; }

    // Distinct (mesh, bundle, variation) with a REAL variation.
    std::set<std::string> seen;
    std::vector<std::pair<std::string, std::pair<std::string, std::string>>> pairs; // mesh, (bundle, var)
    for (const WalkRow& r : w.rows())
    {
        if (r.var.empty() || r.mesh.empty()) continue;
        std::string m = r.mesh;
        if (m.size() > 4 && m.compare(m.size() - 4, 4, ".ebx") == 0) m.resize(m.size() - 4);
        m += "_mesh";
        const std::string key = m + "|" + r.bundle + "|" + r.var;
        if (!seen.insert(key).second) continue;
        pairs.push_back({ m, { r.bundle, r.var } });
    }
    std::fprintf(stderr, "%zu distinct (mesh, bundle, variation) with a variation\n", seen.size());

    std::map<std::string, Depot> depot_cache;
    std::map<std::string, std::vector<uint8_t>> depot_bytes;

    int npairs = 0, sections = 0, var_hits = 0, merged_added = 0;
    std::map<std::string, int> delta_slots;   // display name of slots the variant added
    for (const auto& pr : pairs)
    {
        if (npairs >= limit) break;
        std::vector<uint8_t> mres = src.get_res(pr.first, err);
        if (mres.empty()) continue;
        MeshSet ms = meshset_parse(mres.data(), mres.size(), err);
        if (!ms.ok || ms.lods.empty()) continue;

        const std::string dname = src.depot_for_bundle(pr.second.first);
        if (dname.empty()) continue;
        if (!depot_cache.count(dname))
        {
            std::vector<uint8_t> db = src.get_res(dname, err);
            Depot dp; std::string e;
            if (db.empty() || !dp.parse(db, e)) continue;
            depot_bytes[dname] = std::move(db);
            depot_cache[dname] = std::move(dp);
        }
        Depot& dep = depot_cache[dname];
        const std::vector<uint8_t>& db = depot_bytes[dname];
        npairs++;

        std::string vp = pr.second.second;
        for (char& ch : vp) if (ch == 0x5C) ch = '/';
        if (vp.size() > 4 && vp.compare(vp.size() - 4, 4, ".ebx") == 0) vp.resize(vp.size() - 4);
        const uint64_t vh = djb2_lower(vp);
        for (const MeshSection& s : ms.lods[0].sections)
        {
            if (!s.state_key) continue;
            sections++;
            const uint64_t vkey = s.state_key + vh;
            if (!dep.has_key(vkey)) continue;
            var_hits++;
            // What does the variant record ADD over the base?
            MaterialBinding vb = dep.textures_for(vkey, db);
            MaterialBinding bb = dep.has_key(s.state_key)
                ? dep.textures_for(s.state_key, db) : MaterialBinding();
            bool added = false;
            for (const auto& kv : vb.textures)
                if (!bb.textures.count(kv.first))
                {
                    added = true;
                    const char* dn = MaterialBinding::display_name(kv.first);
                    char buf[16];
                    if (!dn) { std::snprintf(buf, sizeof(buf), "%08x", kv.first); dn = buf; }
                    delta_slots[dn]++;
                }
            for (const auto& kv : vb.constants)
                if (!bb.constants.count(kv.first)) added = true;
            if (added) merged_added++;
        }
    }

    std::printf("%d pairs read, %d keyed sections, variation key RESOLVES on %d (%.1f%%), "
                "variant record adds something on %d\n",
        npairs, sections, var_hits, sections ? 100.0 * var_hits / sections : 0.0, merged_added);
    std::printf("texture slots the variant records added:\n");
    for (const auto& kv : delta_slots)
        std::printf("  %-24s %d\n", kv.first.c_str(), kv.second);
    return 0;
}
