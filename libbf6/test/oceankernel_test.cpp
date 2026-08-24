/* oceankernel_test - the ocean's COMPUTE kernels: find them, extract them.
 *
 * The draw side reads displacement from cascade textures the simulation
 * writes (see the hub finding water-pipeline-recovered-...), so the wave math
 * lives in compute. This enumerates every permutation resource in the mount,
 * keeps the 36-byte COMPUTE form (8.1.1), joins each to its CompiledBytecode,
 * strips the Frostbite wrapper, and writes the container out. It also dumps
 * every field of WaterOceanSimulationEntityData so a state key (if the sim
 * selects its programs the way a surface does) cannot be missed.
 *
 *   oceankernel_test <game_dir> <level> <exe> [out_dir]
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

int main(int argc, char** argv)
{
    if (argc < 4) { std::fprintf(stderr, "usage: oceankernel_test <game_dir> <level> <exe> [out_dir]\n"); return 2; }
    const std::string outdir = argc > 4 ? argv[4] : std::string();

    Source src;
    std::string err;
    if (!src.open(argv[1], err)) { std::fprintf(stderr, "open: %s\n", err.c_str()); return 1; }
    if (!src.mount_level(argv[2], false, err)) { std::fprintf(stderr, "mount: %s\n", err.c_str()); return 1; }
    TypeDb types;
    if (!types.open(argv[3], err)) { std::fprintf(stderr, "types: %s\n", err.c_str()); return 1; }
    const std::string level = argv[2];

    // ---- A: every field of the ocean sim entity, hunting a state key -------
    const char* kSimType = "3ad51130-494f-ee8a-45cd-01103be713ee";
    std::string lvl_dir;
    for (const auto& kv : src.ebx()) {
        const size_t p = kv.first.find("/levels/" + level + "/");
        if (p == std::string::npos) continue;
        lvl_dir = kv.first.substr(0, p + 8 + level.size());
        break;
    }
    for (const auto& kv : src.ebx()) {
        const std::string& n = kv.first;
        if (lvl_dir.empty() || n.compare(0, lvl_dir.size(), lvl_dir) != 0) continue;
        if (n.find("schematic") == std::string::npos) continue;
        std::vector<uint8_t> raw = src.get_ebx(n, err);
        if (raw.empty()) continue;
        Ebx e(types);
        if (!e.parse(std::move(raw), err)) continue;
        for (size_t i = 0; i < e.instance_count(); i++) {
            if (TypeDb::guid_str(e.instance_type(i)) != kSimType) continue;
            EbxValue d = e.read_instance(i);
            std::printf("== sim instance in %s (%zu fields) ==\n", n.c_str(), d.fields.size());
            for (const auto& f : d.fields) {
                const EbxValue& v = f.second;
                if (v.kind == EbxValue::Kind::Uint && v.u > 0xFFFFFFFFull)
                    std::printf("   %08x  U64 %016llx   <- state-key shaped\n",
                        f.first, (unsigned long long)v.u);
                else if (v.kind == EbxValue::Kind::Uint)
                    std::printf("   %08x  uint %llu\n", f.first, (unsigned long long)v.u);
                else if (v.kind == EbxValue::Kind::Int && (uint64_t)v.i > 0xFFFFFFFFull)
                    std::printf("   %08x  I64 %016llx   <- state-key shaped\n",
                        f.first, (unsigned long long)v.i);
            }
        }
    }

    // ---- B: every COMPUTE permutation in the mount -------------------------
    // The record form is the discriminator: 36 bytes = compute (8.1.1),
    // 52/68 = raster (8.1).
    std::vector<std::pair<uint64_t, std::string>> perms;
    for (const auto& kv : src.res()) {
        const std::string& n = kv.first;
        const size_t p = n.find("expressionshader/permutation");
        if (p == std::string::npos) continue;
        const uint64_t id = std::strtoull(n.c_str() + p + 28, nullptr, 10);
        if (id) perms.push_back({ id, n });
    }
    std::printf("\n%zu permutation resources; scanning for the compute form...\n", perms.size());

    int ncomp = 0, nwritten = 0;
    std::map<std::string, int> by_size;
    for (const auto& pr : perms) {
        std::vector<uint8_t> rec = src.get_res(pr.second, err);
        if (rec.size() != 36) continue;
        ncomp++;
        const uint64_t shared = rd64(rec, 0);
        const std::string g = guid_net(rec, 0x10);
        std::string bres;
        for (const auto& kv : src.res())
            if (kv.first.size() > 20 && kv.first.find("bytecode") != std::string::npos &&
                kv.first.find(g) != std::string::npos) { bres = kv.first; break; }
        if (bres.empty()) continue;
        std::vector<uint8_t> bc = src.get_res(bres, err);
        if (bc.empty()) continue;

        // strip the Frostbite wrapper to the DXBC container
        size_t at = std::string::npos;
        for (size_t o = 0; o + 4 <= bc.size() && o < 8192; o++)
            if (!std::memcmp(bc.data() + o, "DXBC", 4)) { at = o; break; }
        size_t len = bc.size();
        if (at != std::string::npos) {
            const uint32_t total = rd32(bc, at + 0x18);
            len = (total > 0 && at + total <= bc.size()) ? total : bc.size() - at;
        } else at = 0;

        char sz[32];
        std::snprintf(sz, sizeof(sz), "%zuKB", len / 1024);
        by_size[sz]++;

        if (!outdir.empty()) {
            char fn[512];
            std::snprintf(fn, sizeof(fn), "%s/cs_%llu.dxbc", outdir.c_str(),
                (unsigned long long)pr.first);
            FILE* f = std::fopen(fn, "wb");
            if (f) { std::fwrite(bc.data() + at, 1, len, f); std::fclose(f); nwritten++; }
        }
        if (ncomp <= 40)
            std::printf("  compute perm %llu shared %llu -> %s (%zu bytes)\n",
                (unsigned long long)pr.first, (unsigned long long)shared,
                g.c_str(), len);
    }
    std::printf("\n%d compute permutation(s), %d written\n", ncomp, nwritten);
    for (const auto& kv : by_size) std::printf("  size %s x%d\n", kv.first.c_str(), kv.second);
    return 0;
}
