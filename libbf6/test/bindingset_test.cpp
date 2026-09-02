/* bindingset_test - the DATA half of the terrain compositor.
 *
 * A ComputeLayer evaluator never names a texture: it fetches a descriptor
 * index out of a ShaderLayerInfos ROW and indexes a table. The kernel says
 * WHICH row field it reads; this says WHAT FILLS that field, and what the
 * table holds, both straight off disk:
 *
 *   compute permutation -> SharedData (+0x00)
 *   SharedData -> CommonBindingSet (+0x18), VariantBindingSet (+0x20),
 *                 LayerInfoBindingSet (+0x28)
 *   BindingSet -> records -> {declaration: paramHash/typeHash/nameHi}
 *                 paired with {destination: byte offset or descriptor index}
 *
 * destinationSpan on the LayerInfo record IS the row stride in bytes, so the
 * row field map falls out of the file rather than out of the disassembly.
 * Layout per SHADERS.md 8.1.1 and its BindingSet section.
 *
 *   bindingset_test <game_dir> <level> [ubershader_index]
 *   bindingset_test <game_dir> <level> --permutation <live_compute_permutation_id>
 */
#include <algorithm>
#include <cstdio>
#include <cstring>
#include <map>
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

// name32 = (nameHi << 16) | (paramHash >> 48 & 0xFFFF) - the depot's own rule.
static uint32_t name32_of(uint64_t param_hash, uint16_t name_hi)
{ return ((uint32_t)name_hi << 16) | (uint32_t)((param_hash >> 48) & 0xFFFF); }

struct Decl { uint64_t param; uint32_t type; uint16_t flags, name_hi;
              uint32_t dest; uint16_t meta; };

static bool read_bindingset(Source& src, uint64_t id,
                            std::vector<std::pair<uint32_t, std::vector<Decl>>>& out_recs,
                            std::string& err)
{
    char nm[128];
    std::snprintf(nm, sizeof(nm), "expressionshader/bindingset/%llu", (unsigned long long)id);
    std::vector<uint8_t> d = src.get_res(nm, err);
    if (d.empty()) { err = "no bindingset resource " + std::string(nm); return false; }

    const uint32_t recordCount = rd32(d, 0);
    const uint64_t recordPtr   = rd64(d, 4);          // unaligned, relocated to a file offset
    if (recordCount == 0 || recordCount > 4096) { err = "bad record count"; return false; }

    for (uint32_t r = 0; r < recordCount; r++) {
        const size_t rec = (size_t)recordPtr + (size_t)r * 0x38;
        if (rec + 0x38 > d.size()) break;
        const uint32_t span      = rd32(d, rec + 0x08);
        const uint16_t nDecl     = rd16(d, rec + 0x10);
        const uint16_t nFixup    = rd16(d, rec + 0x12);
        const uint64_t declPtr   = rd64(d, rec + 0x20);
        const uint64_t destPtr   = rd64(d, rec + 0x28);
        std::vector<Decl> decls;
        for (uint16_t i = 0; i < nDecl; i++) {
            const size_t dp = (size_t)declPtr + (size_t)i * 16;
            const size_t sp = (size_t)destPtr + (size_t)i * 8;
            if (dp + 16 > d.size() || sp + 8 > d.size()) break;
            Decl e;
            e.param   = rd64(d, dp + 0);
            e.type    = rd32(d, dp + 8);
            e.flags   = rd16(d, dp + 12);
            e.name_hi = rd16(d, dp + 14);
            e.dest    = rd32(d, sp + 0);
            e.meta    = rd16(d, sp + 6);
            decls.push_back(e);
        }
        (void)nFixup;
        out_recs.push_back({ span, decls });
    }
    return true;
}

int main(int argc, char** argv)
{
    if (argc < 3) { std::fprintf(stderr, "usage: bindingset_test <game_dir> <level> [ubershader] | --permutation <id>\n"); return 2; }
    const bool direct_permutation = argc > 4 && std::string(argv[3]) == "--permutation";
    const int want_idx = argc > 3 && !direct_permutation ? std::atoi(argv[3]) : 0;
    const uint64_t requested_permutation = direct_permutation
        ? std::strtoull(argv[4], nullptr, 10) : 0;

    Source src;
    std::string err;
    if (!src.open(argv[1], err)) { std::fprintf(stderr, "open: %s\n", err.c_str()); return 1; }
    if (!src.mount_level(argv[2], false, err)) { std::fprintf(stderr, "mount: %s\n", err.c_str()); return 1; }
    const std::string level = argv[2];

    // the level's terrain compositor program -> its permutation for this index
    std::string dbname;
    for (const auto& kv : src.res())
        if (kv.first.find("shaderstate_db") != std::string::npos &&
            kv.first.find(level) != std::string::npos) { dbname = kv.first; break; }
    std::vector<uint8_t> db = src.get_res(dbname, err);
    if (db.empty()) { std::printf("no shaderstate db\n"); return 1; }
    const uint32_t programCount = rd32(db, 0);
    uint64_t programPointer = 0;
    std::memcpy(&programPointer, db.data() + 4, 8);

    uint64_t perm_id = requested_permutation;
    if (!perm_id) {
        const uint64_t kTerrainProg = 0x9F11D96B0FDF4773ull;
        for (uint32_t s = 0; s < programCount; s++) {
            const size_t rec = (size_t)programPointer + (size_t)s * 0xA8;
            if (rec + 0xA8 > db.size()) break;
            bool hit = false;
            for (size_t o = 0; o + 8 <= 0xA8; o += 4)
                if (rd64(db, rec + o) == kTerrainProg) { hit = true; break; }
            if (!hit) continue;
            const uint32_t pcount = rd32(db, rec + 0x60);
            const uint32_t poff   = rd32(db, rec + 0x64);
            if ((uint32_t)want_idx < pcount) perm_id = rd64(db, poff + 8ull * want_idx);
            break;
        }
    }
    if (!perm_id) { std::printf("no terrain compositor permutation for index %d\n", want_idx); return 1; }

    char pn[128];
    std::snprintf(pn, sizeof(pn), "expressionshader/permutation%llu", (unsigned long long)perm_id);
    std::vector<uint8_t> pr = src.get_res(pn, err);
    if (pr.size() != 36) { std::printf("permutation %llu is not the compute form (%zu bytes)\n",
        (unsigned long long)perm_id, pr.size()); return 1; }
    const uint64_t shared_id = rd64(pr, 0);

    char sn[128];
    std::snprintf(sn, sizeof(sn), "expressionshader/permutationshareddata/%llu",
        (unsigned long long)shared_id);
    std::vector<uint8_t> sd = src.get_res(sn, err);
    std::printf("%s %s %d\n  permutation %llu\n  sharedData %llu (%zu bytes)\n",
        level.c_str(), direct_permutation ? "direct compute permutation" : "ubershader",
        direct_permutation ? -1 : want_idx, (unsigned long long)perm_id,
        (unsigned long long)shared_id, sd.size());
    if (sd.size() < 0x60) { std::printf("shared data too short\n"); return 1; }

    const uint64_t common_id  = rd64(sd, 0x18);
    const uint64_t variant_id = rd64(sd, 0x20);
    const uint64_t layer_id   = rd64(sd, 0x28);
    std::printf("  common  BindingSet %llu\n  variant BindingSet %llu\n  LAYERINFO BindingSet %llu\n",
        (unsigned long long)common_id, (unsigned long long)variant_id,
        (unsigned long long)layer_id);

    struct Named { uint64_t id; const char* what; };
    const Named sets[] = { { layer_id, "LAYERINFO (the row map)" },
                           { variant_id, "VARIANT (main cbuffer + tables)" },
                           { common_id, "COMMON (the texture table)" } };

    for (const Named& s : sets) {
        if (!s.id) continue;
        std::vector<std::pair<uint32_t, std::vector<Decl>>> recs;
        std::string e;
        if (!read_bindingset(src, s.id, recs, e)) { std::printf("\n%s: %s\n", s.what, e.c_str()); continue; }
        std::printf("\n==== %s  id %llu: %zu record(s)\n", s.what, (unsigned long long)s.id, recs.size());
        for (size_t r = 0; r < recs.size(); r++) {
            const uint32_t span = recs[r].first;
            const std::vector<Decl>& ds = recs[r].second;
            std::printf("  record %zu: destinationSpan 0x%X (%u bytes = %u dwords), %zu declaration(s)\n",
                r, span, span, span / 4, ds.size());
            // resources first (descriptor indices), then inline values by offset
            // step-by-4 destinations over a big span = a row layout.
            bool bRowLayout = false;
            {
                uint32_t maxd = 0;
                for (const Decl& q : ds) maxd = q.dest > maxd ? q.dest : maxd;
                bRowLayout = (span >= 64 && maxd >= span / 2);
            }
            std::vector<Decl> sorted = ds;
            std::sort(sorted.begin(), sorted.end(),
                [](const Decl& a, const Decl& b){ return a.dest < b.dest; });
            for (size_t i = 0; i < sorted.size() && i < 120; i++) {
                const Decl& x = sorted[i];
                const uint32_t n32 = name32_of(x.param, x.name_hi);
                const char* slot = MaterialBinding::display_name(n32);
                // 0xcc84d53d is the depot TEXTURE type (byte-validated over
                // 3,000 depots): such a row dword holds a DESCRIPTOR INDEX,
                // which is what the kernel fetches before indexing its
                // texture table. Everything else is an inline value.
                const char* kind =
                    x.type == 0xcc84d53d ? "TEXTURE descriptor index"
                  : x.type == 0x14a0b1c1 ? "float"
                  : x.type == 0x25f81af1 ? "float3"
                  : x.type == 0x34791132 ? "int/enum"
                  : x.type == 0xa1c34f4a ? "float(4b)"
                  : x.type == 0x39ab6941 ? "vec?"
                  : x.type == 0xdef2e1a5 ? "?(16b)"
                  : "?";
                // THE DESTINATION IS TWO DIFFERENT THINGS, and the record
                // says which. A row-layout record (a large span whose
                // destinations step by 4) uses BYTE OFFSETS into the row;
                // a pure resource table uses DESCRIPTOR INDICES that step
                // by 1. Reading a table as a row silently divides every
                // index by four.
                if (bRowLayout)
                    std::printf("    dword %3u (byte %4u)  name32 %08x  %-26s %s\n",
                        x.dest / 4, x.dest, n32, kind, slot ? slot : "");
                else
                    std::printf("    descriptor %3u        name32 %08x  %-26s %s\n",
                        x.dest, n32, kind, slot ? slot : "");
            }
            if (sorted.size() > 120) std::printf("    ... %zu more\n", sorted.size() - 120);
        }
    }
    return 0;
}
