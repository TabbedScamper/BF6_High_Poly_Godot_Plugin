/* debris_test - authored debris clusters and the material-relation markers.
 *
 * CONTROLS:
 *   1. EXACT counts, measured on the independent EBX dump path AND predicted by
 *      the level census before this reader existed: 2 clusters total across the
 *      whole game, with 4 and 1 parts, and 11 material-relation markers in
 *      mp_subsurface's grid.
 *   2. THE UNIT-VECTOR LAW. `LinearVelocity` must be unit length on every part.
 *      This is the finding a consumer most needs and the one most easily broken
 *      by a wrong struct offset, so it is asserted rather than described.
 *   3. THE ANGULAR ZERO. Angular velocity is zero on every shipped part. Read
 *      at the wrong offset it would pick up the neighbouring unit vector and
 *      stop being zero, so this is a second independent alignment check on the
 *      same record.
 *   4. Fabricated names return nothing.
 */
#include <cstdio>
#include <cstring>
#include <cmath>
#include "bf6_core.h"

int main(int argc, char** argv) {
    if (argc < 2) { std::printf("usage: debris_test <game>\n"); return 2; }
    char err[256] = {0};
    bf6_ctx* ctx = bf6_open(argv[1], err, sizeof(err));
    if (!ctx) { std::printf("open: %s\n", err); return 1; }
    if (!bf6_mount_all(ctx, 1, err, sizeof(err))) { std::printf("mount: %s\n", err); return 1; }

    struct E { const char* path; int clusters; int parts; };
    const E real[] = {
        { "game/glaciermp/levels/mp_subsurface/jas39/dc_mil_handpiece_01",   1, 4 },
        { "game/glaciermp/levels/mp_subsurface/jas39/dc_mil_handpiece01_01", 1, 1 },
    };

    int mismatch = 0, parts = 0, nonunit = 0, nonzero_ang = 0;
    for (const E& e : real) {
        bf6_debris* d = bf6_debris_read(ctx, e.path);
        if (!d) { std::printf("  %-62s READ FAILED\n", e.path); mismatch++; continue; }
        const bool ok = d->clusters == e.clusters && d->part_count == e.parts;
        if (!ok) mismatch++;
        for (int i = 0; i < d->part_count; i++) {
            const bf6_debris_part& p = d->parts[i];
            const float* v = p.direction;
            const float m = std::sqrt(v[0]*v[0] + v[1]*v[1] + v[2]*v[2]);
            if (std::fabs(m - 1.0f) > 1e-4f) nonunit++;
            const float* a = p.angular;
            if (a[0] != 0.f || a[1] != 0.f || a[2] != 0.f) nonzero_ang++;
            parts++;
        }
        std::printf("  %-62s cl %d/%d  parts %d/%d  maxactive %d  hlimit %.0f  %s\n",
                    e.path, d->clusters, e.clusters, d->part_count, e.parts,
                    d->max_active_parts, d->height_limit, ok ? "ok" : "COUNT MISMATCH");
        bf6_free(ctx, d);
    }

    /* The material grid: the markers that DO ship on every level. */
    bf6_debris* g = bf6_debris_read(ctx,
        "game/glaciermp/levels/mp_subsurface/mp_subsurface/materialgrid_win32");
    int markers = 0;
    if (g) { markers = g->material_relation_markers;
             std::printf("\n  materialgrid_win32: %d MaterialRelationDebrisData markers "
                         "(values NOT decoded - see header)\n", markers);
             bf6_free(ctx, g); }

    int fake_hits = 0;
    if (bf6_debris_read(ctx, "game/glaciermp/levels/mp_subsurface/jas39/dc_mil_nosuchthing")) fake_hits++;
    if (bf6_debris_read(ctx, "game/glaciermp/levels/mp_nowhere/mp_nowhere/materialgrid_win32")) fake_hits++;

    std::printf("\n  count mismatches : %d   (must be 0)\n", mismatch);
    std::printf("  parts read       : %d   (must be 5 - the whole game ships 5)\n", parts);
    std::printf("  NON-unit dirs    : %d   (must be 0 - LinearVelocity is a direction)\n", nonunit);
    std::printf("  non-zero angular : %d   (must be 0 - and a wrong offset here would\n", nonzero_ang);
    std::printf("                     pick up the unit vector next door)\n");
    std::printf("  grid markers     : %d   (must be 11)\n", markers);
    std::printf("  fake names read  : %d of 2   (must be 0)\n", fake_hits);

    const bool pass = mismatch == 0 && fake_hits == 0 && parts == 5 &&
                      nonunit == 0 && nonzero_ang == 0 && markers == 11;
    std::printf("\n%s\n", pass ? "PASS" : "FAIL");
    bf6_close(ctx);
    return pass ? 0 : 1;
}
