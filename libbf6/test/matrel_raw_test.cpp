/* matrel_raw_test - read MaterialRelation*Data instances' RAW bytes.
 *
 * Every MaterialRelation*Data in the material grid decodes to ZERO fields
 * through the schema path (7,737 of 7,833 instances over 52 types), and the
 * executable's reflection table places their fields at offset 0xFFFF with size
 * -1, i.e. unresolved. That is not evidence the data is absent - only that this
 * view cannot reach it. The standing rule is to look at the bytes before
 * concluding anything about a payload.
 *
 * MaterialRelationDebrisData is declared 0x18 with DebrisSpawnDefaultImpulse
 * and DebrisSpawnImpulseMultiplier.
 */
#include "ebx.h"
#include "source.h"
#include "types.h"

#include <cstdio>
#include <cstring>
#include <cmath>
#include <string>
#include <vector>
#include <map>
#include <algorithm>
#include <utility>

using namespace bf6;

static void hexdump(const uint8_t* p, size_t n, int64_t base)
{
    for (size_t i = 0; i < n; i += 16) {
        std::printf("      %08llx  ", (unsigned long long)(base + (int64_t)i));
        for (size_t k = 0; k < 16; k++)
            if (i + k < n) std::printf("%02x ", p[i + k]); else std::printf("   ");
        std::printf(" ");
        for (size_t k = 0; k < 16 && i + k < n; k++) {
            const uint8_t c = p[i + k];
            std::printf("%c", (c >= 32 && c < 127) ? (char)c : '.');
        }
        std::printf("\n");
    }
}

struct Want { const char* name; uint8_t guid[16]; int size; };

int main(int argc, char** argv)
{
    if (argc < 2) { std::printf("usage: matrel_raw_test <game>\n"); return 2; }

    Source src;
    std::string err;
    if (!src.open(argv[1], err)) { std::printf("open: %s\n", err.c_str()); return 1; }
    const char* LEVEL = (argc > 2) ? argv[2] : "mp_subsurface";
    if (!src.mount_level(LEVEL, false, err))
    { std::printf("mount: %s\n", err.c_str()); return 1; }

    TypeDb types;
    bool got = false;
    for (const std::string& cand : TypeDb::exe_candidates(src.game_dir()))
        if (types.open(cand, err) && !types.looks_encrypted()) { got = true; break; }
    if (!got) { std::printf("types: %s\n", err.c_str()); return 1; }

    char namebuf[512];
    std::snprintf(namebuf, sizeof(namebuf),
                  "game/glaciermp/levels/%s/%s/materialgrid_win32", LEVEL, LEVEL);
    const char* name = namebuf;
    std::vector<uint8_t> bytes = src.get_ebx(std::string(name) + ".ebx", err);
    if (bytes.empty()) bytes = src.get_ebx(name, err);
    if (bytes.empty()) { std::printf("get_ebx: %s\n", err.c_str()); return 1; }

    Ebx ebx(types);
    if (!ebx.parse(std::move(bytes), err)) { std::printf("parse: %s\n", err.c_str()); return 1; }

    /* Mixed-endian on disk. */
    const Want wants[] = {
        { "MaterialRelationDebrisData",
          {0x23,0x1a,0xff,0x78,0x6d,0x21,0x58,0x58,0x1e,0xbd,0xad,0x73,0x38,0x1a,0x08,0xb2}, 0x18 },
        /* An AUDIO type with the same shape: one field, ReflectionCoefficient,
         * at an unresolved 0xFFFF offset. If the +0x18 payload boundary is a
         * property of the format rather than of the debris type, its acoustic
         * value reads there too. It ships one per level on 27 levels. */
        { "DiceShooterMaterialPropertySoundData",
          {0x9a,0x92,0xfa,0x56,0xf5,0xdd,0x38,0x18,0xba,0xf8,0x72,0x6e,0x5f,0x24,0xd4,0x4f}, 0x18 },
    };

    const std::vector<uint8_t>& raw = ebx.raw();
    const int64_t payload = ebx.payload();
    std::printf("partition %s\n  %zu instances, payload 0x%llx, %zu bytes total\n\n",
                ebx.partition_guid().c_str(), ebx.instance_count(),
                (unsigned long long)payload, raw.size());

    /* THE DECISIVE TEST. If instances of a relation type are byte-identical to
     * each other, the type carries no per-instance payload and is a pure
     * marker; the parameters must live elsewhere. If they differ, the payload
     * IS inline and the schema view simply cannot reach it. Run over EVERY
     * type in the partition so the answer is not read off one family. */
    std::map<size_t,size_t> extent;
    {
        /* Compare each instance's FULL extent, not a fixed window: the length is
         * the gap to the next instance in offset order. A fixed 0x18 window
         * would call a large type "identical" on its header alone. */
        std::vector<std::pair<uint32_t,size_t>> ord;
        for (size_t i = 0; i < ebx.instance_count(); i++)
            ord.push_back({ebx.instance_offset(i), i});
        std::sort(ord.begin(), ord.end());
        /* extent declared above so the dump below can use it */
        for (size_t k = 0; k < ord.size(); k++) {
            const uint32_t a = ord[k].first;
            const uint32_t b = (k + 1 < ord.size()) ? ord[k+1].first
                                                    : (uint32_t)(raw.size() - payload);
            extent[ord[k].second] = (b > a) ? (size_t)(b - a) : 0;
        }
        std::map<std::string, std::vector<std::string>> by_type;
        size_t maxext = 0;
        for (size_t i = 0; i < ebx.instance_count(); i++) {
            const int64_t off = payload + (int64_t)ebx.instance_offset(i);
            size_t len = extent[i];
            if (len == 0 || len > 4096) continue;
            if (off < 0 || (size_t)(off + (int64_t)len) > raw.size()) continue;
            if (len > maxext) maxext = len;
            std::string img((const char*)raw.data() + off, len);
            by_type[TypeDb::guid_str(ebx.instance_type(i))].push_back(img);
        }
        std::printf("  comparing FULL instance extents (largest %zu bytes)\n", maxext);
        int uniform = 0, varying = 0, single = 0;
        for (const auto& kv : by_type) {
            if (kv.second.size() < 2) { single++; continue; }
            bool same = true;
            for (size_t k = 1; k < kv.second.size(); k++)
                if (kv.second[k] != kv.second[0]) { same = false; break; }
            if (same) uniform++; else varying++;
        }
        std::printf("  FIRST 0x18 BYTES, per type, across %zu types with >1 instance:\n",
                    by_type.size() - (size_t)single);
        std::printf("    byte-IDENTICAL across all instances : %d\n", uniform);
        std::printf("    VARYING between instances           : %d\n", varying);
        std::printf("    (types with a single instance)      : %d\n\n", single);
        for (const auto& kv : by_type) {
            if (kv.second.size() < 8) continue;
            bool same = true;
            for (size_t k = 1; k < kv.second.size(); k++)
                if (kv.second[k] != kv.second[0]) { same = false; break; }
            size_t lo = kv.second[0].size(), hi = lo; bool samelen = true;
            for (size_t k = 1; k < kv.second.size(); k++) { size_t z = kv.second[k].size(); if (z != lo) samelen = false; if (z < lo) lo = z; if (z > hi) hi = z; }
            size_t fd = SIZE_MAX;
            for (size_t b = 0; b < lo && fd == SIZE_MAX; b++)
                for (size_t k = 1; k < kv.second.size(); k++)
                    if (kv.second[k][b] != kv.second[0][b]) { fd = b; break; }
            std::printf("      %-10s n=%-5zu extent %zu..%zu %-9s %-9s first diff +%s\n",
                        kv.first.substr(0,8).c_str(), kv.second.size(), lo, hi,
                        samelen ? "samelen" : "MIXEDLEN",
                        (fd == SIZE_MAX) ? "identical" : "VARIES",
                        (fd == SIZE_MAX) ? "-" : std::to_string(fd).c_str());
        }
        std::printf("\n");
    }

    int total = 0;
    for (const Want& w : wants) {
        if (w.size == 0) continue;
        int shown = 0, found = 0;
        for (size_t i = 0; i < ebx.instance_count(); i++) {
            if (std::memcmp(ebx.instance_type(i).data(), w.guid, 16) != 0) continue;
            found++; total++;
            if (shown >= 20) continue;
            const int64_t off = payload + (int64_t)ebx.instance_offset(i);
            if (off < 0 || (size_t)(off + w.size) > raw.size()) continue;
            const int elen = (int)extent[i];
            std::printf("  [%zu] %s payload+0x%x  header 0x18, EXTENT 0x%x%s",
                        i, w.name, ebx.instance_offset(i), elen, "\n");
            hexdump(raw.data() + off, (size_t)(elen > 0 ? elen : w.size), off);
            for (int o = 0x18; o + 4 <= elen; o += 4) {
                float f; std::memcpy(&f, raw.data() + off + o, 4);
                uint32_t u; std::memcpy(&u, raw.data() + off + o, 4);
                const bool plausible = std::isfinite(f) && f != 0.f &&
                                       std::fabs(f) > 1e-4f && std::fabs(f) < 1e5f;
                std::printf("      +0x%02x  u32 %-12u f32 %-14g%s\n", o, u, f,
                            plausible ? "<- plausible scalar" : "");
            }
            std::printf("\n");
            shown++;
        }
        std::printf("  %s: %d instances in this partition\n\n", w.name, found);
    }
    return total ? 0 : 1;
}
