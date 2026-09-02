/* Runtime closure check for the ocean simulation inputs and CPU H0 builder.
 *
 *   waterclosure_test <game_dir> <level> [--isolated]
 *
 * The report deliberately includes two controls: the authored curve with all
 * Hermite tangents zeroed, and the next cascade's curve paired with the real
 * scalar inputs. Neither control is an identification; their scores show
 * whether the inputs omitted by older readers materially affect H0.
 */
#include "bf6_core.h"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <vector>

static uint64_t fnv1a64(const std::vector<float>& values)
{
    uint64_t hash = 1469598103934665603ull;
    const uint8_t* bytes = reinterpret_cast<const uint8_t*>(values.data());
    for (size_t i = 0; i < values.size() * sizeof(float); ++i) {
        hash ^= bytes[i];
        hash *= 1099511628211ull;
    }
    return hash;
}

static double energy(const std::vector<float>& values)
{
    double sum = 0.0;
    for (float value : values) sum += (double)value * (double)value;
    return sum;
}

static std::vector<float> build(const bf6_water_sim_v2& sim)
{
    const int count = bf6_water_spectrum_h0(&sim, nullptr, 0);
    std::vector<float> values(count > 0 ? (size_t)count : 0);
    if (count > 0 && bf6_water_spectrum_h0(&sim, values.data(), count) != count)
        values.clear();
    return values;
}

struct Complex { float r, i; };

static Complex mul(const Complex& a, float c, float s)
{
    return {a.r * c - a.i * s, a.r * s + a.i * c};
}

static void ifft1d(Complex* values, int n)
{
    for (int i = 1, j = 0; i < n; ++i) {
        int bit = n >> 1;
        for (; j & bit; bit >>= 1) j ^= bit;
        j ^= bit;
        if (i < j) std::swap(values[i], values[j]);
    }
    const float pi = 3.1415927410125732421875f;
    for (int len = 2; len <= n; len <<= 1) {
        const float angle = 2.f * pi / (float)len;
        const float wc = std::cos(angle), ws = std::sin(angle);
        for (int i = 0; i < n; i += len) {
            float c = 1.f, s = 0.f;
            for (int j = 0; j < len / 2; ++j) {
                const Complex a = values[i + j];
                const Complex b = mul(values[i + j + len / 2], c, s);
                values[i + j] = {a.r + b.r, a.i + b.i};
                values[i + j + len / 2] = {a.r - b.r, a.i - b.i};
                const float nc = c * wc - s * ws;
                s = c * ws + s * wc;
                c = nc;
            }
        }
    }
}

static void ifft2d(std::vector<Complex>& values, int n)
{
    for (int y = 0; y < n; ++y) ifft1d(values.data() + (size_t)y * n, n);
    std::vector<Complex> column((size_t)n);
    for (int x = 0; x < n; ++x) {
        for (int y = 0; y < n; ++y) column[(size_t)y] = values[(size_t)y * n + x];
        ifft1d(column.data(), n);
        for (int y = 0; y < n; ++y) values[(size_t)y * n + x] = column[(size_t)y];
    }
}

struct HeightStats { double min = 0.0, max = 0.0, rms = 0.0; };

static HeightStats spatial_height(const bf6_water_sim_v2& sim,
                                  const std::vector<float>& h0, float seconds)
{
    const int n = sim.resolution;
    std::vector<Complex> field((size_t)n * n);
    const float pi = 3.1415927410125732421875f;
    for (int y = 0; y < n; ++y) {
        for (int x = 0; x < n; ++x) {
            const size_t i = (size_t)y * n + x;
            const size_t mirror = (size_t)((n - y) & (n - 1)) * n + ((n - x) & (n - 1));
            const float kx = ((float)(x + x) - n) * -pi / sim.tile_dimension;
            const float ky = ((float)(y + y) - n) * pi / sim.tile_dimension;
            const float phase = std::sqrt(9.8f * std::sqrt(kx * kx + ky * ky)) * seconds;
            const float c = std::cos(phase), s = std::sin(phase);
            const Complex a = mul({h0[i * 2], h0[i * 2 + 1]}, c, s);
            const Complex b = mul({h0[mirror * 2], -h0[mirror * 2 + 1]}, c, -s);
            field[i] = {a.r + b.r, a.i + b.i};
        }
    }
    ifft2d(field, n);
    HeightStats stats;
    stats.min = stats.max = field.empty() ? 0.0 : field[0].r;
    double sum2 = 0.0;
    for (int y = 0; y < n; ++y) for (int x = 0; x < n; ++x) {
        const size_t i = (size_t)y * n + x;
        const double v = ((x + y) & 1) ? -field[i].r : field[i].r;
        stats.min = std::min(stats.min, v);
        stats.max = std::max(stats.max, v);
        sum2 += v * v;
    }
    stats.rms = field.empty() ? 0.0 : std::sqrt(sum2 / (double)field.size());
    return stats;
}

int main(int argc, char** argv)
{
    if (argc != 3 && argc != 4) {
        std::printf("usage: waterclosure_test <game_dir> <level> [--isolated]\n");
        return 2;
    }

    const bool isolated = argc == 4 && !std::strcmp(argv[3], "--isolated");
    if (argc == 4 && !isolated) {
        std::printf("unknown option: %s\n", argv[3]);
        return 2;
    }

    char error[512] = {0};
    bf6_ctx* context = bf6_open(argv[1], error, (int)sizeof(error));
    if (!context) {
        std::printf("open failed: %s\n", error);
        return 1;
    }
    if (!isolated) {
        if (bf6_open_level(context, argv[2], nullptr, 0, error, (int)sizeof(error)) != 0) {
            std::printf("open_level failed: %s\n", error);
            bf6_close(context);
            return 1;
        }
    }

    const auto read_sims = isolated ? bf6_level_water_sims_isolated
                                    : bf6_level_water_sims;
    const int count = read_sims(context, argv[2], nullptr, 0);
    std::vector<bf6_water_sim_v2> sims(count > 0 ? (size_t)count : 0);
    if (count > 0) read_sims(context, argv[2], sims.data(), count);
    std::printf("CLOSURE level=%s route=%s cascades=%d\n", argv[2],
                isolated ? "isolated" : "full", count);

    int failures = count > 0 ? 0 : 1;
    for (int i = 0; i < count; ++i) {
        const bf6_water_sim_v2& sim = sims[(size_t)i];
        const std::vector<float> real = build(sim);
        const std::vector<float> repeat = build(sim);
        bf6_water_sim_v2 flat = sim;
        std::memset(flat.dist_tangent_out, 0, sizeof(flat.dist_tangent_out));
        std::memset(flat.dist_tangent_in, 0, sizeof(flat.dist_tangent_in));
        const std::vector<float> zero_tangent = build(flat);

        bf6_water_sim_v2 shuffled = sim;
        if (count > 1) {
            const bf6_water_sim_v2& donor = sims[(size_t)((i + 1) % count)];
            shuffled.dist_count = donor.dist_count;
            std::memcpy(shuffled.dist_x, donor.dist_x, sizeof(shuffled.dist_x));
            std::memcpy(shuffled.dist_y, donor.dist_y, sizeof(shuffled.dist_y));
            std::memcpy(shuffled.dist_tangent_out, donor.dist_tangent_out,
                        sizeof(shuffled.dist_tangent_out));
            std::memcpy(shuffled.dist_tangent_in, donor.dist_tangent_in,
                        sizeof(shuffled.dist_tangent_in));
            shuffled.dist_clamp_min = donor.dist_clamp_min;
            shuffled.dist_clamp_max = donor.dist_clamp_max;
        }
        const std::vector<float> shuffled_curve = build(shuffled);

        const uint64_t real_hash = fnv1a64(real);
        const uint64_t repeat_hash = fnv1a64(repeat);
        const uint64_t flat_hash = fnv1a64(zero_tangent);
        const uint64_t shuffled_hash = fnv1a64(shuffled_curve);
        const double real_energy = energy(real);
        const double flat_energy = energy(zero_tangent);
        const double shuffled_energy = energy(shuffled_curve);
        const HeightStats at0 = spatial_height(sim, real, 0.f);
        const HeightStats at5 = spatial_height(sim, real, 5.f);
        const std::vector<float> zero_h0(real.size(), 0.f);
        const HeightStats zero_at5 = spatial_height(sim, zero_h0, 5.f);

        std::printf(
            "CASCADE index=%d source=%d resolution=%d tile=%.9g angle_deg=%.9g "
            "speed=%.9g min_wave=%.9g large_reduction=%.9g amplitude=%.9g "
            "curve=%d hash=%016llx energy=%.12g deterministic=%d\n",
            i, sim.source_index, sim.resolution, sim.tile_dimension,
            sim.wind_angle_degrees, sim.wind_speed, sim.min_wavelength,
            sim.large_wave_reduction, sim.wave_amplitude, sim.dist_count,
            (unsigned long long)real_hash, real_energy,
            real_hash == repeat_hash ? 1 : 0);
        std::printf(
            "CONTROL index=%d zero_tangents_hash=%016llx energy=%.12g ratio=%.9g "
            "shuffled_curve_hash=%016llx energy=%.12g ratio=%.9g\n",
            i, (unsigned long long)flat_hash, flat_energy,
            real_energy > 0.0 ? flat_energy / real_energy : 0.0,
            (unsigned long long)shuffled_hash, shuffled_energy,
            real_energy > 0.0 ? shuffled_energy / real_energy : 0.0);
        std::printf(
            "SPATIAL index=%d t0_min_m=%.9g t0_max_m=%.9g t0_rms_m=%.9g "
            "t5_min_m=%.9g t5_max_m=%.9g t5_rms_m=%.9g\n",
            i, at0.min, at0.max, at0.rms, at5.min, at5.max, at5.rms);
        std::printf(
            "CONTROL_SPATIAL index=%d zero_h0_t5_min_m=%.9g "
            "zero_h0_t5_max_m=%.9g zero_h0_t5_rms_m=%.9g\n",
            i, zero_at5.min, zero_at5.max, zero_at5.rms);

        if (real.empty() || real_hash != repeat_hash || sim.resolution < 16 ||
            (i > 0 && sims[(size_t)i - 1].tile_dimension < sim.tile_dimension))
            ++failures;
    }

    bf6_water_sim_v2 fake{};
    fake.resolution = 63;
    fake.tile_dimension = 1.f;
    const int fake_score = bf6_water_spectrum_h0(&fake, nullptr, 0);
    std::printf("CONTROL fake_non_power_of_two_resolution=%d expected=0\n", fake_score);
    if (fake_score != 0) ++failures;

    bf6_close(context);
    std::printf("RESULT failures=%d\n", failures);
    return failures ? 1 : 0;
}
