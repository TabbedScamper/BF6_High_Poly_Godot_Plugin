/* The whole material chain, end to end, on real props.
 *
 * Not shipped. This is the join every previous module was building toward, and
 * it has four links that can each fail silently:
 *
 *   mesh section  -> state key (inline at +0x130)
 *   resource      -> the BUNDLE it came in     (scope)
 *   bundle        -> its ShaderBlockDepot
 *   state key     -> texture slots -> file guids -> asset names -> pixels
 *
 * A break anywhere gives an untextured prop and no error, so this reports the
 * survival rate at every link rather than a single pass or fail.
 *
 *   material_test <game_dir> <level> [max_meshes]
 */
#include "depot.h"
#include "meshset.h"
#include "source.h"
#include "texture.h"

#include <algorithm>
#include <chrono>
#include <cstdio>
#include <map>
#include <string>
#include <vector>

using namespace bf6;

int main(int argc, char** argv)
{
    if (argc < 3)
    {
        std::fprintf(stderr, "usage: material_test <game_dir> <level> [max_meshes]\n");
        return 2;
    }
    const int limit = argc > 3 ? std::atoi(argv[3]) : 200;
    // A substring the mesh name must contain. Without it the sample is whatever
    // sorts first, and "common/characters" sorts before "common/environment" -
    // so three thousand meshes can be entirely characters while the thing being
    // rendered is level props.
    const std::string filter = argc > 4 ? argv[4] : std::string();

    Source src;
    std::string err;
    if (!src.open(argv[1], err)) { std::fprintf(stderr, "open: %s\n", err.c_str()); return 1; }
    std::fprintf(stderr, "mounting...\n");
    if (!src.mount_level(argv[2], false, err)) { std::fprintf(stderr, "mount: %s\n", err.c_str()); return 1; }
    std::fprintf(stderr, "indexing partitions...\n");
    const std::map<std::string, std::string>& gi = src.partition_index();
    std::fprintf(stderr, "  %zu partitions\n", gi.size());

    // Every mesh in the mount, so the sample is props rather than whatever
    // happens to sort first.
    std::vector<std::string> meshes;
    for (const auto& kv : src.res())
        if (kv.first.size() > 5 && kv.first.compare(kv.first.size() - 5, 5, "_mesh") == 0 &&
            (filter.empty() || kv.first.find(filter) != std::string::npos))
            meshes.push_back(kv.first);
    std::sort(meshes.begin(), meshes.end());
    std::fprintf(stderr, "%zu meshes in this mount\n", meshes.size());

    int n_mesh = 0, no_depot = 0, depot_bad = 0;
    int sections = 0, keyed = 0, joined = 0, with_basecolor = 0, with_normal = 0, with_occl = 0;
    int tex_named = 0, tex_decoded = 0, tex_failed = 0;
    std::map<std::string, int> slot_hits;
    std::map<std::string, Depot> depot_cache;
    std::map<std::string, std::vector<uint8_t>> depot_bytes;

    auto fetch = [&](const std::string& g) { std::string e; return src.get_chunk(g, e); };
    const auto t0 = std::chrono::steady_clock::now();

    for (const std::string& mname : meshes)
    {
        if (n_mesh >= limit) break;

        std::vector<uint8_t> mres = src.get_res(mname, err);
        if (mres.empty()) continue;
        MeshSet ms = meshset_parse(mres.data(), mres.size(), err);
        if (!ms.ok || ms.lods.empty()) continue;
        n_mesh++;

        const std::string dname = src.depot_for_res(mname);
        if (dname.empty()) { no_depot++; continue; }

        if (!depot_cache.count(dname))
        {
            std::vector<uint8_t> db = src.get_res(dname, err);
            Depot dp;
            std::string e;
            if (db.empty() || !dp.parse(db, e)) { depot_bad++; continue; }
            depot_bytes[dname] = std::move(db);
            depot_cache[dname] = std::move(dp);
        }
        Depot& dep = depot_cache[dname];
        const std::vector<uint8_t>& db = depot_bytes[dname];

        for (const MeshSection& s : ms.lods[0].sections)
        {
            sections++;
            if (s.state_key == 0) continue;
            keyed++;

            MaterialBinding mb = dep.textures_for(s.state_key, db);
            if (!mb.valid) continue;
            joined++;

            for (const auto& kv : mb.textures) slot_hits[kv.first]++;
            if (mb.textures.count("basecolor")) with_basecolor++;
            if (mb.textures.count("normal"))    with_normal++;
            if (mb.textures.count("occl_rough")) with_occl++;

            // Take the basecolor all the way to pixels: that is the link that
            // proves the guid spelling and the texture decode agree.
            auto bc = mb.textures.find("basecolor");
            if (bc == mb.textures.end()) continue;
            auto asset = gi.find(bc->second);
            if (asset == gi.end()) continue;
            tex_named++;

            std::string tname = asset->second;
            if (tname.size() > 4 && tname.compare(tname.size() - 4, 4, ".ebx") == 0)
                tname.resize(tname.size() - 4);

            std::vector<uint8_t> tres = src.get_res(tname, err);
            if (tres.empty()) { tex_failed++; continue; }
            TextureImage img;
            std::string e;
            if (Texture::decode(tres, fetch, img, 0, e)) tex_decoded++;
            else tex_failed++;

            if (tex_decoded <= 5 && !e.length())
                std::printf("  %-52s  %4dx%-4d dxgi%-3d %s\n",
                            tname.substr(tname.size() > 52 ? tname.size() - 52 : 0).c_str(),
                            img.width, img.height, img.dxgi, img.srgb ? "sRGB" : "linear");
        }
    }
    const double sec = std::chrono::duration<double>(
        std::chrono::steady_clock::now() - t0).count();

    std::printf("\n%d mesh(es) in %.1fs\n", n_mesh, sec);
    std::printf("  depot found for the mesh's bundle : %d of %d (%d missing, %d unreadable)\n",
                n_mesh - no_depot - depot_bad, n_mesh, no_depot, depot_bad);
    std::printf("  sections %d, with a state key %d, joined to a depot record %d (%.1f%%)\n",
                sections, keyed, joined, keyed ? 100.0 * joined / keyed : 0.0);
    std::printf("  of the joined: basecolor %d, normal %d, occl_rough %d\n",
                with_basecolor, with_normal, with_occl);
    std::printf("  basecolor guid resolved to an asset %d, decoded to pixels %d, failed %d\n",
                tex_named, tex_decoded, tex_failed);
    std::printf("  slots seen:");
    for (const auto& kv : slot_hits) std::printf(" %s=%d", kv.first.c_str(), kv.second);
    std::printf("\n");
    return joined > 0 ? 0 : 1;
}
