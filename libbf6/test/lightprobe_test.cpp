/* lightprobe_test - the authored lighting-probe family, three units at once.
 *
 * gi-probe-grids, reflection-probes-local-ibl and baked-gi-lightmaps-enlighten
 * all had decoded findings and ZERO recorded controls. This supplies them:
 * every type in the family is counted against the install through
 * bf6_type_census, and the one type whose fields are NAMED is decoded and
 * range-checked.
 *
 * CONTROLS:
 *   1. FAMILY COUNTS vs the independent level census. Each count comes from a
 *      code path that reads each partition's own type table; the expected
 *      values come from data/level_type_census.tsv, built separately.
 *   2. NAMED FIELDS ONLY. The reflection volumes carry 35 fields that resolve
 *      to no names, so they are counted and NOT decoded. A reader that
 *      "decoded" them would emit plausible floats backed by nothing.
 *   3. BLEND GEOMETRY MUST BE SANE: distances finite and non-negative.
 *   4. Fabricated names return nothing.
 */
#include "bf6_core.h"
#include <cstdio>
#include <cstring>
#include <cmath>
#include <string>
#include <vector>

struct T { const char* guid; const char* name; int expect_dumbo; };

int main(int argc, char** argv)
{
    if (argc < 2) { std::printf("usage: lightprobe_test <game>\n"); return 2; }
    char err[512] = {0};
    bf6_ctx* c = bf6_open(argv[1], err, (int)sizeof(err));
    if (!c) { std::printf("open: %s\n", err); return 1; }
    if (!bf6_mount_all(c, 1, err, (int)sizeof(err))) { std::printf("mount: %s\n", err); return 1; }

    /* Expected counts are per-level figures from data/level_type_census.tsv,
     * which was built by a different method from a different codebase. */
    const T fam[] = {
        { "483bb2e9-0cb9-8df4-0e15-6505efa15104", "LightProbeVolumeData",              1047 },
        { "5c138ea3-fe94-c2fd-bfe1-7649b5a63b47", "PbrBoxReflectionVolumeEntityData",   666 },
        { "5f7b9efe-3af2-690c-b1b1-8217c9a5b661", "PbrDistantReflectionVolumeEntityData", 1 },
        { "53533958-02e7-22ba-326f-a35df27bd82a", "DynamicEnlightenEntityData",          -1 },
        { "46ed369e-cdb4-79ed-b73e-c0be2e1808ea", "EnlightenDataAsset",                  -1 },
        { "fd12791a-daaf-4c67-b8b9-5aa0ae310b63", "GiGridConfigurationData",             -1 },
        { "e10eed97-e000-03fd-89c1-415bb98645c4", "DenseProbesConfigurationData",        -1 },
        { "a3ff5143-eec9-0f08-65d5-44ff3d9124f2", "EnlightenShaderDatabaseAsset",        -1 },
    };
    int bad = 0, nonzero_types = 0;
    std::printf("  family census on mp_dumbo (through each partition's own type table):\n");
    for (const T& t : fam) {
        bf6_type_census_result r = bf6_type_census(c, "levels/mp_dumbo/", t.guid);
        std::printf("    %-38s %6d instances in %4d partitions", t.name, r.instances, r.partitions_with);
        if (t.expect_dumbo >= 0) {
            std::printf("   (census says %d)%s", t.expect_dumbo,
                        r.instances == t.expect_dumbo ? "" : "  <== MISMATCH");
            if (r.instances != t.expect_dumbo) bad++;
        }
        std::printf("\n");
        if (r.instances > 0) nonzero_types++;
        if (r.partitions_parsed == 0) { std::printf("      NOTHING PARSED\n"); bad++; }
    }

    /* The one type whose fields are named. */
    bf6_light_probes* p = bf6_light_probes_read(c,
        "game/glaciermp/levels/mp_dumbo/prefabs/pf_mp_dumbo_area04_building_04_building");
    if (!p) { std::printf("  READ FAILED light probe volumes\n"); bad++; }
    else {
        /* -1 IS A SENTINEL, NOT A BAD VALUE. The first version of this test
         * asserted every blend value was non-negative and reported 16
         * violations; the dump shows why - a volume reads
         * `min 10 -1 -1 / max 3 -1 -1`, overriding the X face only and leaving
         * Y and Z at -1 to mean "use BlendDistance". That is the same
         * take-the-default sentinel PhysicsResource uses for StaticFriction,
         * and a reader that clamped it to 0 would silently collapse every
         * unoverridden face to a zero blend. The assertion is therefore: a
         * value is legal if it is -1 OR non-negative, and never non-finite. */
        int bad_geom = 0, sentinels = 0, overridden = 0;
        for (int i = 0; i < p->count; i++) {
            const bf6_light_probe& v = p->volumes[i];
            const float all[9] = { v.blend_distance, v.blend_min[0], v.blend_max[0],
                                   v.blend_min[1], v.blend_max[1], v.blend_min[2],
                                   v.blend_max[2], v.weight, v.distance_offset_along_normal };
            for (float f : all) {
                if (!std::isfinite(f)) { bad_geom++; continue; }
                if (f == -1.f) { sentinels++; continue; }
                if (f < 0.f) bad_geom++;
            }
            for (int k = 0; k < 3; k++)
                if (v.blend_min[k] != -1.f && v.blend_max[k] != -1.f) overridden++;
        }
        std::printf("    per-axis overrides SET %d, left at the -1 sentinel %d\n",
                    overridden, sentinels);
        std::printf("  light probe volumes decoded: %d   blend %g  weight %g  offset %g  unnamed %u\n",
                    p->count, p->volumes[0].blend_distance, p->volumes[0].weight,
                    p->volumes[0].distance_offset_along_normal, p->volumes[0].unnamed_int);
        std::printf("    non-finite or illegally negative values: %d (must be 0)\n", bad_geom);
        if (bad_geom) bad++;
        if (sentinels == 0) {
            std::printf("      EXPECTED some faces left at the -1 sentinel\n"); bad++;
        }
        for (int i = 0; i < p->count && i < 3; i++) {
            const bf6_light_probe& v = p->volumes[i];
            std::printf("      blend %g  min %g %g %g  max %g %g %g  w %g  off %g\n",
                        v.blend_distance, v.blend_min[0], v.blend_min[1], v.blend_min[2],
                        v.blend_max[0], v.blend_max[1], v.blend_max[2], v.weight,
                        v.distance_offset_along_normal);
        }
        bf6_free(c, p);
    }

    int fake = 0;
    if (bf6_light_probes_read(c, "game/glaciermp/levels/mp_dumbo/prefabs/pf_not_real_zzz")) fake++;
    std::printf("  fabricated partition read: %d (must be 0)\n", fake);
    if (fake) bad++;

    const bool pass = bad == 0 && nonzero_types >= 5;
    std::printf("\n%s\n", pass ? "PASS" : "FAIL");
    bf6_close(c);
    return pass ? 0 : 1;
}
