/* NAME THE DEPOT'S TEXTURE SLOTS FROM THE DATA.
 *
 * Not shipped: this is a research tool whose output becomes a table.
 *
 * A depot binds textures to slots identified only by a 32-bit hash, and the
 * hash function is not the one older Frostbite used, so a slot cannot be named
 * by hashing a guess. But every binding carries the texture's FILE guid, which
 * resolves through the partition index to an asset name - and DICE names
 * textures by what they are: _nmt normal, _cs colour+specular, _wo, _m, _d and
 * so on.
 *
 * So: for every slot hash, resolve what is bound to it across a whole level and
 * count the suffixes. A slot whose bindings are 98% "_nmt" is the normal slot,
 * and that is read off the game rather than guessed.
 *
 * The confidence matters as much as the answer. A slot with one sample, or with
 * its suffixes split evenly, is NOT named here - it is reported as unclear, so
 * nobody writes it into a table as fact.
 *
 *   slots_test <game_dir> <level> [max_depots]
 */
#include "depot.h"
#include "source.h"

#include <algorithm>
#include <chrono>
#include <cstdio>
#include <map>
#include <string>
#include <vector>

using namespace bf6;

namespace {

// "common/.../t_mil_sandbags_01_nmt" -> "nmt". The suffix is the last
// underscore-separated token of the leaf, which is how these are named.
std::string suffix_of(const std::string& asset)
{
    std::string leaf = asset;
    const size_t slash = leaf.find_last_of('/');
    if (slash != std::string::npos) leaf = leaf.substr(slash + 1);
    if (leaf.size() > 4 && leaf.compare(leaf.size() - 4, 4, ".ebx") == 0)
        leaf.resize(leaf.size() - 4);
    const size_t us = leaf.find_last_of('_');
    if (us == std::string::npos) return "(none)";
    return leaf.substr(us + 1);
}

}  // namespace

int main(int argc, char** argv)
{
    if (argc < 3)
    {
        std::fprintf(stderr, "usage: slots_test <game_dir> <level> [max_depots]\n");
        return 2;
    }
    const int limit = argc > 3 ? std::atoi(argv[3]) : 4000;

    Source src;
    std::string err;
    if (!src.open(argv[1], err)) { std::fprintf(stderr, "open: %s\n", err.c_str()); return 1; }
    std::fprintf(stderr, "mounting...\n");
    if (!src.mount_level(argv[2], false, err)) { std::fprintf(stderr, "mount: %s\n", err.c_str()); return 1; }

    std::fprintf(stderr, "indexing partitions (this is the slow part)...\n");
    const auto t0 = std::chrono::steady_clock::now();
    const std::map<std::string, std::string>& gi = src.partition_index();
    std::fprintf(stderr, "  %zu partitions indexed in %.0f s\n", gi.size(),
        std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count());

    std::vector<std::string> depots;
    for (const auto& kv : src.res())
        if (kv.first.find("shaderblockdepot") != std::string::npos) depots.push_back(kv.first);
    std::sort(depots.begin(), depots.end());

    // slot hash -> suffix -> count, plus one example asset for the report.
    std::map<uint32_t, std::map<std::string, int>> by_slot;
    std::map<uint32_t, std::string> example;
    std::map<uint32_t, int> defaults, total;
    uint64_t bound = 0, resolved = 0;

    for (size_t i = 0; i < depots.size() && (int)i < limit; i++)
    {
        std::vector<uint8_t> d = src.get_res(depots[i], err);
        if (d.empty()) continue;
        Depot dep;
        std::string e;
        if (!dep.parse(d, e)) continue;

        for (size_t r = 0; r < dep.record_count(); r++)
        {
            std::vector<DepotParam> ps;
            if (!dep.params(r, d, ps, e)) continue;
            for (const DepotParam& p : ps)
            {
                if (p.refs.empty()) continue;
                bound++;
                // The FILE guid is the second of the pair; the first is the
                // root instance and resolves to nothing useful here.
                auto it = gi.find(p.refs[0].second);
                if (it == gi.end()) continue;
                resolved++;
                // A SLOT FILLED WITH A DEFAULT TEXTURE TELLS YOU NOTHING.
                // Plenty of bindings point at common/shaders/textures/default
                // or /debug - a placeholder standing in for a slot this
                // material does not use - and their suffix describes the
                // placeholder, not the slot. Counted separately so a slot that
                // is 100% "t_black" is reported as unused rather than named
                // "black".
                const bool is_default =
                    it->second.find("/textures/default/") != std::string::npos ||
                    it->second.find("/textures/debug/")   != std::string::npos;
                total[p.name32]++;
                if (is_default) { defaults[p.name32]++; continue; }

                const std::string sfx = suffix_of(it->second);
                by_slot[p.name32][sfx]++;
                if (!example.count(p.name32)) example[p.name32] = it->second;
            }
        }
    }

    std::fprintf(stderr, "%llu bindings, %llu resolved to an asset name (%.1f%%)\n",
        (unsigned long long)bound, (unsigned long long)resolved,
        bound ? 100.0 * (double)resolved / (double)bound : 0.0);

    // Ordered by how much of the map each slot actually carries.
    std::vector<std::pair<int, uint32_t>> order;
    for (const auto& kv : by_slot)
    {
        int n = 0;
        for (const auto& s : kv.second) n += s.second;
        order.emplace_back(n, kv.first);
    }
    std::sort(order.rbegin(), order.rend());

    std::printf("%-12s %-7s %-7s %-7s %-9s %-14s %s\n",
                "slot", "real", "share", "deflt", "known", "suffix", "example");
    for (const auto& o : order)
    {
        const uint32_t hash = o.second;
        const auto& sfx = by_slot[hash];
        std::string best;
        int bestn = 0;
        for (const auto& s : sfx) if (s.second > bestn) { bestn = s.second; best = s.first; }
        const double share = 100.0 * (double)bestn / (double)o.first;

        // Named only when the evidence says so. Anything thin or split is
        // reported as unclear rather than written down as fact.
        const bool confident = o.first >= 20 && share >= 80.0;
        const char* known = Depot::slot_name(hash);
        const int def = defaults[hash];
        std::printf("0x%08x %-7d %5.1f%% %-7d %-9s %-14s %s\n",
                    hash, o.first, share, def,
                    known ? known : (confident ? "-> NEW" : "unclear"),
                    best.c_str(), example[hash].c_str());
    }
    return 0;
}
