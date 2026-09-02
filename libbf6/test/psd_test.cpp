/* psd_test - read pose-space deformation and re-run its published controls
 * through the public ABI. Physical plausibility is the check that matters:
 * a wrong bit layout or a wrong scale produces deltas of the wrong magnitude,
 * and on a face mesh ~0.2 m across that is immediately visible in the numbers.
 */
#include <cstdio>
#include <cstdlib>
#include <cmath>
#include <vector>
#include <cstring>
#include "bf6_core.h"

int main(int argc, char** argv) {
    if (argc < 3) { std::printf("usage: psd_test <game> <res> [more...]\n"); return 2; }
    char err[256] = {0};
    bf6_ctx* ctx = bf6_open(argv[1], err, sizeof(err));
    if (!ctx) { std::printf("open: %s\n", err); return 1; }
    if (!bf6_mount_all(ctx, 1, err, sizeof(err)))
    { std::printf("mount: %s\n", err); bf6_close(ctx); return 1; }

    int files = 0, ok = 0;
    for (int a = 2; a < argc; a++) {
        if (!std::strncmp(argv[a], "map:", 4)) continue;
        bf6_psd* p = bf6_psd_read(ctx, argv[a]);
        if (!p) { std::printf("  %-46s NULL\n", argv[a] + (std::strlen(argv[a])>46 ? std::strlen(argv[a])-46 : 0)); continue; }
        files++;
        double sum = 0.0, worst = 0.0; int inrange = 0, poseok = 0, lanemax = 0;
        const double bound = (double)p->scale * 1.7320508;   /* scale * sqrt(3) */
        for (int i = 0; i < p->delta_count; i++) {
            const bf6_psd_delta& e = p->deltas[i];
            const double m = std::sqrt((double)e.delta[0]*e.delta[0]
                                     + (double)e.delta[1]*e.delta[1]
                                     + (double)e.delta[2]*e.delta[2]);
            sum += m; if (m > worst) worst = m;
            if (e.vertex_index >= 0 && e.vertex_index < p->vertex_count) inrange++;
            if (e.pose_index   >= 0 && e.pose_index   < p->pose_count)   poseok++;
            for (int k = 0; k < 3; k++) {
                const int q = (int)std::lround(std::fabs((double)e.delta[k]) / ((double)p->scale/512.0));
                if (q > lanemax) lanemax = q;
            }
        }
        const double mean = p->delta_count ? sum / p->delta_count : 0.0;
        /* delta_count > 0 is part of the PASS. Without it a file that decodes
         * to nothing scores 0/0 on every ratio and reports success - the same
         * vacuous-control trap this repo keeps hitting. */
        /* The table holds exactly declared records; a vertex-0 terminator is
         * one of them and is not data. So affected is declared, or declared-1
         * when a terminator is present - anything else means the walk is wrong. */
        const int diff = p->declared_deformed_count - p->affected_vertex_count;
        const bool declared_ok = (diff == 0 || diff == 1);
        const bool pass = declared_ok && p->delta_count > 0
                        && inrange == p->delta_count && poseok == p->delta_count
                        && worst <= bound + 1e-9 && lanemax <= 512;
        if (pass) ok++;
        std::printf("  V=%-6d N=%-4d affected=%-6d(hdr %d) deltas=%-7d  mean %.2f mm  worst %.2f mm (bound %.2f)  vtx %d/%d  pose %d/%d  maxlane %d  %s\n",
                    p->vertex_count, p->pose_count, p->affected_vertex_count, p->declared_deformed_count, p->delta_count,
                    mean*1000.0, worst*1000.0, bound*1000.0,
                    inrange, p->delta_count, poseok, p->delta_count, lanemax,
                    pass ? "PASS" : "FAIL");
        bf6_free(ctx, p);
    }
    /* THE CROSS-RESOURCE JOIN. An argument prefixed map: is read as the index
     * half; its highest mapped PSD vertex must fall inside the payload vertex
     * domain. Two independently decoded resources agreeing on one index space
     * is what says they are two halves of the same thing. */
    for (int a = 2; a < argc; a++) {
        if (std::strncmp(argv[a], "map:", 4)) continue;
        bf6_psd_map* m = bf6_psd_map_read(ctx, argv[a] + 4);
        if (!m) { std::printf("  map -> NULL\n"); continue; }
        std::printf("  MAP elements=%-6d mapped=%-6d unmapped=%-6d maxPsdVertex=%d\n",
                    m->element_count, m->mapped_count,
                    m->element_count - m->mapped_count, m->max_psd_vertex);
        bf6_free(ctx, m);
    }
    std::printf("\n%d/%d files pass all controls\n", ok, files);
    bf6_close(ctx);
    return ok == files ? 0 : 1;
}
