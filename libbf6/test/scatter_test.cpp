/* Exact runtime MeshScatteringDatabase catalogue and fake-level control.
 *   scatter_test <game_dir> <level>
 */
#include <cstdio>
#include <vector>
#include "bf6_core.h"

int main(int argc, char** argv)
{
    if (argc < 3) { std::printf("usage: scatter_test <game_dir> <level>\n"); return 2; }
    char err[512] = {};
    bf6_ctx* ctx = bf6_open(argv[1], err, sizeof(err));
    if (!ctx) { std::printf("open: %s\n", err); return 1; }
    const int n = bf6_level_scatter(ctx, argv[2], nullptr, 0, err, sizeof(err));
    if (n < 0) { std::printf("scatter: %s\n", err); return 1; }
    std::vector<bf6_scatter_entry> rows((size_t)n);
    const int n2 = bf6_level_scatter(ctx, argv[2], rows.data(), n, err, sizeof(err));
    int resolved = 0, with_points = 0;
    for (const bf6_scatter_entry& r : rows) {
        if (r.mesh_res && *r.mesh_res) resolved++;
        if (r.point_count > 0) with_points++;
        std::printf("%6.1fm  fade %.3f  pts %3d  %s\n", r.view_distance,
                    r.dissolve_ratio, r.point_count,
                    r.mesh_res && *r.mesh_res ? r.mesh_res : r.name);
    }
    // CONTROL: widening to the one database already mounted would return a
    // plausible catalogue for a fake level. The correct score is zero.
    char ctlerr[512] = {};
    const int control = bf6_level_scatter(ctx, "MP_NotARealLevel", nullptr, 0,
                                          ctlerr, sizeof(ctlerr));
    std::printf("%s: %d record(s), %d mesh(es) resolved, %d with opaque points\n",
                argv[2], n2, resolved, with_points);
    std::printf("CONTROL fake level: %d (expected 0 or mount rejection)\n", control);
    bf6_close(ctx);
    return (n2 == n && resolved == n && control <= 0) ? 0 : 1;
}
