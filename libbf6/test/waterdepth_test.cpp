/* waterdepth_test - how deep is a level's water, actually?
 *
 *   waterdepth_test <game_dir> <level>
 *
 * WHY. A renderer can argue forever about whether water is "see through"
 * without anyone establishing how much water there is to see through. Beer
 * Lambert absorption that is correct at one metre is correctly opaque at
 * twenty, so the honest first question is the DEPTH DISTRIBUTION over the
 * surface: if a level's water is nowhere shallow, a shoreline clarity ramp has
 * nothing to act on and the fault is elsewhere.
 *
 * Reads the level's water surfaces and its heightfield and reports, over the
 * area each surface covers, the histogram of (water height - ground height).
 */
#include <cstdio>
#include <vector>
#include "bf6_core.h"

int main(int argc, char** argv)
{
    if (argc < 3) { std::printf("usage: waterdepth_test <game_dir> <level>\n"); return 2; }
    char err[512] = {0};
    bf6_ctx* ctx = bf6_open(argv[1], err, sizeof(err));
    if (!ctx) { std::printf("open: %s\n", err); return 1; }
    if (bf6_open_level(ctx, argv[2], nullptr, 0, err, sizeof(err)) != 0)
        std::printf("note: open_level said %s; continuing on the mount\n", err);

    bf6_water w[16];
    const int nw = bf6_level_water(ctx, argv[2], w, 16);
    if (nw <= 0) { std::printf("%s: no water\n", argv[2]); return 0; }

    bf6_terrain* t = bf6_read_terrain(ctx, argv[2]);
    if (!t || t->width <= 1) { std::printf("%s: no heightfield\n", argv[2]); return 1; }

    const double yscale = t->height_scale > 0.f
        ? (double)t->height_scale / 65536.0
        : 1.0;
    const double x0 = t->world_min[0], z0 = t->world_min[2];
    const double sx = (t->world_max[0] - x0) / (double)(t->width - 1);
    const double sz = (t->world_max[2] - z0) / (double)(t->height - 1);

    for (int i = 0; i < nw; i++) {
        const bf6_water& s = w[i];
        std::printf("\n%s surface %d: height %.1f m, %.0f x %.0f m at (%.0f, %.0f)\n",
                    argv[2], i, s.height, s.size[0], s.size[1], s.center[0], s.center[1]);

        // Buckets a person can reason about, in metres of water.
        const double edge[] = {0.0, 0.5, 1.0, 2.0, 5.0, 10.0, 20.0, 1e9};
        const char*  name[] = {"0.0-0.5", "0.5-1", "1-2", "2-5", "5-10", "10-20", "20+"};
        long long bucket[7] = {0,0,0,0,0,0,0};
        long long dry = 0, total = 0;

        // SANITY: the heightfield itself, before any depth is believed.
        std::printf("  terrain: %d x %d, world Y %.1f..%.1f, height_scale %.1f\n",
                    t->width, t->height, t->world_min[1], t->world_max[1], t->height_scale);
        double gmin = 1e9, gmax = -1e9;

        const int N = 512;   // sample grid over the surface
        for (int gy = 0; gy < N; gy++) {
            for (int gx = 0; gx < N; gx++) {
                const double wx = s.center[0] - s.size[0] * 0.5 + s.size[0] * (gx + 0.5) / N;
                const double wz = s.center[1] - s.size[1] * 0.5 + s.size[1] * (gy + 0.5) / N;
                const int ix = (int)((wx - x0) / sx + 0.5);
                const int iz = (int)((wz - z0) / sz + 0.5);
                if (ix < 0 || iz < 0 || ix >= t->width || iz >= t->height) continue;
                const double gyh = t->heights[(size_t)iz * t->width + ix] * yscale + t->world_min[1];
                if (gyh < gmin) gmin = gyh;
                if (gyh > gmax) gmax = gyh;
                const double d = (double)s.height - gyh;
                total++;
                if (d <= 0.0) { dry++; continue; }
                for (int b = 0; b < 7; b++)
                    if (d < edge[b + 1]) { bucket[b]++; break; }
            }
        }
        if (total == 0) { std::printf("  no heightfield under it\n"); continue; }
        std::printf("  ground under the surface spans %.1f..%.1f m (water at %.1f)\n",
                    gmin, gmax, s.height);
        const long long wet = total - dry;
        std::printf("  %lld of %lld samples are under water (%.1f%%)\n",
                    wet, total, 100.0 * (double)wet / (double)total);
        for (int b = 0; b < 7; b++)
            std::printf("    %-8s m  %6.2f%% of the wet area\n",
                        name[b], wet ? 100.0 * (double)bucket[b] / (double)wet : 0.0);
    }
    bf6_free(ctx, t);
    bf6_close(ctx);
    return 0;
}
