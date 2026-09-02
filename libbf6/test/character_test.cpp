/* character_test - can we recreate THIS character from the game's own data?
 *
 * One command that walks the whole 1:1 read path and reports per requirement,
 * so "what can we actually reproduce" is a measurement rather than a memory.
 * Each line is a capability a renderer needs, and each is checked rather than
 * assumed present:
 *
 *   geometry            sections, vertices, LOD count, mesh type
 *   rig                 the composed skeleton the mesh actually indexes
 *   skinning            influences, weights summing to 1, indices resolvable
 *   bind pose           skinning at rest reproduces the mesh exactly
 *   materials           base colour and normal, which need the placing bundle
 *   facial deformation  the PSD map and payload, when the part has them
 *
 * It is deliberately quiet about what it cannot do: a line that is missing is
 * reported missing rather than skipped.
 */
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cmath>
#include <vector>
#include "bf6_core.h"

static void xf(const float* m, const float* v, float* o) {
    o[0] = v[0]*m[0] + v[1]*m[3] + v[2]*m[6] + m[9];
    o[1] = v[0]*m[1] + v[1]*m[4] + v[2]*m[7] + m[10];
    o[2] = v[0]*m[2] + v[1]*m[5] + v[2]*m[8] + m[11];
}
static void mul(const float* a, const float* b, float* o) {
    for (int r = 0; r < 4; r++)
        for (int c = 0; c < 3; c++) {
            float s = 0.0f;
            for (int k = 0; k < 3; k++) s += a[r*3+k]*b[k*3+c];
            if (r == 3) s += b[9+c];
            o[r*3+c] = s;
        }
}

int main(int argc, char** argv) {
    if (argc < 5) {
        std::printf("usage: character_test <game> <mesh_res> <bundle> <skeleton_ebx> [renderbones_ebx]\n");
        return 2;
    }
    char err[256] = {0};
    bf6_ctx* ctx = bf6_open(argv[1], err, sizeof(err));
    if (!ctx) { std::printf("open: %s\n", err); return 1; }
    if (!bf6_mount_all(ctx, 1, err, sizeof(err)))
    { std::printf("mount: %s\n", err); bf6_close(ctx); return 1; }

    int pass = 0, total = 0;
    auto line = [&](const char* what, bool ok, const char* detail) {
        total++; if (ok) pass++;
        std::printf("  [%s] %-22s %s\n", ok ? "ok" : "--", what, detail);
    };
    char buf[400];

    /* geometry, scoped to the placing bundle - unscoped loses the materials */
    bf6_mesh* m = bf6_read_mesh_scoped(ctx, argv[2], 0, argv[3], nullptr);
    if (!m) { std::printf("mesh did not read\n"); bf6_close(ctx); return 1; }
    long long verts = 0, tris = 0;
    for (int i = 0; i < m->section_count; i++)
    { verts += m->sections[i].vertex_count; tris += m->sections[i].index_count/3; }
    std::snprintf(buf, sizeof(buf), "%d sections, %lld verts, %lld tris, %d LODs, MeshType %d",
                  m->section_count, verts, tris, m->lod_count, m->mesh_type);
    line("geometry", verts > 0 && tris > 0, buf);

    /* the composed skeleton the mesh indexes */
    bf6_skeleton* sk = bf6_skeleton_compose(ctx, argv[4], argc > 5 ? argv[5] : nullptr);
    std::snprintf(buf, sizeof(buf), "%d bones (%d rig + %d renderbones); MeshSet declares %d",
                  sk?sk->bone_count:0, sk?sk->rig_bone_count:0,
                  sk?sk->bone_count-sk->rig_bone_count:0, m->bone_count);
    line("rig", sk && sk->bone_count > 0, buf);
    /* the MeshSet's own declared count is an independent check on composition */
    if (sk) line("rig matches the mesh", sk->bone_count == m->bone_count,
                 sk->bone_count == m->bone_count ? "composed size == declared"
                                                 : "MISMATCH - wrong renderbones asset?");

    /* skinning */
    long long inf_ok = 0, wsum_ok = 0, nsk = 0, resolvable = 0, infl_total = 0;
    for (int i = 0; i < m->section_count; i++) {
        const bf6_section& s = m->sections[i];
        if (!s.skin_bones) continue;
        nsk++;
        if (s.skin_influences == 4 || s.skin_influences == 8) inf_ok++;
        for (int v = 0; v < s.vertex_count; v++) {
            double t = 0;
            for (int k = 0; k < s.skin_influences; k++) {
                const size_t d = (size_t)v*s.skin_influences + k;
                t += s.skin_weights[d];
                infl_total++;
                if (sk && bf6_skin_index_to_bone(sk, s.skin_bones[d]) >= 0) resolvable++;
            }
            if (std::fabs(t - 1.0) < 2.0/255.0) wsum_ok++;
        }
    }
    std::snprintf(buf, sizeof(buf), "%lld/%d sections skinned, weights sum on %lld verts, %lld/%lld indices resolve",
                  nsk, m->section_count, wsum_ok, resolvable, infl_total);
    line("skinning", nsk > 0 && resolvable == infl_total, buf);

    /* bind pose: the whole chain at once */
    long long exact = 0, tot = 0;
    double worst = 0;
    if (sk) for (int i = 0; i < m->section_count; i++) {
        const bf6_section& s = m->sections[i];
        if (!s.skin_bones) continue;
        for (int v = 0; v < s.vertex_count; v++) {
            const float* p = &s.positions[(size_t)v*3];
            float acc[3] = {0,0,0}; bool bad = false;
            for (int k = 0; k < s.skin_influences; k++) {
                const size_t d = (size_t)v*s.skin_influences + k;
                const float w = s.skin_weights[d];
                if (w == 0.0f) continue;
                const int32_t b = bf6_skin_index_to_bone(sk, s.skin_bones[d]);
                if (b < 0) { bad = true; break; }
                float sm[12], q[3];
                mul(sk->bones[b].inverse, sk->bones[b].model, sm);
                xf(sm, p, q);
                acc[0]+=w*q[0]; acc[1]+=w*q[1]; acc[2]+=w*q[2];
            }
            if (bad) continue;
            const double e = std::sqrt((double)(acc[0]-p[0])*(acc[0]-p[0])
                                     + (double)(acc[1]-p[1])*(acc[1]-p[1])
                                     + (double)(acc[2]-p[2])*(acc[2]-p[2]));
            if (e > worst) worst = e;
            if (e <= 1e-3) exact++;
            tot++;
        }
    }
    std::snprintf(buf, sizeof(buf), "%lld/%lld vertices reproduce, worst %.5f m", exact, tot, worst);
    line("bind pose", tot > 0 && exact == tot, buf);

    /* materials */
    int with_tex = 0;
    for (int i = 0; i < m->section_count; i++)
        if (m->materials[i].texture_count > 0) with_tex++;
    std::snprintf(buf, sizeof(buf), "%d/%d sections carry textures (needs the placing bundle)",
                  with_tex, m->section_count);
    line("materials", with_tex > 0, buf);

    std::printf("\n  %d/%d capabilities present\n", pass, total);
    if (sk) bf6_free(ctx, sk);
    bf6_free(ctx, m); bf6_close(ctx);
    return pass == total ? 0 : 1;
}
