/* groundcov_test - the per-pixel ground path: coverage plus a material list.
 *
 *   groundcov_test <game_dir> <level> [size]
 */
#include <cstdio>
#include <vector>
#include <utility>
#include <algorithm>
#include "bf6_core.h"

int main(int argc, char** argv)
{
    if (argc < 3) { std::printf("usage: groundcov_test <game_dir> <level> [size]\n"); return 2; }
    const int size = argc > 3 ? std::atoi(argv[3]) : 2048;
    char err[512] = {0};
    bf6_ctx* ctx = bf6_open(argv[1], err, sizeof(err));
    if (!ctx) { std::printf("open: %s\n", err); return 1; }
    // Non-fatal: the ground only needs the archives mounted, and on an EA App
    // install the walk stops at the encrypted type table.
    if (bf6_open_level(ctx, argv[2], argc > 4 ? argv[4] : nullptr, 0, err, sizeof(err)) != 0)
        std::printf("note: open_level said %s; continuing on the mount alone\n", err);

    bf6_ground_coverage g{};
    if (!bf6_ground_coverage_get(ctx, argv[2], size, &g, err, sizeof(err))) {
        std::printf("coverage: %s\n", err); return 1; }

    std::printf("%s: %d x %d over %.0f x %.0f m (%.2f m/texel)\n",
        argv[2], g.size, g.size, g.hi[0] - g.lo[0], g.hi[1] - g.lo[1],
        (g.hi[0] - g.lo[0]) / (float)g.size);
    std::printf("%d material(s), %.2f%% of texels empty\n",
        g.material_count, g.empty_fraction * 100.f);
    std::printf("aerial colour map: %s\n", g.colour ? "PRESENT" : "absent");

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
    {
        // How LOPSIDED the mix is. Four active slots on every texel would be
        // alarming if the tail were heavy; what matters to a four-tap blend is
        // how much of the weight the dominant layer already carries.
        double dom = 0.0;
        for (long long i2 = 0; i2 < (long long)g.size * g.size; i2++) {
            int mx = 0, tot = 0;
            for (int s = 0; s < 4; s++) {
                const int w = g.weight[i2 * 4 + s];
                tot += w;
                if (w > mx) mx = w;
            }
            if (tot > 0) dom += (double)mx / (double)tot;
        }
        const double n2 = (double)g.size * (double)g.size;
        std::printf("dominant slot carries %.1f%% of the weight on average\n",
                    100.0 * dom / n2);
    }
    std::printf("\n\n%-4s %-6s %-9s %s\n", "slot", "layer", "m/repeat", "albedo");
    for (int i = 0; i < g.material_count; i++) {
        const bf6_ground_material& m = g.materials[i];
        const char* a = m.albedo_res && *m.albedo_res ? m.albedo_res : "(none)";
        const char* sl = a;
        for (const char* p = a; *p; p++) if (*p == '/') sl = p + 1;
        std::printf("%-4d %-6d %-9.2f %s\n", i, m.layer, m.metres_per_repeat, sl);
    }
    // decode every bound sheet, which is what a texture array would need
    std::vector<unsigned char> buf(512 * 512 * 4);
    int ok = 0, bad = 0;
    for (int i = 0; i < g.material_count; i++) {
        const char* a = g.materials[i].albedo_res;
        if (!a || !*a) continue;
        char e2[256] = {0};
        if (bf6_layer_sheet(ctx, a, 512, buf.data(), e2, sizeof(e2))) ok++;
        else { bad++; if (bad <= 3) std::printf("  sheet FAIL %s: %s\n", a, e2); }
    }
    std::printf("\nsheets decoded to 512: %d ok, %d failed\n", ok, bad);
    int hn = 0, hok = 0;
    for (int i = 0; i < g.material_count; i++) {
        const char* nr = g.materials[i].normal_res;
        if (!nr || !*nr) continue;
        hn++;
        char e3[256] = {0};
        if (bf6_layer_sheet(ctx, nr, 512, buf.data(), e3, sizeof(e3))) hok++;
    }
    std::printf("height sheets: %d bound, %d decoded\n", hn, hok);
    {
        // WHICH materials actually own the ground, and what each one costs in
        // texels per metre once resampled. A layer that tiles every hundred
        // metres cannot be sharp at 512 no matter how good the decode is, and
        // whether that MATTERS depends entirely on how much ground it covers.
        std::vector<double> share((size_t)g.material_count, 0.0);
        long long tot = 0;
        for (long long i2 = 0; i2 < (long long)g.size * g.size; i2++) {
            const int id = g.idx[i2 * 4 + 0];
            if (id < 0 || id >= g.material_count) continue;
            share[(size_t)id] += 1.0;
            tot++;
        }
        std::vector<std::pair<double,int>> by;
        for (int i3 = 0; i3 < g.material_count; i3++) by.push_back({share[(size_t)i3], i3});
        std::sort(by.rbegin(), by.rend());
        std::printf("\ndominant share, top 12 (sheet 512 -> texels per metre)\n");
        for (int k = 0; k < 12 && k < (int)by.size(); k++) {
            const int id = by[(size_t)k].second;
            if (by[(size_t)k].first <= 0) break;
            const bf6_ground_material& m = g.materials[id];
            const char* a = m.albedo_res && *m.albedo_res ? m.albedo_res : "(NO SHEET)";
            const char* sl = a;
            for (const char* q = a; *q; q++) if (*q == '/') sl = q + 1;
            std::printf("  %5.1f%%  L%-3d  %7.2f m/repeat  %6.1f tex/m  %s\n",
                        100.0 * by[(size_t)k].first / (double)(tot ? tot : 1),
                        m.layer, m.metres_per_repeat,
                        512.0 / (m.metres_per_repeat > 0.01f ? m.metres_per_repeat : 4.f),
                        sl);
        }
        // IS THE DOMINANT LAYER A BACKDROP RING OR IS IT ON THE PLAY AREA?
        //
        // A "distance" sheet tiling every 100 m is authored for the far ring
        // beyond the playable box. If it only wins out near the edges it is
        // doing its job and the footprint simply includes the ring; if it
        // wins in the CENTRE too then it is painted on ground a player walks
        // on, which is a join error. The two need different fixes, so it is
        // worth one measurement rather than an argument.
        std::printf("\nring test, share of each top layer inside the central half\n");
        for (int k = 0; k < 4 && k < (int)by.size(); k++) {
            const int id = by[(size_t)k].second;
            if (by[(size_t)k].first <= 0) break;
            long long inner = 0, total = 0;
            const int q0 = g.size / 4, q1 = g.size - g.size / 4;
            for (int y = 0; y < g.size; y++) {
                for (int x = 0; x < g.size; x++) {
                    if (g.idx[((long long)y * g.size + x) * 4] != id) continue;
                    total++;
                    if (x >= q0 && x < q1 && y >= q0 && y < q1) inner++;
                }
            }
            const bf6_ground_material& m = g.materials[id];
            const char* a = m.albedo_res && *m.albedo_res ? m.albedo_res : "(none)";
            const char* sl = a;
            for (const char* q = a; *q; q++) if (*q == 47) sl = q + 1;
            std::printf("  L%-3d %-38s %5.1f%% of its texels are central\n",
                        m.layer, sl, total ? 100.0 * (double)inner / (double)total : 0.0);
        }
        std::printf("  (the central half is 25%% of the area, so ~25%% means EDGE ONLY)\n");
        double noSheet = 0.0;
        for (int i3 = 0; i3 < g.material_count; i3++)
            if (!(g.materials[i3].albedo_res && *g.materials[i3].albedo_res))
                noSheet += share[(size_t)i3];
        std::printf("  ground with NO sheet at all: %.1f%%\n",
                    100.0 * noSheet / (double)(tot ? tot : 1));
    }
    std::printf("evaluator constants (first 6): ");
    for (int i = 0; i < g.material_count && i < 6; i++)
        std::printf("[hb=%.2f disp=%.2f ramp=%.2f] ",
                    g.materials[i].height_blend, g.materials[i].displace_range,
                    g.materials[i].mask_ramp_exp);
    std::printf("\n");

    bf6_close(ctx);
    return 0;
}
