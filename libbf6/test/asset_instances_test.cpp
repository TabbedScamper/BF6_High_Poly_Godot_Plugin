/* Controlled C-ABI test for direct asset placement traversal.
 * Reads the mounted game at runtime; no exported placement data is consumed. */
#include "bf6_core.h"

#include <cstdio>
#include <cstring>
#include <algorithm>
#include <cmath>
#include <cstdlib>
#include <string>
#include <vector>

int main(int argc, char** argv)
{
    if (argc != 4 && argc != 7) {
        std::fprintf(stderr, "usage: asset_instances_test <game_dir> <asset> <expected-source> [x z radius]\n");
        return 2;
    }
    char err[512] = {};
    bf6_ctx* c = bf6_open(argv[1], err, (int)sizeof(err));
    if (!c) { std::fprintf(stderr, "open: %s\n", err); return 1; }
    if (!bf6_mount_all(c, 1, err, (int)sizeof(err))) {
        std::fprintf(stderr, "mount: %s\n", err); bf6_close(c); return 1;
    }

    const int n = bf6_asset_instances(c, argv[2], nullptr, 0, err, (int)sizeof(err));
    if (n <= 0) {
        std::fprintf(stderr, "walk: %s\n", err[0] ? err : "no placements");
        bf6_close(c); return 1;
    }
    std::vector<bf6_instance> rows((size_t)n);
    if (bf6_asset_instances(c, argv[2], rows.data(), n, err, (int)sizeof(err)) != n) {
        std::fprintf(stderr, "second read changed count\n"); bf6_close(c); return 1;
    }

    int real = 0, fake = 0;
    for (const bf6_instance& r : rows) {
        if ((std::strcmp(argv[3], "*") == 0) ||
            (r.source && std::strstr(r.source, argv[3]) != nullptr) ||
            (r.res_name && std::strstr(r.res_name, argv[3]) != nullptr)) {
            real++;
            if (real <= 32)
                std::printf("match (%8.2f %7.2f %8.2f) res=%s source=%s\n",
                    r.xform[9], r.xform[10], r.xform[11],
                    r.res_name ? r.res_name : "", r.source ? r.source : "");
        }
        if (r.source && std::strcmp(r.source, "control/not/a/real/source") == 0) fake++;
    }
    std::printf("rows=%d expected_source=%d shuffled_control=%d\n", n, real, fake);
    if (argc == 7) {
        const float cx = (float)std::atof(argv[4]), cz = (float)std::atof(argv[5]);
        const float radius = (float)std::atof(argv[6]);
        struct Hit { float d; const bf6_instance* p; };
        std::vector<Hit> hits;
        for (const bf6_instance& p : rows) {
            const float dx = p.xform[9] - cx, dz = p.xform[11] - cz;
            const float d = std::sqrt(dx*dx + dz*dz);
            if (d <= radius) hits.push_back({d, &p});
        }
        std::sort(hits.begin(), hits.end(), [](const Hit& a, const Hit& b) { return a.d < b.d; });
        std::printf("within %.1fm=%zu\n", radius, hits.size());
        for (size_t i = 0; i < hits.size() && i < 100; ++i) {
            const bf6_instance& p = *hits[i].p;
            std::printf("  %7.2f  (%8.2f %7.2f %8.2f)  %s  source=%s\n",
                hits[i].d, p.xform[9], p.xform[10], p.xform[11],
                p.res_name ? p.res_name : "", p.source ? p.source : "");
        }
    }
    bf6_close(c);
    return real > 0 && fake == 0 ? 0 : 1;
}
