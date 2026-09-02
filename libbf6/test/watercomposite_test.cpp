/* Runtime proof for the active VE -> deferred-water composite join.
 *
 * No exported table is read.  Both the real sample and controls are mounted
 * from the installed game during this process.
 */
#include <cmath>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

#include "bf6_core.h"

struct Sample {
    bool ok = false;
    bf6_water_render w{};
};

static Sample read_one(const char* game, const char* exe, const char* level)
{
    Sample s;
    char err[512] = {};
    bf6_ctx* c = bf6_open(game, err, sizeof(err));
    if (!c) {
        std::printf("OPEN_FAIL level=%s error=%s\n", level, err);
        return s;
    }
    if (bf6_open_level(c, level, exe, 0, err, sizeof(err)) != 0) {
        std::printf("LEVEL_REJECT level=%s error=%s\n", level, err);
        bf6_close(c);
        return s;
    }
    const int n = bf6_level_water_render(c, level, nullptr, 0);
    std::vector<bf6_water_render> rows(n > 0 ? (size_t)n : 0);
    const int got = n > 0
        ? bf6_level_water_render(c, level, rows.data(), n) : 0;
    if (got > 0) {
        s.w = rows[0];
        s.ok = true;
    }
    bf6_close(c);
    return s;
}

static float expected_transmission(float albedo, float distance)
{
    if (distance <= 0.01f) return albedo < 0.f ? 0.f : (albedo > 1.f ? 1.f : albedo);
    const float c = albedo > 1e-6f ? albedo : 1e-6f;
    const float v = 1.f + std::log(c) / distance;
    return v < 0.f ? 0.f : (v > 1.f ? 1.f : v);
}

int main(int argc, char** argv)
{
    if (argc < 4) {
        std::printf("usage: watercomposite_test <game_dir> <exe> <level> [control_level]\n");
        return 2;
    }
    const char* control_level = argc > 4 ? argv[4] : "mp_dumbo";
    const Sample real = read_one(argv[1], argv[2], argv[3]);
    if (!real.ok) {
        std::printf("RESULT fail=no_real_surface\n");
        return 1;
    }
    const bf6_water_render& w = real.w;
    std::printf("REAL level=%s version=%u preset=%s candidates=%d enable=%d simplified=%d "
                "foam=%d ior=%.9g opacity_ramp_m=%.9g foam_ramp_m=%.9g g=%.9g shadow=%.9g\n",
        argv[3], w.ocean_component_version, w.ocean_preset,
        w.ocean_preset_candidates, w.ocean_enable, w.simplified_distortion,
        w.foam_enable, w.composite_ior, w.opacity_ramp_m,
        w.foam_depth_ramp_m, w.scatter_phase_g,
        w.scatter_shadow_influence);
    std::printf("REAL albedo=(%.9g,%.9g,%.9g) distance=%.9g transmission=(%.9g,%.9g,%.9g) "
                "foam_tint=(%.9g,%.9g,%.9g) smoothness=%.9g roughness=%.9g\n",
        w.authored_ocean_albedo[0], w.authored_ocean_albedo[1],
        w.authored_ocean_albedo[2], w.authored_albedo_distance_m,
        w.transmission_colour[0], w.transmission_colour[1],
        w.transmission_colour[2], w.foam_tint[0], w.foam_tint[1],
        w.foam_tint[2], w.foam_smoothness, w.foam_roughness);

    int formula_pass = 0;
    float max_formula_error = 0.f;
    for (int k = 0; k < 3; ++k) {
        const float expected = expected_transmission(
            w.authored_ocean_albedo[k], w.authored_albedo_distance_m);
        const float error = std::fabs(expected - w.transmission_colour[k]);
        if (error <= 1e-6f) ++formula_pass;
        if (error > max_formula_error) max_formula_error = error;
    }
    std::printf("CONTROL formula=%d/3 max_abs_error=%.9g\n",
                formula_pass, max_formula_error);

    const Sample fake = read_one(argv[1], argv[2], "mp_not_a_real_level");
    std::printf("CONTROL fake_level_rejected=%d\n", fake.ok ? 0 : 1);

    const Sample shuffled = read_one(argv[1], argv[2], control_level);
    bool differs = false;
    if (shuffled.ok) {
        differs = std::strcmp(w.ocean_preset, shuffled.w.ocean_preset) != 0 ||
            std::fabs(w.opacity_ramp_m - shuffled.w.opacity_ramp_m) > 1e-6f ||
            std::fabs(w.scatter_phase_g - shuffled.w.scatter_phase_g) > 1e-6f ||
            std::fabs(w.authored_albedo_distance_m -
                      shuffled.w.authored_albedo_distance_m) > 1e-6f;
        std::printf("CONTROL shuffled_level=%s resolved=%d differs=%d preset=%s "
                    "opacity_ramp_m=%.9g g=%.9g albedo_distance_m=%.9g\n",
            control_level, shuffled.ok ? 1 : 0, differs ? 1 : 0,
            shuffled.w.ocean_preset, shuffled.w.opacity_ramp_m,
            shuffled.w.scatter_phase_g,
            shuffled.w.authored_albedo_distance_m);
    } else {
        std::printf("CONTROL shuffled_level=%s resolved=0 differs=0\n", control_level);
    }

    const bool pass = w.ocean_component_version == 1 &&
        w.ocean_preset[0] != '\0' && formula_pass == 3 && !fake.ok &&
        shuffled.ok && differs;
    std::printf("RESULT %s\n", pass ? "pass" : "fail");
    return pass ? 0 : 1;
}
