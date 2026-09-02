// What is placed near a point? Answers "what am I looking at" from the data
// rather than from the outliner, and reports the bundle so a game-mode layer
// is visible as such.
#include "bf6_core.h"
#include <cstdio>
#include <cstring>
#include <cmath>
#include <map>
#include <string>
#include <vector>
#include <algorithm>

int main(int argc, char** argv)
{
    if (argc < 6)
    {
        std::printf("usage: vicinity_test <game_dir> <level> <x> <z> <radius_m> [asset_substring] [exe]\n");
        return 2;
    }
    const float CX = (float)atof(argv[3]);
    const float CZ = (float)atof(argv[4]);
    const float R  = (float)atof(argv[5]);

    char err[512] = { 0 };
    bf6_ctx* c = bf6_open(argv[1], err, (int)sizeof(err));
    if (!c) { std::printf("open failed: %s\n", err); return 1; }
    const char* filter = argc > 6 ? argv[6] : "";
    if (bf6_open_level(c, argv[2], argc > 7 ? argv[7] : nullptr, 0,
                       err, (int)sizeof(err)) != 0)
        std::printf("note: open_level said %s\n", err);

    const int n = bf6_level_instances(c, argv[2], nullptr, 0);
    if (n <= 0) { std::printf("no placements (%d)\n", n); return 1; }
    std::vector<bf6_instance> v((size_t)n);
    const int got = bf6_level_instances(c, argv[2], v.data(), n);

    struct Row { float d; std::string mesh, bundle, variation; float x, y, z; };
    std::vector<Row> hits;
    for (int i = 0; i < got; i++)
    {
        const bf6_instance& s = v[(size_t)i];
        const char* mesh = s.res_name ? s.res_name : "";
        if (*filter && !std::strstr(mesh, filter)) continue;
        // xform is 3x4 row-major, row 3 is the translation, in metres.
        const float x = s.xform[9], y = s.xform[10], z = s.xform[11];
        const float d = std::sqrt((x - CX) * (x - CX) + (z - CZ) * (z - CZ));
        if (d > R) continue;
        hits.push_back({ d, mesh,
                         s.placing_bundle ? s.placing_bundle : "",
                         s.variation ? s.variation : "", x, y, z });
    }
    std::sort(hits.begin(), hits.end(),
              [](const Row& a, const Row& b) { return a.d < b.d; });

    std::printf("\n%d placement(s) within %.0f m of (x %.1f, z %.1f)\n",
                (int)hits.size(), R, CX, CZ);

    std::map<std::string, int> byMesh, byBundle;
    for (const Row& h : hits) { byMesh[h.mesh]++; byBundle[h.bundle]++; }

    std::printf("\nnearest 20:\n");
    for (size_t i = 0; i < hits.size() && i < 20; i++)
    {
        std::string mode = "shared";
        const std::string marker = "_layers_gameplay/";
        const size_t at = hits[i].bundle.rfind(marker);
        if (at != std::string::npos)
        {
            mode = hits[i].bundle.substr(at + marker.size());
            const size_t slash = mode.find('/');
            if (slash != std::string::npos) mode.resize(slash);
        }
        std::printf("  %6.1f m  xyz (%8.1f %7.1f %8.1f)  %-35s  %s  variation=%s\n",
                    hits[i].d, hits[i].x, hits[i].y, hits[i].z,
                    mode.c_str(), hits[i].mesh.c_str(), hits[i].variation.c_str());
    }

    std::vector<std::pair<int, std::string>> m;
    for (const auto& kv : byMesh) m.push_back({ kv.second, kv.first });
    std::sort(m.begin(), m.end(), [](const std::pair<int, std::string>& a,
                                     const std::pair<int, std::string>& b)
              { return a.first > b.first; });
    std::printf("\nby asset (top 20 of %d distinct):\n", (int)byMesh.size());
    for (size_t i = 0; i < m.size() && i < 20; i++)
        std::printf("  %5d  %s\n", m[i].first, m[i].second.c_str());

    std::printf("\nby placing bundle:\n");
    for (const auto& kv : byBundle)
        std::printf("  %5d  %s\n", kv.second, kv.first.c_str());

    bf6_close(c);
    return 0;
}
