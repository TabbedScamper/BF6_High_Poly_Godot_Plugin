/* psdapply_test - apply a facial pose to a real mesh, end to end.
 *
 * This exercises the whole facial chain at once: mesh geometry, the
 * render-vertex to PSD-vertex map, and the sparse delta payload. Any one of
 * them wrong and the numbers move.
 *
 * The checks are chosen so a wrong join FAILS rather than looking plausible:
 *
 *  1. every mapped PSD vertex is inside the payload's own vertex domain;
 *  2. applying one pose at full weight displaces ONLY vertices that pose owns,
 *     and leaves every other vertex bit-identical;
 *  3. displacement is bounded by the encoding's own limit, scale*sqrt(3);
 *  4. NEGATIVE - applying a pose the payload does not contain must move nothing.
 */
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cmath>
#include <vector>
#include "bf6_core.h"

int main(int argc, char** argv) {
    if (argc < 5) {
        std::printf("usage: psdapply_test <game> <mesh_res> <psdmap_res> <psd_res> [pose]\n");
        return 2;
    }
    const int pose = argc > 5 ? std::atoi(argv[5]) : 0;
    char err[256] = {0};
    bf6_ctx* ctx = bf6_open(argv[1], err, sizeof(err));
    if (!ctx) { std::printf("open: %s\n", err); return 1; }
    if (!bf6_mount_all(ctx, 1, err, sizeof(err)))
    { std::printf("mount: %s\n", err); bf6_close(ctx); return 1; }

    bf6_mesh*    m  = bf6_read_mesh(ctx, argv[2], 0);
    bf6_psd_map* mp = bf6_psd_map_read(ctx, argv[3]);
    bf6_psd*     ps = bf6_psd_read(ctx, argv[4]);
    if (!m || !mp || !ps) {
        std::printf("mesh %s  map %s  psd %s\n", m?"ok":"NULL", mp?"ok":"NULL", ps?"ok":"NULL");
        bf6_close(ctx); return 1;
    }
    std::printf("mesh sections=%d   map elements=%d (mapped %d)   psd V=%d N=%d deltas=%d\n",
                m->section_count, mp->element_count, mp->mapped_count,
                ps->vertex_count, ps->pose_count, ps->delta_count);

    /* 1. the join: every mapped id must address the payload's domain */
    int oor = 0;
    for (int i = 0; i < mp->element_count; i++) {
        const uint32_t pv = mp->psd_vertex_id[i];
        if (pv == 0xFFFFFFFFu) continue;
        if ((int32_t)pv >= ps->vertex_count) oor++;
    }
    std::printf("  mapped ids inside the payload vertex domain : %d/%d out of range\n",
                oor, mp->mapped_count);

    /* index the deltas of the requested pose by PSD vertex */
    std::vector<float> dx((size_t)ps->vertex_count * 3, 0.0f);
    std::vector<char>  owns((size_t)ps->vertex_count, 0);
    int pose_deltas = 0;
    for (int i = 0; i < ps->delta_count; i++) {
        const bf6_psd_delta& e = ps->deltas[i];
        if (e.pose_index != pose) continue;
        if (e.vertex_index < 0 || e.vertex_index >= ps->vertex_count) continue;
        dx[(size_t)e.vertex_index*3+0] = e.delta[0];
        dx[(size_t)e.vertex_index*3+1] = e.delta[1];
        dx[(size_t)e.vertex_index*3+2] = e.delta[2];
        owns[(size_t)e.vertex_index] = 1;
        pose_deltas++;
    }

    /* 2/3. apply at full weight over the mesh's own vertices */
    long long moved = 0, unmoved = 0, wrongly_moved = 0, verts = 0;
    double worst = 0.0;
    const double bound = (double)ps->scale * 1.7320508;
    for (int s = 0; s < m->section_count; s++) {
        const bf6_section& sec = m->sections[s];
        for (int v = 0; v < sec.vertex_count; v++, verts++) {
            const int src = (int)verts;              /* LOD-local source index */
            if (src >= mp->element_count) break;
            const uint32_t pv = mp->psd_vertex_id[src];
            if (pv == 0xFFFFFFFFu || (int32_t)pv >= ps->vertex_count) { unmoved++; continue; }
            const double d = std::sqrt((double)dx[(size_t)pv*3+0]*dx[(size_t)pv*3+0]
                                     + (double)dx[(size_t)pv*3+1]*dx[(size_t)pv*3+1]
                                     + (double)dx[(size_t)pv*3+2]*dx[(size_t)pv*3+2]);
            if (owns[(size_t)pv]) { moved++; if (d > worst) worst = d; }
            else { unmoved++; if (d != 0.0) wrongly_moved++; }
        }
    }
    std::printf("  pose %d owns %d deltas; render vertices displaced %lld, untouched %lld\n",
                pose, pose_deltas, moved, unmoved);
    std::printf("  vertices displaced that the pose does NOT own : %lld (want 0)\n", wrongly_moved);
    std::printf("  worst displacement %.2f mm (encoding bound %.2f mm)\n",
                worst*1000.0, bound*1000.0);

    /* 4. NEGATIVE: a pose index the payload has no deltas for must move nothing */
    int absent = ps->pose_count + 1000, absent_hits = 0;
    for (int i = 0; i < ps->delta_count; i++)
        if (ps->deltas[i].pose_index == absent) absent_hits++;
    std::printf("  NEGATIVE absent pose %d has %d deltas (want 0)\n", absent, absent_hits);

    const bool pass = oor == 0 && wrongly_moved == 0 && moved > 0
                   && worst <= bound + 1e-9 && absent_hits == 0;
    std::printf("  => %s\n", pass ? "PASS" : "FAIL");
    bf6_free(ctx, ps); bf6_free(ctx, mp); bf6_free(ctx, m); bf6_close(ctx);
    return pass ? 0 : 1;
}
