/* gameplay_test - behaviour trees, the network registry, unlock manifests.
 *
 * CONTROLS:
 *   1. EXACT COUNTS, declared up front. A GUID reader that has one wrong byte
 *      returns zero instances and every other check still reads green, so the
 *      only control that catches it is an expected count that must match.
 *   2. THE TREE MUST AGREE WITH ITSELF. BehaviorTreeData.Nodes declares a
 *      length; the number of node instances read must equal it. Two numbers
 *      from two different places in the partition.
 *   3. ORDER IS IDENTITY IN THE REGISTRY, and this is asserted the hard way:
 *      the sabotage registry MUST contain repeated imports. If a future change
 *      ever deduplicates the Objects array this test fails, which is the point
 *      - the slot index is the network id.
 *   4. EVERY SUBTREE LINK MUST RESOLVE. 36 links, 36 distinct targets, and
 *      each one must name a partition that exists in the mount.
 *   5. PER-LEVEL MANIFESTS MUST DIFFER. If unlock manifests were one global
 *      list replicated per level, three levels would give one size. They give
 *      three.
 *   6. FABRICATED NAMES RETURN NOTHING, for all three readers.
 */
#include "bf6_core.h"
#include <cstdio>
#include <cstring>
#include <set>
#include <string>
#include <vector>

static const char* kSoldier =
    "diceai/behavior/behaviortrees/root/behaviortree_soldier";
static const char* kSabotage =
    "game/glaciermp/levels/mp_dumbo/_layers_gameplay/sabotage_networkregistry_win32";

int main(int argc, char** argv)
{
    if (argc < 2) { std::printf("usage: gameplay_test <game>\n"); return 2; }
    char err[512] = {0};
    bf6_ctx* c = bf6_open(argv[1], err, (int)sizeof(err));
    if (!c) { std::printf("open: %s\n", err); return 1; }
    if (!bf6_mount_all(c, 1, err, (int)sizeof(err))) { std::printf("mount: %s\n", err); return 1; }

    int fails = 0;

    /* ---- 1. behaviour tree ------------------------------------------------ */
    bf6_behavior_tree* t = bf6_behavior_tree_read(c, kSoldier);
    if (!t) { std::printf("  READ FAILED %s\n", kSoldier); fails++; }
    else {
        int links = 0, selectors = 0, sequences = 0, running = 0, titled = 0;
        std::set<std::string> targets;
        for (int i = 0; i < t->count; i++) {
            const bf6_bt_node& n = t->nodes[i];
            if (n.title[0]) titled++;
            switch (n.kind) {
            case BF6_BT_TREELINK: links++; if (n.subtree[0]) targets.insert(n.subtree); break;
            case BF6_BT_SELECTOR: selectors++; break;
            case BF6_BT_SEQUENCE: sequences++; break;
            case BF6_BT_RUNNING:  running++;   break;
            default: break;
            }
        }
        std::printf("  behaviortree_soldier: %d nodes (declared %d), root instance %d\n",
                    t->count, t->declared_nodes, t->root_index);
        std::printf("      links %d (distinct targets %zu)  selector %d  sequence %d  running %d\n",
                    links, targets.size(), selectors, sequences, running);
        std::printf("      nodes carrying an authored Title: %d\n", titled);

        /* CONTROL 1 + 2: exact counts, and the tree agreeing with itself. */
        if (t->count != 145)        { std::printf("      EXPECTED 145 node instances\n"); fails++; }
        if (t->declared_nodes != 140) { std::printf("      EXPECTED Nodes[140]\n"); fails++; }
        if (titled != 140)          { std::printf("      EXPECTED 140 titled nodes\n"); fails++; }
        if (links != 36)            { std::printf("      EXPECTED 36 BTTreeLink\n"); fails++; }
        if (selectors != 15)        { std::printf("      EXPECTED 15 BTSelectorNode\n"); fails++; }
        if (sequences != 8)         { std::printf("      EXPECTED 8 BTSequenceNode\n"); fails++; }
        if (running != 18)          { std::printf("      EXPECTED 18 BTRunningNode\n"); fails++; }
        if (t->root_index < 0)      { std::printf("      EXPECTED a resolved Root\n"); fails++; }

        /* CONTROL 4: 36 links, 36 distinct, and every target must exist. */
        if ((int)targets.size() != 36) { std::printf("      EXPECTED 36 DISTINCT targets\n"); fails++; }
        int unresolved = 0;
        for (const std::string& s : targets) {
            std::string n = s;
            if (n.size() > 4 && n.compare(n.size() - 4, 4, ".ebx") == 0) n.resize(n.size() - 4);
            bf6_behavior_tree* sub = bf6_behavior_tree_read(c, n.c_str());
            if (!sub) unresolved++; else bf6_free(c, sub);
        }
        std::printf("      subtree targets that READ BACK as trees: %zu of %zu\n",
                    targets.size() - (size_t)unresolved, targets.size());
        if (unresolved) { std::printf("      EXPECTED every subtree to resolve\n"); fails++; }
        bf6_free(c, t);
    }

    /* ---- 2. network registry --------------------------------------------- */
    bf6_net_registry* r = bf6_net_registry_read(c, kSabotage);
    if (!r) { std::printf("  READ FAILED %s\n", kSabotage); fails++; }
    else {
        std::set<std::string> distinct;
        for (int i = 0; i < r->count; i++) distinct.insert(r->objects[i].object);
        std::printf("  sabotage_networkregistry: %d objects, %zu distinct, checksum %u\n",
                    r->count, distinct.size(), r->checksum);
        std::printf("      Name = %s\n", r->name);
        if (r->count != 10) { std::printf("      EXPECTED 10 Objects\n"); fails++; }
        /* CONTROL 3: duplicates MUST be present - order is identity. */
        if (distinct.size() >= (size_t)r->count) {
            std::printf("      EXPECTED repeated imports (slot index is the id)\n"); fails++;
        }
        if (!r->name[0] || !std::strstr(r->name, "sabotage_networkregistry")) {
            std::printf("      EXPECTED Name to describe this partition\n"); fails++;
        }
        if (!r->checksum) { std::printf("      EXPECTED a non-zero Checksum\n"); fails++; }
        bf6_free(c, r);
    }

    /* ---- 3. unlock manifests, three levels -------------------------------- */
    struct L { const char* root; int expect; };
    const L levels[] = {
        { "game/glaciermp/levels/mp_dumbo/mp_dumbo",         20795 },
        { "game/glaciermp/levels/mp_abbasid/mp_abbasid",     20797 },
        { "game/glaciermp/levels/mp_aftermath/mp_aftermath", 20830 },
    };
    std::set<int> sizes;
    for (const L& l : levels) {
        bf6_unlock_manifest* m = bf6_unlocks_read(c, l.root);
        if (!m) { std::printf("  READ FAILED %s\n", l.root); fails++; continue; }
        std::printf("  %-46s %6d entries (expect %d) checksum %u\n",
                    m->manifest, m->count, l.expect, m->root_checksum);
        if (m->count != l.expect) { std::printf("      COUNT MISMATCH\n"); fails++; }
        if (!m->root_checksum)    { std::printf("      EXPECTED a non-zero Checksum\n"); fails++; }
        sizes.insert(m->count);
        bf6_free(c, m);
    }
    /* CONTROL 5: three levels, three DIFFERENT sizes. */
    std::printf("  distinct manifest sizes over 3 levels: %zu\n", sizes.size());
    if (sizes.size() != 3) {
        std::printf("      EXPECTED per-level manifests, not one replicated list\n"); fails++;
    }

    /* ---- 4. gems: the schematic-pin binding, over EVERY gem --------------- */
    /* The binding was DERIVED from gem_capturepoint. Testing it only there
     * would be circular, so it is asserted across the whole gem catalogue. */
    static const char* kGemDir = "game/glaciermp/gamemodes/_shared/gems/";
    static const char* kGems[] = {
        "capture/spatial/gem_capturepoint",
        "capture/spatial/gem_capturepoint_proxy",
        "mcom/spatial/gem_objective_mcom",
        "hq/spatial/gem_hq",
        "checkpoint/spatial/gem_checkpoint",
        "battle_pickup/spatial/gem_battle_pickup",
        "bomb_pickup/spatial/gem_bomb_pickup",
        "payload/spatial/gem_payload",
        "destructible/spatial/gem_destructible",
        "vehiclespawner/spatial/gem_vehiclespawner",
        "objectivegroup/spatial/gem_objectivegroup",
        "deploycam/spatial/gem_deploycam",
    };
    int gems_read = 0, gems_with_iface = 0, gems_with_binds = 0, total_binds = 0;
    for (const char* g : kGems) {
        bf6_gem* gem = bf6_gem_read(c, (std::string(kGemDir) + g).c_str());
        if (!gem) continue;
        gems_read++;
        if (gem->interface_ebx[0]) gems_with_iface++;
        else std::printf("      no mi_ interface: %s\n", g);
        if (gem->count > 0) { gems_with_binds++; total_binds += gem->count; }
        /* A bind with a zero hash on either side is a misread, not data. */
        for (int i = 0; i < gem->count; i++)
            if (!gem->binds[i].pin_hash || !gem->binds[i].field_info_hash) {
                std::printf("      ZERO HASH in %s bind %d\n", g, i); fails++;
            }
        bf6_free(c, gem);
    }
    std::printf("  gems read %d of %zu   with an mi_* interface %d   with pin binds %d (%d binds)\n",
                gems_read, sizeof(kGems) / sizeof(kGems[0]),
                gems_with_iface, gems_with_binds, total_binds);
    if (gems_read < 10) { std::printf("      EXPECTED most named gems to read\n"); fails++; }
    /* NOT every gem is parameterised. `gem_checkpoint` ships with no mi_*
     * interface at all, which is data and not a misread - so the assertion is
     * "all but the known exception", and it would fail again if a SECOND gem
     * ever came back interface-less. Asserting 12 of 12 here would have been
     * asserting a tidier game than the one that shipped. */
    if (gems_with_iface < gems_read - 1) {
        std::printf("      EXPECTED at most one interface-less gem\n"); fails++;
    }
    if (total_binds < 50)    { std::printf("      EXPECTED a substantial bind table\n"); fails++; }

    /* ---- 5. negative controls -------------------------------------------- */
    int fake = 0;
    if (bf6_behavior_tree_read(c, "diceai/behavior/behaviortrees/root/behaviortree_nope")) fake++;
    if (bf6_net_registry_read(c, "game/glaciermp/levels/mp_dumbo/not_a_networkregistry")) fake++;
    if (bf6_unlocks_read(c, "game/glaciermp/levels/mp_nowhere/mp_nowhere")) fake++;
    /* A REAL partition that is not of the asked-for type must also return null:
     * the level root exists and carries no NetworkRegistryAsset. */
    if (bf6_net_registry_read(c, "game/glaciermp/levels/mp_dumbo/mp_dumbo")) fake++;
    std::printf("  fabricated / wrong-type reads that returned data: %d of 4 (must be 0)\n", fake);
    if (fake) fails++;

    std::printf("\n%s\n", fails == 0 ? "PASS" : "FAIL");
    bf6_close(c);
    return fails == 0 ? 0 : 1;
}
