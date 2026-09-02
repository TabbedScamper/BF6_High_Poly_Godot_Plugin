/* pose_test - skin a character end to end and check the bind-pose identity.
 *
 * This is the test that exercises the WHOLE chain at once: influence count,
 * lane pairing, the 0x8000 remap, the skin indices being skeleton ids, the
 * inverse bind, the model bind, and the composition order. Any one of them
 * wrong and the result moves.
 *
 * WHAT THIS TEST CANNOT DO. Because inverse[b] o model[b] is the identity for
 * EVERY bone b, the bind-pose identity is insensitive to WHICH bone a vertex
 * names. It verifies the weights, the two bind poses and that indices resolve -
 * it does NOT verify that the indices are the right bones. Only the semantic
 * check (a face mesh must ride Head and Neck, a body mesh Spine and Hips) does
 * that, and it lives in skin_test.
 *
 * The identity: skinning with pose == model must reproduce the mesh EXACTLY.
 *
 *     v' = sum_k w_k * ( v * inverse[b_k] * pose[b_k] )
 *
 * At bind pose the inverse cancels the model, so each term is v, and the
 * weights sum to 1, so v' = v. It sounds trivial and it is not: it is only
 * true if every part of the chain is right, and it fails loudly otherwise.
 *
 * Three negative controls run alongside, each disabling one thing that is
 * supposed to matter. If a negative reproduces the mesh too, the positive
 * proved nothing.
 */
#include <cstdio>
#include <cstdlib>
#include <cmath>
#include <vector>
#include "bf6_core.h"

static void xform(const float* m, const float* v, float* o) {
    o[0] = v[0]*m[0] + v[1]*m[3] + v[2]*m[6] + m[9];
    o[1] = v[0]*m[1] + v[1]*m[4] + v[2]*m[7] + m[10];
    o[2] = v[0]*m[2] + v[1]*m[5] + v[2]*m[8] + m[11];
}
static void mul(const float* a, const float* b, float* o) {
    for (int r = 0; r < 4; r++)
        for (int c = 0; c < 3; c++) {
            float s = 0.0f;
            for (int k = 0; k < 3; k++) s += a[r*3+k] * b[k*3+c];
            if (r == 3) s += b[9+c];
            o[r*3+c] = s;
        }
}

static bool close(const float* a, const float* b, float tol = 1e-3f) {
    for (int i = 0; i < 12; i++) if (std::fabs(a[i] - b[i]) > tol) return false;
    return true;
}
static const float IDENT[12] = {1,0,0, 0,1,0, 0,0,1, 0,0,0};

/* A general inverse of a 3x4 affine. These transforms carry scale, so the
 * transpose shortcut is wrong - which one of the NEG controls measures. */
static bool invert(const float* m, float* o) {
    const float a=m[0],b=m[1],c=m[2], d=m[3],e=m[4],f=m[5], g=m[6],h=m[7],i=m[8];
    const float A=e*i-f*h, B=f*g-d*i, C=d*h-e*g;
    const float det = a*A + b*B + c*C;
    if (std::fabs(det) < 1e-12f) return false;
    const float s = 1.0f/det;
    o[0]=A*s; o[1]=(c*h-b*i)*s; o[2]=(b*f-c*e)*s;
    o[3]=B*s; o[4]=(a*i-c*g)*s; o[5]=(c*d-a*f)*s;
    o[6]=C*s; o[7]=(b*g-a*h)*s; o[8]=(a*e-b*d)*s;
    const float tx=m[9],ty=m[10],tz=m[11];
    o[9]  = -(tx*o[0] + ty*o[3] + tz*o[6]);
    o[10] = -(tx*o[1] + ty*o[4] + tz*o[7]);
    o[11] = -(tx*o[2] + ty*o[5] + tz*o[8]);
    return true;
}

/* THE COMPOSED SKELETON: the rig, then the renderbones in order, so entry k is
 * bone rigCount + k. Every renderbone parent is already composed when reached,
 * so one forward pass suffices - the same property the rig has. */
struct Composed {
    std::vector<float> model, inverse;   /* 12 floats per bone */
    int rig = 0, total = 0;
};

/* mode 0 = correct; 1 = transpose instead of inverse; 2 = first 4 lanes only;
 * 3 = skip the inverse entirely. */
static void run(const bf6_mesh* m, const Composed& C, int mode, const char* label) {
    long long ok = 0, tot = 0, unresolved = 0;
    double worst = 0.0;
    for (int i = 0; i < m->section_count; i++) {
        const bf6_section& s = m->sections[i];
        if (!s.skin_bones || s.skin_influences <= 0) continue;
        const int inf = s.skin_influences;
        const int lanes = (mode == 2 && inf > 4) ? 4 : inf;
        for (int v = 0; v < s.vertex_count; v++) {
            const float* p = &s.positions[(size_t)v*3];
            float acc[3] = {0,0,0};
            bool bad = false;
            /* A vertex that references a RENDERBONE cannot be placed from the
             * skeleton alone: the flagged index names a slot in the mesh's
             * appended Renderbones array, which is a separate asset. Count
             * those rather than scoring them as failures - they are not wrong,
             * they are outside what a rig-only consumer can resolve. */
            for (int k = 0; k < lanes; k++) {
                const size_t d = (size_t)v*inf + k;
                const uint16_t rawb = s.skin_bones[d];
                const float w = s.skin_weights[d];
                if (w == 0.0f) continue;
                /* Resolve a flagged index against the COMPOSED skeleton:
                 * renderbone slot ((raw & 0x7FFF) >> 1) is bone rig + slot. */
                const int b = (rawb & 0x8000) ? C.rig + (int)((rawb & 0x7FFF) >> 1) : (int)rawb;
                if (b < 0 || b >= C.total) { bad = true; break; }
                float skinm[12];
                if (mode == 3) {
                    for (int t = 0; t < 12; t++) skinm[t] = C.model[(size_t)b*12+t];
                } else if (mode == 1) {
                    const float* M = &C.model[(size_t)b*12];
                    const float tr[12] = { M[0],M[3],M[6], M[1],M[4],M[7], M[2],M[5],M[8], 0,0,0 };
                    mul(tr, M, skinm);
                } else {
                    mul(&C.inverse[(size_t)b*12], &C.model[(size_t)b*12], skinm);
                }
                float q[3];
                xform(skinm, p, q);
                acc[0] += w*q[0]; acc[1] += w*q[1]; acc[2] += w*q[2];
            }
            if (bad) { unresolved++; continue; }
            const double dx = acc[0]-p[0], dy = acc[1]-p[1], dz = acc[2]-p[2];
            const double err = std::sqrt(dx*dx + dy*dy + dz*dz);
            if (err > worst) worst = err;
            if (err <= 1e-3) ok++;
            tot++;
        }
    }
    std::printf("  %-42s %8lld/%-8lld  worst %.5f m\n", label, ok, tot, worst);
}

int main(int argc, char** argv) {
    if (argc < 4) { std::printf("usage: pose_test <game> <mesh_res> <skeleton_ebx>\n"); return 2; }
    char err[256] = {0};
    bf6_ctx* ctx = bf6_open(argv[1], err, sizeof(err));
    if (!ctx) { std::printf("open: %s\n", err); return 1; }
    if (!bf6_mount_all(ctx, 1, err, sizeof(err)))
    { std::printf("mount: %s\n", err); bf6_close(ctx); return 1; }
    bf6_mesh* m = bf6_read_mesh(ctx, argv[2], 0);
    if (!m) { std::printf("mesh null\n"); bf6_close(ctx); return 1; }
    bf6_skeleton* sk = bf6_skeleton_read(ctx, argv[3]);
    if (!sk) { std::printf("skeleton null\n"); bf6_close(ctx); return 1; }

    Composed C;
    C.rig = sk->bone_count;
    C.total = C.rig;
    bf6_renderbones* rb = (argc > 4) ? bf6_renderbones_read(ctx, argv[4]) : nullptr;
    if (rb) C.total += rb->bone_count;
    C.model.resize((size_t)C.total*12);
    C.inverse.resize((size_t)C.total*12);
    for (int b = 0; b < C.rig; b++)
        for (int t = 0; t < 12; t++) {
            C.model[(size_t)b*12+t]   = sk->bones[b].model[t];
            C.inverse[(size_t)b*12+t] = sk->bones[b].inverse[t];
        }
    int rb_bad_parent = 0;
    for (int k = 0; rb && k < rb->bone_count; k++) {
        const int b = C.rig + k, par = rb->bones[k].parent;
        /* CONTROL: a renderbone parent must ALREADY be composed - a rig bone or
         * an earlier entry. If this fails the append-order model is wrong. */
        if (par < 0 || par >= b) {
            rb_bad_parent++;
            for (int t = 0; t < 12; t++) { C.model[(size_t)b*12+t] = IDENT[t];
                                           C.inverse[(size_t)b*12+t] = IDENT[t]; }
            continue;
        }
        mul(rb->bones[k].local, &C.model[(size_t)par*12], &C.model[(size_t)b*12]);
        if (!invert(&C.model[(size_t)b*12], &C.inverse[(size_t)b*12]))
            for (int t = 0; t < 12; t++) C.inverse[(size_t)b*12+t] = IDENT[t];
    }

    std::printf("MESH %s\nRIG  %s (%d bones)\n", argv[2],
                sk->name ? sk->name : argv[3], sk->bone_count);
    if (rb) std::printf("RB   %d renderbones -> composed %d bones; parents already composed %d/%d\n",
                        rb->bone_count, C.total, rb->bone_count - rb_bad_parent, rb->bone_count);
    /* CROSS-CHECK: the library's composer must agree with the hand-rolled
     * composition above, bone for bone. If they differ, one of them is wrong
     * and shipping the convenience function would hide it. */
    {
        bf6_skeleton* lib = bf6_skeleton_compose(ctx, argv[3], argc > 4 ? argv[4] : nullptr);
        if (!lib) std::printf("  library compose returned NULL\n");
        else {
            int same = 0, tot = lib->bone_count;
            for (int b = 0; b < tot && b < C.total; b++) {
                bool eq = true;
                for (int t = 0; t < 12; t++) {
                    if (std::fabs(lib->bones[b].model[t]   - C.model[(size_t)b*12+t])   > 1e-4f) eq = false;
                    if (std::fabs(lib->bones[b].inverse[t] - C.inverse[(size_t)b*12+t]) > 1e-4f) eq = false;
                }
                if (eq) same++;
            }
            std::printf("  library compose agrees with hand-rolled: %d/%d bones (rig %d)\n",
                        same, tot, lib->rig_bone_count);
            bf6_free(ctx, lib);
        }
    }
    std::printf("\n  %-42s %17s\n", "", "vertices exact");
    run(m, C, 0, "BIND POSE reproduces the mesh");
    std::printf("\n  negative controls - these must NOT reproduce it:\n");
    run(m, C, 1, "NEG transpose(model) used as the inverse");
    run(m, C, 2, "NEG only the first 4 influence lanes");
    run(m, C, 3, "NEG model with no inverse at all");
    if (rb) bf6_free(ctx, rb);
    bf6_free(ctx, sk); bf6_free(ctx, m); bf6_close(ctx);
    return 0;
}
