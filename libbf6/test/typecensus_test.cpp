/* typecensus_test - make "this system authors nothing" a measurement.
 *
 * Several shaders-rendering systems have reflected types and, by a table join,
 * no level instances. A table join is not the installed game, so this counts
 * them directly from the mount.
 *
 * THE CONTROLS ARE THE POINT. A census that returns zero is worthless on its
 * own - it is what a broken reader returns too. So every run pairs the absent
 * types with types INDEPENDENTLY KNOWN TO SHIP, decoded elsewhere in this
 * repository, and the test fails unless the known ones are found.
 */
#include "bf6_core.h"
#include <cstdio>
#include <cstring>
#include <vector>

struct T { const char* guid; const char* name; int expect; };  /* expect = EXACT count */

int main(int argc, char** argv)
{
    if (argc < 2) { std::printf("usage: typecensus_test <game> [level]\n"); return 2; }
    const char* level = (argc > 2) ? argv[2] : "levels/mp_dumbo/";
    char err[512] = {0};
    bf6_ctx* c = bf6_open(argv[1], err, (int)sizeof(err));
    if (!c) { std::printf("open: %s\n", err); return 1; }
    if (!bf6_mount_all(c, 1, err, (int)sizeof(err))) { std::printf("mount: %s\n", err); return 1; }

    /* EXACT counts, taken from data/level_type_census.tsv - built by a
     * DIFFERENT method (a standalone EFIX walk) from a different codebase.
     * Asserting equality against it means this reader has to agree with an
     * independent census on the same level, not merely find something. */
    const T rows[] = {
        { "a73e8ce2-ce60-7c2d-7c4c-697c6babf69a", "NetworkRegistryAsset       (control)",   39 },
        { "9a8849a2-42d2-b638-115e-84abb295ab0c", "OccluderPlaneEntityData    (control)",  704 },
        { "169c0258-bac6-d35d-833d-23c8e11dfc01", "OccluderVolumeEntityData   (control)",  108 },
        { "d67bc416-8540-47d7-8aae-e01c50f1b8c1", "EnvironmentDecalVolumeData (control)", 1426 },
        /* THE EXCLUSIONS - reflected types that should author nothing here. */
        { "3f9f27c9-c9e6-7796-d938-bfc864664a78", "AmbientShadowsRender type 1",             0 },
        { "92890117-a2df-f3c0-7d20-26f0becdbbec", "AmbientShadowsRender type 2",             0 },
        { "b185584f-2b15-09f0-4a56-3830b4d2e574", "ExtendedVirtualTextureChannelCount",      0 },
        { "2373c37a-1476-7aa7-d1c7-ef1889e78272", "VirtualTextureShaderBuildMode",           0 },
        { "993fb6f1-604c-c196-7dec-274353bcaa9f", "RenderLayersFrameGraphLocation",          0 },
        { "1cb1288f-9b21-ad9b-4377-4be99e2a447c", "FrameGraphDurationBundlingMethod",        0 },
        { "ca3acf77-ef18-580b-8f30-ffe116f77e00", "MeshComputeParameterStaticState",         0 },
        { "a220ed91-eb15-fa69-3af7-487cd3d9d85b", "MeshComputeRuntimeOutputNode",            0 },
        { "e9c3f578-718a-1263-3bf1-8f37e3c1fa6f", "MeshComputeRuntimeBuffer",                0 },
    };

    int bad = 0, parsed_total = 0;
    for (const T& t : rows) {
        bf6_type_census_result r = bf6_type_census(c, level, t.guid);
        parsed_total += r.partitions_parsed;
        std::printf("  %-52s inst %6d  in %4d of %4d parsed (%d matched)\n",
                    t.name, r.instances, r.partitions_with,
                    r.partitions_parsed, r.partitions_matched);
        if (r.last_partition[0])
            std::printf("        e.g. %s\n", r.last_partition);
        if (r.instances != t.expect) {
            std::printf("        MISMATCH: the independent census says %d\n", t.expect); bad++;
        }
        if (r.partitions_parsed == 0) {
            std::printf("        NOTHING PARSED - the mount failed, the zero means nothing\n"); bad++;
        }
    }

    /* A fabricated GUID must find nothing, and a malformed one must not crash. */
    bf6_type_census_result fake = bf6_type_census(c, level, "deadbeef-0000-0000-0000-000000000000");
    bf6_type_census_result junk = bf6_type_census(c, level, "not-a-guid");
    std::printf("  fabricated guid instances: %d (must be 0)   malformed guid parsed: %d (must be 0)\n",
                fake.instances, junk.partitions_parsed);
    if (fake.instances || junk.partitions_parsed) bad++;

    const bool pass = bad == 0 && parsed_total > 0;
    std::printf("\n%s\n", pass ? "PASS" : "FAIL");
    bf6_close(c);
    return pass ? 0 : 1;
}
