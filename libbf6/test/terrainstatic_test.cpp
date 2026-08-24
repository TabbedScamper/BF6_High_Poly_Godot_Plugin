/* terrainstatic_test - the missing half of the terrain compositor's textures.
 *
 * A layer's material reaches the evaluator two ways. One is a BINDLESS
 * descriptor index the layer-graph depot fills, which terrainlayers.h already
 * decodes. The other is STATIC binding out of the compute permutation's
 * COMMON BindingSet - 26 of 40 layer bodies on Aftermath, and on an urban map
 * it is the asphalt: the streets come out untextured without it.
 *
 * The chain this proves:
 *   compositor program -> permutation -> compute SharedData
 *     -> CommonBindingSet (+0x18) : descriptor index -> Name32
 *     -> the compositor's own ShaderBlockDepot : Name32 -> texture file guid
 *     -> partition index : guid -> asset name
 *
 *   terrainstatic_test <game_dir> <level> [ubershader]
 */
#include <algorithm>
#include <cstdio>
#include <cstring>
#include <map>
#include <set>
#include <string>
#include <vector>

#include "depot.h"
#include "source.h"

using namespace bf6;

static uint32_t rd32(const std::vector<uint8_t>& d, size_t o)
{ uint32_t v = 0; if (o + 4 <= d.size()) std::memcpy(&v, d.data() + o, 4); return v; }
static uint16_t rd16(const std::vector<uint8_t>& d, size_t o)
{ uint16_t v = 0; if (o + 2 <= d.size()) std::memcpy(&v, d.data() + o, 2); return v; }
static uint64_t rd64(const std::vector<uint8_t>& d, size_t o)
{ uint64_t v = 0; if (o + 8 <= d.size()) std::memcpy(&v, d.data() + o, 8); return v; }

static uint32_t name32_of(uint64_t param_hash, uint16_t name_hi)
{ return ((uint32_t)name_hi << 16) | (uint32_t)((param_hash >> 48) & 0xFFFF); }

int main(int argc, char** argv)
{
    if (argc < 3) { std::fprintf(stderr, "usage: terrainstatic_test <game_dir> <level> [ubershader]\n"); return 2; }
    const int want_idx = argc > 3 ? std::atoi(argv[3]) : 0;

    Source src;
    std::string err;
    if (!src.open(argv[1], err)) { std::fprintf(stderr, "open: %s\n", err.c_str()); return 1; }
    if (!src.mount_level(argv[2], false, err)) { std::fprintf(stderr, "mount: %s\n", err.c_str()); return 1; }
    const std::string level = argv[2];
    const auto& gi = src.partition_index();

    // ---- the compositor program's common BindingSet -----------------------
    std::string dbname;
    for (const auto& kv : src.res())
        if (kv.first.find("shaderstate_db") != std::string::npos &&
            kv.first.find(level) != std::string::npos) { dbname = kv.first; break; }
    std::vector<uint8_t> db = src.get_res(dbname, err);
    if (db.empty()) { std::printf("no shaderstate db\n"); return 1; }
    const uint32_t programCount = rd32(db, 0);
    uint64_t programPointer = 0;
    std::memcpy(&programPointer, db.data() + 4, 8);

    uint64_t perm_id = 0;
    for (uint32_t s = 0; s < programCount; s++) {
        const size_t rec = (size_t)programPointer + (size_t)s * 0xA8;
        if (rec + 0xA8 > db.size()) break;
        bool hit = false;
        for (size_t o = 0; o + 8 <= 0xA8; o += 4)
            if (rd64(db, rec + o) == 0x9F11D96B0FDF4773ull) { hit = true; break; }
        if (!hit) continue;
        const uint32_t pc = rd32(db, rec + 0x60), po = rd32(db, rec + 0x64);
        if ((uint32_t)want_idx < pc) perm_id = rd64(db, po + 8ull * want_idx);
        break;
    }
    if (!perm_id) { std::printf("no compositor permutation\n"); return 1; }

    char nm[160];
    std::snprintf(nm, sizeof(nm), "expressionshader/permutation%llu", (unsigned long long)perm_id);
    std::vector<uint8_t> pr = src.get_res(nm, err);
    if (pr.size() != 36) { std::printf("permutation is not the compute form\n"); return 1; }
    std::snprintf(nm, sizeof(nm), "expressionshader/permutationshareddata/%llu",
        (unsigned long long)rd64(pr, 0));
    std::vector<uint8_t> sd = src.get_res(nm, err);
    if (sd.size() < 0x60) { std::printf("no shared data\n"); return 1; }
    const uint64_t common_id = rd64(sd, 0x18);
    std::snprintf(nm, sizeof(nm), "expressionshader/bindingset/%llu", (unsigned long long)common_id);
    std::vector<uint8_t> bs = src.get_res(nm, err);
    if (bs.empty()) { std::printf("no common bindingset\n"); return 1; }
    std::printf("%s ubershader %d: common BindingSet %llu\n",
        level.c_str(), want_idx, (unsigned long long)common_id);

    // descriptor index -> Name32
    std::map<uint32_t, uint32_t> desc_to_name;
    {
        const uint32_t nrec = rd32(bs, 0);
        const uint64_t rp = rd64(bs, 4);
        for (uint32_t r = 0; r < nrec; r++) {
            const size_t rec = (size_t)rp + (size_t)r * 0x38;
            if (rec + 0x38 > bs.size()) break;
            const uint16_t nd = rd16(bs, rec + 0x10);
            const uint64_t dp = rd64(bs, rec + 0x20), sp = rd64(bs, rec + 0x28);
            for (uint16_t i = 0; i < nd; i++) {
                const size_t d0 = (size_t)dp + i * 16, s0 = (size_t)sp + i * 8;
                if (d0 + 16 > bs.size() || s0 + 8 > bs.size()) break;
                desc_to_name[rd32(bs, s0)] = name32_of(rd64(bs, d0), rd16(bs, d0 + 14));
            }
        }
    }
    std::printf("%zu descriptor(s) declared\n", desc_to_name.size());

    // ---- the compositor's own depot: Name32 -> texture ---------------------
    // Search the level's depots for the record that carries these names. The
    // compositor binds its OWN sheets, so the record holding the most of them
    // is the one.
    std::set<uint32_t> want;
    for (const auto& kv : desc_to_name) want.insert(kv.second);

    std::string best_res;
    size_t best_rec = 0;
    size_t best_hits = 0;
    for (const auto& kv : src.res()) {
        if (kv.first.find("shaderblockdepot") == std::string::npos) continue;
        if (kv.first.find(level) == std::string::npos) continue;
        std::vector<uint8_t> d = src.get_res(kv.first, err);
        if (d.empty()) continue;
        Depot dep;
        std::string e;
        if (!dep.parse(d, e)) continue;
        // Walk the RECORDS rather than the keys: the depot exposes no key
        // list, and the compositor's own bindings are a record like any
        // other. Keep whichever record names the most of our slots.
        for (size_t r = 0; r < dep.record_count(); r++) {
            std::vector<DepotParam> ps;
            std::string pe;
            if (!dep.params(r, d, ps, pe)) continue;
            size_t hits = 0;
            for (const DepotParam& q : ps)
                if (want.count(q.name32)) hits++;
            if (hits > best_hits) { best_hits = hits; best_res = kv.first; best_rec = r; }
        }
    }
    if (best_hits == 0) { std::printf("no depot record carries these names\n"); return 1; }
    std::printf("best depot %s record %zu: %zu of %zu names\n",
        best_res.c_str(), best_rec, best_hits, want.size());

    std::vector<uint8_t> dd = src.get_res(best_res, err);
    Depot dep;
    std::string e2;
    dep.parse(dd, e2);
    std::vector<DepotParam> ps;
    std::string pe;
    dep.params(best_rec, dd, ps, pe);
    // name32 -> file guid, straight off the record's texture entries
    std::map<uint32_t, std::string> tex;
    for (const DepotParam& q : ps)
        if (!q.refs.empty()) tex[q.name32] = q.refs[0].second;

    // ---- descriptor -> texture asset --------------------------------------
    std::printf("\n%-6s %-10s %s\n", "desc", "name32", "texture");
    int named = 0;
    for (const auto& kv : desc_to_name) {
        auto tit = tex.find(kv.second);
        if (tit == tex.end()) continue;
        auto ait = gi.find(tit->second);
        std::string asset = ait == gi.end() ? std::string("?") : ait->second;
        if (asset.size() > 4 && asset.compare(asset.size() - 4, 4, ".ebx") == 0)
            asset.resize(asset.size() - 4);
        const size_t sl = asset.find_last_of('/');
        std::printf("%-6u %08x   %s\n", kv.first, kv.second,
            sl == std::string::npos ? asset.c_str() : asset.c_str() + sl + 1);
        named++;
    }
    std::printf("\n%d of %zu descriptors resolve to a texture\n", named, desc_to_name.size());
    return 0;
}
