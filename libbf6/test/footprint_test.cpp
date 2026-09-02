/* footprint_test - the battle-royale placement system, read from the install.
 *
 * CONTROLS:
 *   1. EXACT COUNTS per partition and an exact category count, measured on the
 *      independent EBX dump path first. A type-GUID reader with the byte order
 *      wrong returns a clean zero everywhere and passes every other check.
 *   2. THE ORIENTATION CONTRAST. Spawn points are yaw-only on 247 of 247;
 *      footprint slots must NOT be, because they sit on the surface they are
 *      placed against. Asserted as 0 < yaw_only < total: if the reader forced
 *      an orientation, every one would come out yaw-only, and if it read the
 *      transform at the wrong offset none would.
 *   3. THE NAME HASH, against values taken from two unrelated subsystems - a
 *      footprint biome theme and a telemetry scoring member. A hash function is
 *      trivially checkable and there is no excuse for shipping it unverified.
 *   4. Fabricated partition names return nothing.
 */
#include <cstdio>
#include <cstring>
#include <cmath>
#include "bf6_core.h"

struct Expect { const char* path; int placements; int categories; };

int main(int argc, char** argv) {
    if (argc < 2) { std::printf("usage: footprint_test <game>\n"); return 2; }
    setvbuf(stdout, NULL, _IONBF, 0);
    char err[256] = {0};
    bf6_ctx* ctx = bf6_open(argv[1], err, sizeof(err));
    if (!ctx) { std::printf("open: %s\n", err); return 1; }
    if (!bf6_mount_all(ctx, 1, err, sizeof(err))) { std::printf("mount: %s\n", err); return 1; }

    const Expect real[] = {
        { "game/glaciergranite/levels/mp_granite/golfresort_psygaspoi",                4,  0  },
        { "game/glaciergranite/levels/mp_granite/granitegauntlet32_medium_05_global", 20,  0  },
        { "game/glaciergranite/levels/mp_granite/rift_missions",                       2,  0  },
        { "game/glaciergranite/common/footprints/granite_footprint_size",              0, 79  },
    };

    int mismatch = 0, total = 0, yaw_only = 0, bad_xform = 0, cats = 0;
    float ylo = 1e30f, yhi = -1e30f;

    for (const Expect& e : real) {
        bf6_footprints* f = bf6_footprints_read(ctx, e.path);
        if (!f) { std::printf("  %-72s READ FAILED\n", e.path); mismatch++; continue; }
        for (int i = 0; i < f->count; i++) {
            const bf6_footprint& p = f->points[i];
            if (!p.has_transform) { bad_xform++; continue; }
            const float* m = p.transform;
            for (int r = 0; r < 3; r++) {
                const float* q = m + r * 3;
                if (std::fabs(std::sqrt(q[0]*q[0]+q[1]*q[1]+q[2]*q[2]) - 1.f) > 0.01f) bad_xform++;
            }
            if (std::fabs(m[3]) < 1e-4f && std::fabs(m[4]-1.f) < 1e-4f &&
                std::fabs(m[5]) < 1e-4f) yaw_only++;
            if (m[10] < ylo) ylo = m[10];
            if (m[10] > yhi) yhi = m[10];
        }
        const bool ok = (f->count == e.placements && f->category_count == e.categories);
        if (!ok) mismatch++;
        total += f->count; cats += f->category_count;
        std::printf("  %-72s place %2d/%2d  cats %3d/%3d  %s\n", e.path,
                    f->count, e.placements, f->category_count, e.categories,
                    ok ? "ok" : "COUNT MISMATCH");
        if (f->category_count > 0)
            std::printf("      e.g. %s | %s | %s\n",
                        f->categories[0], f->categories[f->category_count/2],
                        f->categories[f->category_count-1]);
        bf6_free(ctx, f);
    }

    int fake_hits = 0;
    const char* fake[] = {
        "game/glaciergranite/levels/mp_granite/rift_missions_NOPE",
        "game/glaciergranite/common/footprints/granite_footprint_size_BOGUS",
    };
    for (const char* p : fake) {
        bf6_footprints* f = bf6_footprints_read(ctx, p);
        if (f) { fake_hits++; bf6_free(ctx, f); }
    }

    /* Control 3: the name hash, from two unrelated subsystems. */
    struct HV { const char* s; unsigned v; };
    const HV hv[] = {
        { "Granite_FootprintDatabase_Loot_NoSuppression",             4031764446u },
        { "Granite_FootprintDatabase_Gauntlet_Extraction_Vehicles_Large", 2671557305u },
        { "Granite_FootprintDatabase_DynamicVehicles_Center",          311580107u },
        { "current_tickets",                                           103597604u },
        { "majority_bleed",                                           2767503631u },
        { "kill_tickets",                                             3971618799u },
    };
    int hash_ok = 0;
    for (const HV& h : hv) if (bf6_name_hash(h.s) == h.v) hash_ok++;
    /* and a case-sensitivity check: lowercasing must NOT reproduce it */
    const bool case_sensitive = bf6_name_hash("current_TICKETS") != 103597604u;

    std::printf("\n  placements       : %d\n", total);
    std::printf("  categories       : %d\n", cats);
    std::printf("  count mismatches : %d   (must be 0)\n", mismatch);
    std::printf("  bad transforms   : %d   (must be 0)\n", bad_xform);
    std::printf("  yaw-only         : %d of %d  (must be >0 AND <total: spawns are\n", yaw_only, total);
    std::printf("                     247/247 yaw-only, footprints must not be)\n");
    std::printf("  ground Y band    : %.1f .. %.1f\n", ylo, yhi);
    std::printf("  name hash        : %d of %d  (must be all)  case-sensitive: %s\n",
                hash_ok, (int)(sizeof(hv)/sizeof(hv[0])), case_sensitive ? "yes" : "NO");
    std::printf("  fake names read  : %d of 2   (must be 0)\n", fake_hits);

    const bool pass = mismatch == 0 && bad_xform == 0 && fake_hits == 0 &&
                      total > 0 && cats == 79 && hash_ok == 6 && case_sensitive &&
                      yaw_only > 0 && yaw_only < total;
    std::printf("\n%s\n", pass ? "PASS" : "FAIL");
    bf6_close(ctx);
    return pass ? 0 : 1;
}
