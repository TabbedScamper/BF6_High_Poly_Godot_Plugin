/* mesh_read_test - exercise the PUBLIC ABI: bf6_open + bf6_read_mesh. */
#include <cstdio>
#include "bf6_core.h"
int main(int argc, char** argv) {
    if (argc < 3) { std::printf("usage: mesh_read_test <game> <res>\n"); return 2; }
    char err[256] = {0};
    bf6_ctx* ctx = bf6_open(argv[1], err, sizeof(err));
    if (!ctx) { std::printf("open: %s\n", err); return 1; }
    bf6_mesh* m = bf6_read_mesh(ctx, argv[2], 0);
    if (!m) { std::printf("read_mesh returned null\n"); bf6_close(ctx); return 1; }
    std::printf("MESH sections=%d aabb=[%.2f %.2f %.2f]..[%.2f %.2f %.2f]\n",
        m->section_count, m->aabb_min[0], m->aabb_min[1], m->aabb_min[2],
        m->aabb_max[0], m->aabb_max[1], m->aabb_max[2]);
    for (int i = 0; i < m->section_count; i++) {
        const bf6_section& s = m->sections[i];
        std::printf("  S%d verts=%d tris=%d normals=%s uv0=%s\n", i,
            s.vertex_count, s.index_count / 3,
            s.normals ? "yes" : "no", s.uv0 ? "yes" : "no");
    }
    bf6_free(ctx, m);
    bf6_close(ctx);
    return 0;
}
