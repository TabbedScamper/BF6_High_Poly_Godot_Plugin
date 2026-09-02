/* Exact local VisualEnvironment zone reader and controls through the public ABI.
 * Runtime inputs are only the installed game directory and level name.
 *
 *   lightingzones_test <game_dir> <level>
 */
#include <cstdio>
#include <string>
#include <vector>

#include "bf6_core.h"

int main(int argc, char** argv)
{
    if (argc != 3) {
        std::fprintf(stderr, "usage: lightingzones_test <game_dir> <level>\n");
        return 2;
    }
    if (bf6_abi_version() != BF6_ABI_VERSION) {
        std::fprintf(stderr, "ABI mismatch: header=%d runtime=%d\n",
                     BF6_ABI_VERSION, bf6_abi_version());
        return 1;
    }

    char err[512] = {};
    bf6_ctx* ctx = bf6_open(argv[1], err, (int)sizeof(err));
    if (!ctx) {
        std::fprintf(stderr, "open: %s\n", err);
        return 1;
    }

    bf6_lighting_zone_stats st{};
    const int n = bf6_level_lighting_zones(
        ctx, argv[2], nullptr, 0, &st, err, (int)sizeof(err));
    if (n <= 0) {
        std::fprintf(stderr, "zones: %s\n", err[0] ? err : "no direct zones");
        bf6_close(ctx);
        return 1;
    }
    std::vector<bf6_lighting_zone> zones((size_t)n);
    err[0] = 0;
    const int filled = bf6_level_lighting_zones(
        ctx, argv[2], zones.data(), n, nullptr, err, (int)sizeof(err));
    if (filled != n) {
        std::fprintf(stderr, "fill: count changed %d -> %d (%s)\n", n, filled, err);
        bf6_close(ctx);
        return 1;
    }

    std::printf("=== %s ABI %d\n", argv[2], bf6_abi_version());
    std::printf("partitions=%d instances=%d proximity=%d shape_links=%d "
                "non_geometry_links=%d non_shape_geometry_links=%d\n",
        st.partitions, st.instances, st.proximity, st.shape_links,
        st.non_geometry_links, st.non_shape_geometry_links);
    std::printf("targets obb=%d polygon=%d other=%d\n",
        st.target_obb, st.target_polygon, st.target_other);
    std::printf("preset_join=%d omitted_no_preset=%d zones=%d (obb=%d polygon=%d)\n",
        st.joined_preset, st.omitted_no_preset, st.total, st.obb, st.polygon);
    std::printf("control rotated_source_same_target=%d / %d real links\n",
        st.rotated_control_hits, st.shape_links);
    std::printf("parse_fail=%d missing=%d cycles=%d malformed=%d unresolved_types=%d\n",
        st.parse_fail, st.missing, st.cycles, st.malformed_shape,
        st.unresolved_types);

    int bad = 0;
    for (int i = 0; i < n && i < 12; ++i) {
        const bf6_lighting_zone& z = zones[(size_t)i];
        std::printf("[%d] %s area=%d shape=%d fade=%g preset=%s source=%s ",
            i, z.kind == BF6_LIGHTING_ZONE_OBB ? "obb" : "polygon",
            z.proximity_instance, z.shape_instance, (double)z.fade_distance,
            z.preset ? z.preset : "", z.source ? z.source : "");
        if (z.kind == BF6_LIGHTING_ZONE_OBB) {
            std::printf("center=(%g,%g,%g) half=(%g,%g,%g)\n",
                (double)z.xform[9], (double)z.xform[10], (double)z.xform[11],
                (double)z.half_extents[0], (double)z.half_extents[1],
                (double)z.half_extents[2]);
            if (z.points || z.point_count != 0) {
                std::fprintf(stderr, "FAIL: OBB row carries polygon points\n");
                ++bad;
            }
        } else {
            std::printf("origin=(%g,%g,%g) points=%d height=%g\n",
                (double)z.xform[9], (double)z.xform[10], (double)z.xform[11],
                z.point_count, (double)z.height);
            if (!z.points || z.point_count < 3) {
                std::fprintf(stderr, "FAIL: malformed polygon ABI row\n");
                ++bad;
            }
        }
        if (!z.preset || !*z.preset || !z.source || !*z.source) {
            std::fprintf(stderr, "FAIL: zone lost its provenance at the ABI\n");
            ++bad;
        }
    }

    err[0] = 0;
    bf6_lighting_zone_stats fake_stats{};
    const int fake_n = bf6_level_lighting_zones(
        ctx, "mp_this_level_does_not_exist", nullptr, 0, &fake_stats,
        err, (int)sizeof(err));
    std::printf("control fake_level zones=%d error=%s\n", fake_n, err);

    if (st.proximity == 0 || st.shape_links == 0) {
        std::fprintf(stderr, "FAIL: real level produced no AreaProximity shape links\n");
        ++bad;
    }
    if (st.target_other != 0) {
        std::fprintf(stderr, "FAIL: %d shape links target an unproven type\n",
                     st.target_other);
        ++bad;
    }
    if (st.total != n || st.joined_preset != n) {
        std::fprintf(stderr, "FAIL: count/preset join mismatch (%d/%d/%d)\n",
                     st.total, st.joined_preset, n);
        ++bad;
    }
    if (st.rotated_control_hits >= st.shape_links) {
        std::fprintf(stderr, "FAIL: rotated control reproduced every real link\n");
        ++bad;
    }
    if (fake_n != 0 || !err[0]) {
        std::fprintf(stderr, "FAIL: fabricated level did not fail explicitly\n");
        ++bad;
    }

    bf6_close(ctx);
    return bad ? 1 : 0;
}
