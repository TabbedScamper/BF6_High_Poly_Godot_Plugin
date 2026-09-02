/* waterconst_test - hunt the AUTHORED water constants.
 *
 * Two sources are dumped side by side for every level given:
 *
 *  A. every OceanComponentData in the level (the VisualEnvironment's tenth
 *     component), printed in LAYOUT ORDER with its FieldFlagOverride0 bitmask
 *     and its PropertyOverrides name list. Layout index i lines up with bit i
 *     of the mask, so a name that is present exactly when a bit is set is that
 *     field's name - solved across every preset in the game by waterconst.py.
 *
 *  B. the water surface's ShaderBlockDepot record, EVERY parameter, with its
 *     type hash and values. That is the material half of the pair.
 *
 * Machine-readable lines (prefix OC/OCM/OCN/DP) so a solver can consume it.
 *
 *   waterconst_test <game_dir> <exe> <level> [level...]
 */
#include <cstdio>
#include <cstring>
#include <cstdlib>
#include <string>
#include <vector>
#include <map>

#include "depot.h"
#include "ebx.h"
#include "source.h"
#include "types.h"

using namespace bf6;

static const char* kOceanComp  = "f7f42a90-6547-0ee2-cb65-9252e610e782";
static const char* kWaterType  = "ae0b69fc-2207-d874-8230-fcd467a592cf";
static const char* kSimType    = "3ad51130-494f-ee8a-45cd-01103be713ee";
static const char* kWaveType   = "f616e49a-e740-d842-f3e5-224f025761cc";
static const uint32_t kStateKeyField = 0x2E15621F;
static const uint32_t kFieldFlags    = 0x66A77748;
static const uint32_t kPropOverrides = 0x0BD67EC6;

// Vec3 member hashes, in offset order.
static const uint32_t kV3[4] = { 0x3901DB14, 0x42FC0F5E, 0x32A99B9C, 0x7C8062F2 };

static bool is_vec3(const EbxValue& v)
{
    return v.kind == EbxValue::Kind::Struct && v.fields.size() == 3 &&
           v.field(kV3[0]) && v.field(kV3[1]) && v.field(kV3[2]);
}

// A Vec4 is the same three members plus 0x7C8062F2. The shore blend cubic is
// the only one on the surface entity, and it printed as an opaque struct until
// this case existed.
static bool is_vec4(const EbxValue& v)
{
    return v.kind == EbxValue::Kind::Struct && v.fields.size() == 4 &&
           v.field(kV3[0]) && v.field(kV3[1]) && v.field(kV3[2]) && v.field(kV3[3]);
}

// One field, as one token: hash:kind:value(s)
static std::string tok(uint32_t h, const EbxValue& v)
{
    char b[160];
    if (is_vec4(v)) {
        std::snprintf(b, sizeof(b), "%08x:v4:%.6g,%.6g,%.6g,%.6g", h,
            v.field(kV3[0])->f, v.field(kV3[1])->f, v.field(kV3[2])->f, v.field(kV3[3])->f);
        return b;
    }
    if (is_vec3(v)) {
        std::snprintf(b, sizeof(b), "%08x:v3:%.6g,%.6g,%.6g", h,
            v.field(kV3[0])->f, v.field(kV3[1])->f, v.field(kV3[2])->f);
        return b;
    }
    switch (v.kind) {
    case EbxValue::Kind::Bool: std::snprintf(b, sizeof(b), "%08x:b:%d", h, v.b ? 1 : 0); break;
    case EbxValue::Kind::Real: std::snprintf(b, sizeof(b), "%08x:f:%.6g", h, v.f); break;
    case EbxValue::Kind::Int:  std::snprintf(b, sizeof(b), "%08x:i:%lld", h, (long long)v.i); break;
    case EbxValue::Kind::Uint: std::snprintf(b, sizeof(b), "%08x:u:%llu", h, (unsigned long long)v.u); break;
    case EbxValue::Kind::Struct: std::snprintf(b, sizeof(b), "%08x:s:%zu", h, v.fields.size()); break;
    case EbxValue::Kind::Array:  std::snprintf(b, sizeof(b), "%08x:a:%zu", h, v.items.size()); break;
    default: std::snprintf(b, sizeof(b), "%08x:?:0", h); break;
    }
    return b;
}

static float f32(const std::vector<uint8_t>& r, size_t o)
{ float v = 0; if (o + 4 <= r.size()) std::memcpy(&v, r.data() + o, 4); return v; }

int main(int argc, char** argv)
{
    if (argc < 4) {
        std::fprintf(stderr, "usage: waterconst_test <game_dir> <exe> <level> [level...]\n");
        return 2;
    }
    TypeDb types;
    std::string err;
    if (!types.open(argv[2], err)) { std::fprintf(stderr, "types: %s\n", err.c_str()); return 1; }

    for (int li = 3; li < argc; li++) {
        const std::string level = argv[li];
        Source src;
        if (!src.open(argv[1], err)) { std::fprintf(stderr, "open: %s\n", err.c_str()); return 1; }
        if (!src.mount_level(level.c_str(), false, err)) {
            std::printf("SKIP %s mount: %s\n", level.c_str(), err.c_str());
            continue;
        }

        // A raw resource, for looking at a container nobody has decoded yet
        // (the permutation shared data, which is where a slot -> cbuffer-offset
        // binding table would have to live).
        if (const char* want = getenv("BF6_DUMP_RES")) {
            std::vector<uint8_t> d = src.get_res(want, err);
            std::printf("RAW %s %zu bytes (%s)\n", want, d.size(), err.c_str());
            for (size_t o = 0; o < d.size(); o += 16) {
                std::printf("%06zx ", o);
                for (size_t k = 0; k < 16 && o + k < d.size(); k++)
                    std::printf("%02x ", d[o + k]);
                std::printf("\n");
            }
            std::printf("END %s\n", level.c_str());
            continue;
        }

        // The level directory prefix, off any partition path that contains it.
        std::string lvl_dir;
        for (const auto& kv : src.ebx()) {
            const size_t p = kv.first.find("/levels/" + level + "/");
            if (p == std::string::npos) continue;
            lvl_dir = kv.first.substr(0, p + 8 + level.size());
            break;
        }
        if (lvl_dir.empty()) { std::printf("SKIP %s (no level dir)\n", level.c_str()); continue; }

        // ---- A: every OceanComponentData, and the sim entity ---------------
        const bool wide = getenv("BF6_WIDE") != nullptr;
        const bool wide_waves = getenv("BF6_WIDE_WAVES") != nullptr;
        for (const auto& kv : src.ebx()) {
            const std::string& n = kv.first;
            if (wide) {
                // Every visual-environment preset the mount can see, not just
                // this level's: a preset that overrides a DIFFERENT subset is
                // what breaks a tie between two fields.
                if (n.find("/lighting/") == std::string::npos &&
                    n.find("/ve_") == std::string::npos &&
                    n.find("visualenvironment") == std::string::npos) continue;
            } else if (!wide_waves && n.compare(0, lvl_dir.size(), lvl_dir) != 0) continue;
            std::vector<uint8_t> raw = src.get_ebx(n, err);
            if (raw.empty()) continue;
            Ebx e(types);
            e.set_guid_index(&src.partition_index());
            if (!e.parse(std::move(raw), err)) continue;
            for (size_t i = 0; i < e.instance_count(); i++) {
                const std::string tg = TypeDb::guid_str(e.instance_type(i));
                if (tg != kOceanComp && tg != kSimType && tg != kWaveType) continue;
                if (wide && tg != kOceanComp) continue;
                if (wide_waves && n.compare(0, lvl_dir.size(), lvl_dir) != 0 &&
                    tg != kWaveType) continue;
                EbxValue d = e.read_instance(i);
                const char* tag = (tg == kOceanComp) ? "OC" :
                                  (tg == kSimType) ? "SIM" : "WAVE";
                std::printf("%s %s %s", tag, level.c_str(), n.c_str());
                for (const auto& f : d.fields) {
                    if (f.first == kFieldFlags || f.first == kPropOverrides) continue;
                    std::printf(" %s", tok(f.first, f.second).c_str());
                }
                std::printf("\n");
                if (const EbxValue* m = d.field(kFieldFlags))
                    std::printf("OCM %s %s %llu\n", level.c_str(), n.c_str(),
                                (unsigned long long)(m->kind == EbxValue::Kind::Uint ? m->u : (uint64_t)m->i));
                if (const EbxValue* a = d.field(kPropOverrides)) {
                    std::printf("OCN %s %s", level.c_str(), n.c_str());
                    for (const auto& it : a->items)
                        if (it.kind == EbxValue::Kind::Str) std::printf(" %s", it.s.c_str());
                    std::printf("\n");
                }
            }
        }

        // ---- B: the water surface's depot record, every parameter ----------
        std::vector<uint64_t> keys;
        for (const auto& kv : src.ebx()) {
            const std::string& n = kv.first;
            if (n.compare(0, lvl_dir.size(), lvl_dir) != 0) continue;
            std::vector<uint8_t> raw = src.get_ebx(n, err);
            if (raw.empty()) continue;
            Ebx e(types);
            e.set_guid_index(&src.partition_index());
            if (!e.parse(std::move(raw), err)) continue;
            for (size_t i = 0; i < e.instance_count(); i++) {
                if (TypeDb::guid_str(e.instance_type(i)) != kWaterType) continue;
                {
                    // The surface entity in FULL: 65 named fields, and several
                    // of them are authored water look constants in their own
                    // right (wave amplitude, interactive foam, tile offset).
                    EbxValue full = e.read_instance(i);
                    std::printf("WSE %s %s", level.c_str(), n.c_str());
                    for (const auto& f : full.fields)
                        std::printf(" %s", tok(f.first, f.second).c_str());
                    std::printf("\n");
                }
                const std::vector<uint32_t> want = { kStateKeyField };
                EbxValue inst = e.read_instance(i, &want);
                uint64_t k = 0;
                if (const EbxValue* f = inst.field(kStateKeyField)) {
                    if (f->kind == EbxValue::Kind::Uint) k = f->u;
                    else if (f->kind == EbxValue::Kind::Int) k = (uint64_t)f->i;
                }
                if (k) {
                    bool dup = false;
                    for (uint64_t o : keys) if (o == k) dup = true;
                    if (!dup) { keys.push_back(k); std::printf("KEY %s %s %016llx\n",
                        level.c_str(), n.c_str(), (unsigned long long)k); }
                }
            }
        }

        // FALLBACK, and the honest one: a level whose water entity we cannot
        // find still ships the material. Sweep the level's depots for any
        // record that binds the ocean colour slot and dump those too, so the
        // sample is every water material in the game rather than every water
        // material whose entity a heuristic happened to reach.
        if (keys.empty() && getenv("BF6_SCAN_DEPOTS")) {
            for (const auto& kv : src.res()) {
                const std::string& rn = kv.first;
                if (rn.find("shaderblockdepot") == std::string::npos) continue;
                if (rn.find(lvl_dir) == std::string::npos) continue;
                std::vector<uint8_t> d = src.get_res(rn, err);
                if (d.empty()) continue;
                Depot dep;
                if (!dep.parse(d, err)) continue;
                for (size_t r = 0; r < dep.record_count(); r++) {
                    std::vector<DepotParam> ps;
                    std::string e2;
                    if (!dep.params(r, d, ps, e2)) continue;
                    bool ocean = false;
                    for (const DepotParam& p : ps)
                        if (p.name32 == 0xeaca953a) ocean = true;
                    if (!ocean) continue;
                    std::printf("REC %s scan#%zu %s\n", level.c_str(), r, rn.c_str());
                    int i2 = 0;
                    for (const DepotParam& p : ps) {
                        if (!p.refs.empty()) { i2++; continue; }
                        std::printf("DP %s %2d %08x th=%08x cnt=%u len=%zu ph=%016llx fl=%04x",
                                    level.c_str(), i2++, p.name32, p.type_hash, p.count,
                                    p.raw.size(), (unsigned long long)p.param_hash, p.flags);
                        if (p.raw.size() == 1) std::printf(" b%u", (unsigned)p.raw[0]);
                        else for (size_t o = 0; o + 4 <= p.raw.size(); o += 4)
                            std::printf(" %.6g", f32(p.raw, o));
                        std::printf("\n");
                    }
                }
            }
        }

        for (uint64_t k : keys) {
            for (const auto& kv : src.res()) {
                const std::string& rn = kv.first;
                if (rn.find("shaderblockdepot") == std::string::npos) continue;
                if (rn.find(lvl_dir) == std::string::npos) continue;
                std::vector<uint8_t> d = src.get_res(rn, err);
                if (d.empty()) continue;
                Depot dep;
                if (!dep.parse(d, err)) continue;
                if (!dep.has_key(k)) continue;
                // Re-walk to the record so every param can be printed, not just
                // the texture ones textures_for() keeps.
                MaterialBinding mb = dep.textures_for(k, d);
                if (!mb.valid) continue;
                std::printf("REC %s %016llx %s\n", level.c_str(),
                            (unsigned long long)k, rn.c_str());
                const auto& gi = src.partition_index();
                // The RECORD, in its own order: cb1 packing is positional, so a
                // map-ordered dump would hide which constant sits where. Found
                // by matching the record whose slot set is this binding's.
                size_t hit = (size_t)-1;
                for (size_t r = 0; r < dep.record_count() && hit == (size_t)-1; r++) {
                    std::vector<DepotParam> ps;
                    std::string e2;
                    if (!dep.params(r, d, ps, e2)) continue;
                    if (ps.size() != mb.textures.size() + mb.constants.size()) continue;
                    bool same = true;
                    for (const DepotParam& p : ps) {
                        const bool tex = !p.refs.empty();
                        if (tex ? !mb.textures.count(p.name32) : !mb.constants.count(p.name32))
                            { same = false; break; }
                        if (!tex && mb.constants[p.name32] != p.raw) { same = false; break; }
                    }
                    if (same) hit = r;
                }
                std::vector<DepotParam> ps;
                std::string e2;
                if (hit != (size_t)-1) dep.params(hit, d, ps, e2);
                int idx = 0;
                for (const DepotParam& p : ps) {
                    if (!p.refs.empty()) {
                        auto a = gi.find(p.refs[0].second);
                        std::printf("DPT %s %2d %08x %s\n", level.c_str(), idx++, p.name32,
                                    a == gi.end() ? p.refs[0].second.c_str() : a->second.c_str());
                        continue;
                    }
                    std::printf("DP %s %2d %08x th=%08x cnt=%u len=%zu ph=%016llx fl=%04x",
                                level.c_str(), idx++, p.name32, p.type_hash, p.count,
                                p.raw.size(), (unsigned long long)p.param_hash, p.flags);
                    if (p.raw.size() == 1) std::printf(" b%u", (unsigned)p.raw[0]);
                    else for (size_t o = 0; o + 4 <= p.raw.size(); o += 4)
                        std::printf(" %.6g", f32(p.raw, o));
                    std::printf("\n");
                }
                break;
            }
        }
        std::printf("END %s\n", level.c_str());
        std::fflush(stdout);
    }
    return 0;
}
