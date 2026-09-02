/* gpcensus_test - instance-level EBX type census over a PATH FAMILY, game-wide.
 *
 * WHY THIS EXISTS. data/level_type_census.tsv censuses the 28 level
 * directories, and that is the right scope for a map rebuild. It is the WRONG
 * scope for gameplay logic: a game mode, an activity, a bot behaviour and a
 * network registry are not authored under a level. Censusing gameplay with a
 * level-scoped table therefore reports "this system ships almost nothing",
 * which is an artifact of where the table looked, not a fact about the game.
 *
 * Method is deliberately the SAME as the level census so the two are
 * comparable: parse the partition, walk its instances, take each instance's
 * type GUID from the partition's own type table. Names are NOT resolved here -
 * this prints GUIDs and the join to names happens in the research repo, which
 * is where the name tables live.
 *
 *   gpcensus_test <game_dir> <substring> [--max N] [--paths] [--nolevels]
 */
#include "source.h"
#include "types.h"
#include "ebx.h"
#include <cstdio>
#include <cstring>
#include <cstdlib>
#include <algorithm>
#include <map>
#include <string>
#include <vector>
using namespace bf6;

int main(int argc, char** argv)
{
    if (argc < 3) { std::printf("usage: gpcensus_test <game> <substring> [--max N] [--paths] [--nolevels]\n"); return 2; }
    const char* game = argv[1];
    const std::string q = argv[2];
    int maxp = 0, paths_only = 0, levels = 1, names_only = 0, per_part = 0;
    for (int i = 3; i < argc; i++) {
        if (!std::strcmp(argv[i], "--max") && i + 1 < argc) maxp = std::atoi(argv[++i]);
        else if (!std::strcmp(argv[i], "--paths")) paths_only = 1;
        else if (!std::strcmp(argv[i], "--names")) names_only = 1;
        else if (!std::strcmp(argv[i], "--per-partition")) per_part = 1;
        else if (!std::strcmp(argv[i], "--nolevels")) levels = 0;
    }

    Source src; std::string err;
    if (!src.open(game, err)) { std::printf("open: %s\n", err.c_str()); return 1; }
    if (!src.mount_level("", levels != 0, err)) { std::printf("mount: %s\n", err.c_str()); return 1; }

    /* names first, so the walk order is stable rather than hash order */
    std::vector<std::string> hits;
    for (const auto& kv : src.ebx())
        if (kv.first.find(q) != std::string::npos) hits.push_back(kv.first);
    std::sort(hits.begin(), hits.end());
    std::printf("# mounted ebx %zu   matching \"%s\": %zu\n", src.ebx_count(), q.c_str(), hits.size());

    if (names_only) {
        for (const std::string& n : hits) std::printf("%s\n", n.c_str());
        return 0;
    }

    if (paths_only) {
        std::map<std::string,int> fam;
        for (const std::string& n : hits) {
            size_t a = n.find('/'); size_t b = (a==std::string::npos)?a:n.find('/', a+1);
            size_t c = (b==std::string::npos)?b:n.find('/', b+1);
            fam[n.substr(0, c==std::string::npos?n.size():c)]++;
        }
        std::vector<std::pair<int,std::string>> v;
        for (const auto& kv : fam) v.push_back({kv.second, kv.first});
        std::sort(v.rbegin(), v.rend());
        for (size_t i = 0; i < v.size() && i < 60; i++)
            std::printf("%8d  %s\n", v[i].first, v[i].second.c_str());
        return 0;
    }

    /* THE TYPE DB IS BORROWED BY EVERY PARTITION. It holds the executable; one
     * instance per walk, never one per file. */
    TypeDb types;
    const std::vector<std::string> exes = TypeDb::exe_candidates(game);
    bool got = false;
    for (const std::string& e : exes) { std::string te; if (types.open(e, te)) { got = true; break; } }
    if (!got) { std::printf("no usable executable type db\n"); return 1; }

    std::map<std::string, std::pair<long,int>> census;   /* guid -> (instances, partitions) */
    long total_inst = 0; int parsed = 0, failed = 0;
    for (const std::string& n : hits) {
        if (maxp && parsed >= maxp) break;
        std::string e;
        std::vector<uint8_t> b = src.get_ebx(n, e);
        if (b.empty()) { failed++; continue; }
        Ebx x(types);
        if (!x.parse(std::move(b), e)) { failed++; continue; }
        parsed++;
        std::map<std::string,int> here;
        for (size_t i = 0; i < x.instance_count(); i++) { here[TypeDb::guid_str(x.instance_type(i))]++; total_inst++; }
        for (const auto& kv : here) { census[kv.first].first += kv.second; census[kv.first].second += 1; }
        if (per_part) for (const auto& kv : here)
            std::printf("P\t%s\t%s\t%d\n", n.c_str(), kv.first.c_str(), kv.second);
    }
    std::printf("# partitions parsed %d  failed %d  instances %ld  distinct types %zu\n",
                parsed, failed, total_inst, census.size());
    std::vector<std::pair<long,std::pair<std::string,int>>> v;
    for (const auto& kv : census) v.push_back({kv.second.first, {kv.first, kv.second.second}});
    std::sort(v.rbegin(), v.rend());
    std::printf("type_guid\tinstances\tpartitions\n");
    for (const auto& r : v) std::printf("%s\t%ld\t%d\n", r.second.first.c_str(), r.first, r.second.second);
    return parsed > 0 ? 0 : 1;
}
