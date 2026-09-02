/* skeleton_test - verify a rig read through the PUBLIC ABI.
 *
 * The three pose arrays are the whole point, and a mislabelled one still
 * produces 291 plausible matrices. These are the identities that separate them,
 * plus negative controls so a pass cannot be vacuous.
 */
#include <cstdio>
#include <cstdlib>
#include <cmath>
#include "bf6_core.h"

/* Compose two 3x4 row-major affine transforms: apply a, then b. */
static void mul(const float* a, const float* b, float* o) {
    for (int r = 0; r < 4; r++)
        for (int c = 0; c < 3; c++) {
            float s = 0.0f;
            for (int k = 0; k < 3; k++) s += a[r * 3 + k] * b[k * 3 + c];
            if (r == 3) s += b[9 + c];
            o[r * 3 + c] = s;
        }
}
static bool close(const float* a, const float* b, float tol = 1e-3f) {
    for (int i = 0; i < 12; i++) if (std::fabs(a[i] - b[i]) > tol) return false;
    return true;
}
static const float IDENT[12] = {1,0,0, 0,1,0, 0,0,1, 0,0,0};

int main(int argc, char** argv) {
    if (argc < 3) { std::printf("usage: skeleton_test <game> <ebx> [more ebx...]\n"); return 2; }
    char err[256] = {0};
    bf6_ctx* ctx = bf6_open(argv[1], err, sizeof(err));
    if (!ctx) { std::printf("open: %s\n", err); return 1; }
    if (!bf6_mount_all(ctx, 1, err, sizeof(err)))
    { std::printf("mount: %s\n", err); bf6_close(ctx); return 1; }

    int failures = 0;
    for (int a = 2; a < argc; a++) {
        bf6_skeleton* sk = bf6_skeleton_read(ctx, argv[a]);
        if (!sk) { std::printf("%-52s NOT A RIG (null)\n", argv[a]); continue; }
        const int n = sk->bone_count;
        int topo = 0, roots = 0, comp = 0, inv = 0, negI = 0, negT = 0;
        float t[12];
        for (int i = 0; i < n; i++) {
            const bf6_bone& b = sk->bones[i];
            if (b.parent < 0) { roots++; topo++; }
            else if (b.parent < i) topo++;

            /* model == local composed onto the parent's model */
            if (b.parent < 0) { if (close(b.local, b.model)) comp++; }
            else { mul(b.local, sk->bones[b.parent].model, t); if (close(t, b.model)) comp++; }

            /* inverse o model == identity */
            mul(b.inverse, b.model, t);
            if (close(t, IDENT)) inv++;

            /* NEGATIVE 1: inverse o LOCAL must NOT be the identity, except on
             * bones whose local and model already coincide (the root chain). */
            mul(b.inverse, b.local, t);
            if (close(t, IDENT)) negI++;

            /* NEGATIVE 2: the transpose is not the inverse. If this scores as
             * high as the real check, the rig has no rotation to speak of and
             * the inverse test proved nothing. */
            float tr[12] = { b.model[0], b.model[3], b.model[6],
                             b.model[1], b.model[4], b.model[7],
                             b.model[2], b.model[5], b.model[8],
                             0, 0, 0 };
            mul(tr, b.model, t);
            if (close(t, IDENT)) negT++;
        }
        const bool pass = (topo == n && roots == 1 && comp == n && inv == n);
        std::printf("%-52s bones %4d\n", argv[a], n);
        std::printf("    topological (parent < child)      %4d/%d\n", topo, n);
        std::printf("    exactly one root                  %4d\n", roots);
        std::printf("    model == local o model[parent]     %4d/%d\n", comp, n);
        std::printf("    inverse o model == identity        %4d/%d\n", inv, n);
        std::printf("    NEG inverse o local == identity    %4d/%d\n", negI, n);
        std::printf("    NEG transpose(model) is inverse    %4d/%d\n", negT, n);
        std::printf("    => %s\n\n", pass ? "PASS" : "FAIL");
        if (!pass) failures++;
        bf6_free(ctx, sk);
    }
    bf6_close(ctx);
    return failures ? 1 : 0;
}
