/* skin_test - verify the per-vertex skin binding through the PUBLIC ABI.
 *
 * The point of this test is not to print skin data, it is to try to FALSIFY it.
 * A wrong lane order, a missed second element or a skipped 0x8000 remap all
 * still produce a full array of plausible-looking small integers, so the only
 * useful output is a set of checks that a wrong read fails:
 *
 *   1. weights sum to 1 over ALL influences        (the published law: 255/255)
 *   2. NEGATIVE - for every vertex that actually PUTS WEIGHT in lanes 4..7,
 *      the first four alone must NOT sum to 1.
 *
 *      The naive form of this check ("first four never sum to 1") is useless:
 *      an 8-lane section is free to leave the upper lanes at zero, and on a
 *      face mesh most vertices do exactly that, so the check fails on correct
 *      data. Restricting it to vertices with real weight up top is what makes
 *      it discriminating - on those, and only those, dropping the second
 *      element must visibly lose weight.
 *   3. influence count is 4 or 8, never anything else
 *   4. every bone index is inside the section's palette bound
 */
#include <cstdio>
#include <cstdlib>
#include <cmath>
#include <vector>
#include "bf6_core.h"

int main(int argc, char** argv) {
    if (argc < 3) { std::printf("usage: skin_test <game> <res> [lod]\n"); return 2; }
    const int lod = argc > 3 ? std::atoi(argv[3]) : 0;
    char err[256] = {0};
    bf6_ctx* ctx = bf6_open(argv[1], err, sizeof(err));
    if (!ctx) { std::printf("open: %s\n", err); return 1; }
    if (!bf6_mount_all(ctx, 1, err, sizeof(err)))
    { std::printf("mount: %s\n", err); bf6_close(ctx); return 1; }

    bf6_mesh* m = bf6_read_mesh(ctx, argv[2], lod);
    if (!m) { std::printf("read_mesh returned null for %s\n", argv[2]); bf6_close(ctx); return 1; }

    std::printf("MESH %s  lod %d  sections %d\n", argv[2], lod, m->section_count);
    long long skinned = 0, tot_v = 0, sum_ok = 0, first4_ok = 0, inf_ok = 0, upper = 0;
    int  maxbone = 0;
    long long flagged_lo = 0;
    for (int i = 0; i < m->section_count; i++) {
        const bf6_section& s = m->sections[i];
        if (!s.skin_bones || s.skin_influences <= 0) {
            std::printf("  S%-2d verts %-6d  NOT SKINNED\n", i, s.vertex_count);
            continue;
        }
        skinned++;
        const int inf = s.skin_influences;
        if (inf == 4 || inf == 8) inf_ok++;
        long long ok = 0, f4 = 0, hi_used = 0;
        double worst = 0.0;
        int mb = 0;
        for (int v = 0; v < s.vertex_count; v++) {
            double t = 0.0, t4 = 0.0;
            for (int k = 0; k < inf; k++) {
                const size_t d = (size_t)v * inf + k;
                t += s.skin_weights[d];
                if (k < 4) t4 += s.skin_weights[d];
                if (s.skin_bones[d] > mb) mb = s.skin_bones[d];
            }
            if (std::fabs(t - 1.0) <= 2.0 / 255.0) ok++;
            if (std::fabs(t - 1.0) > worst) worst = std::fabs(t - 1.0);
            if (inf > 4 && t4 < 1.0 - 2.0 / 255.0) { hi_used++; }
            if (inf > 4 && t4 < 1.0 - 2.0 / 255.0 && std::fabs(t - 1.0) <= 2.0 / 255.0) f4++;
        }
        tot_v += s.vertex_count; sum_ok += ok; first4_ok += f4; upper += hi_used;
        if (mb > maxbone) maxbone = mb;
        std::printf("  S%-2d verts %-6d influences %d  sum==1 %lld/%d (worst %.4f)  maxbone %d",
                    i, s.vertex_count, inf, ok, s.vertex_count, worst, mb);
        if (inf > 4) std::printf("   [upper lanes carry weight on %lld verts; joined read fixes %lld]",
                                 hi_used, f4);
        std::printf("\n");
    }
    std::printf("\nSUMMARY  skinned sections %lld  vertices %lld\n", skinned, tot_v);
    std::printf("  weights sum to 1 over all influences : %lld/%lld\n", sum_ok, tot_v);
    std::printf("  influence count is 4 or 8            : %lld/%lld sections\n", inf_ok, skinned);
    std::printf("  highest bone index seen              : %d\n", maxbone);
    std::printf("  vertices with weight in lanes 4..7   : %lld/%lld\n", upper, tot_v);
    /* THE PALETTE. Does a skin index address the palette, or the skeleton
     * directly? An identity palette makes the two indistinguishable, so say
     * which it is rather than letting a consumer assume. */
    {
        const bf6_section& s0 = m->sections[0];
        std::printf("  bone palette entries                 : %d\n", s0.bone_list_count);
        if (s0.bone_list && s0.bone_list_count > 0) {
            int ident = 0, mx = 0;
            for (int k = 0; k < s0.bone_list_count; k++) {
                if (s0.bone_list[k] == (uint16_t)k) ident++;
                if (s0.bone_list[k] > mx) mx = s0.bone_list[k];
            }
            std::printf("  palette[i] == i (identity)           : %d/%d\n", ident, s0.bone_list_count);
            std::printf("  highest skeleton id in palette       : %d\n", mx);
            std::printf("  skin indices addressable by palette  : %s\n",
                        maxbone < s0.bone_list_count ? "yes" : "NO - indices exceed the palette");
        }
    }
    std::printf("  a one-element read under-weights     : %lld of them\n", first4_ok);
    /* THE SEMANTIC CONTROL. Numeric range proves only that indices FIT the
     * skeleton. If they really are skeleton bone ids, the bones a mesh weights
     * must match what the mesh IS - a face must ride face bones. A remap or an
     * off-by-something would still fit the range and would name nonsense. */
    if (argc > 4) {
        bf6_skeleton* sk = bf6_skeleton_read(ctx, argv[4]);
        if (!sk) std::printf("\nskeleton %s did not read\n", argv[4]);
        else {
            std::vector<double> wsum((size_t)sk->bone_count, 0.0);
            long long oor = 0, tot = 0;
            for (int i = 0; i < m->section_count; i++) {
                const bf6_section& s = m->sections[i];
                if (!s.skin_bones) continue;
                for (int v = 0; v < s.vertex_count; v++)
                    for (int k = 0; k < s.skin_influences; k++) {
                        const size_t d = (size_t)v * s.skin_influences + k;
                        const int b = s.skin_bones[d];
                        tot++;
                        if (b < 0 || b >= sk->bone_count) { oor++; continue; }
                        wsum[(size_t)b] += s.skin_weights[d];
                    }
            }
            std::printf("\n  rig %s (%d bones)\n", sk->name ? sk->name : argv[4], sk->bone_count);
            std::printf("  skin indices out of skeleton range   : %lld/%lld\n", oor, tot);
            std::printf("  bones carrying the most weight:\n");
            for (int r = 0; r < 8; r++) {
                int best = -1; double bw = 0.0;
                for (int b = 0; b < sk->bone_count; b++)
                    if (wsum[(size_t)b] > bw) { bw = wsum[(size_t)b]; best = b; }
                if (best < 0) break;
                std::printf("      %-28s %.0f\n", sk->bones[best].name, bw);
                wsum[(size_t)best] = 0.0;
            }
            bf6_free(ctx, sk);
        }
    }

    /* THE FLAGGED POPULATION, over EVERY lane.
     *
     * A flagged value addresses a renderbone appended past the rig, resolved as
     * ((raw & 0x7FFF) >> 1) + rigBoneCount. The shifted SLOT should be small -
     * the format spec measures a global max of 20 - so printing its range says
     * whether a mesh belongs to the documented population or not. Counting only
     * the last lane (as an earlier version of this test did) misses them: the
     * even-bit cases concentrate in lanes 0 and 1. */
    {
        long long fl = 0, bit0 = 0, tot = 0; int slotmax = -1, slotmin = 1<<30;
        double flagged_weight = 0.0;
        for (int i = 0; i < m->section_count; i++) {
            const bf6_section& s = m->sections[i];
            if (!s.skin_bones) continue;
            for (int v = 0; v < s.vertex_count * s.skin_influences; v++) {
                const uint16_t r = s.skin_bones[v];
                tot++;
                if (r & 0x8000) {
                    fl++;
                    if (r & 1) bit0++;
                    const int slot = (r & 0x7FFF) >> 1;
                    if (slot > slotmax) slotmax = slot;
                    if (slot < slotmin) slotmin = slot;
                    flagged_weight += s.skin_weights[v];
                }
            }
        }
        std::printf("  flagged (0x8000) over ALL lanes      : %lld/%lld\n", fl, tot);
        if (fl) {
            std::printf("  ...bit 0 also set                    : %lld/%lld\n", bit0, fl);
            std::printf("  ...renderbone slot after >>1         : %d..%d (spec global max 20)\n",
                        slotmin, slotmax);
            std::printf("  ...total weight they carry           : %.1f\n", flagged_weight);
        }
    }

    /* RAW vs DECODED. `bones` is the un-remapped last lane of BoneIndices;
     * `skin_bones` has had the 0x8000 remap applied. Comparing them says
     * whether the remap is firing and whether the flagged population here
     * looks like the one the remap was measured on (bit 0 always SET). */
    {
        long long flagged = 0, bit0 = 0, raw_tot = 0; int rawmax = 0;
        for (int i = 0; i < m->section_count; i++) {
            const bf6_section& s = m->sections[i];
            if (!s.bones) continue;
            for (int v = 0; v < s.vertex_count; v++) {
                const uint16_t r = s.bones[v];
                raw_tot++;
                if (r > rawmax) rawmax = r;
                if (r & 0x8000) { flagged++; if (r & 1) bit0++; }
            }
        }
        if (raw_tot) {
            std::printf("  raw last-lane indices                : max %d over %lld\n", rawmax, raw_tot);
            std::printf("  ...with 0x8000 set                   : %lld/%lld\n", flagged, raw_tot);
            std::printf("  ...of those, bit 0 also set          : %lld/%lld  (documented population: ALL)\n",
                        bit0, flagged);
        }
    }

    bf6_free(ctx, m);
    bf6_close(ctx);
    return 0;
}
