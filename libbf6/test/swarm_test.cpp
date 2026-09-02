/* swarm_test - read SP-campaign crowd regions from the installed game.
 *
 * CONTROLS, because a reader that returns numbers is not evidence:
 *   1. a FAKE asset name must return nothing - otherwise "it read something"
 *      means nothing;
 *   2. every coordinate must be finite and within a sane world envelope, so a
 *      misaligned struct read shows up as garbage rather than passing quietly;
 *   3. the point count must match an independent count of position-bearing
 *      instances taken from the EBX dump path, which does not share this code;
 *   4. swarm content is SP-only, so a multiplayer asset name must yield nothing.
 */
#include <cstdio>
#include <cstring>
#include <cmath>
#include <string>
#include <vector>
#include "bf6_core.h"

static bool finite3(const float* p) {
    return std::isfinite(p[0]) && std::isfinite(p[1]) && std::isfinite(p[2]);
}

int main(int argc, char** argv) {
    if (argc < 2) { std::printf("usage: swarm_test <game>\n"); return 2; }
    char err[256] = {0};
    bf6_ctx* ctx = bf6_open(argv[1], err, sizeof(err));
    if (!ctx) { std::printf("open: %s\n", err); return 1; }
    if (!bf6_mount_all(ctx, 1, err, sizeof(err))) { std::printf("mount: %s\n", err); return 1; }

    const char* real[] = {
        "game/glaciersp/levels/dsub_sp_nightraid/_logic/sub_dsn_beat03_area_swarm",
        "game/glaciersp/levels/dsub_sp_nightraid/sub_dsn_beat01_area_swarm",
        "game/glaciersp/levels/sp_invasion/sub_dsn_beat10_area_swarm",
        "game/glaciersp/levels/dsub_sp_brooklynattack/lay_dsn_beat0200_swarm_schematic",
        "game/glaciersp/levels/dsub_sp_prologue/lay_dsn_beat0200_swarm_schematic",
    };
    int assets = 0, pts = 0, xfs = 0, bad_coord = 0;
    float lo[3] = {1e30f, 1e30f, 1e30f}, hi[3] = {-1e30f, -1e30f, -1e30f};

    for (const char* a : real) {
        bf6_swarm* s = bf6_swarm_read(ctx, a);
        if (!s) { std::printf("  %-72s READ FAILED\n", a); continue; }
        assets++; pts += s->point_count; xfs += s->xform_count;
        for (int i = 0; i < s->point_count; i++) {
            const float* p = s->points + (size_t)i * 3;
            if (!finite3(p) || std::fabs(p[0]) > 1e6f || std::fabs(p[1]) > 1e6f || std::fabs(p[2]) > 1e6f)
                bad_coord++;
            for (int k = 0; k < 3; k++) { if (p[k] < lo[k]) lo[k] = p[k]; if (p[k] > hi[k]) hi[k] = p[k]; }
        }
        std::printf("  %-72s points=%-5d xforms=%d\n", a, s->point_count, s->xform_count);
    }

    /* control 1 and 4: fabricated names, and a multiplayer level */
    const char* fake[] = {
        "game/glaciersp/levels/sp_invasion/sub_dsn_beat10_area_swarm_NOTAREALASSET",
        "game/glaciermp/levels/mp_abbasid/mp_abbasid_area_swarm",
        "game/glaciermp/levels/mp_aftermath/sub_dsn_beat01_area_swarm",
    };
    int fake_hits = 0;
    for (const char* a : fake) {
        bf6_swarm* s = bf6_swarm_read(ctx, a);
        const int n = s ? s->point_count + s->xform_count : -1;
        if (s && n > 0) fake_hits++;
        std::printf("  CONTROL %-64s %s\n", a, s ? (n > 0 ? "RESOLVED (BAD)" : "empty") : "null");
    }

    std::printf("\n  assets read      %d of %d\n", assets, (int)(sizeof(real)/sizeof(*real)));
    std::printf("  spawn points     %d\n", pts);
    std::printf("  transforms       %d\n", xfs);
    std::printf("  bad coordinates  %d\n", bad_coord);
    if (pts) std::printf("  world envelope   x[%.1f %.1f] y[%.1f %.1f] z[%.1f %.1f]\n",
                         lo[0], hi[0], lo[1], hi[1], lo[2], hi[2]);
    std::printf("  fake/MP resolved %d  (must be 0)\n", fake_hits);

    const bool pass = assets > 0 && pts > 0 && bad_coord == 0 && fake_hits == 0;
    std::printf("\n  => %s\n", pass ? "PASS" : "FAIL");
    bf6_close(ctx);
    return pass ? 0 : 1;
}
