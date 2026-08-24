/* water_test - the level's water planes and mined colours over the public ABI.
 *
 *   water_test <game_dir> <level>
 */
#include <cstdio>
#include <vector>
#include "bf6_core.h"

int main(int argc, char** argv)
{
    if (argc < 3) { std::printf("usage: water_test <game_dir> <level>\n"); return 2; }
    char err[512] = {0};
    bf6_ctx* ctx = bf6_open(argv[1], err, sizeof(err));
    if (!ctx) { std::printf("open: %s\n", err); return 1; }
    if (bf6_open_level(ctx, argv[2], nullptr, 0, err, sizeof(err)) != 0) {
        std::printf("open_level: %s\n", err); bf6_close(ctx); return 1;
    }
    const int n = bf6_level_water(ctx, argv[2], nullptr, 0);
    std::printf("%d water surface(s)\n", n);
    if (n > 0) {
        std::vector<bf6_water> w(n);
        bf6_level_water(ctx, argv[2], w.data(), n);
        for (int i = 0; i < n; i++) {
            const bf6_water& s = w[i];
            std::printf("  #%d %s at y %.1f, %.0f x %.0f m at (%.0f, %.0f)",
                i, s.is_ocean ? "ocean" : "water", s.height,
                s.size[0], s.size[1], s.center[0], s.center[1]);
            if (s.shallow[0] >= 0.f)
                std::printf("  shallow %.3f %.3f %.3f", s.shallow[0], s.shallow[1], s.shallow[2]);
            std::printf("  tex detail=%d foamN=%d foamRGB=%d noise=%d perlin=%d", 
                s.detail_normal, s.foam_normal, s.foam_rgb, s.noise, s.perlin);
            if (s.deep[0] >= 0.f)
                std::printf("  deep %.3f %.3f %.3f", s.deep[0], s.deep[1], s.deep[2]);
            std::printf("\n");
        }
    }
    bf6_water_sim sim{};
    if (bf6_level_water_sim(ctx, argv[2], &sim))
    {
        std::printf("sim: %s  angle %.3f  speed %.3f  chop %.3f  tile %.3f  minwl %.3f  lwr %.1f  foam %.1f/%.2f  %d point(s)\n",
            sim.enabled ? "flagged" : "first", sim.wind_angle, sim.wind_speed,
            sim.choppiness, sim.tile_dimension, sim.min_wavelength,
            sim.large_wave_reduction, sim.foam_threshold, sim.foam_max, sim.dist_count);
        for (int i = 0; i < sim.dist_count; i++)
            std::printf("  pt %2d  x %.4f  y %.4f\n", i, sim.dist_x[i], sim.dist_y[i]);
    }
    else std::printf("sim: none\n");

    bf6_close(ctx);
    return 0;
}
