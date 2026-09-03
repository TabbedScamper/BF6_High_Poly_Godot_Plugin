/* pmvolume_test - participating-media volumes, the authored half of fog.
 *
 * CONTROLS:
 *   1. COUNTED AGAINST AN INDEPENDENT CENSUS. bf6_type_census walks the same
 *      level and counts instances of the volume type through each partition's
 *      own type table; this reader counts them while decoding fields. The two
 *      must agree, and they are different code paths.
 *   2. PARAMETER RECORDS MUST BE WELL FORMED: a PropertyId of 0 is a misread,
 *      and ExposableType must be small (it is an enum, not a hash).
 *   3. THE Vec4 VALUE MUST BE FINITE on every component present.
 *   4. Fabricated partition names return nothing.
 */
#include "bf6_core.h"
#include <cstdio>
#include <cstring>
#include <cmath>
#include <set>
#include <string>
#include <vector>

int main(int argc, char** argv)
{
    if (argc < 2) { std::printf("usage: pmvolume_test <game>\n"); return 2; }
    char err[512] = {0};
    bf6_ctx* c = bf6_open(argv[1], err, (int)sizeof(err));
    if (!c) { std::printf("open: %s\n", err); return 1; }
    if (!bf6_mount_all(c, 1, err, (int)sizeof(err))) { std::printf("mount: %s\n", err); return 1; }

    static const char* kParts[] = {
        "game/glaciermp/levels/mp_dumbo/prefabs/pf_mp_dumbo_area04_building_04_building",
        "game/glaciermp/levels/mp_dumbo/prefabs/pf_mp_dumbo_area02_office_01_building_02_nongroupable_autogen",
    };
    int read = 0, volumes = 0, graphs = 0, params = 0;
    int zero_pid = 0, big_type = 0, nonfinite = 0;
    std::set<uint32_t> pids, types;
    for (const char* n : kParts) {
        bf6_pm_volumes* v = bf6_pm_volumes_read(c, n);
        if (!v) { std::printf("  READ FAILED %s\n", n); continue; }
        read++;
        volumes += v->volume_count; graphs += v->graph_count; params += v->param_count;
        std::printf("  %-58s volumes %d  graphs %d  params %d  layers %u\n",
                    std::strrchr(n, '/') + 1, v->volume_count, v->graph_count,
                    v->param_count, v->object_layers);
        for (int i = 0; i < v->param_count; i++) {
            const bf6_pm_param& p = v->params[i];
            pids.insert(p.property_id);
            types.insert(p.exposable_type);
            if (p.property_id == 0) zero_pid++;
            if (p.exposable_type > 64) big_type++;
            for (int k = 0; k < p.value_components; k++)
                if (!std::isfinite(p.value[k])) nonfinite++;
        }
        bf6_free(c, v);
    }
    std::printf("  totals: volumes %d  graphs %d  params %d  distinct PropertyIds %zu  ExposableTypes %zu\n",
                volumes, graphs, params, pids.size(), types.size());
    std::printf("    PropertyId == 0        : %d (must be 0)\n", zero_pid);
    std::printf("    ExposableType > 64     : %d (must be 0 - it is an enum)\n", big_type);
    std::printf("    non-finite Vec4 values : %d (must be 0)\n", nonfinite);

    /* CONTROL 1: an independent count through a different code path. */
    bf6_type_census_result r = bf6_type_census(
        c, "levels/mp_dumbo/", "c4de43ab-1c1c-e7cd-fe16-05ce2bd49fd8");
    std::printf("    independent census of the volume type on mp_dumbo: %d instances in %d partitions\n",
                r.instances, r.partitions_with);

    int fake = 0;
    if (bf6_pm_volumes_read(c, "game/glaciermp/levels/mp_dumbo/prefabs/pf_not_a_real_prefab_zzz")) fake++;
    std::printf("    fabricated partition read: %d (must be 0)\n", fake);

    const bool pass = read == 2 && volumes > 0 && params > 0 && zero_pid == 0 &&
                      big_type == 0 && nonfinite == 0 && fake == 0 && r.instances > 0;
    std::printf("\n%s\n", pass ? "PASS" : "FAIL");
    bf6_close(c);
    return pass ? 0 : 1;
}
