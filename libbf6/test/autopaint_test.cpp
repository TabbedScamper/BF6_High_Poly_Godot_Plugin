/* autopaint_test - autopaint content and the ECS system descriptor.
 *
 * CONTROLS:
 *   1. EXACT per-asset counts, measured on the independent EBX dump path.
 *   2. THE ANONYMITY CONTROL, which is the whole point. Leaves must come back
 *      unnamed and containers must come back NAMED, from the same partitions in
 *      the same pass. If a reader simply failed to resolve CStrings it would
 *      blank both, so asserting "presets_named == 0 AND blueprints_named > 0"
 *      together is what makes the anonymity a property of the data rather than
 *      a parse failure. Either half alone proves nothing.
 *   3. The ECS system's schedulable hashes must be in step with its imports.
 *   4. bf6_name_hash must NOT decode the ECS hashes - a negative that keeps the
 *      cracked NameHash function from being over-applied.
 *   5. Fabricated names return nothing.
 */
#include <cstdio>
#include <cstring>
#include "bf6_core.h"

struct Expect { const char* path; int presets; int outputs; int groups; int blueprints; };

int main(int argc, char** argv) {
    if (argc < 2) { std::printf("usage: autopaint_test <game>\n"); return 2; }
    char err[256] = {0};
    bf6_ctx* ctx = bf6_open(argv[1], err, sizeof(err));
    if (!ctx) { std::printf("open: %s\n", err); return 1; }
    if (!bf6_mount_all(ctx, 1, err, sizeof(err))) { std::printf("mount: %s\n", err); return 1; }

    const char* AP = "game/glaciergranite/levels/mp_granite/autopaint/";
    const Expect real[] = {
        { "pois/pfvc_grn_crashsite",            19, 0, 0, 1 },
        { "pois/pfvc_grn_marina",                1, 0, 0, 1 },
        { "pois/pfvc_grn_crashsite_hf_01",       1, 0, 0, 1 },
        { "nature/hills/pfvc_grn_radarsite",     2, 0, 0, 1 },
        { "nature/cliffs/pfvc_grn_cliffside_03", 1, 0, 0, 1 },
        { "nature/hills/pfvc_cst_hills_01",      1, 0, 0, 1 },
        { "presets/ap_filldecal_concrete",       0, 2, 1, 0 },
        { "shapes/ap_polyplane",                 0, 0, 0, 1 },
    };

    int mismatch = 0, presets = 0, outputs = 0, leaves_named = 0, containers_named = 0;
    for (const Expect& e : real) {
        char path[512];
        std::snprintf(path, sizeof(path), "%s%s", AP, e.path);
        bf6_autopaint* a = bf6_autopaint_read(ctx, path);
        if (!a) { std::printf("  %-40s READ FAILED\n", e.path); mismatch++; continue; }
        const bool ok = a->capture_presets == e.presets && a->outputs == e.outputs &&
                        a->outputs_groups == e.groups && a->blueprints == e.blueprints;
        if (!ok) mismatch++;
        presets += a->capture_presets; outputs += a->outputs;
        leaves_named += a->presets_named + a->outputs_named;
        containers_named += a->groups_named + a->blueprints_named;
        std::printf("  %-40s preset %2d/%2d  out %d/%d  grp %d  bp %d   %s\n",
                    e.path, a->capture_presets, e.presets, a->outputs, e.outputs,
                    a->outputs_groups, a->blueprints, ok ? "ok" : "COUNT MISMATCH");
        bf6_free(ctx, a);
    }

    /* ECS system */
    bf6_ecs_system* sys = bf6_ecs_system_read(ctx,
        "systems/ecssystems/ecsworldanchorsystem/ecssystemasset");
    int sched = 0, imports = 0; unsigned syshash = 0; int hash_decodes = 0;
    if (sys) {
        sched = sys->schedulables; imports = sys->import_count; syshash = sys->system_hash;
        std::printf("\n  ECS system: %s\n", sys->name);
        std::printf("    system_hash %u, %d schedulables, %d imports\n",
                    syshash, sched, imports);
        for (int i = 0; i < imports && i < 3; i++)
            std::printf("      %u  %s\n",
                        i < sched ? sys->schedule_hashes[i] : 0u, sys->imports[i]);
        /* Control 4: the cracked NameHash function must NOT explain these. */
        const char* cand[] = { "Systems/EcsSystems/EcsWorldAnchorSystem/EcsSystemAsset",
                               "EcsWorldAnchorSystem", "WorldAnchorTags" };
        for (const char* c : cand) {
            if (bf6_name_hash(c) == syshash) hash_decodes++;
            for (int i = 0; i < sched; i++)
                if (bf6_name_hash(c) == sys->schedule_hashes[i]) hash_decodes++;
        }
        bf6_free(ctx, sys);
    }

    int fake_hits = 0;
    const char* fake[] = { "game/glaciergranite/levels/mp_granite/autopaint/pois/pfvc_grn_nowhere",
                           "systems/ecssystems/ecsnotarealsystem/ecssystemasset" };
    if (bf6_autopaint_read(ctx, fake[0])) fake_hits++;
    if (bf6_ecs_system_read(ctx, fake[1])) fake_hits++;

    std::printf("\n  count mismatches : %d   (must be 0)\n", mismatch);
    std::printf("  capture presets  : %d   outputs: %d\n", presets, outputs);
    std::printf("  LEAVES named     : %d   (must be 0 - identity is positional)\n", leaves_named);
    std::printf("  CONTAINERS named : %d   (must be >0 - else the reader just\n", containers_named);
    std::printf("                     fails to resolve names and proves nothing)\n");
    std::printf("  ECS schedulables : %d, imports %d  (must be equal and >0)\n", sched, imports);
    std::printf("  name-hash decodes: %d   (must be 0 - bf6_name_hash does NOT\n", hash_decodes);
    std::printf("                     explain the ECS hashes)\n");
    std::printf("  fake names read  : %d of 2   (must be 0)\n", fake_hits);

    const bool pass = mismatch == 0 && fake_hits == 0 && presets == 25 && outputs == 2 &&
                      leaves_named == 0 && containers_named > 0 &&
                      sched > 0 && sched == imports && hash_decodes == 0;
    std::printf("\n%s\n", pass ? "PASS" : "FAIL");
    bf6_close(ctx);
    return pass ? 0 : 1;
}
