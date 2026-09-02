/* Runtime proof for the large water-surface input.
 *
 * Reads block 0 and block 2 directly from the mounted Steam install.  The
 * half-map shuffled ground pairing is the control: it is reported beside the
 * real world-coordinate pairing and is never used as a runtime oracle.
 */
#include "bf6_core.h"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <vector>

static double sample(const bf6_terrain* t, double x, double z)
{
    if (!t || t->width < 2 || t->height < 2) return NAN;
    const double u = (x - t->world_min[0]) /
                     (t->world_max[0] - t->world_min[0]);
    const double v = (z - t->world_min[2]) /
                     (t->world_max[2] - t->world_min[2]);
    if (u < 0.0 || u > 1.0 || v < 0.0 || v > 1.0) return NAN;
    const int ix = std::clamp((int)std::llround(u * (t->width - 1)), 0, t->width - 1);
    const int iz = std::clamp((int)std::llround(v * (t->height - 1)), 0, t->height - 1);
    // Height samples in both terrain blocks are absolute through zero.  The
    // AABB Y minimum is a coverage bound, not a quantisation bias.
    return t->heights[(size_t)iz * t->width + ix] *
           ((double)t->height_scale / 65536.0);
}

int main(int argc, char** argv)
{
    if (argc < 3) {
        std::printf("usage: waterheightfield_test <game_dir> <level>\n");
        return 2;
    }
    char err[512] = {};
    bf6_ctx* ctx = bf6_open(argv[1], err, sizeof(err));
    if (!ctx) { std::printf("open failed: %s\n", err); return 1; }
    if (bf6_open_level(ctx, argv[2], nullptr, 0, err, sizeof(err)) != 0) {
        std::printf("open_level failed: %s\n", err); bf6_close(ctx); return 1;
    }

    bf6_terrain* ground = bf6_read_terrain(ctx, argv[2]);
    bf6_terrain* water = bf6_read_water_heightfield(ctx, argv[2]);
    bf6_terrain* fake = bf6_read_water_heightfield(ctx, "__missing_level_control__");
    if (!ground || !water) {
        std::printf("RESULT fail: ground=%p water=%p\n", (void*)ground, (void*)water);
        if (ground) bf6_free(ctx, ground);
        if (water) bf6_free(ctx, water);
        bf6_close(ctx);
        return 1;
    }

    double hmin = 1e30, hmax = -1e30;
    for (int z = 0; z < water->height; z += std::max(1, water->height / 1024))
        for (int x = 0; x < water->width; x += std::max(1, water->width / 1024)) {
            const double h = water->heights[(size_t)z * water->width + x] *
                             ((double)water->height_scale / 65536.0);
            hmin = std::min(hmin, h); hmax = std::max(hmax, h);
        }

    const int N = 512;
    long long real_wet = 0, shuffled_wet = 0, valid = 0;
    const double span_x = water->world_max[0] - water->world_min[0];
    for (int z = 0; z < N; ++z) for (int x = 0; x < N; ++x) {
        const double wx = water->world_min[0] + (x + .5) / N * span_x;
        const double wz = water->world_min[2] + (z + .5) / N *
                          (water->world_max[2] - water->world_min[2]);
        const double wh = sample(water, wx, wz);
        const double gh = sample(ground, wx, wz);
        double sx = wx + span_x * .5;
        if (sx > water->world_max[0]) sx -= span_x;
        const double shuffled = sample(ground, sx, wz);
        if (!std::isfinite(wh) || !std::isfinite(gh) || !std::isfinite(shuffled)) continue;
        valid++;
        real_wet += wh > gh + .02;
        shuffled_wet += wh > shuffled + .02;
    }

    std::printf("real block2: %dx%d absolute-Y %.3f..%.3f m (span %.3f m)\n",
                water->width, water->height, hmin, hmax, hmax - hmin);
    std::printf("real world pairing wet: %.3f%%\n",
                valid ? 100.0 * real_wet / valid : 0.0);
    std::printf("control half-map shuffled pairing wet: %.3f%%\n",
                valid ? 100.0 * shuffled_wet / valid : 0.0);
    std::printf("control fake level returned: %s\n", fake ? "NON-NULL" : "null");

    bf6_water surfaces[32] = {};
    const int surface_count = bf6_level_water(ctx, argv[2], surfaces, 32);
    double patch_min = 1e30, patch_max = -1e30, patch_center = NAN;
    for (int i = 0; i < std::min(surface_count, 32); ++i) {
        if (!surfaces[i].is_ocean) continue;
        patch_center = sample(water, surfaces[i].center[0], surfaces[i].center[1]);
        for (int z = 0; z < 129; ++z) for (int x = 0; x < 129; ++x) {
            const double wx = surfaces[i].center[0] - 64.0 + x;
            const double wz = surfaces[i].center[1] - 64.0 + z;
            const double h = sample(water, wx, wz);
            if (!std::isfinite(h) || h <= 0.0) continue;
            patch_min = std::min(patch_min, h); patch_max = std::max(patch_max, h);
        }
        std::printf("ocean entity: center (%.3f, %.3f), flatY %.3f m; "
                    "block2 center %.3f m; lab128 positive %.3f..%.3f m\n",
                    surfaces[i].center[0], surfaces[i].center[1], surfaces[i].height,
                    patch_center, patch_min == 1e30 ? 0.0 : patch_min,
                    patch_max == -1e30 ? 0.0 : patch_max);
        double matched_min = 1e30, matched_max = -1e30;
        for (int z = 0; z < 129; ++z) for (int x = 0; x < 129; ++x) {
            const double h = sample(water, -1020.1 - 64.0 + x, 178.1 - 64.0 + z);
            if (!std::isfinite(h) || h <= 0.0) continue;
            matched_min = std::min(matched_min, h); matched_max = std::max(matched_max, h);
        }
        std::printf("matched Tsuru overlook (-1020.1,178.1) lab128 positive %.3f..%.3f m\n",
                    matched_min == 1e30 ? 0.0 : matched_min,
                    matched_max == -1e30 ? 0.0 : matched_max);
        patch_min = matched_min; patch_max = matched_max;

        double best_range = -1.0, best_x = 0.0, best_z = 0.0;
        double best_min = 0.0, best_max = 0.0;
        const double x0s = surfaces[i].center[0] - surfaces[i].size[0] * .5;
        const double x1s = surfaces[i].center[0] + surfaces[i].size[0] * .5;
        const double z0s = surfaces[i].center[1] - surfaces[i].size[1] * .5;
        const double z1s = surfaces[i].center[1] + surfaces[i].size[1] * .5;
        for (double cz = z0s + 64; cz <= z1s - 64; cz += 32)
            for (double cx = x0s + 64; cx <= x1s - 64; cx += 32) {
                double lo = 1e30, hi = -1e30;
                for (int dz : {-64, -32, 0, 32, 64})
                    for (int dx : {-64, -32, 0, 32, 64}) {
                        const double h = sample(water, cx + dx, cz + dz);
                        if (!std::isfinite(h) || h <= 0.0) continue;
                        lo = std::min(lo, h); hi = std::max(hi, h);
                    }
                if (lo == 1e30 || hi - lo <= best_range) continue;
                best_range = hi - lo; best_x = cx; best_z = cz;
                best_min = lo; best_max = hi;
            }
        std::printf("control/diagnostic most-varying lab128 center (%.3f,%.3f): "
                    "%.3f..%.3f m (range %.3f m)\n",
                    best_x, best_z, best_min, best_max, best_range);
        break;
    }

    const bool patch_ok = std::isfinite(patch_center) && patch_center > 0.0;
    const bool pass = valid > N * N / 2 && hmax - hmin > 0.5 &&
                      fake == nullptr && patch_ok;
    std::printf("RESULT %s\n", pass ? "pass" : "fail");
    if (fake) bf6_free(ctx, fake);
    bf6_free(ctx, water);
    bf6_free(ctx, ground);
    bf6_close(ctx);
    return pass ? 0 : 1;
}
