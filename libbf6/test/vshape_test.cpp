/* vshape_test - read authored vector shapes and splines from the installed game.
 *
 * CONTROLS:
 *   1. EXACT COUNTS per partition, measured beforehand on the independent EBX
 *      dump path. A type-GUID reader that gets the byte order wrong matches
 *      nothing and reports an empty level, which passes every other check.
 *   2. THE PLANARITY SPLIT IS THE REAL CONTROL. The same code path reads both
 *      types, so if it produced planar output by construction it would flatten
 *      both. Volumes must come out EXACTLY planar and splines must NOT:
 *         volumes  - every one Y-span 0
 *         splines  - most non-planar
 *      One parser, opposite results, decided by the data.
 *   3. A fake partition name must return nothing.
 *   4. Point counts must be sane (>= 3 for a closed polygon) and finite.
 */
#include <cstdio>
#include <cstring>
#include <cmath>
#include "bf6_core.h"

struct Expect { const char* path; int vol; int spl; };

int main(int argc, char** argv) {
    if (argc < 2) { std::printf("usage: vshape_test <game>\n"); return 2; }
    char err[256] = {0};
    bf6_ctx* ctx = bf6_open(argv[1], err, sizeof(err));
    if (!ctx) { std::printf("open: %s\n", err); return 1; }
    if (!bf6_mount_all(ctx, 1, err, sizeof(err))) { std::printf("mount: %s\n", err); return 1; }

    const Expect real[] = {
        { "game/glaciermp/levels/mp_abbasid/_layers_gameplay/domination/mp_domination0",   10, 1 },
        { "game/glaciermp/levels/mp_abbasid/_layers_gameplay/breakthrough/breakthrough0",  19, 5 },
        { "game/glaciermp/levels/mp_abbasid/_layers_gameplay/escalation/mp_escalation0",   11, 3 },
        { "game/glaciermp/levels/mp_eastwood/_layers_gameplay/conquest0",                   9, 0 },
        { "game/glaciergranite/levels/mp_granite/granitegauntlet32_medium_05_global",       1, 0 },
        { "game/glaciergranite/levels/mp_granite/granitegauntlet32_small_01_global_alliances", 1, 0 },
    };

    int mismatch = 0, nvol = 0, nspl = 0;
    int vol_planar = 0, spl_planar = 0, bad_pts = 0, vol_open = 0, spl_closed = 0;
    int dup_endpoint = 0, cw = 0, ccw = 0;

    for (const Expect& e : real) {
        bf6_vector_shapes* s = bf6_vector_shapes_read(ctx, e.path);
        if (!s) { std::printf("  %-74s READ FAILED\n", e.path); mismatch++; continue; }
        int v = 0, p = 0;
        for (int i = 0; i < s->count; i++) {
            const bf6_vector_shape& sh = s->shapes[i];
            if (sh.is_volume) v++; else p++;

            if (sh.point_count < 3) { bad_pts++; continue; }
            float lo = 1e30f, hi = -1e30f; bool fin = true;
            for (int k = 0; k < sh.point_count; k++) {
                const float* q = sh.points + (size_t)k * 3;
                if (!std::isfinite(q[0]) || !std::isfinite(q[1]) || !std::isfinite(q[2])) fin = false;
                if (q[1] < lo) lo = q[1];
                if (q[1] > hi) hi = q[1];
            }
            if (!fin) { bad_pts++; continue; }
            const bool planar = (hi - lo) < 1e-3f;

            if (sh.is_volume) { if (planar) vol_planar++; if (!sh.is_closed) vol_open++; }
            else              { if (planar) spl_planar++; if (sh.is_closed) spl_closed++; }

            const float* f0 = sh.points;
            const float* fn = sh.points + (size_t)(sh.point_count - 1) * 3;
            if (f0[0] == fn[0] && f0[1] == fn[1] && f0[2] == fn[2]) dup_endpoint++;

            double a = 0.0;
            for (int k = 0; k < sh.point_count; k++) {
                const float* q1 = sh.points + (size_t)k * 3;
                const float* q2 = sh.points + (size_t)((k + 1) % sh.point_count) * 3;
                a += (double)(q2[0] - q1[0]) * (double)(q2[2] + q1[2]);
            }
            if (a > 0) cw++; else ccw++;
        }
        nvol += v; nspl += p;
        const bool ok = (v == e.vol && p == e.spl);
        if (!ok) mismatch++;
        std::printf("  %-74s vol %2d/%2d  spl %2d/%2d  %s\n", e.path, v, e.vol, p, e.spl,
                    ok ? "ok" : "COUNT MISMATCH");
        bf6_free(ctx, s);
    }

    int fake_hits = 0;
    const char* fake[] = {
        "game/glaciermp/levels/mp_abbasid/_layers_gameplay/domination/mp_domination0_NOPE",
        "game/glaciermp/levels/mp_nowhere/_layers_gameplay/conquest0",
    };
    for (const char* f : fake) {
        bf6_vector_shapes* s = bf6_vector_shapes_read(ctx, f);
        if (s) { fake_hits++; bf6_free(ctx, s); }
    }

    std::printf("\n  volumes / splines : %d / %d\n", nvol, nspl);
    std::printf("  count mismatches  : %d   (must be 0)\n", mismatch);
    std::printf("  bad point arrays  : %d   (must be 0)\n", bad_pts);
    std::printf("  volumes planar    : %d of %d   (must be ALL)\n", vol_planar, nvol);
    std::printf("  splines planar    : %d of %d   (must NOT be all - same parser,\n", spl_planar, nspl);
    std::printf("                      so identical results would mean the parser\n");
    std::printf("                      flattens rather than reads)\n");
    std::printf("  volumes not closed: %d   (must be 0)\n", vol_open);
    std::printf("  splines closed    : %d   (must be 0)\n", spl_closed);
    std::printf("  duplicated endpts : %d   (closure is implicit; must be 0)\n", dup_endpoint);
    std::printf("  XZ winding        : %d CW / %d CCW  (NOT normalised by design)\n", cw, ccw);
    std::printf("  fake names read   : %d of 2   (must be 0)\n", fake_hits);

    bool pass = mismatch == 0 && bad_pts == 0 && fake_hits == 0 &&
                nvol > 0 && nspl > 0 && vol_planar == nvol && spl_planar < nspl &&
                vol_open == 0 && spl_closed == 0 && dup_endpoint == 0;
    std::printf("\n%s\n", pass ? "PASS" : "FAIL");
    bf6_close(ctx);
    return pass ? 0 : 1;
}
