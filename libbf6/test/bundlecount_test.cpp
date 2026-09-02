// What does a placement's placing_bundle actually say?
#include <algorithm>
//
// The question behind this: a level ships several MUTUALLY EXCLUSIVE game-mode
// layouts and a consumer that builds them all draws four carriers where the
// game shows one. If the bundle string identifies which mode placed a row,
// filtering is free and needs no new decode.
#include "bf6_core.h"
#include <cstdio>
#include <cstring>
#include <map>
#include <set>
#include <string>
#include <vector>

int main(int argc, char** argv)
{
    if (argc < 3) { std::printf("usage: bundlecount_test <game_dir> <level> [exe]\n"); return 2; }
    char err[512] = { 0 };
    bf6_ctx* c = bf6_open(argv[1], err, (int)sizeof(err));
    if (!c) { std::printf("open failed: %s\n", err); return 1; }
    if (bf6_open_level(c, argv[2], argc > 3 ? argv[3] : nullptr, 0,
                       err, (int)sizeof(err)) != 0)
        std::printf("note: open_level said %s\n", err);

    const int n = bf6_level_instances(c, argv[2], nullptr, 0);
    if (n <= 0) { std::printf("%s: no placements (%d)\n", argv[2], n); return 1; }
    std::vector<bf6_instance> v((size_t)n);
    const int got = bf6_level_instances(c, argv[2], v.data(), n);

    std::map<std::string, int> byBundle;
    std::set<std::string> meshes, meshBundles;
    int empty = 0;
    for (int i = 0; i < got; i++)
    {
        const char* b = v[(size_t)i].placing_bundle;
        const char* m = v[(size_t)i].res_name;
        if (m && *m)
        {
            meshes.insert(m);
            meshBundles.insert(std::string(m) + "|" + (b ? b : ""));
        }
        if (!b || !*b) { empty++; continue; }
        byBundle[b]++;
    }
    std::printf("%s: %d placements, %d distinct bundles, %d with none\n",
                argv[2], got, (int)byBundle.size(), empty);
    std::printf("  distinct meshes %d; exact mesh+bundle scopes %d (x%.2f)\n",
                (int)meshes.size(), (int)meshBundles.size(),
                meshes.empty() ? 0.0 : (double)meshBundles.size() / meshes.size());

    std::vector<std::pair<int, std::string>> rows;
    for (const auto& kv : byBundle) rows.push_back({ kv.second, kv.first });
    std::sort(rows.begin(), rows.end(),
              [](const std::pair<int, std::string>& a,
                 const std::pair<int, std::string>& b) { return a.first > b.first; });

    std::printf("\ntop bundles by placement count:\n");
    for (size_t i = 0; i < rows.size() && i < 16; i++)
        std::printf("  %7d  %s\n", rows[i].first, rows[i].second.c_str());

    // The question that decides whether a filter is possible at all.
    int gameplay = 0;
    std::printf("\nbundles whose name contains \"gameplay\":\n");
    for (const auto& r : rows)
        if (r.second.find("gameplay") != std::string::npos)
        { std::printf("  %7d  %s\n", r.first, r.second.c_str()); gameplay += r.first; }
    std::printf("  -> %d placements (%.1f%% of the level)\n",
                gameplay, got ? 100.0 * gameplay / got : 0.0);

    bf6_close(c);
    return 0;
}
