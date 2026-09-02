/* wind_test - authored MeshWind components and vector-field volumes.
 *
 * CONTROLS:
 *   1. EXACT counts per partition, measured on the independent EBX dump path.
 *   2. BONEPOSITIONS MUST BE EMPTY on cable-set components. A separate result
 *      established that BonePositions is not a cable chain; the partitions here
 *      are literally named `cableset_*`, so a reader that found bones on them
 *      would contradict it. Asserted so the two cannot silently diverge.
 *   3. SPRING CONSTANTS MUST BE POSITIVE AND FINITE. Mass, area and the three
 *      secondary constants feed a spring integrator; a zero mass or a NaN is a
 *      misread, not authored data.
 *   4. THE TWO TYPES MUST NOT BOTH APPEAR in the same partition in this sample -
 *      wind components live in cable sets, vector fields live in building
 *      prefabs. A reader matching the wrong GUID would blur that.
 *   5. Fabricated names return nothing.
 */
#include <cstdio>
#include <cstring>
#include <cmath>
#include "bf6_core.h"

struct E { const char* path; int comps; int fields; };

int main(int argc, char** argv) {
    if (argc < 2) { std::printf("usage: wind_test <game>\n"); return 2; }
    char err[256] = {0};
    bf6_ctx* ctx = bf6_open(argv[1], err, sizeof(err));
    if (!ctx) { std::printf("open: %s\n", err); return 1; }
    if (!bf6_mount_all(ctx, 1, err, sizeof(err))) { std::printf("mount: %s\n", err); return 1; }

    const E real[] = {
        { "game/glaciermp/levels/mp_plaza/_layers_world/cables/cableset_3dfa3707-e22d-4811-bbb8-630a23471bdc", 1, 0 },
        { "game/glaciermp/levels/mp_plaza/_layers_world/cables/cableset_ff6d4aef-8c92-46bd-bb5e-3516b29d0edd", 1, 0 },
        { "game/glaciermp/levels/mp_plaza/_layers_world/cables/cableset_9cbdd501-6beb-4f70-8e93-c50f7ce0f074", 1, 0 },
        { "game/glaciermp/levels/mp_dumbo/prefabs/pf_mp_dumbo_tenement_01_832x1728_a",                        0, 2 },
    };

    int mismatch = 0, comps = 0, fields = 0, bones = 0, badspring = 0, mixed = 0;
    for (const E& e : real) {
        bf6_wind* w = bf6_wind_read(ctx, e.path);
        if (!w) { std::printf("  READ FAILED %s\n", e.path); mismatch++; continue; }
        const bool ok = (w->component_count == e.comps && w->field_count == e.fields);
        if (!ok) mismatch++;
        if (w->component_count > 0 && w->field_count > 0) mixed++;
        for (int i = 0; i < w->component_count; i++) {
            const bf6_wind_component& c = w->components[i];
            bones += c.bone_count;
            const float v[5] = { c.mass, c.area, c.secondary_mass, c.secondary_damping, c.secondary_area };
            for (float x : v) if (!std::isfinite(x) || x <= 0.f) badspring++;
            comps++;
        }
        fields += w->field_count;
        std::printf("  %-58s comp %d/%d  field %d/%d  %s\n",
                    std::strrchr(e.path, '/') + 1, w->component_count, e.comps,
                    w->field_count, e.fields, ok ? "ok" : "COUNT MISMATCH");
        if (w->component_count) {
            const bf6_wind_component& c = w->components[0];
            std::printf("      mass %g area %g  secondary(mass %g damp %g area %g)  mask %u  bones %d\n",
                        c.mass, c.area, c.secondary_mass, c.secondary_damping,
                        c.secondary_area, c.vector_field_mask, c.bone_count);
        }
        bf6_free(ctx, w);
    }

    int fake_hits = 0;
    if (bf6_wind_read(ctx, "game/glaciermp/levels/mp_plaza/_layers_world/cables/cableset_nope")) fake_hits++;
    if (bf6_wind_read(ctx, "game/glaciermp/levels/mp_nowhere/prefabs/pf_none")) fake_hits++;

    std::printf("\n  components / fields : %d / %d\n", comps, fields);
    std::printf("  count mismatches    : %d   (must be 0)\n", mismatch);
    std::printf("  BonePositions total : %d   (must be 0 on cable sets - BonePositions\n", bones);
    std::printf("                        is not a cable chain)\n");
    std::printf("  bad spring constants: %d   (must be 0 - non-finite or <= 0)\n", badspring);
    std::printf("  partitions with BOTH: %d   (must be 0 - cables vs building prefabs)\n", mixed);
    std::printf("  fake names read     : %d of 2   (must be 0)\n", fake_hits);

    const bool pass = mismatch == 0 && fake_hits == 0 && comps > 0 && fields > 0 &&
                      bones == 0 && badspring == 0 && mixed == 0;
    std::printf("\n%s\n", pass ? "PASS" : "FAIL");
    bf6_close(ctx);
    return pass ? 0 : 1;
}
