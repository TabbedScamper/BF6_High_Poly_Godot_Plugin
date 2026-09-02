/* spawn_test - read AlternateSpawnEntityData placements from the installed game.
 *
 * CONTROLS, because a reader that returns numbers is not evidence:
 *   1. EXACT COUNTS. Each partition's instance count was measured beforehand on
 *      the independent EBX dump path, which shares none of this code. A GUID
 *      comparison that picks the wrong byte order returns a clean ZERO on every
 *      partition and looks like "no spawns here", so an exact count is the only
 *      assertion that catches it.
 *   2. A FAKE partition name must return nothing.
 *   3. TRANSFORM SHAPE. row1 == (0,1,0) and row0.y == row2.y == 0 on every
 *      instance; a misaligned struct read breaks this immediately.
 *   4. TEAM IS ALWAYS 0. Asserted as a standing negative - if a future build of
 *      the game ever ships a non-zero team, this test must fail loudly rather
 *      than let the "not per-team" finding rot silently.
 *   5. ENABLED MUST VARY across the set. This is what proves the reader
 *      surfaces authored per-instance values rather than type defaults - and
 *      therefore what makes control 4 mean anything at all.
 */
#include <cstdio>
#include <cstring>
#include <cmath>
#include "bf6_core.h"

struct Expect { const char* path; int count; };

int main(int argc, char** argv) {
    if (argc < 2) { std::printf("usage: spawn_test <game>\n"); return 2; }
    char err[256] = {0};
    bf6_ctx* ctx = bf6_open(argv[1], err, sizeof(err));
    if (!ctx) { std::printf("open: %s\n", err); return 1; }
    if (!bf6_mount_all(ctx, 1, err, sizeof(err))) { std::printf("mount: %s\n", err); return 1; }

    /* Counts measured independently via the EBX dump path. */
    const Expect real[] = {
        { "game/glaciermp/levels/mp_abbasid/_layers_gameplay/domination/mp_domination0",  42  },
        { "game/glaciermp/levels/mp_abbasid/_layers_gameplay/breakthrough/breakthrough0", 236 },
        { "game/glaciermp/levels/mp_abbasid/_layers_gameplay/sabotage/mp_sabotage0",      10  },
        { "game/glaciergranite/levels/mp_granite/granitegauntlet32_medium_05_global",     61  },
        { "game/glaciermp/levels/mp_eastwood/_layers_gameplay/conquest0",                 124 },
        { "game/glaciermp/levels/mp_eastwood/_layers_gameplay/squaddeathmatch/mp_squaddm0", 20 },
    };

    int assets = 0, total = 0, count_mismatch = 0;
    int no_xform = 0, bad_yaw = 0, nonzero_team = 0, enabled_true = 0, fallback_true = 0;
    float ylo = 1e30f, yhi = -1e30f;

    for (const Expect& e : real) {
        bf6_spawns* s = bf6_spawns_read(ctx, e.path);
        if (!s) { std::printf("  %-74s READ FAILED\n", e.path); count_mismatch++; continue; }
        assets++; total += s->count;

        int en = 0;
        for (int i = 0; i < s->count; i++) {
            const bf6_spawn_point& p = s->points[i];
            if (!p.has_transform) { no_xform++; continue; }
            const float* m = p.transform;
            /* row1 must be world up, and rows 0/2 must have no Y component. */
            if (std::fabs(m[3]) > 1e-6f || std::fabs(m[4] - 1.0f) > 1e-6f ||
                std::fabs(m[5]) > 1e-6f || std::fabs(m[1]) > 1e-6f ||
                std::fabs(m[7]) > 1e-6f) bad_yaw++;
            if (!std::isfinite(m[9]) || !std::isfinite(m[10]) || !std::isfinite(m[11])) bad_yaw++;
            if (m[10] < ylo) ylo = m[10];
            if (m[10] > yhi) yhi = m[10];
            if (p.team != 0) nonzero_team++;
            if (p.enabled) { en++; enabled_true++; }
            if (p.use_as_fallback) fallback_true++;
        }
        const char* mark = (s->count == e.count) ? "ok" : "COUNT MISMATCH";
        if (s->count != e.count) count_mismatch++;
        std::printf("  %-74s %4d (want %4d) %-14s enabled=%d\n",
                    e.path, s->count, e.count, mark, en);
        bf6_free(ctx, s);
    }

    /* Control 2: a fabricated name must yield nothing. */
    const char* fake[] = {
        "game/glaciermp/levels/mp_abbasid/_layers_gameplay/domination/mp_domination0_BOGUS",
        "game/glaciermp/levels/mp_notarealmap/_layers_gameplay/conquest0",
    };
    int fake_hits = 0;
    for (const char* f : fake) {
        bf6_spawns* s = bf6_spawns_read(ctx, f);
        if (s) { fake_hits++; bf6_free(ctx, s); }
    }

    std::printf("\n  assets read      : %d of %d\n", assets, (int)(sizeof(real)/sizeof(real[0])));
    std::printf("  spawn points     : %d\n", total);
    std::printf("  count mismatches : %d   (must be 0)\n", count_mismatch);
    std::printf("  missing transform: %d   (must be 0)\n", no_xform);
    std::printf("  non yaw-only     : %d   (must be 0)\n", bad_yaw);
    std::printf("  non-zero team    : %d   (must be 0 - spawns are NOT per-team)\n", nonzero_team);
    std::printf("  enabled true     : %d of %d  (must be >0 AND <total, else the\n", enabled_true, total);
    std::printf("                     reader is showing defaults, not authored data)\n");
    std::printf("  use_as_fallback  : %d of %d\n", fallback_true, total);
    std::printf("  ground Y band    : %.1f .. %.1f\n", ylo, yhi);
    std::printf("  fake names read  : %d of 2   (must be 0)\n", fake_hits);

    bool pass = assets == (int)(sizeof(real)/sizeof(real[0])) && count_mismatch == 0 &&
                no_xform == 0 && bad_yaw == 0 && nonzero_team == 0 && fake_hits == 0 &&
                enabled_true > 0 && enabled_true < total && total > 0;
    std::printf("\n%s\n", pass ? "PASS" : "FAIL");
    bf6_close(ctx);
    return pass ? 0 : 1;
}
