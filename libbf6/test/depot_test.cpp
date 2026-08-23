/* Validation harness for module 8 (ShaderBlockDepot).
 *
 * Not shipped. There is no reference dump to diff against here, but this format
 * is unusually self-checking, and the checks are the parse itself:
 *
 *  - the key table's length is not stored, it is recovered by dereferencing the
 *    first record pointer, so a wrong header fails immediately;
 *  - the records must TILE the blob area exactly, which is also the only
 *    terminator the array has;
 *  - every blob must be consumed to the byte, because entries are packed with
 *    no alignment and a wrong size desynchronises everything after it;
 *  - an unknown inline type hash is a hard error rather than a skip.
 *
 * So "parsed N depots to their exact end" is a real statement. What it cannot
 * tell you is whether the SLOT names are right; that shows up when the textures
 * are looked at.
 *
 *   depot_test <game_dir> <level> [max]
 */
#include "depot.h"
#include "source.h"

#include <chrono>
#include <cstdio>
#include <algorithm>
#include <map>
#include <vector>
#include <string>

using namespace bf6;

int main(int argc, char** argv)
{
    if (argc < 3)
    {
        std::fprintf(stderr, "usage: depot_test <game_dir> <level> [max]\n");
        return 2;
    }
    const int limit = argc > 3 ? std::atoi(argv[3]) : 60;

    Source src;
    std::string err;
    if (!src.open(argv[1], err)) { std::fprintf(stderr, "open: %s\n", err.c_str()); return 1; }
    if (!src.mount_level(argv[2], false, err)) { std::fprintf(stderr, "mount: %s\n", err.c_str()); return 1; }

    std::vector<std::string> depots;
    for (const auto& kv : src.res())
        if (kv.first.find("shaderblockdepot") != std::string::npos) depots.push_back(kv.first);
    std::printf("%zu depot resource(s) in this mount\n", depots.size());
    if (depots.empty()) return 1;

    int ok = 0, bad = 0;
    uint64_t keys = 0, recs = 0, blobs_ok = 0, blobs_bad = 0, tex_params = 0;
    std::map<std::string, int> slots;
    std::map<uint32_t, int> unnamed;
    std::map<std::string, int> failures;
    const auto t0 = std::chrono::steady_clock::now();

    for (size_t i = 0; i < depots.size() && (int)i < limit; i++)
    {
        std::vector<uint8_t> d = src.get_res(depots[i], err);
        if (d.empty()) continue;

        Depot dep;
        std::string e;
        if (!dep.parse(d, e)) { bad++; failures[e]++; continue; }
        ok++;
        keys += dep.key_count();
        recs += dep.record_count();

        // Parse EVERY blob, not a sample: the "consumed exactly" check is the
        // whole value here, and a sample would miss the entry that desyncs.
        for (size_t r = 0; r < dep.record_count(); r++)
        {
            std::vector<DepotParam> ps;
            if (!dep.params(r, d, ps, e)) { blobs_bad++; failures[e]++; continue; }
            blobs_ok++;
            for (const DepotParam& p : ps)
                if (!p.refs.empty())
                {
                    tex_params++;
                    const char* nm = Depot::slot_name(p.name32);
                    slots[nm ? nm : "(unnamed)"]++;
                    if (!nm) unnamed[p.name32]++;
                }
        }
    }
    const double ms = std::chrono::duration<double, std::milli>(
        std::chrono::steady_clock::now() - t0).count();

    std::printf("%d depot(s) parsed, %d refused, %.0f ms\n", ok, bad, ms);
    std::printf("  %llu keys, %llu records, %llu blobs read to their exact end, %llu bad\n",
                (unsigned long long)keys, (unsigned long long)recs,
                (unsigned long long)blobs_ok, (unsigned long long)blobs_bad);
    std::printf("  %llu texture parameters bound\n", (unsigned long long)tex_params);
    for (const auto& kv : slots) std::printf("    %-18s %d\n", kv.first.c_str(), kv.second);
    // THE UNNAMED SLOTS, most-used first. The Godot plugin names the slots it
    // needed; the game plainly uses more, and a slot nobody has named is a
    // texture nobody is binding. This is the list worth working through.
    std::vector<std::pair<int, uint32_t>> top;
    for (const auto& kv : unnamed) top.emplace_back(kv.second, kv.first);
    std::sort(top.rbegin(), top.rend());
    std::printf("  %zu distinct UNNAMED slot hashes; the busiest:\n", top.size());
    for (size_t i = 0; i < top.size() && i < 20; i++)
        std::printf("    0x%08x  %d\n", top[i].second, top[i].first);

    for (const auto& kv : failures) std::printf("  refused: %s (x%d)\n", kv.first.c_str(), kv.second);
    return (bad || blobs_bad) ? 1 : 0;
}
