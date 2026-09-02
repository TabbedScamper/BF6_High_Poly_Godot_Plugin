/* water_test - the level's water planes and mined colours over the public ABI.
 *
 *   water_test <game_dir> <level>
 */
#include <cstdio>
#include <cstdlib>
#include <cmath>
#include <vector>
#include "bf6_core.h"

static float bc4_at(const bf6_texture* t, int x, int y)
{
    if (!t || t->format != BF6_FMT_BC4 || !t->data || t->width <= 0 || t->height <= 0)
        return -1.f;
    x = (x % t->width + t->width) % t->width;
    y = (y % t->height + t->height) % t->height;
    const int bx = x >> 2, by = y >> 2;
    const int blocks_x = (t->width + 3) >> 2;
    const uint8_t* b = t->data + ((size_t)by * blocks_x + bx) * 8;
    float p[8] = { b[0] / 255.f, b[1] / 255.f };
    if (b[0] > b[1]) {
        for (int i = 1; i <= 6; ++i)
            p[i + 1] = ((7 - i) * b[0] + i * b[1]) / (7.f * 255.f);
    } else {
        for (int i = 1; i <= 4; ++i)
            p[i + 1] = ((5 - i) * b[0] + i * b[1]) / (5.f * 255.f);
        p[6] = 0.f; p[7] = 1.f;
    }
    uint64_t bits = 0;
    for (int i = 0; i < 6; ++i) bits |= (uint64_t)b[2 + i] << (8 * i);
    const int pixel = ((y & 3) << 2) | (x & 3);
    return p[(bits >> (3 * pixel)) & 7];
}

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
    const int rn = bf6_level_water_render(ctx, argv[2], nullptr, 0);
    if (rn > 0) {
        std::vector<bf6_water_render> rw(rn);
        bf6_level_water_render(ctx, argv[2], rw.data(), rn);
        for (int i = 0; i < rn; ++i) {
            const bf6_water_render& s = rw[i];
            std::printf("draw #%d state=%016llx micro_uv=%.9g foam_uv=%.9g flow=%.9g "
                        "strength=%.9g/%.9g composite=%.9g..%.9g contact=%.9g/%.9g/%.9g\n",
                i, (unsigned long long)s.state_key,
                s.micro_sheet_uv_scale, s.foam_sheet_uv_scale,
                s.micro_sheet_flow_speed, s.micro_sheet_normal_strength,
                s.foam_sheet_normal_strength, s.foam_composite_low,
                s.foam_composite_high, s.contact_world_divisor_m,
                s.contact_remap_low, s.contact_gain);
            std::printf("broad #%d tex=%d world=%.9g*%.9g floor=%.9g ceiling_literal=0.8 graph=%u "
                        "g6=(%.9g,%.9g,%.9g,%.9g) g13=(%.9g,%.9g,%.9g,%.9g)\n",
                i, s.foam_rgb2, s.broad_pattern_world_mul,
                s.broad_pattern_world_scale, s.broad_pattern_floor,
                s.extended_graph_version,
                s.extended_cb1[6][0], s.extended_cb1[6][1],
                s.extended_cb1[6][2], s.extended_cb1[6][3],
                s.extended_cb1[13][0], s.extended_cb1[13][1],
                s.extended_cb1[13][2], s.extended_cb1[13][3]);
            for (int r = 0; r < 22; ++r)
                std::printf("  extended_cb1[%02d]=(%.9g,%.9g,%.9g,%.9g)\n", r,
                    s.extended_cb1[r][0], s.extended_cb1[r][1],
                    s.extended_cb1[r][2], s.extended_cb1[r][3]);
            std::printf("selected pass0 pixel="
                "%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x\n",
                s.selected_pass0_pixel_guid[3], s.selected_pass0_pixel_guid[2],
                s.selected_pass0_pixel_guid[1], s.selected_pass0_pixel_guid[0],
                s.selected_pass0_pixel_guid[5], s.selected_pass0_pixel_guid[4],
                s.selected_pass0_pixel_guid[7], s.selected_pass0_pixel_guid[6],
                s.selected_pass0_pixel_guid[8], s.selected_pass0_pixel_guid[9],
                s.selected_pass0_pixel_guid[10], s.selected_pass0_pixel_guid[11],
                s.selected_pass0_pixel_guid[12], s.selected_pass0_pixel_guid[13],
                s.selected_pass0_pixel_guid[14], s.selected_pass0_pixel_guid[15]);
            std::printf("selected pass0 vertex="
                "%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x\n",
                s.selected_pass0_vertex_guid[3], s.selected_pass0_vertex_guid[2],
                s.selected_pass0_vertex_guid[1], s.selected_pass0_vertex_guid[0],
                s.selected_pass0_vertex_guid[5], s.selected_pass0_vertex_guid[4],
                s.selected_pass0_vertex_guid[7], s.selected_pass0_vertex_guid[6],
                s.selected_pass0_vertex_guid[8], s.selected_pass0_vertex_guid[9],
                s.selected_pass0_vertex_guid[10], s.selected_pass0_vertex_guid[11],
                s.selected_pass0_vertex_guid[12], s.selected_pass0_vertex_guid[13],
                s.selected_pass0_vertex_guid[14], s.selected_pass0_vertex_guid[15]);
            std::printf("overlap #%d version=%u enabled=%d params=(%.9g,%.9g,%.9g,%.9g) "
                        "params2=(%.9g,%.9g,%.9g,%.9g) height=%.9g\n",
                i, s.cascade_overlap_version, s.cascade_overlap_enabled,
                s.cascade_overlap_params[0], s.cascade_overlap_params[1],
                s.cascade_overlap_params[2], s.cascade_overlap_params[3],
                s.cascade_overlap_params2[0], s.cascade_overlap_params2[1],
                s.cascade_overlap_params2[2], s.cascade_overlap_params2[3],
                s.cascade_overlap_height_scale);
            if (argc >= 5 && s.contact_foam >= 0 && s.contact_world_divisor_m > 0.f) {
                const bf6_texture* ct = bf6_texture_at(ctx, s.contact_foam);
                const float wx = (float)std::atof(argv[3]);
                const float wz = (float)std::atof(argv[4]);
                const float u = wx / s.contact_world_divisor_m - 0.5f;
                const float v = wz / s.contact_world_divisor_m - 0.5f;
                const int px = (int)std::floor((u - std::floor(u)) * ct->width);
                const int py = (int)std::floor((v - std::floor(v)) * ct->height);
                float mx = 0.f;
                for (int dy = -4; dy <= 4; ++dy)
                    for (int dx = -4; dx <= 4; ++dx)
                        mx = std::fmax(mx, bc4_at(ct, px + dx, py + dy));
                float global_max = 0.f;
                int global_x = 0, global_y = 0, nonzero = 0;
                int closest2 = 0x7fffffff, closest_x = 0, closest_y = 0;
                for (int ty = 0; ty < ct->height; ++ty)
                    for (int tx = 0; tx < ct->width; ++tx) {
                        const float q = bc4_at(ct, tx, ty);
                        if (q > global_max) { global_max = q; global_x = tx; global_y = ty; }
                        if (q <= 0.f) continue;
                        ++nonzero;
                        const int ddx = tx - px, ddy = ty - py;
                        const int d2 = ddx * ddx + ddy * ddy;
                        if (d2 < closest2) { closest2 = d2; closest_x = tx; closest_y = ty; }
                    }
                std::printf("  contact sample world=(%.3f,%.3f) uv=(%.9g,%.9g) "
                            "tex=%dx%d pixel=(%d,%d) value=%.6g max9x9=%.6g\n",
                            wx, wz, u, v, ct->width, ct->height, px, py,
                            bc4_at(ct, px, py), mx);
                const auto world_of = [&](int p, int dim) {
                    const float wrapped_uv = ((float)p + 0.5f) / (float)dim;
                    return (wrapped_uv - 0.5f) * s.contact_world_divisor_m;
                };
                std::printf("  contact census nonzero=%d/%d max=%.6g at world=(%.1f,%.1f); "
                            "nearest nonzero %.1f texels at world=(%.1f,%.1f)\n",
                            nonzero, ct->width * ct->height, global_max,
                            world_of(global_x, ct->width), world_of(global_y, ct->height),
                            std::sqrt((float)closest2),
                            world_of(closest_x, ct->width), world_of(closest_y, ct->height));
            }
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

    // Sequence control for the Unreal lab: the mask must remain readable from
    // the same mounted context after surface/render/simulation queries.
    bf6_water_mask mask{};
    err[0] = 0;
    const int mask_ok = bf6_level_water_mask(ctx, argv[2], &mask, err, sizeof(err));
    std::printf("post-water mask: ok=%d tile=%u pages=%u indirection=%u err=%s\n",
        mask_ok, mask.tile_side, mask.page_count, mask.indirection_side,
        err[0] ? err : "<none>");

    bf6_close(ctx);
    return 0;
}
