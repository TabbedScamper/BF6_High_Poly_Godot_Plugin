/* WHICH PLACED SECTIONS COME OUT WITH NO BASE COLOUR, AND WHAT THEY BIND INSTEAD.
 *
 * Not shipped. "Some of the vegetation has no texture and the rest looks right"
 * is not a rendering problem, it is a LOOKUP problem: a slot hash the albedo
 * picker does not recognise resolves to nothing, and that section draws
 * untextured while its neighbours are fine.
 *
 * That failure is invisible in the aggregate. The add-on reported 4,243 of
 * 4,243 bindings bound, because every binding it RECOGNISED did bind. The
 * sections with no recognised slot never entered the count at all.
 *
 * So this counts the other thing: sections that joined a depot record and still
 * have no albedo, grouped by the slots they do carry, with example assets. A
 * slot at the top of that list with a plausible name is the missing case.
 *
 * Placed meshes only, from the walk. The mount holds thousands of assets this
 * level never draws, and a coverage number over all of them measures the wrong
 * population.
 *
 *   albedo_test <game_dir> <level> <exe> [max_meshes]
 */
#include "depot.h"
#include "meshset.h"
#include "source.h"
#include "types.h"
#include "walk.h"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <map>
#include <string>
#include <vector>

using namespace bf6;

namespace {

bool wrap_ok(const MaterialBinding& mb)
{
    return mb.textures.count(0x54BBCD22) &&
           !mb.textures.count(0x54BBCD30) && !mb.textures.count(0x54BBCD36) &&
           !mb.textures.count(0xA11011B8);
}

bool c3(const MaterialBinding& mb, uint32_t h, size_t off, float o[3])
{
    std::map<uint32_t, std::vector<uint8_t> >::const_iterator it = mb.constants.find(h);
    if (it == mb.constants.end() || it->second.size() < off + 12) return false;
    std::memcpy(o, &it->second[off], 12);
    return true;
}

bool near3(const float c[3], float v)
{
    return std::fabs(c[0]-v) < 0.004f && std::fabs(c[1]-v) < 0.004f && std::fabs(c[2]-v) < 0.004f;
}

bool has_tint(const MaterialBinding& mb)
{
    float t[3];
    if (c3(mb, 0x8A369BB2, 0, t) && !near3(t, 1.f)) return true;
    if ((c3(mb, 0x686A1072, 0, t) || c3(mb, 0x888A432A, 0, t)) &&
        !near3(t, 0.5f) && !near3(t, 0.4995f)) return true;
    return false;
}

}  // namespace

int main(int argc, char** argv)
{
    if (argc < 4)
    {
        std::fprintf(stderr, "usage: albedo_test <game_dir> <level> <exe> [max]\n");
        return 2;
    }
    const int limit = argc > 4 ? std::atoi(argv[4]) : 100000;
    const std::string detail = argc > 5 ? argv[5] : std::string();
    int detailed = 0;

    Source src;
    std::string err;
    if (!src.open(argv[1], err)) { std::fprintf(stderr, "open: %s\n", err.c_str()); return 1; }
    std::fprintf(stderr, "mounting...\n");
    if (!src.mount_level(argv[2], false, err)) { std::fprintf(stderr, "mount: %s\n", err.c_str()); return 1; }
    std::fprintf(stderr, "indexing...\n");
    const std::map<std::string, std::string>& gi = src.partition_index();

    TypeDb types;
    if (!types.open(argv[3], err)) { std::fprintf(stderr, "types: %s\n", err.c_str()); return 1; }
    Walk w(src, types);
    w.build_catalog();
    if (!w.run(argv[2], err)) { std::fprintf(stderr, "walk: %s\n", err.c_str()); return 1; }

    // mesh resource -> the bundle that placed it, and how many times it lands.
    std::map<std::string, std::string> placing;
    std::map<std::string, int> placed_count;
    for (const WalkRow& r : w.rows())
    {
        std::string m = r.mesh;
        if (m.size() > 4 && m.compare(m.size() - 4, 4, ".ebx") == 0) m.resize(m.size() - 4);
        placing.emplace(m + "_mesh", r.bundle);
        placed_count[m + "_mesh"]++;
    }
    std::fprintf(stderr, "%zu rows, %zu distinct meshes placed\n", w.rows().size(), placing.size());

    std::map<std::string, Depot> dcache;
    std::map<std::string, std::vector<uint8_t>> dbytes;

    int meshes = 0, unreadable = 0, sections = 0, keyed = 0, joined = 0;
    int with_albedo = 0, no_albedo = 0;
    long long inst_albedo = 0, inst_no_albedo = 0;
    std::map<uint32_t, int> hit;
    std::map<uint32_t, int> orphan_slot;
    std::map<uint32_t, long long> orphan_inst;
    std::map<std::string, int> orphan_material;
    std::map<std::string, int> orphan_mesh;
    std::map<uint32_t, std::string> orphan_example;
    std::map<std::string, int> bad_mesh;
    std::map<std::string, long long> bad_why;
    std::map<std::string, int> rescue;
    std::map<std::string, long long> rescue_inst;
    std::map<uint32_t, int> ocons;
    std::map<uint32_t, int> ocons_sz;
    std::map<uint32_t, std::map<std::string,int> > paint;
    std::map<uint32_t, std::map<std::string, long long> > cen;
    std::map<uint32_t, long long> cen_tot;
    std::map<uint32_t, int> cen_def;
    std::map<uint32_t, std::string> cen_ex;
    int chain_sections = 0, colour_sections = 0;
    long long chain_inst = 0, colour_inst = 0;

    for (const auto& pm : placing)
    {
        if (meshes >= limit) break;
        const std::string& mname = pm.first;
        std::vector<uint8_t> mres = src.get_res(mname, err);
        if (mres.empty())
        {
            unreadable++;
            bad_mesh[mname] = placed_count[mname];
            bad_why["the resource itself could not be read"] += placed_count[mname];
            continue;
        }
        MeshSet ms = meshset_parse(mres.data(), mres.size(), err);
        if (!ms.ok || ms.lods.empty())
        {
            unreadable++;
            bad_mesh[mname] = placed_count[mname];
            bad_why[ms.ok ? "parsed but carries no LOD" : ("parse: " + err)] += placed_count[mname];
            continue;
        }
        meshes++;
        const int inst = placed_count[mname];

        std::string dname = src.depot_for_bundle(pm.second);
        if (dname.empty()) dname = src.depot_for_res(mname);
        if (dname.empty()) continue;
        if (!dcache.count(dname))
        {
            std::vector<uint8_t> db = src.get_res(dname, err);
            Depot dp;
            std::string e;
            if (db.empty() || !dp.parse(db, e)) continue;
            dbytes[dname] = std::move(db);
            dcache[dname] = std::move(dp);
        }
        Depot& dep = dcache[dname];
        const std::vector<uint8_t>& db = dbytes[dname];

        for (const MeshSection& s : ms.lods[0].sections)
        {
            // THE SAME FILTER THE GEOMETRY READ APPLIES, or this measures a
            // population that never reaches the screen. Shadow, ZOnly and depth
            // proxies are real sections with real state keys and no albedo, and
            // counting them makes the untextured share look twice its true size
            // while pointing at meshes that are already being dropped.
            if (s.prim_count == 0 || s.vertex_count == 0) continue;
            std::string low = s.material;
            for (char& ch : low) if (ch >= 'A' && ch <= 'Z') ch = (char)(ch + 32);
            if (low.find("shadow") != std::string::npos ||
                low.find("zonly")  != std::string::npos ||
                low.find("depth")  != std::string::npos) continue;
            sections++;
            if (s.state_key == 0) continue;
            keyed++;
            MaterialBinding mb = dep.textures_for(s.state_key, db);
            if (!mb.valid) continue;
            joined++;

            // THE SLOT CENSUS, over the depots a PLACED prop actually resolves
            // to. The standalone census walks every resource named
            // shaderblockdepot, which on this level turns out to be the shared
            // weapon and character bundles and none of the environment ones -
            // so it names the slots of things the map never draws and misses
            // every slot its own props use. The cable set is the proof: it
            // binds an asset "_cs" at 0xa17e658f and an "_nmt" at 0xd14b0408,
            // and neither appears in that census at all.
            for (const auto& kv : mb.textures)
            {
                auto ai = gi.find(kv.second);
                if (ai == gi.end()) continue;
                const std::string& asset = ai->second;
                if (asset.find("/textures/default/") != std::string::npos ||
                    asset.find("/textures/debug/") != std::string::npos)
                { cen_def[kv.first]++; continue; }
                std::string leaf = asset;
                size_t sl = leaf.find_last_of('/');
                if (sl != std::string::npos) leaf = leaf.substr(sl + 1);
                if (leaf.size() > 4 && leaf.compare(leaf.size() - 4, 4, ".ebx") == 0)
                    leaf.resize(leaf.size() - 4);
                size_t us = leaf.find_last_of('_');
                std::string sfx = us == std::string::npos ? "(none)" : leaf.substr(us + 1);
                cen[kv.first][sfx] += inst;
                cen_tot[kv.first] += inst;
                if (!cen_ex.count(kv.first)) cen_ex[kv.first] = asset;
            }

            // THE PICKER AS IT STANDS TODAY, and nothing more. The point is to
            // find what it misses, so it must not be quietly improved here.
            uint32_t got = 0;
            if (mb.textures.count(0x54BBCD30))      got = 0x54BBCD30;
            else if (mb.textures.count(0x54BBCD36)) got = 0x54BBCD36;

            // THE CHAIN AS SHIPPED, measured alongside the old picker so the
            // improvement is a number rather than a claim.
            {
                static const uint32_t chain[] = { 0x54BBCD30, 0x54BBCD36,
                                                  0x21F3F4E1, 0xEA026FC7, 0xA4415059,
                                                  0x691A5E17, 0x691BEAB4, 0x39DA140E,
                                                  0xA17E658F, 0x365B13EF, 0x1C5FA3EE };
                uint32_t ns = 0;
                for (int ci3 = 0; ci3 < 11 && !ns; ci3++)
                    if (mb.textures.count(chain[ci3])) ns = chain[ci3];
                if (!ns && wrap_ok(mb)) ns = 0x54BBCD22;
                if (ns) { chain_sections++; chain_inst += inst; }
                else if (mb.textures.count(0xA11011B8) && mb.constants.count(0xDD0512FA))
                { colour_sections++; colour_inst += inst; }
            }

            if (got) { with_albedo++; inst_albedo += inst; hit[got]++; continue; }

            // WHAT WOULD RESCUE THIS SECTION, if anything. Classified with the
            // same tests the core now applies, so the number here is the number
            // the renderer will get rather than an estimate of it.
            {
                const bool tp = mb.constants.count(0xF1CEE56D) != 0;
                const char* why = "nothing found";
                if (mb.textures.count(0xA11011B8) && !tp &&
                    mb.constants.count(0xDD0512FA))       why = "car paint body colour";
                else if (wrap_ok(mb))                     why = "impostor sheet at the wrap slot";
                else if (tp)                              why = "tile paint palette";
                else if (has_tint(mb))                    why = "an albedo tint constant";
                rescue[why]++;
                rescue_inst[why] += inst;
                // EVERY CARPAINT SECTION'S CANDIDATE BODY COLOUR. If one hash
                // holds a different, plausible paint colour per vehicle then it
                // IS the body colour; if it holds the same value everywhere it
                // is a shared shader constant that happens to look like one.
                if (mb.textures.count(0xA11011B8))
                {
                    static const uint32_t cand[] = { 0xDD0512FA, 0x84E531AF, 0x3C4777D3, 0x8D1160C8 };
                    for (int ci2 = 0; ci2 < 4; ci2++)
                    {
                        auto k = mb.constants.find(cand[ci2]);
                        if (k == mb.constants.end() || k->second.size() < 12) continue;
                        float f[3];
                        std::memcpy(f, k->second.data(), 12);
                        char buf[64];
                        std::snprintf(buf, sizeof(buf), "%.3f %.3f %.3f", f[0], f[1], f[2]);
                        paint[cand[ci2]][buf]++;
                    }
                }
                // ONE SECTION IN FULL, when asked for. An aggregate says a
                // constant is absent; only the whole record says what is there
                // instead, and that is the difference between "the rule does
                // not fire" and "the rule is wrong for this map".
                if (!detail.empty() && s.material.find(detail) != std::string::npos &&
                    detailed < 4)
                {
                    detailed++;
                    std::printf("\n--- %s  /  %s\n", s.material.c_str(), mname.c_str());
                    std::printf("    textures:\n");
                    for (const auto& kv : mb.textures)
                    {
                        auto ai = gi.find(kv.second);
                        const char* nm2 = Depot::slot_name(kv.first);
                        std::printf("      0x%08x %-16s %s\n", kv.first, nm2 ? nm2 : "",
                                    ai != gi.end() ? ai->second.c_str() : "(unresolved)");
                    }
                    std::printf("    constants (%zu):\n", mb.constants.size());
                    for (const auto& kv : mb.constants)
                    {
                        std::printf("      0x%08x %2zu bytes", kv.first, kv.second.size());
                        if (kv.second.size() >= 12 && kv.second.size() <= 16)
                        {
                            float f[3];
                            std::memcpy(f, kv.second.data(), 12);
                            std::printf("  = %.3f %.3f %.3f", f[0], f[1], f[2]);
                        }
                        else if (kv.second.size() == 4)
                        {
                            float f; std::memcpy(&f, kv.second.data(), 4);
                            std::printf("  = %.3f", f);
                        }
                        std::printf("\n");
                    }
                }
                for (std::map<uint32_t, std::vector<uint8_t> >::const_iterator
                         ci = mb.constants.begin(); ci != mb.constants.end(); ++ci)
                {
                    ocons[ci->first]++;
                    ocons_sz[ci->first] = (int)ci->second.size();
                }
            }
            no_albedo++;
            inst_no_albedo += inst;
            orphan_material[s.material]++;
            orphan_mesh[mname] += inst;
            for (const auto& kv : mb.textures)
            {
                orphan_slot[kv.first]++;
                orphan_inst[kv.first] += inst;
                if (!orphan_example.count(kv.first))
                {
                    auto it = gi.find(kv.second);
                    if (it != gi.end()) orphan_example[kv.first] = it->second;
                }
            }
        }
    }

    std::printf("\nplaced meshes %d readable, %d unreadable\n", meshes, unreadable);
    std::printf("sections %d, keyed %d, joined a depot record %d\n", sections, keyed, joined);
    std::printf("  WITH a base colour %d (%lld instances)\n", with_albedo, inst_albedo);
    std::printf("  WITHOUT one       %d (%lld instances)  <-- these draw untextured\n",
                no_albedo, inst_no_albedo);
    std::printf("  carried by:");
    for (const auto& kv : hit) std::printf(" 0x%08x=%d", kv.first, kv.second);

    std::printf("\n\nslots present on the sections that have NO base colour,\n");
    std::printf("ranked by how many placed instances they affect:\n");
    std::vector<std::pair<long long, uint32_t> > ord;
    for (const auto& kv : orphan_inst) ord.push_back(std::make_pair(kv.second, kv.first));
    std::sort(ord.rbegin(), ord.rend());
    for (size_t i = 0; i < ord.size() && i < 24; i++)
    {
        const uint32_t h = ord[i].second;
        const char* nm = Depot::slot_name(h);
        std::printf("  0x%08x %-16s sections %-6d instances %-8lld %s\n",
                    h, nm ? nm : "(unnamed)", orphan_slot[h], ord[i].first,
                    orphan_example.count(h) ? orphan_example[h].c_str() : "");
    }

    std::printf("\nthe materials most affected:\n");
    std::vector<std::pair<int, std::string> > mo;
    for (const auto& kv : orphan_material) mo.push_back(std::make_pair(kv.second, kv.first));
    std::sort(mo.rbegin(), mo.rend());
    for (size_t i = 0; i < mo.size() && i < 15; i++)
        std::printf("  %-6d %s\n", mo[i].first, mo[i].second.c_str());

    std::printf("\nthe meshes most affected, by placed instance count:\n");
    std::vector<std::pair<int, std::string> > me;
    for (const auto& kv : orphan_mesh) me.push_back(std::make_pair(kv.second, kv.first));
    std::sort(me.rbegin(), me.rend());
    for (size_t i = 0; i < me.size() && i < 20; i++)
        std::printf("  %-6d %s\n", me[i].first, me[i].second.c_str());
    // AND THE MESHES THAT NEVER GOT THIS FAR. A prop that cannot be read draws
    // nothing at all, which on a leaf card is indistinguishable from a prop
    // that draws untextured - so the two have to be counted separately or the
    // wrong one gets fixed.
    std::printf("\nunreadable placed meshes, by reason (instances):\n");
    for (const auto& kv : bad_why) std::printf("  %-8lld %s\n", kv.second, kv.first.c_str());
    std::printf("\nunreadable meshes, most placed first:\n");
    std::vector<std::pair<int, std::string> > bm;
    for (const auto& kv : bad_mesh) bm.push_back(std::make_pair(kv.second, kv.first));
    std::sort(bm.rbegin(), bm.rend());
    for (size_t i = 0; i < bm.size() && i < 25; i++)
        std::printf("  %-6d %s\n", bm[i].first, bm[i].second.c_str());
    std::printf("\nwhat would give the untextured sections a colour:\n");
    for (const auto& kv : rescue)
        std::printf("  %-6d sections %-8lld instances  %s\n",
                    kv.second, rescue_inst[kv.first], kv.first.c_str());
    std::printf("\nconstants carried by the untextured sections:\n");
    std::vector<std::pair<int, uint32_t> > co;
    for (std::map<uint32_t,int>::const_iterator it = ocons.begin(); it != ocons.end(); ++it)
        co.push_back(std::make_pair(it->second, it->first));
    std::sort(co.rbegin(), co.rend());
    for (size_t i = 0; i < co.size() && i < 20; i++)
        std::printf("  0x%08x  %-6d sections  %d bytes\n", co[i].second, co[i].first,
                    ocons_sz[co[i].second]);
    std::printf("\ncandidate car-paint body-colour constants, distinct values seen:\n");
    for (const auto& kv : paint)
    {
        std::printf("  0x%08x : %zu distinct value(s)\n", kv.first, kv.second.size());
        int shown = 0;
        for (const auto& v : kv.second)
        {
            if (shown++ >= 8) { std::printf("      ...\n"); break; }
            std::printf("      %-24s x%d\n", v.first.c_str(), v.second);
        }
    }
    // Ranked by placed instances, because a slot on one prop matters less than
    // the same slot on nine thousand.
    std::printf("\nSLOT CENSUS over the depots placed props resolve to\n");
    std::printf("%-11s %-9s %-7s %-18s %-9s %s\n",
                "slot", "instances", "share", "dominant suffix", "known", "example");
    std::vector<std::pair<long long, uint32_t> > cord;
    for (const auto& kv : cen_tot) cord.push_back(std::make_pair(kv.second, kv.first));
    std::sort(cord.rbegin(), cord.rend());
    for (size_t i = 0; i < cord.size(); i++)
    {
        const uint32_t h = cord[i].second;
        std::string best; long long bestn = 0;
        for (const auto& kv : cen[h]) if (kv.second > bestn) { bestn = kv.second; best = kv.first; }
        const char* known = Depot::slot_name(h);
        std::printf("0x%08x %-9lld %5.1f%%  %-18s %-9s %s\n",
                    h, cord[i].first, 100.0 * (double)bestn / (double)cord[i].first,
                    best.c_str(), known ? known : "-", cen_ex[h].c_str());
    }
    std::printf("\nBEFORE AND AFTER, over the same %d joined sections:\n", joined);
    std::printf("  old picker (two hashes)      : %d sections, %lld instances\n",
                with_albedo, inst_albedo);
    std::printf("  chain, a texture found       : %d sections, %lld instances\n",
                chain_sections, chain_inst);
    std::printf("  plus a colour from constants : %d sections, %lld instances\n",
                colour_sections, colour_inst);
    std::printf("  still nothing                : %d sections, %lld instances\n",
                joined - chain_sections - colour_sections,
                inst_albedo + inst_no_albedo - chain_inst - colour_inst);
    return 0;
}
