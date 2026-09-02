/* occluder_test - OccluderMesh, ported from findings/occluder-entities-decoded.md.
 *
 * CONTROLS, taken from the finding's own verification rather than invented:
 *   1. THE OFFSETS ARE PREDICTED from the two u16 counts and compared against
 *      the stored ones. The finding reports byte-exact on 324 of 324; anything
 *      less here means this reader has the layout wrong.
 *   2. EVERY VERTEX INSIDE THE HEADER AABB. The finding reports 324/324. This
 *      ties the vertex block to two floats read from a completely different
 *      part of the header, so it cannot be satisfied by reading the wrong
 *      region - the scratch block is zero-filled on 282 of 324 files and would
 *      fail this instantly.
 *   3. NO INDEX >= vertexCount, and indexCount a multiple of 3.
 *   4. scratchOffset is always 64.
 *   5. Fabricated resource names return nothing.
 */
#include "bf6_core.h"
#include <cstdio>
#include <cstring>
#include <cmath>
#include <vector>

int main(int argc, char** argv)
{
    if (argc < 2) { std::printf("usage: occluder_test <game> [max]\n"); return 2; }
    const int maxn = (argc > 2) ? atoi(argv[2]) : 400;
    char err[512] = {0};
    bf6_ctx* c = bf6_open(argv[1], err, (int)sizeof(err));
    if (!c) { std::printf("open: %s\n", err); return 1; }
    if (!bf6_mount_all(c, 1, err, (int)sizeof(err))) { std::printf("mount: %s\n", err); return 1; }

    const int total = bf6_list_res(c, nullptr, nullptr, 0);
    std::vector<bf6_asset> assets((size_t)(total > 0 ? total : 0));
    const int got = bf6_list_res(c, nullptr, assets.data(), total);

    int seen = 0, read = 0, pred_ok = 0, aabb_ok = 0, idx_ok = 0, scratch64 = 0, tri_ok = 0;
    long verts = 0, tris = 0;
    for (int i = 0; i < got && read < maxn; i++) {
        const bf6_asset& a = assets[(size_t)i];
        if (!a.name || a.type != 0x30B4A553u) continue;
        seen++;
        bf6_occluder_mesh* m = bf6_occluder_mesh_read(c, a.name);
        if (!m) continue;
        read++;
        if (m->offsets_predicted) pred_ok++;
        if (m->scratch_at == 64) scratch64++;
        if (m->index_count % 3 == 0) tri_ok++;
        verts += m->vertex_count; tris += m->index_count / 3;

        /* CONTROL 2: every vertex inside the header AABB, with a small epsilon
         * for float round-trip. The two corners are not asserted to be min/max
         * - the finding leaves that open - so the box is normalised here. */
        float lo[3], hi[3];
        for (int k = 0; k < 3; k++) {
            lo[k] = m->aabb_a[k] < m->aabb_b[k] ? m->aabb_a[k] : m->aabb_b[k];
            hi[k] = m->aabb_a[k] < m->aabb_b[k] ? m->aabb_b[k] : m->aabb_a[k];
        }
        bool inside = m->vertex_count > 0;
        for (uint32_t v = 0; v < m->vertex_count && inside; v++)
            for (int k = 0; k < 3; k++) {
                const float x = m->vertices[v * 3 + k];
                if (x < lo[k] - 0.01f || x > hi[k] + 0.01f) { inside = false; break; }
            }
        if (inside) aabb_ok++;

        bool ok = m->index_count > 0;
        for (uint32_t k = 0; k < m->index_count && ok; k++)
            if (m->indices[k] >= m->vertex_count) ok = false;
        if (ok) idx_ok++;
        bf6_free(c, m);
    }

    std::printf("  OccluderMesh seen %d   read %d\n", seen, read);
    std::printf("  vertices %ld   triangles %ld\n", verts, tris);
    std::printf("  offsets PREDICTED from the two u16 counts : %d of %d\n", pred_ok, read);
    std::printf("  every vertex inside the header AABB       : %d of %d\n", aabb_ok, read);
    std::printf("  no index >= vertexCount                   : %d of %d\n", idx_ok, read);
    std::printf("  indexCount a multiple of 3                : %d of %d\n", tri_ok, read);
    std::printf("  scratchOffset == 64                       : %d of %d\n", scratch64, read);

    int fake = 0;
    if (bf6_occluder_mesh_read(c, "common/environment/nope_zzz_mesh_occludermesh")) fake++;
    if (bf6_occluder_mesh_read(c, "not/a/resource")) fake++;
    std::printf("  fabricated reads returning data           : %d of 2 (must be 0)\n", fake);

    const bool pass = read > 50 && pred_ok == read && aabb_ok == read &&
                      idx_ok == read && tri_ok == read && scratch64 == read && fake == 0;
    std::printf("\n%s\n", pass ? "PASS" : "FAIL");
    bf6_close(c);
    return pass ? 0 : 1;
}
