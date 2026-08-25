/* waterbind_test - closes the water material's slot -> cbuffer-offset question.
 *
 * The chain, entirely on disk:
 *
 *   WaterSurfaceEntityData.StateKey (0x2E15621F)
 *     -> <level>_win32_shaderstate_db  (ExpressionShaderDatabase)
 *        key record -> N program slot indices
 *     -> program record (0xA8 stride) -> permutation id array (+0x60 count, +0x64 ptr)
 *     -> expressionshader/permutation<id>   (RasterPermutation, 52 or 68 bytes)
 *        +0x00 -> RasterPermutationSharedData id
 *     -> expressionshader/permutationshareddata/<id>
 *        +0x18 common BindingSet id, +0x20 variant BindingSet id
 *     -> expressionshader/bindingset/<id>
 *        record[] (0x38 stride): span, nDecl, nFixup, declPtr, destPtr
 *        decl[i] = {u64 paramHash, u32 typeHash, u16 flags, u16 nameHi}
 *        dest[i] = {u32 destination, ..., u16 meta}
 *
 * The BindingSet is the table SHADERS.md 8.1.0.1 found for terrain: it pairs a
 * depot parameter's Name32 with the BYTE OFFSET that parameter is written to in
 * the material constant buffer. Running it on water names every cb1 slot.
 *
 * Also joins the level's ShaderBlockDepot record for the same StateKey, so each
 * binding prints with the VALUE the level actually ships at that offset.
 *
 *   waterbind_test <game_dir> <exe> <level> [level...]
 */
#include <algorithm>
#include <cstdio>
#include <cstring>
#include <cstdlib>
#include <map>
#include <set>
#include <string>
#include <vector>

#include "depot.h"
#include "ebx.h"
#include "source.h"
#include "types.h"

using namespace bf6;

static uint32_t rd32(const std::vector<uint8_t>& d, size_t o)
{ uint32_t v = 0; if (o + 4 <= d.size()) std::memcpy(&v, d.data() + o, 4); return v; }
static uint16_t rd16(const std::vector<uint8_t>& d, size_t o)
{ uint16_t v = 0; if (o + 2 <= d.size()) std::memcpy(&v, d.data() + o, 2); return v; }
static uint64_t rd64(const std::vector<uint8_t>& d, size_t o)
{ uint64_t v = 0; if (o + 8 <= d.size()) std::memcpy(&v, d.data() + o, 8); return v; }
static float rdf(const std::vector<uint8_t>& d, size_t o)
{ float v = 0; if (o + 4 <= d.size()) std::memcpy(&v, d.data() + o, 4); return v; }

static uint32_t name32_of(uint64_t ph, uint16_t nh)
{ return ((uint32_t)nh << 16) | (uint32_t)((ph >> 48) & 0xFFFF); }

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

struct Decl {
    uint64_t param = 0;
    uint32_t type = 0;
    uint16_t flags = 0, name_hi = 0;
    uint32_t dest = 0;
    uint16_t meta = 0;
    uint32_t name32 = 0;
};
struct BsRec {
    uint32_t span = 0;
    uint16_t n_decl = 0, n_fixup = 0;
    std::vector<Decl> decls;
};

static bool read_bindingset(Source& src, uint64_t id, std::vector<BsRec>& out, std::string& err)
{
    char nm[128];
    std::snprintf(nm, sizeof(nm), "expressionshader/bindingset/%llu", (unsigned long long)id);
    std::vector<uint8_t> d = src.get_res(nm, err);
    if (d.empty()) { err = "no bindingset " + std::string(nm); return false; }
    const uint32_t n = rd32(d, 0);
    const uint64_t p = rd64(d, 4);
    if (n == 0 || n > 4096) { err = "bad record count"; return false; }
    for (uint32_t r = 0; r < n; r++) {
        const size_t rec = (size_t)p + (size_t)r * 0x38;
        if (rec + 0x38 > d.size()) break;
        BsRec b;
        b.span    = rd32(d, rec + 0x08);
        b.n_decl  = rd16(d, rec + 0x10);
        b.n_fixup = rd16(d, rec + 0x12);
        const uint64_t dp = rd64(d, rec + 0x20);
        const uint64_t sp = rd64(d, rec + 0x28);
        for (uint16_t i = 0; i < b.n_decl; i++) {
            const size_t a = (size_t)dp + (size_t)i * 16;
            const size_t s = (size_t)sp + (size_t)i * 8;
            if (a + 16 > d.size() || s + 8 > d.size()) break;
            Decl e;
            e.param   = rd64(d, a + 0);
            e.type    = rd32(d, a + 8);
            e.flags   = rd16(d, a + 12);
            e.name_hi = rd16(d, a + 14);
            e.dest    = rd32(d, s + 0);
            e.meta    = rd16(d, s + 6);
            e.name32  = name32_of(e.param, e.name_hi);
            b.decls.push_back(e);
        }
        out.push_back(std::move(b));
    }
    return true;
}

static const char* type_name(uint32_t t)
{
    switch (t) {
    case 0xCC84D53Du: return "Resource";
    case 0x14A0B1C1u: return "Float32";
    case 0x34791132u: return "Int32";
    case 0xA1C34F4Au: return "UInt32";
    case 0x80F40524u: return "Scalar";
    case 0x39AB6941u: return "Vec2";
    case 0x25F81AF1u: return "Float3";
    case 0xDEF2E1A5u: return "Float4";
    case 0x26B52646u: return "Bool8";
    default: return "?";
    }
}
static int type_size(uint32_t t)
{
    switch (t) {
    case 0x14A0B1C1u: case 0x34791132u: case 0xA1C34F4Au: case 0x80F40524u: return 4;
    case 0x39AB6941u: return 8;
    case 0x25F81AF1u: return 12;
    case 0xDEF2E1A5u: return 16;
    case 0x26B52646u: return 1;
    default: return 0;
    }
}

int main(int argc, char** argv)
{
    if (argc < 4) {
        std::fprintf(stderr, "usage: waterbind_test <game_dir> <exe> <level> [level...]\n");
        return 2;
    }
    std::string err;
    TypeDb types;
    if (!types.open(argv[2], err)) { std::fprintf(stderr, "types: %s\n", err.c_str()); return 1; }

    for (int li = 3; li < argc; li++) {
        const std::string level = argv[li];
        std::printf("\n################ %s ################\n", level.c_str());
        Source src;
        if (!src.open(argv[1], err)) { std::fprintf(stderr, "open: %s\n", err.c_str()); return 1; }
        if (!src.mount_level(level, false, err)) { std::printf("mount failed: %s\n", err.c_str()); continue; }

        std::string lvl_dir;
        for (const auto& kv : src.ebx()) {
            const size_t p = kv.first.find("/levels/" + level + "/");
            if (p == std::string::npos) continue;
            lvl_dir = kv.first.substr(0, p + 8 + level.size());
            break;
        }
        if (lvl_dir.empty()) { std::printf("no level dir\n"); continue; }

        // --- water StateKey -------------------------------------------------
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
            for (const std::string& c : cands) {
                if (!src.ebx().count(c)) continue;
                std::vector<uint8_t> raw = src.get_ebx(c, err);
                if (raw.empty()) continue;
                Ebx e(types);
                if (!e.parse(std::move(raw), err)) continue;
                for (size_t i = 0; i < e.instance_count() && !water_key; i++) {
                    if (TypeDb::guid_str(e.instance_type(i)) != kWaterType) continue;
                    EbxValue d = e.read_instance(i);
                    if (const EbxValue* f = d.field(kStateKeyField))
                        water_key = f->kind == EbxValue::Kind::Uint ? f->u : (uint64_t)f->i;
                }
                if (water_key) { std::printf("water entity in %s\n", c.c_str()); break; }
            }
        }
        if (!water_key) { std::printf("no water StateKey on this level\n"); continue; }
        std::printf("StateKey %016llx\n", (unsigned long long)water_key);

        // --- the depot record for that key (values) --------------------------
        std::map<uint32_t, std::vector<uint8_t>> vals;   // name32 -> raw bytes
        std::map<uint32_t, std::string>          texs;   // name32 -> file guid
        for (const auto& kv : src.res()) {
            if (kv.first.find("shaderblockdepot") == std::string::npos) continue;
            if (kv.first.compare(0, lvl_dir.size(), lvl_dir) != 0) continue;
            std::vector<uint8_t> d = src.get_res(kv.first, err);
            if (d.empty()) continue;
            Depot dep;
            if (!dep.parse(d, err)) continue;
            if (!dep.has_key(water_key)) continue;
            MaterialBinding mb = dep.textures_for(water_key, d);
            std::printf("depot: %s  (%zu keys)\n", kv.first.c_str(), dep.key_count());
            vals = mb.constants;
            texs = mb.textures;
            break;
        }
        std::printf("depot params for this key: %zu const + %zu tex\n", vals.size(), texs.size());

        // --- ESDB slots ------------------------------------------------------
        std::string dbname;
        for (const auto& kv : src.res())
            if (kv.first.find("shaderstate_db") != std::string::npos &&
                kv.first.find(lvl_dir) != std::string::npos) { dbname = kv.first; break; }
        std::vector<uint8_t> db = src.get_res(dbname, err);
        if (db.empty()) { std::printf("no shaderstate db\n"); continue; }
        const uint32_t programCount = rd32(db, 0);
        const uint64_t programPointer = rd64(db, 4);

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
        if (!key_at) { std::printf("key not in shaderstate db\n"); continue; }
        const uint32_t nslots = rd32(db, key_at + 8);

        std::map<uint64_t, std::string> perm_res;
        for (const auto& kv : src.res()) {
            const size_t p = kv.first.find("expressionshader/permutation");
            if (p == std::string::npos) continue;
            const uint64_t id = std::strtoull(kv.first.c_str() + p + 28, nullptr, 10);
            if (id) perm_res.emplace(id, kv.first);
        }

        std::set<uint64_t> seen_shared, seen_bs;
        for (uint32_t s = 0; s < nslots; s++) {
            const uint32_t slot = rd32(db, key_at + 12 + 4 * s);
            const size_t rec = (size_t)programPointer + (size_t)slot * 0xA8;
            const uint32_t pcount = rd32(db, rec + 0x60);
            const uint32_t poff   = rd32(db, rec + 0x64);
            std::printf("\n=== pass %u (program slot %u), %u permutation(s) ===\n", s, slot, pcount);
            for (uint32_t pi = 0; pi < pcount && pi < 512; pi++) {
                const uint64_t pid = rd64(db, poff + 8ull * pi);
                auto it = perm_res.find(pid);
                if (it == perm_res.end()) continue;
                std::vector<uint8_t> pr = src.get_res(it->second, err);
                if (pr.size() < 52) continue;
                const uint64_t shared = rd64(pr, 0);
                if (!seen_shared.insert(shared).second) continue;
                char nm[128];
                std::snprintf(nm, sizeof(nm), "expressionshader/permutationshareddata/%llu",
                              (unsigned long long)shared);
                std::vector<uint8_t> sd = src.get_res(nm, err);
                if (sd.empty()) { std::printf("  shared %llu: NO RES\n", (unsigned long long)shared); continue; }
                const uint64_t common  = rd64(sd, 0x18);
                const uint64_t variant = rd64(sd, 0x20);
                std::printf("  perm %llu  shared %llu (%zu B)  common BS %llu  variant BS %llu  stage2 %s\n",
                    (unsigned long long)pid, (unsigned long long)shared, sd.size(),
                    (unsigned long long)common, (unsigned long long)variant,
                    pr.size() >= 68 ? guid_net(pr, 0x30).c_str() : "-");

                for (int which = 0; which < 2; which++) {
                    const uint64_t bsid = which ? variant : common;
                    if (!bsid) continue;
                    if (!seen_bs.insert(bsid).second) continue;
                    std::vector<BsRec> recs;
                    if (!read_bindingset(src, bsid, recs, err)) {
                        std::printf("    %s BS %llu: %s\n", which ? "variant" : "common",
                                    (unsigned long long)bsid, err.c_str());
                        continue;
                    }
                    std::printf("    --- %s BindingSet %llu: %zu record(s) ---\n",
                                which ? "variant" : "common", (unsigned long long)bsid, recs.size());
                    for (size_t r = 0; r < recs.size(); r++) {
                        const BsRec& b = recs[r];
                        std::printf("      rec %zu: span=%u decls=%u fixups=%u\n",
                                    r, b.span, b.n_decl, b.n_fixup);
                        std::vector<Decl> sorted = b.decls;
                        std::sort(sorted.begin(), sorted.end(),
                                  [](const Decl& a, const Decl& c){ return a.dest < c.dest; });
                        for (const Decl& e : sorted) {
                            std::printf("        +%-4u %-8s %08X flags=%04x meta=%04x",
                                        e.dest, type_name(e.type), e.name32, e.flags, e.meta);
                            auto t = texs.find(e.name32);
                            auto v = vals.find(e.name32);
                            if (t != texs.end()) {
                                std::printf("  = tex %s", t->second.c_str());
                            } else if (v != vals.end()) {
                                const std::vector<uint8_t>& raw = v->second;
                                const int ts = type_size(e.type);
                                std::printf("  = ");
                                if (ts == 4 && raw.size() >= 4) {
                                    if (e.type == 0x34791132u || e.type == 0xA1C34F4Au)
                                        std::printf("%u", rd32(raw, 0));
                                    else std::printf("%g", rdf(raw, 0));
                                } else if (ts && raw.size() >= (size_t)ts) {
                                    for (int k = 0; k < ts / 4; k++) std::printf("%s%g", k ? "," : "", rdf(raw, 4 * k));
                                } else {
                                    std::printf("(%zu raw bytes)", raw.size());
                                }
                            } else {
                                std::printf("  = <not in this depot record>");
                            }
                            std::printf("\n");
                        }
                    }
                }
            }
        }
    }
    return 0;
}
