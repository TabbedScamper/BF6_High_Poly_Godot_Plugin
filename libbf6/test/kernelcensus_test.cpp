/* kernelcensus_test - two questions at once.
 *
 *  A. TERRAIN: pin the level's ComputeLayer evaluator pair through the ESDB
 *     program 0x9F11D96B0FDF4773 (its permutation array is ordered by
 *     UberShaderIndex, SHADERS.md 8.1.1), and write the kernels out named.
 *  B. OCEAN: is there any compute bytecode in the mount that the
 *     expression-shader permutation families do NOT reach? If the ocean's FFT
 *     ships as an engine shader rather than a generated one, it is in that
 *     remainder - and if the remainder is empty, the kernels are not in a
 *     level mount at all, which is itself the answer.
 *
 *   kernelcensus_test <game_dir> <level> [out_dir]
 */
#include <algorithm>
#include <cstdio>
#include <cstring>
#include <map>
#include <set>
#include <string>
#include <vector>

#include "source.h"

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

// stage from the DXBC container inside the Frostbite wrapper; -1 if none.
static int stage_of(const std::vector<uint8_t>& bc, size_t& out_at, size_t& out_len)
{
    size_t at = std::string::npos;
    for (size_t o = 0; o + 4 <= bc.size() && o < 8192; o++)
        if (!std::memcmp(bc.data() + o, "DXBC", 4)) { at = o; break; }
    if (at == std::string::npos) return -1;
    out_at = at;
    const uint32_t total = rd32(bc, at + 0x18);
    out_len = (total > 0 && at + total <= bc.size()) ? total : bc.size() - at;
    const uint32_t nch = rd32(bc, at + 0x1C);
    for (uint32_t c = 0; c < nch && c < 32; c++) {
        const uint32_t co = rd32(bc, at + 0x20 + 4 * c);
        if (at + co + 12 > bc.size()) break;
        const uint8_t* ch = bc.data() + at + co;
        if (!std::memcmp(ch, "SHEX", 4) || !std::memcmp(ch, "SHDR", 4) ||
            !std::memcmp(ch, "DXIL", 4))
            return (int)(rd32(bc, at + co + 8) >> 16);
    }
    return -1;
}

int main(int argc, char** argv)
{
    if (argc < 3) { std::fprintf(stderr, "usage: kernelcensus_test <game_dir> <level> [out_dir]\n"); return 2; }
    const std::string outdir = argc > 3 ? argv[3] : std::string();

    Source src;
    std::string err;
    if (!src.open(argv[1], err)) { std::fprintf(stderr, "open: %s\n", err.c_str()); return 1; }
    if (!src.mount_level(argv[2], false, err)) { std::fprintf(stderr, "mount: %s\n", err.c_str()); return 1; }
    const std::string level = argv[2];

    // ---- A: the terrain ComputeLayer evaluators ----------------------------
    std::string dbname;
    for (const auto& kv : src.res())
        if (kv.first.find("shaderstate_db") != std::string::npos &&
            kv.first.find(level) != std::string::npos) { dbname = kv.first; break; }
    std::map<uint64_t, std::string> perm_res;
    for (const auto& kv : src.res()) {
        const size_t p = kv.first.find("expressionshader/permutation");
        if (p == std::string::npos) continue;
        const uint64_t id = std::strtoull(kv.first.c_str() + p + 28, nullptr, 10);
        if (id) perm_res.emplace(id, kv.first);
    }
    std::printf("db %s\n%zu permutation resources\n", dbname.c_str(), perm_res.size());

    std::set<std::string> reached;    // bytecode guids reachable from permutations
    if (!dbname.empty()) {
        std::vector<uint8_t> db = src.get_res(dbname, err);
        const uint32_t programCount = rd32(db, 0);
        uint64_t programPointer = 0;
        std::memcpy(&programPointer, db.data() + 4, 8);
        std::printf("programs %u\n", programCount);

        // The terrain compositor program carries this serialized id.
        const uint64_t kTerrainProg = 0x9F11D96B0FDF4773ull;
        for (uint32_t s = 0; s < programCount; s++) {
            const size_t rec = (size_t)programPointer + (size_t)s * 0xA8;
            if (rec + 0xA8 > db.size()) break;
            // the serialized program id sits in the record; scan its words
            bool is_terrain = false;
            for (size_t o = 0; o + 8 <= 0xA8; o += 4)
                if (rd64(db, rec + o) == kTerrainProg) { is_terrain = true; break; }
            if (!is_terrain) continue;
            const uint32_t pcount = rd32(db, rec + 0x60);
            const uint32_t poff   = rd32(db, rec + 0x64);
            std::printf("\nTERRAIN compositor program at slot %u: %u permutation(s)\n", s, pcount);
            for (uint32_t i = 0; i < pcount && i < 16; i++) {
                const uint64_t pid = rd64(db, poff + 8ull * i);
                auto it = perm_res.find(pid);
                std::printf("  UberShaderIndex %u -> permutation %llu %s\n", i,
                    (unsigned long long)pid,
                    it == perm_res.end() ? "(no resource)" : "");
                if (it == perm_res.end()) continue;
                std::vector<uint8_t> pr = src.get_res(it->second, err);
                if (pr.size() != 36) { std::printf("      not a compute record (%zu bytes)\n", pr.size()); continue; }
                const std::string g = guid_net(pr, 0x10);
                std::string bres;
                for (const auto& kv : src.res())
                    if (kv.first.find("bytecode") != std::string::npos &&
                        kv.first.find(g) != std::string::npos) { bres = kv.first; break; }
                if (bres.empty()) continue;
                std::vector<uint8_t> bc = src.get_res(bres, err);
                size_t at = 0, len = 0;
                const int st = stage_of(bc, at, len);
                std::printf("      bytecode %s  stage %d  %zu bytes\n", g.c_str(), st, len);
                if (!outdir.empty() && len) {
                    char fn[512];
                    std::snprintf(fn, sizeof(fn), "%s/terrain_%s_ubershader%u.dxbc",
                        outdir.c_str(), level.c_str(), i);
                    FILE* f = std::fopen(fn, "wb");
                    if (f) { std::fwrite(bc.data() + at, 1, len, f); std::fclose(f); }
                }
            }
        }

        // The fixed program table is also the authoritative way to find the
        // generated compositor culling/list kernels.  Do not identify them by
        // a remembered GUID: enumerate every program whose permutation run
        // resolves to the 36-byte compute-permutation record class in this
        // mounted level, then report its live bytecode resource and stage.
        std::printf("\nCOMPUTE PROGRAM CENSUS\n");
        uint32_t compute_programs = 0, compute_permutations = 0;
        for (uint32_t s = 0; s < programCount; s++) {
            const size_t rec = (size_t)programPointer + (size_t)s * 0xA8;
            if (rec + 0xA8 > db.size()) break;
            const uint32_t pcount = rd32(db, rec + 0x60);
            const uint32_t poff = rd32(db, rec + 0x64);
            if (!pcount || pcount > 64 || (size_t)poff + 8ull * pcount > db.size())
                continue;
            std::vector<std::pair<uint64_t, std::string>> compute;
            for (uint32_t i = 0; i < pcount; i++) {
                const uint64_t pid = rd64(db, poff + 8ull * i);
                const auto it = perm_res.find(pid);
                if (it == perm_res.end()) continue;
                std::vector<uint8_t> pr = src.get_res(it->second, err);
                if (pr.size() == 36) compute.emplace_back(pid, guid_net(pr, 0x10));
            }
            if (compute.empty()) continue;
            compute_programs++;
            compute_permutations += (uint32_t)compute.size();
            std::printf("  program slot %u: %u total, %zu compute\n",
                s, pcount, compute.size());
            for (size_t i = 0; i < compute.size(); i++) {
                const uint64_t pid = compute[i].first;
                const std::string& g = compute[i].second;
                std::string bres;
                for (const auto& kv : src.res())
                    if (kv.first.compare(0, 17, "shaders/bytecode/") == 0 &&
                        kv.first.find(g, 17) != std::string::npos) {
                        bres = kv.first; break;
                    }
                size_t at = 0, len = 0;
                int st = -1;
                if (!bres.empty()) {
                    std::vector<uint8_t> bc = src.get_res(bres, err);
                    st = stage_of(bc, at, len);
                    if (!outdir.empty() && len) {
                        char fn[512];
                        std::snprintf(fn, sizeof(fn), "%s/compute_program%u_run%zu_%s.dxbc",
                            outdir.c_str(), s, i, g.c_str());
                        FILE* f = std::fopen(fn, "wb");
                        if (f) {
                            std::fwrite(bc.data() + at, 1, len, f);
                            std::fclose(f);
                        }
                    }
                }
                std::printf("    run %zu permutation %llu bytecode %s stage %d %zu bytes\n",
                    i, (unsigned long long)pid, g.c_str(), st, len);
            }
        }
        std::printf("compute census total: %u program(s), %u permutation(s)\n",
            compute_programs, compute_permutations);
    }

    // every bytecode guid any permutation reaches
    for (const auto& kv : perm_res) {
        std::vector<uint8_t> pr = src.get_res(kv.second, err);
        if (pr.size() == 36) reached.insert(guid_net(pr, 0x10));
        else if (pr.size() >= 52) {
            reached.insert(guid_net(pr, 0x20));
            if (pr.size() >= 68) reached.insert(guid_net(pr, 0x30));
        }
    }
    std::printf("\npermutations reach %zu distinct bytecode guid(s)\n", reached.size());

    // ---- B: compute bytecode NOT reachable from any permutation ------------
    std::vector<std::string> all_bc;
    for (const auto& kv : src.res())
        if (kv.first.compare(0, 17, "shaders/bytecode/") == 0) all_bc.push_back(kv.first);
    std::printf("%zu shaders/bytecode resources in the mount\n", all_bc.size());

    int orphan = 0, orphan_cs = 0, checked = 0;
    std::map<int, int> stage_hist;
    for (const std::string& n : all_bc) {
        const std::string g = n.substr(17);
        if (reached.count(g)) continue;
        orphan++;
        std::vector<uint8_t> bc = src.get_res(n, err);
        if (bc.empty()) continue;
        checked++;
        size_t at = 0, len = 0;
        const int st = stage_of(bc, at, len);
        stage_hist[st]++;
        // ALL STAGES, not just compute. The first census kept stage 5 only,
        // which silently excluded 2,192 pixel and 252 vertex shaders - and a
        // full-screen composite or a render-to-texture generator is a PIXEL
        // shader. "Not in the compute set" was never "not in the engine".
        if (st == 5 || st == 0 || st == 1) {
            orphan_cs++;
            if (orphan_cs <= 30) std::printf("  ORPHAN COMPUTE %s  %zu bytes\n", n.c_str(), len);
            if (!outdir.empty() && len) {
                char fn[512];
                static const char* sn[] = { "ps", "vs", "gs", "hs", "ds", "cs" };
                std::snprintf(fn, sizeof(fn), "%s/orphan_%s_%s.dxbc", outdir.c_str(),
                    (st >= 0 && st < 6) ? sn[st] : "xx", g.c_str());
                FILE* f = std::fopen(fn, "wb");
                if (f) { std::fwrite(bc.data() + at, 1, len, f); std::fclose(f); }
            }
        }
    }
    std::printf("\n%d bytecode resource(s) unreachable from permutations, %d read\n", orphan, checked);
    std::printf("  by stage: ");
    static const char* nm[] = { "PIXEL", "VERTEX", "GEOM", "HULL", "DOMAIN", "COMPUTE" };
    for (const auto& kv : stage_hist)
        std::printf("%s=%d ", (kv.first >= 0 && kv.first < 6) ? nm[kv.first] : "?", kv.second);
    std::printf("\n");
    return 0;
}
