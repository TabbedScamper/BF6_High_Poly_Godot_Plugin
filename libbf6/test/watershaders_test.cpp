/* watershaders_test - rung two, the deep half:
 *   1. decode the VE ocean component's override array in full
 *   2. walk each water program slot's permutation to its CompiledBytecode,
 *      extract the DXBC/DXIL payloads, and identify each stage
 *
 *   watershaders_test <game_dir> <level> <exe> [out_dir]
 */
#include <algorithm>
#include <cstdio>
#include <cstring>
#include <map>
#include <string>
#include <vector>

#include "ebx.h"
#include "source.h"
#include "types.h"

using namespace bf6;

static uint32_t rd32(const std::vector<uint8_t>& d, size_t o)
{ uint32_t v = 0; if (o + 4 <= d.size()) std::memcpy(&v, d.data() + o, 4); return v; }
static uint64_t rd64(const std::vector<uint8_t>& d, size_t o)
{ uint64_t v = 0; if (o + 8 <= d.size()) std::memcpy(&v, d.data() + o, 8); return v; }

// .NET little-endian GUID at offset o -> canonical string.
static std::string guid_net(const std::vector<uint8_t>& d, size_t o)
{
    if (o + 16 > d.size()) return "";
    char b[64];
    std::snprintf(b, sizeof(b),
        "%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x",
        d[o+3], d[o+2], d[o+1], d[o+0], d[o+5], d[o+4], d[o+7], d[o+6],
        d[o+8], d[o+9], d[o+10], d[o+11], d[o+12], d[o+13], d[o+14], d[o+15]);
    return b;
}

static void dump_value(const EbxValue& v, int indent)
{
    char pad[32];
    std::snprintf(pad, sizeof(pad), "%*s", indent * 2, "");
    switch (v.kind) {
    case EbxValue::Kind::Bool: std::printf("bool %d\n", v.b ? 1 : 0); break;
    case EbxValue::Kind::Real: std::printf("real %.6f\n", v.f); break;
    case EbxValue::Kind::Int:  std::printf("int  %lld\n", (long long)v.i); break;
    case EbxValue::Kind::Uint: std::printf("uint %llu (0x%llx)\n",
        (unsigned long long)v.u, (unsigned long long)v.u); break;
    case EbxValue::Kind::Str:  std::printf("str  %s\n", v.s.c_str()); break;
    case EbxValue::Kind::Guid: std::printf("guid %s\n", TypeDb::guid_str(v.guid).c_str()); break;
    case EbxValue::Kind::ResRef: std::printf("resref %llu\n", (unsigned long long)v.u); break;
    case EbxValue::Kind::InstanceRef: std::printf("instref #%d\n", v.instance); break;
    case EbxValue::Kind::ImportRef: std::printf("import %s (%s)\n",
        v.import_path.c_str(), v.s.c_str()); break;
    case EbxValue::Kind::Unknown: std::printf("unknown te=%u raw=0x%llx\n",
        v.te, (unsigned long long)v.u); break;
    case EbxValue::Kind::Struct:
        std::printf("struct %s, %zu field(s)\n",
            TypeDb::guid_str(v.guid).c_str(), v.fields.size());
        for (const auto& f : v.fields) {
            std::printf("%s  %08x ", pad, f.first);
            dump_value(f.second, indent + 1);
        }
        break;
    case EbxValue::Kind::Array:
        std::printf("array[%zu]\n", v.items.size());
        for (size_t i = 0; i < v.items.size(); i++) {
            std::printf("%s  [%zu] ", pad, i);
            dump_value(v.items[i], indent + 1);
        }
        break;
    default: std::printf("null\n"); break;
    }
}

int main(int argc, char** argv)
{
    if (argc < 4) { std::fprintf(stderr, "usage: watershaders_test <game_dir> <level> <exe> [out_dir]\n"); return 2; }
    const std::string outdir = argc > 4 ? argv[4] : std::string();

    Source src;
    std::string err;
    if (!src.open(argv[1], err)) { std::fprintf(stderr, "open: %s\n", err.c_str()); return 1; }
    if (!src.mount_level(argv[2], false, err)) { std::fprintf(stderr, "mount: %s\n", err.c_str()); return 1; }
    TypeDb types;
    if (!types.open(argv[3], err)) { std::fprintf(stderr, "types: %s\n", err.c_str()); return 1; }
    const std::string level = argv[2];

    std::string lvl_dir;
    for (const auto& kv : src.ebx()) {
        const size_t p = kv.first.find("/levels/" + level + "/");
        if (p == std::string::npos) continue;
        lvl_dir = kv.first.substr(0, p + 8 + level.size());
        break;
    }

    // ---- PART A: the VE ocean component, in FULL ---------------------------
    const char* kOceanComp = "f7f42a90-6547-0ee2-cb65-9252e610e782";
    for (const auto& kv : src.ebx()) {
        const std::string& n = kv.first;
        if (lvl_dir.empty() || n.compare(0, lvl_dir.size(), lvl_dir) != 0) continue;
        if (n.find("/lighting/") == std::string::npos &&
            n.find("schematic") == std::string::npos) continue;
        std::vector<uint8_t> raw = src.get_ebx(n, err);
        if (raw.empty()) continue;
        Ebx e(types);
        e.set_guid_index(&src.partition_index());
        if (!e.parse(std::move(raw), err)) continue;
        for (size_t i = 0; i < e.instance_count(); i++) {
            if (TypeDb::guid_str(e.instance_type(i)) != kOceanComp) continue;
            std::printf("==== OceanComponentData in %s ====\n", n.c_str());
            EbxValue d = e.read_instance(i);
            dump_value(d, 0);
        }
    }

    // ---- the water key and its slots (as in oceanshader_test) --------------
    const char* kWaterType = "ae0b69fc-2207-d874-8230-fcd467a592cf";
    const uint32_t kStateKeyField = 0x2E15621F;
    uint64_t water_key = 0;
    {
        std::vector<std::string> cands = { lvl_dir + "/default",
                                           lvl_dir + "/_layers_content/water" };
        for (const auto& kv : src.ebx())
            if (kv.first.compare(0, lvl_dir.size(), lvl_dir) == 0 &&
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
                if (const EbxValue* f = d.field(kStateKeyField))
                    water_key = f->kind == EbxValue::Kind::Uint ? f->u : (uint64_t)f->i;
            }
            if (water_key) break;
        }
    }
    if (!water_key) { std::printf("no water key\n"); return 0; }

    std::string dbname;
    for (const auto& kv : src.res())
        if (kv.first.find("shaderstate_db") != std::string::npos &&
            kv.first.find(lvl_dir) != std::string::npos) { dbname = kv.first; break; }
    std::vector<uint8_t> db = src.get_res(dbname, err);
    if (db.empty()) { std::printf("no db\n"); return 1; }
    const uint32_t programCount = rd32(db, 0);
    uint64_t programPointer = 0;
    std::memcpy(&programPointer, db.data() + 4, 8);

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
    if (!key_at) { std::printf("key not found in db\n"); return 1; }
    const uint32_t nslots = rd32(db, key_at + 8);

    // ---- PART B: down to the bytecode --------------------------------------
    std::printf("\n==== water StateKey %016llx: %u pass slot(s) ====\n",
        (unsigned long long)water_key, nslots);

    // permutation resource names, once
    std::map<uint64_t, std::string> perm_res;
    for (const auto& kv : src.res()) {
        const std::string& n = kv.first;
        const size_t p = n.find("expressionshader/permutation");
        if (p == std::string::npos) continue;
        const uint64_t id = std::strtoull(n.c_str() + p + 28, nullptr, 10);
        if (id) perm_res.emplace(id, n);
    }
    std::printf("%zu raster permutation resources in the mount\n", perm_res.size());

    for (uint32_t s = 0; s < nslots; s++) {
        const uint32_t slot = rd32(db, key_at + 12 + 4 * s);
        const size_t rec = (size_t)programPointer + (size_t)slot * 0xA8;
        const uint32_t pcount = rd32(db, rec + 0x60);
        const uint32_t poff   = rd32(db, rec + 0x64);
        std::printf("\npass %u (slot %u):\n", s, slot);
        for (uint32_t pi = 0; pi < pcount && pi < 64; pi++) {
            const uint64_t pid = rd64(db, poff + 8ull * pi);
            auto it = perm_res.find(pid);
            std::printf("  permutation %llu (0x%016llx): %s\n",
                (unsigned long long)pid, (unsigned long long)pid,
                it == perm_res.end() ? "NO RESOURCE" : it->second.c_str());
            if (it == perm_res.end()) continue;
            std::vector<uint8_t> pr = src.get_res(it->second, err);
            if (pr.size() < 52) { std::printf("    short record (%zu)\n", pr.size()); continue; }
            std::printf("    sharedData %llu  inputLayout %llu  form %zu bytes\n",
                (unsigned long long)rd64(pr, 0), (unsigned long long)rd64(pr, 0x10), pr.size());
            const int stages = pr.size() >= 68 ? 2 : 1;
            for (int st = 0; st < stages; st++) {
                const std::string g = guid_net(pr, 0x20 + 0x10 * st);
                std::string bres;
                for (const auto& kv : src.res())
                    if (kv.first.find("bytecode") != std::string::npos &&
                        kv.first.find(g) != std::string::npos) { bres = kv.first; break; }
                if (bres.empty()) { std::printf("    stage %d guid %s: no bytecode res\n", st, g.c_str()); continue; }
                std::vector<uint8_t> bc = src.get_res(bres, err);
                // DXBC container: magic + program type from the SHEX/DXIL part.
                const char* kind = "UNK";
                // The payload may carry a wrapper before the container: scan
                // for the DXBC magic rather than assuming offset 0, and say
                // what the first bytes ARE when it is absent.
                size_t dxbc_at = std::string::npos;
                for (size_t o = 0; o + 4 <= bc.size() && o < 8192; o += 1)
                    if (!std::memcmp(bc.data() + o, "DXBC", 4)) { dxbc_at = o; break; }
                if (dxbc_at != std::string::npos) {
                    const uint32_t nch = rd32(bc, dxbc_at + 0x1C);
                    for (uint32_t c = 0; c < nch && c < 32; c++) {
                        const uint32_t co = rd32(bc, dxbc_at + 0x20 + 4 * c);
                        if (dxbc_at + co + 12 > bc.size()) break;
                        const uint8_t* ch = bc.data() + dxbc_at + co;
                        if (!std::memcmp(ch, "SHEX", 4) || !std::memcmp(ch, "SHDR", 4)) {
                            const uint32_t pv = rd32(bc, dxbc_at + co + 8);
                            const uint32_t ptype = pv >> 16;
                            static const char* names[] = { "PIXEL", "VERTEX", "GEOMETRY",
                                "HULL", "DOMAIN", "COMPUTE" };
                            if (ptype < 6) kind = names[ptype];
                        } else if (!std::memcmp(ch, "DXIL", 4)) {
                            // DXIL part: program header at +8: u32 pv where
                            // type is the HIGH 16 of the first dword
                            const uint32_t pv = rd32(bc, dxbc_at + co + 8);
                            const uint32_t ptype = pv >> 16;
                            static const char* names[] = { "PIXEL", "VERTEX", "GEOMETRY",
                                "HULL", "DOMAIN", "COMPUTE" };
                            if (ptype < 6 && kind[0] == 'U') kind = names[ptype];
                        }
                    }
                    if (kind[0] == 'U') kind = "DXBC";
                } else {
                    static char magicbuf[48];
                    std::snprintf(magicbuf, sizeof(magicbuf),
                        "magic %02x%02x%02x%02x %02x%02x%02x%02x",
                        bc[0], bc[1], bc[2], bc[3], bc[4], bc[5], bc[6], bc[7]);
                    kind = magicbuf;
                }
                std::printf("    stage %d %s  %zu bytes  %s\n", st, kind, bc.size(), bres.c_str());
                if (!outdir.empty()) {
                    // The CONTAINER, stripped of the Frostbite wrapper, so a
                    // stock dxc -dumpbin opens it. Total size is the DXBC
                    // header's own u32 at +0x18.
                    size_t at = dxbc_at == std::string::npos ? 0 : dxbc_at;
                    size_t len = bc.size() - at;
                    if (dxbc_at != std::string::npos) {
                        const uint32_t total = rd32(bc, dxbc_at + 0x18);
                        if (total > 0 && dxbc_at + total <= bc.size()) len = total;
                    }
                    char fn[512];
                    std::snprintf(fn, sizeof(fn), "%s/water_%s_pass%u_stage%d_%s.dxbc",
                        outdir.c_str(), level.c_str(), s, st,
                        kind[0] == 'm' ? "raw" : kind);
                    FILE* f = std::fopen(fn, "wb");
                    if (f) { std::fwrite(bc.data() + at, 1, len, f); std::fclose(f); }
                }
            }
        }
    }
    return 0;
}
