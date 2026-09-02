/* groundcov_test - the per-pixel ground path: coverage plus a material list.
 *
 *   groundcov_test <game_dir> <level> [size] [ubershader] [--point=x,z]
 */
#include <cstdio>
#include <cstring>
#include <vector>
#include <utility>
#include <algorithm>
#include "bf6_core.h"

int main(int argc, char** argv)
{
    if (argc < 3) { std::printf("usage: groundcov_test <game_dir> <level> [size] [ubershader] [--point=x,z]\n"); return 2; }
    const int size = argc > 3 ? std::atoi(argv[3]) : 2048;
    float point_x = 0.f, point_z = 0.f;
    bool have_point = false;
    int dump_layer = -1;
    bool dump_colour = false;
    for (int ai = 4; ai < argc; ai++) {
        if (std::strncmp(argv[ai], "--point=", 8) == 0) {
            have_point = std::sscanf(argv[ai] + 8, "%f,%f", &point_x, &point_z) == 2;
        }
        if (std::strncmp(argv[ai], "--dump-layer=", 13) == 0)
            dump_layer = std::atoi(argv[ai] + 13);
        if (std::strcmp(argv[ai], "--dump-colour") == 0)
            dump_colour = true;
    }
    const char* ubershader = (argc > 4 && std::strncmp(argv[4], "--point=", 8) != 0)
                           ? argv[4] : nullptr;
    char err[512] = {0};
    bf6_ctx* ctx = bf6_open(argv[1], err, sizeof(err));
    if (!ctx) { std::printf("open: %s\n", err); return 1; }
    // Non-fatal: the ground only needs the archives mounted, and on an EA App
    // install the walk stops at the encrypted type table.
    if (bf6_open_level(ctx, argv[2], ubershader, 0, err, sizeof(err)) != 0)
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
    if (dump_colour && g.colour) {
        if (FILE* f = std::fopen("ground_colour.ppm", "wb")) {
            std::fprintf(f, "P6\n%d %d\n255\n", g.size, g.size);
            std::fwrite(g.colour, 1, (size_t)g.size * g.size * 3, f);
            std::fclose(f);
            std::printf("dumped ground_colour.ppm\n");
        }
    }
    const int slots = g.slot_count > 0 ? g.slot_count : 4;
    std::printf("evaluator slots retained: %d\n", slots);

    // how many slots a texel actually uses, which is what a shader must blend
    std::vector<long long> hist((size_t)slots + 1, 0);
    for (long long i = 0; i < (long long)g.size * g.size; i++) {
        int n = 0;
        for (int s = 0; s < slots; s++) if (g.weight[i * slots + s]) n++;
        hist[n]++;
    }
    const double tot = (double)g.size * g.size;
    std::printf("layers per texel: ");
    for (int n = 0; n <= slots; n++) std::printf("%d=%.1f%% ", n, 100.0 * hist[(size_t)n] / tot);
    {
        long long full_first = 0;
        for (long long i2 = 0; i2 < (long long)g.size * g.size; i2++)
            if (g.weight[i2 * slots] == 255) full_first++;
        std::printf("full-mask first slot: %.2f%%\n", 100.0 * full_first / tot);
    }
    {
        // How LOPSIDED the mix is. Four active slots on every texel would be
        // alarming if the tail were heavy; what matters to a four-tap blend is
        // how much of the weight the dominant layer already carries.
        double dom = 0.0;
        for (long long i2 = 0; i2 < (long long)g.size * g.size; i2++) {
            int mx = 0, tot = 0;
            for (int s = 0; s < slots; s++) {
                const int w = g.weight[i2 * slots + s];
                tot += w;
                if (w > mx) mx = w;
            }
            if (tot > 0) dom += (double)mx / (double)tot;
        }
        const double n2 = (double)g.size * (double)g.size;
        std::printf("dominant slot carries %.1f%% of the weight on average\n",
                    100.0 * dom / n2);
    }
    std::printf("\n\n%-4s %-6s %-9s %-7s %s\n", "slot", "layer", "m/repeat", "mask", "albedo");
    for (int i = 0; i < g.material_count; i++) {
        const bf6_ground_material& m = g.materials[i];
        const char* a = m.albedo_res && *m.albedo_res ? m.albedo_res : "(none)";
        const char* sl = a;
        for (const char* p = a; *p; p++) if (*p == '/') sl = p + 1;
        const bool gated = m.coverage_res && *m.coverage_res;
        std::printf("%-4d %-6d %-9.2f %-7s %s\n", i, m.layer, m.metres_per_repeat,
                    gated ? "_op" : "identity", sl);
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
    int mn = 0, mok = 0;
    for (int i = 0; i < g.material_count; i++) {
        const char* mr = g.materials[i].coverage_res;
        if (!mr || !*mr) continue;
        mn++;
        char e4[256] = {0};
        if (bf6_layer_sheet(ctx, mr, 512, buf.data(), e4, sizeof(e4))) {
            mok++;
            unsigned char lo = 255, hi = 0;
            double sum = 0.0;
            for (size_t p = 0; p < 512u * 512u; p++) {
                const unsigned char v = buf[p * 4];
                lo = std::min(lo, v); hi = std::max(hi, v); sum += v;
            }
            const char* leaf = mr;
            for (const char* q = mr; *q; q++) if (*q == '/') leaf = q + 1;
            std::printf("  L%-3d coverage mean %.3f range %.3f..%.3f  %s\n",
                        g.materials[i].layer, sum / (512.0 * 512.0 * 255.0),
                        lo / 255.0, hi / 255.0, leaf);
        }
    }
    std::printf("coverage sheets: %d bound, %d decoded\n", mn, mok);
    if (dump_layer >= 0) {
        for (int i = 0; i < g.material_count; i++) {
            if (g.materials[i].layer != dump_layer) continue;
            char e5[256] = {0};
            if (!bf6_layer_sheet(ctx, g.materials[i].albedo_res, 512,
                                 buf.data(), e5, sizeof(e5))) break;
            char fn[80]; std::snprintf(fn, sizeof(fn), "layer_%d.ppm", dump_layer);
            if (FILE* f = std::fopen(fn, "wb")) {
                std::fprintf(f, "P6\n512 512\n255\n");
                for (size_t p = 0; p < 512u * 512u; p++)
                    std::fwrite(&buf[p * 4], 1, 3, f);
                std::fclose(f);
                std::printf("dumped %s\n", fn);
            }
            break;
        }
    }
    {
        // WHICH materials actually own the ground, and what each one costs in
        // texels per metre once resampled. A layer that tiles every hundred
        // metres cannot be sharp at 512 no matter how good the decode is, and
        // whether that MATTERS depends entirely on how much ground it covers.
        std::vector<double> share((size_t)g.material_count, 0.0);
        long long tot = 0;
        for (long long i2 = 0; i2 < (long long)g.size * g.size; i2++) {
            const int id = g.idx[i2 * slots];
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
                    if (g.idx[((long long)y * g.size + x) * slots] != id) continue;
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

    if (have_point) {
        const float sx = g.hi[0] - g.lo[0], sz = g.hi[1] - g.lo[1];
        const int px = std::clamp((int)((point_x - g.lo[0]) / sx * g.size), 0, g.size - 1);
        const int pz = std::clamp((int)((point_z - g.lo[1]) / sz * g.size), 0, g.size - 1);
        const long long po = ((long long)pz * g.size + px) * slots;
        std::printf("\npoint world (%.2f, %.2f) -> texel (%d, %d):\n", point_x, point_z, px, pz);
        for (int s = 0; s < slots; s++) {
            const int id = g.idx[po + s], w = g.weight[po + s];
            if (w == 0 || id < 0 || id >= g.material_count) continue;
            const bf6_ground_material& m = g.materials[id];
            const char* a = m.albedo_res && *m.albedo_res ? m.albedo_res : "(none)";
            const char* sl = a;
            for (const char* q = a; *q; q++) if (*q == '/') sl = q + 1;
            std::printf("  eval %d: slot %d raw L%d mask %.3f  %s\n",
                        s, id, m.layer, (double)w / 255.0, sl);
        }
    }

    bf6_close(ctx);
    return 0;
}
