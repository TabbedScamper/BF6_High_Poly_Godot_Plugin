// How deep can you actually see, according to the level's own data?
//
// The Unreal add-on formerly derived its extinction from a HEURISTIC: it took
// the authored colour as a hue plus a brightness and pushed those through two
// hardcoded per-metre constants. The decode says the authored
// colour is not a colour at all - on the ocean family it is a per-metre
// TRANSMISSION, what the water reaches after absorption_distance_m metres -
// and it hands back the extinction directly.
//
// This prints both, as a visible depth rather than as a coefficient, because
// "0.00208 per centimetre" means nothing to anyone and "you can see 3 m" does.
#include "bf6_core.h"
#include <cstdio>
#include <cmath>
#include <vector>

static float half_depth(float ext_per_m)
{
    return ext_per_m > 1e-9f ? 0.6931472f / ext_per_m : 1e9f;
}

// The discarded add-on heuristic, retained as a negative control so the two
// can be compared on the same level without rebuilding the editor.
static void heuristic(const float c[3], float out_ext_per_m[3])
{
    float mx = c[0] > c[1] ? c[0] : c[1];
    if (c[2] > mx) mx = c[2];
    const float bright = mx > 1e-6f ? mx : 1e-6f;
    float hue[3] = { c[0] / bright, c[1] / bright, c[2] / bright };
    const float sat[3] = { hue[0] * hue[0], hue[1] * hue[1], hue[2] * hue[2] };
    // The historical constants from the heuristic being controlled.
    const float ScatterPerM = 0.22f, AbsorbPerM = 0.20f;
    for (int k = 0; k < 3; k++)
    {
        const float scat = sat[k] * bright * ScatterPerM;
        const float abso = (1.f - hue[k]) * AbsorbPerM + 0.02f;
        out_ext_per_m[k] = scat + abso;
    }
}

int main(int argc, char** argv)
{
    if (argc < 3) { std::printf("usage: waterdepthcmp_test <game_dir> <level> [exe]\n"); return 2; }
    char err[512] = { 0 };
    bf6_ctx* c = bf6_open(argv[1], err, (int)sizeof(err));
    if (!c) { std::printf("open failed: %s\n", err); return 1; }
    if (bf6_open_level(c, argv[2], argc > 3 ? argv[3] : nullptr, 0,
                       err, (int)sizeof(err)) != 0)
        std::printf("note: open_level said %s; continuing on the mount alone\n", err);

    const int n = bf6_level_water_render(c, argv[2], nullptr, 0);
    if (n <= 0) { std::printf("%s: no water surfaces (%d)\n", argv[2], n); return 0; }
    std::vector<bf6_water_render> w((size_t)n);
    const int got = bf6_level_water_render(c, argv[2], w.data(), n);

    for (int i = 0; i < got; i++)
    {
        const bf6_water_render& s = w[(size_t)i];
        std::printf("\n%s surface %d: variant %d (%s), river %d, attenuation %d\n",
                    argv[2], i, s.variant,
                    s.variant == 1 ? "ocean" : s.variant == 0 ? "foam" : "region-banded",
                    s.is_river, s.attenuation_type);
        std::printf("  plane %.1f x %.1f m at y %.2f\n", s.size[0], s.size[1], s.height);
        std::printf("  authored base colour   (%.4f %.4f %.4f)\n",
                    s.base_colour[0], s.base_colour[1], s.base_colour[2]);
        std::printf("  absorption distance    %.3f m\n", s.absorption_distance_m);
        std::printf("  shore                   valid %d enable %d depth %.3f m "
                    "blend (%.3f %.3f %.3f %.3f) suppress %.3f\n",
                    s.shore_fade_valid, s.shore_enable, s.shore_depth_m,
                    s.shore_blend[0], s.shore_blend[1],
                    s.shore_blend[2], s.shore_blend[3],
                    s.shore_foam_suppression);
        std::printf("  foam/detail             threshold %.3f contrast %.3f "
                    "cascade (%.3f %.3f %.3f %.3f), detail %.1f..%.1f m\n",
                    s.foam_threshold, s.foam_contrast_divisor,
                    s.cascade_foam_weight[0], s.cascade_foam_weight[1],
                    s.cascade_foam_weight[2], s.cascade_foam_weight[3],
                    s.detail_fade_start_m, s.detail_fade_end_m);
        std::printf("  reflectance             low %.4f high %.4f bias %.3f\n",
                    s.reflectance_low, s.reflectance_high, s.reflectance_bias);
        std::printf("  DERIVED surface colour (%.4f %.4f %.4f)\n",
                    s.surface_colour[0], s.surface_colour[1], s.surface_colour[2]);

        const bool have = s.extinction[0] >= 0.f;
        if (have)
        {
            std::printf("  DERIVED extinction /m  (%.5f %.5f %.5f)\n",
                        s.extinction[0], s.extinction[1], s.extinction[2]);
            std::printf("    -> half-transmittance depth  R %.2f m  G %.2f m  B %.2f m\n",
                        half_depth(s.extinction[0]), half_depth(s.extinction[1]),
                        half_depth(s.extinction[2]));
            // The depth at which the green channel is down to a tenth, which is
            // about where a sandy bottom stops being readable.
            std::printf("    -> green down to 10%%ular at %.2f m\n",
                        s.extinction[1] > 1e-9f ? 2.302585f / s.extinction[1] : 0.f);
        }
        else
        {
            std::printf("  DERIVED extinction     absent on this family\n");
        }

        float h[3];
        heuristic(s.base_colour, h);
        std::printf("  discarded HEURISTIC    (%.5f %.5f %.5f)\n", h[0], h[1], h[2]);
        std::printf("    -> half-transmittance depth  R %.2f m  G %.2f m  B %.2f m\n",
                    half_depth(h[0]), half_depth(h[1]), half_depth(h[2]));
        if (have && s.extinction[1] > 1e-9f)
            std::printf("  RATIO green: heuristic is %.2fx the decoded extinction, "
                        "so it sees %.2fx less deep\n",
                        h[1] / s.extinction[1], h[1] / s.extinction[1]);
    }
    bf6_close(c);
    return 0;
}
