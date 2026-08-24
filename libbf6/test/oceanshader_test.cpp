/* oceanshader_test - rung one of recovering the game's own ocean rendering:
 * walk the on-disk join from the water surface's StateKey to its shader
 * programs and their permutation ids, per SHADERS.md 6.3/6.3.1, and audit the
 * dependency the sim answer stands on (OceanComponentData overrides).
 *
 *   oceanshader_test <game_dir> <level> <exe>
 */
#include <algorithm>
#include <cstdio>
#include <cstring>
#include <map>
#include <string>
#include <vector>

#include "depot.h"
#include "ebx.h"
#include "source.h"
#include "types.h"

using namespace bf6;

static uint32_t rd32(const std::vector<uint8_t>& d, size_t o)
{ uint32_t v = 0; if (o + 4 <= d.size()) std::memcpy(&v, d.data() + o, 4); return v; }
static uint64_t rd64(const std::vector<uint8_t>& d, size_t o)
{ uint64_t v = 0; if (o + 8 <= d.size()) std::memcpy(&v, d.data() + o, 8); return v; }

int main(int argc, char** argv)
{
    if (argc < 4) { std::fprintf(stderr, "usage: oceanshader_test <game_dir> <level> <exe>\n"); return 2; }

    Source src;
    std::string err;
    if (!src.open(argv[1], err)) { std::fprintf(stderr, "open: %s\n", err.c_str()); return 1; }
    if (!src.mount_level(argv[2], false, err)) { std::fprintf(stderr, "mount: %s\n", err.c_str()); return 1; }
    TypeDb types;
    if (!types.open(argv[3], err)) { std::fprintf(stderr, "types: %s\n", err.c_str()); return 1; }

    const std::string level = argv[2];

    // ---- 1. the water surface's StateKey -----------------------------------
    // Same scan as bf6_level_water: candidates, then names saying water.
    const char* kWaterType = "ae0b69fc-2207-d874-8230-fcd467a592cf";
    const uint32_t kStateKeyField = 0x2E15621F;
    uint64_t water_key = 0;
    std::string lvl_dir;
    {
        // level dir from any level-owned ebx
        for (const auto& kv : src.ebx()) {
            const std::string& n = kv.first;
            const size_t p = n.find("/levels/" + level + "/");
            if (p == std::string::npos) continue;
            lvl_dir = n.substr(0, p + 8 + level.size());
            break;
        }
        std::vector<std::string> cands = { lvl_dir + "/default",
                                           lvl_dir + "/_layers_content/water" };
        for (const auto& kv : src.ebx())
            if (!lvl_dir.empty() && kv.first.compare(0, lvl_dir.size(), lvl_dir) == 0 &&
                kv.first.find("water") != std::string::npos)
                cands.push_back(kv.first);
        for (const std::string& cand : cands) {
            if (!src.ebx().count(cand)) continue;
            std::vector<uint8_t> raw = src.get_ebx(cand, err);
            if (raw.empty()) continue;
            Ebx e(types);
            if (!e.parse(std::move(raw), err)) continue;
            for (size_t i = 0; i < e.instance_count() && !water_key; i++) {
                if (TypeDb::guid_str(e.instance_type(i)) != kWaterType) continue;
                EbxValue d = e.read_instance(i);
                if (const EbxValue* f = d.field(kStateKeyField)) {
                    if (f->kind == EbxValue::Kind::Uint) water_key = f->u;
                    else if (f->kind == EbxValue::Kind::Int) water_key = (uint64_t)f->i;
                }
                if (water_key) std::printf("water StateKey %016llx  (in %s)\n",
                    (unsigned long long)water_key, cand.c_str());
            }
            if (water_key) break;
        }
    }
    if (!water_key) { std::printf("no water StateKey on this level\n"); return 0; }

    // ---- 2. the level's shaderstate db -------------------------------------
    std::string dbname;
    for (const auto& kv : src.res())
        if (kv.first.find("shaderstate_db") != std::string::npos &&
            (lvl_dir.empty() || kv.first.find(lvl_dir) != std::string::npos))
            { dbname = kv.first; break; }
    if (dbname.empty())
        for (const auto& kv : src.res())
            if (kv.first.find("shaderstate_db") != std::string::npos &&
                kv.first.find(level) != std::string::npos)
                { dbname = kv.first; break; }
    if (dbname.empty()) { std::printf("no shaderstate_db found\n"); return 1; }
    std::vector<uint8_t> db = src.get_res(dbname, err);
    std::printf("db %s  (%zu bytes)\n", dbname.c_str(), db.size());
    if (db.empty()) return 1;

    const uint32_t programCount = rd32(db, 0);
    uint64_t programPointer = 0;
    std::memcpy(&programPointer, db.data() + 4, 8);   // unaligned, relocated (= file offset)
    std::printf("programs %u  table at 0x%llx\n", programCount, (unsigned long long)programPointer);

    // ---- 3. find the water key in the selection stream ---------------------
    // Groundwork scan: the stream's exact start needs the resMeta walk, so the
    // key is located by value (aligned u64 sweep) and validated by its record
    // shape - count small, every slot below programCount.
    size_t key_at = 0;
    for (size_t o = 0; o + 12 <= db.size(); o += 4) {
        if (rd64(db, o) != water_key) continue;
        const uint32_t cnt = rd32(db, o + 8);
        if (cnt == 0 || cnt > 8) continue;
        bool ok = true;
        for (uint32_t s = 0; s < cnt && ok; s++)
            if (rd32(db, o + 12 + 4 * s) >= programCount) ok = false;
        if (ok) { key_at = o; break; }
    }
    if (!key_at) { std::printf("water key not in the selection stream (record shape mismatch)\n"); return 1; }

    const uint32_t nslots = rd32(db, key_at + 8);
    std::printf("selection record at 0x%zx: %u program slot(s):", key_at, nslots);
    std::vector<uint32_t> slots;
    for (uint32_t s = 0; s < nslots; s++) {
        slots.push_back(rd32(db, key_at + 12 + 4 * s));
        std::printf(" %u", slots.back());
    }
    std::printf("\n");

    // ---- 4. each program's permutation ids ---------------------------------
    for (uint32_t slot : slots) {
        const size_t rec = (size_t)programPointer + (size_t)slot * 0xA8;
        if (rec + 0xA8 > db.size()) { std::printf("  slot %u out of file\n", slot); continue; }
        const uint32_t pcount = rd32(db, rec + 0x60);
        const uint32_t poff   = rd32(db, rec + 0x64);
        std::printf("  slot %4u  record 0x%zx  permutations %u at 0x%x:", slot, rec, pcount, poff);
        if (pcount > 0 && pcount <= 64 && (size_t)poff + 8ull * pcount <= db.size())
            for (uint32_t i = 0; i < pcount; i++)
                std::printf(" %016llx", (unsigned long long)rd64(db, poff + 8ull * i));
        else
            std::printf(" (shape unexpected - needs the resMeta relocation walk)");
        std::printf("\n");
    }

    // ---- 5. the dependency audit: OceanComponentData -----------------------
    // A component can OVERRIDE the entity values a consumer mines. Enumerate
    // every OceanComponentData in the level's schematics and print its fields,
    // so "the sim says X" is checked against what actually reaches the sim.
    const char* kOceanComp = "f7f42a90-6547-0ee2-cb65-9252e610e782";
    int comp_found = 0;
    for (const auto& kv : src.ebx()) {
        const std::string& n = kv.first;
        if (lvl_dir.empty() || n.compare(0, lvl_dir.size(), lvl_dir) != 0) continue;
        // argv[4] = wide: sweep EVERY level partition, not just schematics -
        // "not in the schematics" is not "not in the level".
        if (argc < 5 && n.find("schematic") == std::string::npos) continue;
        std::vector<uint8_t> raw = src.get_ebx(n, err);
        if (raw.empty()) continue;
        Ebx e(types);
        if (!e.parse(std::move(raw), err)) continue;
        for (size_t i = 0; i < e.instance_count(); i++) {
            if (TypeDb::guid_str(e.instance_type(i)) != kOceanComp) continue;
            comp_found++;
            EbxValue d = e.read_instance(i);
            std::printf("OceanComponentData #%d in %s: %zu field(s)\n",
                comp_found, n.c_str(), d.fields.size());
            for (const auto& f : d.fields) {
                const EbxValue& v = f.second;
                switch (v.kind) {
                case EbxValue::Kind::Bool: std::printf("    %08x bool %d\n", f.first, v.b ? 1 : 0); break;
                case EbxValue::Kind::Real: std::printf("    %08x real %.4f\n", f.first, v.f); break;
                case EbxValue::Kind::Int:  std::printf("    %08x int  %lld\n", f.first, (long long)v.i); break;
                case EbxValue::Kind::Uint: std::printf("    %08x uint %llu\n", f.first, (unsigned long long)v.u); break;
                case EbxValue::Kind::Str:  std::printf("    %08x str  %s\n", f.first, v.s.c_str()); break;
                case EbxValue::Kind::Array: std::printf("    %08x array[%zu]\n", f.first, v.items.size());
                    // one level of detail, for PropertyOverrides-shaped arrays
                    for (size_t ai = 0; ai < v.items.size() && ai < 8; ai++)
                        if (v.items[ai].kind == EbxValue::Kind::Struct)
                            for (const auto& sf : v.items[ai].fields)
                                if (sf.second.kind == EbxValue::Kind::Str)
                                    std::printf("        [%zu] %08x str %s\n", ai, sf.first, sf.second.s.c_str());
                                else if (sf.second.kind == EbxValue::Kind::Real)
                                    std::printf("        [%zu] %08x real %.4f\n", ai, sf.first, sf.second.f);
                    break;
                default: break;
                }
            }
        }
    }
    if (!comp_found) std::printf("no OceanComponentData in this level's schematics\n");
    return 0;
}
