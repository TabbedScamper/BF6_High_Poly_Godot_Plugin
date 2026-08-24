/* groundcov_test - the per-pixel ground path: coverage plus a material list.
 *
 *   groundcov_test <game_dir> <level> [size]
 */
#include <cstdio>
#include <vector>
#include "bf6_core.h"

int main(int argc, char** argv)
{
    if (argc < 3) { std::printf("usage: groundcov_test <game_dir> <level> [size]\n"); return 2; }
    const int size = argc > 3 ? std::atoi(argv[3]) : 2048;
    char err[512] = {0};
    bf6_ctx* ctx = bf6_open(argv[1], err, sizeof(err));
    if (!ctx) { std::printf("open: %s\n", err); return 1; }
    if (bf6_open_level(ctx, argv[2], nullptr, 0, err, sizeof(err)) != 0) {
        std::printf("open_level: %s\n", err); return 1; }

    bf6_ground_coverage g{};
    if (!bf6_ground_coverage_get(ctx, argv[2], size, &g, err, sizeof(err))) {
        std::printf("coverage: %s\n", err); return 1; }

    std::printf("%s: %d x %d over %.0f x %.0f m (%.2f m/texel)\n",
        argv[2], g.size, g.size, g.hi[0] - g.lo[0], g.hi[1] - g.lo[1],
        (g.hi[0] - g.lo[0]) / (float)g.size);
    std::printf("%d material(s), %.2f%% of texels empty\n",
        g.material_count, g.empty_fraction * 100.f);

    // how many slots a texel actually uses, which is what a shader must blend
    long long hist[5] = {0, 0, 0, 0, 0};
    for (long long i = 0; i < (long long)g.size * g.size; i++) {
        int n = 0;
        for (int s = 0; s < 4; s++) if (g.weight[i * 4 + s]) n++;
        hist[n]++;
    }
    const double tot = (double)g.size * g.size;
    std::printf("layers per texel: ");
    for (int n = 0; n < 5; n++) std::printf("%d=%.1f%% ", n, 100.0 * hist[n] / tot);
    std::printf("\n\n%-4s %-6s %-9s %s\n", "slot", "layer", "m/repeat", "albedo");
    for (int i = 0; i < g.material_count; i++) {
        const bf6_ground_material& m = g.materials[i];
        const char* a = m.albedo_res && *m.albedo_res ? m.albedo_res : "(none)";
        const char* sl = a;
        for (const char* p = a; *p; p++) if (*p == '/') sl = p + 1;
        std::printf("%-4d %-6d %-9.2f %s\n", i, m.layer, m.metres_per_repeat, sl);
    }
    bf6_close(ctx);
    return 0;
}
