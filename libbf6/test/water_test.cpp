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
            if (s.deep[0] >= 0.f)
                std::printf("  deep %.3f %.3f %.3f", s.deep[0], s.deep[1], s.deep[2]);
            std::printf("\n");
        }
    }
    bf6_close(ctx);
    return 0;
}
