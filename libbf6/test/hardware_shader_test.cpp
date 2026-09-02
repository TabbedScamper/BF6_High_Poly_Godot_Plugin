/* Resolve one live hardware material state key to the exact raster
 * permutations and compiled bytecode selected by the installed game.
 *
 * This is the hardware counterpart to terrainsurface_raster_test.  It does
 * not take a copied shader or an exported table: the key comes from a live
 * MeshSet section, every ExpressionShaderDatabase in the mounted install is
 * searched, and a perturbed key is searched beside it as the negative
 * control.
 *
 *   hardware_shader_test <game_dir> <level> <state_key_hex> [out_dir]
 */
#include <algorithm>
#include <cctype>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <map>
#include <set>
#include <string>
#include <vector>

#include "depot.h"
#include "source.h"

using namespace bf6;

template <typename T> static T rd(const std::vector<uint8_t>& d, size_t o)
{ T v{}; if (o + sizeof(T) <= d.size()) std::memcpy(&v, d.data() + o, sizeof(T)); return v; }

static std::string lower(std::string s)
{ for (char& c : s) c = (char)std::tolower((unsigned char)c); return s; }

static std::string guid_net(const std::vector<uint8_t>& d, size_t o)
{
    if (o + 16 > d.size()) return {};
    char b[64];
    std::snprintf(b, sizeof(b),
        "%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x",
        d[o+3],d[o+2],d[o+1],d[o],d[o+5],d[o+4],d[o+7],d[o+6],
        d[o+8],d[o+9],d[o+10],d[o+11],d[o+12],d[o+13],d[o+14],d[o+15]);
    return b;
}

static std::string texture_asset(Source& src, const std::string& guid)
{
    const auto& index = src.partition_index();
    auto it = index.find(guid);
    if (it == index.end()) return "<unresolved>";
    std::string name = it->second;
    if (name.size() > 4 && name.compare(name.size() - 4, 4, ".ebx") == 0)
        name.resize(name.size() - 4);
    return name;
}

struct Decl {
    uint64_t param{}; uint32_t type{}, dest{}; uint16_t flags{}, name_hi{}, meta{};
    uint32_t name32() const
    { return ((uint32_t)name_hi << 16) | (uint32_t)((param >> 48) & 0xffff); }
};
struct BsRec { uint32_t span{}; uint16_t fixups{}; std::vector<Decl> decls; };

static bool read_bindingset(Source& src, uint64_t id,
                            std::vector<BsRec>& out, std::string& err)
{
    out.clear(); if (!id) return true;
    char nm[128];
    std::snprintf(nm, sizeof(nm), "expressionshader/bindingset/%llu",
                  (unsigned long long)id);
    const std::vector<uint8_t> d = src.get_res(nm, err);
    if (d.size() < 12) { err = "missing BindingSet " + std::string(nm); return false; }
    const uint32_t n = rd<uint32_t>(d, 0); const uint64_t p = rd<uint64_t>(d, 4);
    if (!n || n > 4096 || p >= d.size()) { err = "invalid BindingSet table"; return false; }
    for (uint32_t r = 0; r < n; ++r) {
        const size_t at = (size_t)p + (size_t)r * 0x38;
        if (at + 0x38 > d.size()) { err = "truncated BindingSet record"; return false; }
        BsRec b; b.span = rd<uint32_t>(d, at + 8);
        const uint16_t nd = rd<uint16_t>(d, at + 0x10);
        b.fixups = rd<uint16_t>(d, at + 0x12);
        const uint64_t dp = rd<uint64_t>(d, at + 0x20);
        const uint64_t sp = rd<uint64_t>(d, at + 0x28);
        for (uint16_t i = 0; i < nd; ++i) {
            const size_t da = (size_t)dp + (size_t)i * 16;
            const size_t sa = (size_t)sp + (size_t)i * 8;
            if (da + 16 > d.size() || sa + 8 > d.size()) {
                err = "truncated BindingSet declaration"; return false;
            }
            Decl x; x.param = rd<uint64_t>(d, da); x.type = rd<uint32_t>(d, da + 8);
            x.flags = rd<uint16_t>(d, da + 12); x.name_hi = rd<uint16_t>(d, da + 14);
            x.dest = rd<uint32_t>(d, sa); x.meta = rd<uint16_t>(d, sa + 6);
            b.decls.push_back(x);
        }
        out.push_back(std::move(b));
    }
    return true;
}

static void print_bindingset(Source& src, const char* label, uint64_t id,
                             const MaterialBinding& material, std::string& err)
{
    std::vector<BsRec> recs;
    if (!read_bindingset(src, id, recs, err)) {
        std::printf("      %s ERROR %s\n", label, err.c_str()); return;
    }
    std::printf("      %s id=%llu records=%zu\n", label,
                (unsigned long long)id, recs.size());
    for (size_t r = 0; r < recs.size(); ++r) {
        std::vector<Decl> ds = recs[r].decls;
        std::sort(ds.begin(), ds.end(), [](const Decl& a, const Decl& b) {
            return a.dest < b.dest;
        });
        std::printf("        rec%zu span=%u fixups=%u decls=%zu\n", r,
                    recs[r].span, recs[r].fixups, ds.size());
        for (const Decl& x : ds) {
            const uint32_t n = x.name32();
            std::printf("          dest=%u name32=%08x type=%08x", x.dest, n, x.type);
            auto ti = material.textures.find(n); auto ci = material.constants.find(n);
            if (ti != material.textures.end())
                std::printf(" texture=%s asset=%s", ti->second.c_str(),
                            texture_asset(src, ti->second).c_str());
            else if (ci != material.constants.end()) {
                std::printf(" bytes="); for (uint8_t b : ci->second) std::printf("%02x", b);
            } else std::printf(" missing");
            std::printf("\n");
        }
    }
}

static bool key_record(const std::vector<uint8_t>& db, uint64_t key,
                       uint32_t programs, size_t& at)
{
    at = 0;
    for (size_t o = 0; o + 12 <= db.size(); o += 4) {
        if (rd<uint64_t>(db, o) != key) continue;
        const uint32_t n = rd<uint32_t>(db, o + 8);
        if (!n || n > 8 || o + 12ull + 4ull * n > db.size()) continue;
        bool ok = true;
        for (uint32_t i = 0; i < n; ++i)
            if (rd<uint32_t>(db, o + 12 + 4ull * i) >= programs) ok = false;
        if (ok) { at = o; return true; }
    }
    return false;
}

static bool bare_dxbc(Source& src, const std::string& guid,
                      std::vector<uint8_t>& out, std::string& err)
{
    const std::string needle = lower(guid);
    std::vector<uint8_t> wrapped;
    for (const auto& kv : src.res()) {
        const std::string n = lower(kv.first);
        if (n.find("bytecode") == std::string::npos || n.find(needle) == std::string::npos) continue;
        wrapped = src.get_res(kv.first, err);
        if (!wrapped.empty()) break;
    }
    size_t at = std::string::npos;
    for (size_t o = 0; o + 4 <= wrapped.size() && o < 8192; ++o)
        if (!std::memcmp(wrapped.data() + o, "DXBC", 4)) { at = o; break; }
    if (at == std::string::npos || at + 0x20 > wrapped.size()) {
        err = "no DXBC container for " + guid; return false;
    }
    const uint32_t bytes = rd<uint32_t>(wrapped, at + 0x18);
    if (bytes < 0x20 || at + bytes > wrapped.size()) {
        err = "invalid DXBC size for " + guid; return false;
    }
    out.assign(wrapped.begin() + at, wrapped.begin() + at + bytes);
    return true;
}

int main(int argc, char** argv)
{
    if (argc < 4) {
        std::fprintf(stderr, "usage: hardware_shader_test <game_dir> <level> <state_key_hex> [out_dir]\n");
        return 2;
    }
    const uint64_t key = std::strtoull(argv[3], nullptr, 16);
    const uint64_t fake = key ^ 0x9e3779b97f4a7c15ull;
    const std::filesystem::path outdir = argc > 4 ? argv[4] : "";
    if (!key) { std::fprintf(stderr, "state key is zero\n"); return 2; }

    Source src; std::string err;
    if (!src.open(argv[1], err) || !src.mount_level(argv[2], false, err)) {
        std::fprintf(stderr, "mount: %s\n", err.c_str()); return 1;
    }
    MaterialBinding material; bool have_material = false;
    for (const auto& kv : src.res()) {
        if (lower(kv.first).find("shaderblockdepot") == std::string::npos) continue;
        const std::vector<uint8_t> d = src.get_res(kv.first, err); Depot dep;
        if (d.empty() || !dep.parse(d, err) || !dep.has_key(key)) continue;
        material = dep.textures_for(key, d); have_material = true;
        std::printf("MATERIAL depot=%s constants=%zu textures=%zu\n", kv.first.c_str(),
                    material.constants.size(), material.textures.size());
        break;
    }
    if (!have_material) {
        std::fprintf(stderr, "material key has no live ShaderBlockDepot record\n"); return 1;
    }
    std::map<uint64_t, std::string> permutations;
    for (const auto& kv : src.res()) {
        const std::string n = lower(kv.first);
        const size_t p = n.find("expressionshader/permutation");
        if (p == std::string::npos || n.find("shareddata") != std::string::npos) continue;
        const uint64_t id = std::strtoull(n.c_str() + p + 28, nullptr, 10);
        if (id) permutations[id] = kv.first;
    }
    if (!outdir.empty()) std::filesystem::create_directories(outdir);

    int real_hits = 0, fake_hits = 0, raster = 0;
    std::set<uint64_t> perm_seen;
    std::set<uint64_t> shared_seen;
    std::set<std::string> bytecode_seen;
    for (const auto& kv : src.res()) {
        if (lower(kv.first).find("shaderstate_db") == std::string::npos) continue;
        const std::vector<uint8_t> db = src.get_res(kv.first, err);
        if (db.size() < 12) continue;
        const uint32_t programs = rd<uint32_t>(db, 0);
        const uint64_t pp = rd<uint64_t>(db, 4);
        if (!programs || programs > 100000 || pp >= db.size()) continue;
        size_t at = 0, fat = 0;
        const bool real = key_record(db, key, programs, at);
        const bool bad = key_record(db, fake, programs, fat);
        if (bad) ++fake_hits;
        if (!real) continue;
        ++real_hits;
        std::printf("DATABASE %s key_at=0x%zx programs=%u\n", kv.first.c_str(), at, programs);
        const uint32_t slots = rd<uint32_t>(db, at + 8);
        for (uint32_t si = 0; si < slots; ++si) {
            const uint32_t slot = rd<uint32_t>(db, at + 12 + 4ull * si);
            const size_t rec = (size_t)pp + (size_t)slot * 0xA8;
            if (rec + 0xA8 > db.size()) continue;
            const uint32_t np = rd<uint32_t>(db, rec + 0x60);
            const uint32_t po = rd<uint32_t>(db, rec + 0x64);
            std::printf("  slot[%u]=%u permutations=%u\n", si, slot, np);
            for (uint32_t pi = 0; pi < np && pi < 1024; ++pi) {
                const uint64_t pid = rd<uint64_t>(db, (size_t)po + 8ull * pi);
                if (!perm_seen.insert(pid).second) continue;
                auto it = permutations.find(pid);
                if (it == permutations.end()) continue;
                const std::vector<uint8_t> pr = src.get_res(it->second, err);
                if (pr.size() != 52 && pr.size() != 68) continue;
                ++raster;
                const uint64_t shared = rd<uint64_t>(pr, 0);
                std::printf("    raster[%u] id=%llu bytes=%zu shared=%llu input=%llu\n",
                    pi, (unsigned long long)pid, pr.size(),
                    (unsigned long long)shared, (unsigned long long)rd<uint64_t>(pr, 0x10));
                if (shared_seen.insert(shared).second) {
                    char sn[128]; std::snprintf(sn, sizeof(sn),
                        "expressionshader/permutationshareddata/%llu",
                        (unsigned long long)shared);
                    const std::vector<uint8_t> sd = src.get_res(sn, err);
                    if (sd.size() >= 0x28) {
                        print_bindingset(src, "common", rd<uint64_t>(sd, 0x18), material, err);
                        print_bindingset(src, "variant", rd<uint64_t>(sd, 0x20), material, err);
                    } else std::printf("      shared data missing/short (%zu bytes)\n", sd.size());
                }
                const size_t offsets[] = { 0x20, 0x30 };
                for (int stage = 0; stage < (pr.size() == 68 ? 2 : 1); ++stage) {
                    const std::string guid = guid_net(pr, offsets[stage]);
                    if (guid.empty()) continue;
                    std::printf("      stage%d=%s\n", stage, guid.c_str());
                    if (!bytecode_seen.insert(guid).second || outdir.empty()) continue;
                    std::vector<uint8_t> dxbc;
                    if (!bare_dxbc(src, guid, dxbc, err)) {
                        std::fprintf(stderr, "      %s\n", err.c_str()); continue;
                    }
                    const std::filesystem::path path = outdir / (guid + ".dxbc");
                    FILE* f = nullptr; fopen_s(&f, path.string().c_str(), "wb");
                    if (!f) { std::fprintf(stderr, "cannot write %s\n", path.string().c_str()); continue; }
                    fwrite(dxbc.data(), 1, dxbc.size(), f); fclose(f);
                }
            }
        }
    }
    std::printf("SUMMARY key=%016llx db_hits=%d raster=%d bytecodes=%zu CONTROL fake=%016llx hits=%d\n",
        (unsigned long long)key, real_hits, raster, bytecode_seen.size(),
        (unsigned long long)fake, fake_hits);
    return real_hits > 0 && raster > 0 && fake_hits == 0 ? 0 : 1;
}
