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
#include "types.h"
#include "walk.h"

#include <algorithm>
#include <chrono>
#include <cstdio>
#include <cstring>
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
    // With an exe path, the level is walked and the PLACING bundle rule is
    // compared head to head against the mesh-resource rule on the same
    // sections. Without one, only the resource rule can be measured.
    const std::string exe = argc > 5 ? argv[5] : std::string();
    // A substring the mesh name must contain. Without it the sample is whatever
    // sorts first, and "common/characters" sorts before "common/environment" -
    // so three thousand meshes can be entirely characters while the thing being
    // rendered is level props.
    const std::string filter = argc > 4 ? argv[4] : std::string();
    // Optional exact placement bundle for a local control point. A material
    // key is bundle-scoped, so a nearest-instance diagnosis must not silently
    // substitute another placement of the same mesh from a sibling bundle.
    const std::string forced_bundle = argc > 6 ? argv[6] : std::string();

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

    // mesh res name -> the bundle that PLACED it, from the walk.
    std::map<std::string, std::string> placing;
    TypeDb types;
    if (!exe.empty() && types.open(exe, err))
    {
        Walk w(src, types);
        w.build_catalog();
        std::string e;
        if (w.run(argv[2], e))
        {
            for (const WalkRow& r : w.rows())
            {
                std::string m = r.mesh;
                if (m.size() > 4 && m.compare(m.size() - 4, 4, ".ebx") == 0) m.resize(m.size() - 4);
                placing.emplace(m + "_mesh", r.bundle);
            }
            std::fprintf(stderr, "walked: %zu rows, %zu distinct meshes placed\n",
                         w.rows().size(), placing.size());
        }
    }

    int by_res = 0, by_placing = 0, placing_known = 0;
    int differ_sections = 0, hit_placing = 0, hit_res = 0;
    int carpaint = 0, carpaint_const = 0, carpaint_tc1 = 0, carpaint_tc3 = 0;
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

        // THE TWO RULES, side by side on the same mesh.
        const std::string res_rule = src.depot_for_res(mname);
        std::string place_rule;
        if (!forced_bundle.empty())
            place_rule = src.depot_for_bundle(forced_bundle);
        auto pit = placing.find(mname);
        if (place_rule.empty() && pit != placing.end())
        {
            placing_known++;
            place_rule = src.depot_for_bundle(pit->second);
        }
        if (!res_rule.empty()) by_res++;
        if (!place_rule.empty()) by_placing++;

        // The placing bundle wins when we have it; that is the measured rule.
        const std::string dname = !place_rule.empty() ? place_rule : res_rule;
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

        // HEAD TO HEAD, on the same sections. Both rules find A depot; the
        // question is whether it is the RIGHT one, and only the key lookup
        // answers that.
        Depot* dep_res = nullptr;
        const std::vector<uint8_t>* db_res = nullptr;
        if (!res_rule.empty() && !place_rule.empty() && res_rule != place_rule)
        {
            if (!depot_cache.count(res_rule))
            {
                std::vector<uint8_t> rb = src.get_res(res_rule, err);
                Depot rp;
                std::string e2;
                if (!rb.empty() && rp.parse(rb, e2))
                {
                    depot_bytes[res_rule] = std::move(rb);
                    depot_cache[res_rule] = std::move(rp);
                }
            }
            if (depot_cache.count(res_rule))
            {
                dep_res = &depot_cache[res_rule];
                db_res  = &depot_bytes[res_rule];
            }
        }
        const bool rules_differ = (dep_res != nullptr);

        for (const MeshSection& s : ms.lods[0].sections)
        {
            sections++;
            if (s.state_key == 0) continue;
            keyed++;

            if (rules_differ)
            {
                differ_sections++;
                if (dep.has_key(s.state_key)) hit_placing++;
                if (dep_res->has_key(s.state_key)) hit_res++;
            }

            MaterialBinding mb = dep.textures_for(s.state_key, db);
            if (!mb.valid) continue;
            joined++;

            if (!filter.empty())
            {
                std::printf("\nDIAG mesh=%s\n  material=%s state=0x%016llx\n  bundle=%s\n",
                            mname.c_str(), s.material.c_str(),
                            (unsigned long long)s.state_key,
                            forced_bundle.empty() ? place_rule.c_str() : forced_bundle.c_str());
                for (const auto& kv : mb.textures)
                {
                    auto named = gi.find(kv.second);
                    std::printf("  TEX %08x -> %s\n", kv.first,
                                named == gi.end() ? kv.second.c_str() : named->second.c_str());
                }
                for (const auto& kv : mb.constants)
                {
                    std::printf("  VAL %08x bytes=%zu", kv.first, kv.second.size());
                    if (kv.second.size() >= 4)
                    {
                        float f = 0.f;
                        std::memcpy(&f, kv.second.data(), 4);
                        std::printf(" f0=%.9g", f);
                    }
                    std::printf("\n");
                }
            }

            for (const auto& kv : mb.textures) slot_hits[MaterialBinding::display_name(kv.first)]++;

            // WHICH TEXCOORD THE RULE PICKS, and whether the depot actually
            // says. Reported rather than trusted: the last time a channel was
            // chosen without the depot it was wrong and had to be retracted.
            {
                // DATA-DRIVEN, not by name: carpaint is the flakes-normal slot
                // being bound. The material names in this data do not contain
                // "carpaint" at all, so a name test finds nothing and reports
                // a clean zero, which looks like agreement and is not.
                // THE FULL CONJUNCTION. Flakes alone is not carpaint: a fuel
                // canister and a machine gun bind it too, and forcing them onto
                // TC3 would break props that are fine on TC0.
                if (mb.textures.count(0xA11011B8) &&
                    !mb.textures.count(0x54BBCD30) &&
                    !mb.constants.count(0xF1CEE56D) && !mb.constants.count(0xF1CEE56E))
                {
                    carpaint++;
                    auto it = mb.constants.find(0x4F5F0664);
                    const bool present = it != mb.constants.end() && !it->second.empty();
                    const bool tc1 = present && it->second[0] != 0;
                    if (present) carpaint_const++;
                    if (tc1) carpaint_tc1++; else carpaint_tc3++;
                    if (carpaint <= 6)
                        std::printf("  carpaint: %-44s const %s -> TC%d\n",
                                    s.material.substr(0, 44).c_str(),
                                    present ? "present" : "ABSENT ", tc1 ? 1 : 3);
                }
            }
            // By hash now, which is what the binding carries.
            if (mb.textures.count(0x54BBCD30)) with_basecolor++;
            if (mb.textures.count(0xEC35A757) || mb.textures.count(0xEC35A68C) ||
                mb.textures.count(0xEC35A9E2) || mb.textures.count(0xEC35A74C)) with_normal++;
            if (mb.textures.count(0xB1A29A3C)) with_occl++;

            // Take the basecolor all the way to pixels: that is the link that
            // proves the guid spelling and the texture decode agree.
            auto bc = mb.textures.find(0x54BBCD30);
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
    std::printf("  placing bundle known for %d of %d mesh(es)\n", placing_known, n_mesh);
    std::printf("  depot by resource rule %d, by PLACING rule %d\n", by_res, by_placing);
    std::printf("  depot found for the mesh's bundle : %d of %d (%d missing, %d unreadable)\n",
                n_mesh - no_depot - depot_bad, n_mesh, no_depot, depot_bad);
    std::printf("  sections %d, with a state key %d, joined to a depot record %d (%.1f%%)\n",
                sections, keyed, joined, keyed ? 100.0 * joined / keyed : 0.0);
    std::printf("  of the joined: basecolor %d, normal %d, occl_rough %d\n",
                with_basecolor, with_normal, with_occl);
    std::printf("  basecolor guid resolved to an asset %d, decoded to pixels %d, failed %d\n",
                tex_named, tex_decoded, tex_failed);
    std::printf("  where the two rules pick DIFFERENT depots: %d section(s), placing-rule hits %d, resource-rule hits %d\n",
                differ_sections, hit_placing, hit_res);
    std::printf("  carpaint sections %d: %d carry the channel const, %d -> TC1, %d -> TC3\n",
                carpaint, carpaint_const, carpaint_tc1, carpaint_tc3);
    std::printf("  slots seen:");
    for (const auto& kv : slot_hits) std::printf(" %s=%d", kv.first.c_str(), kv.second);
    std::printf("\n");
    return joined > 0 ? 0 : 1;
}
