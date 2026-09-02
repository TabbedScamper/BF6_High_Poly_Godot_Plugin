/* chardeform_test - re-run the published controls THROUGH the public ABI.
 *
 * A reader that exists is not a reader that works. These are the same controls
 * the findings record, evaluated on what the ABI actually hands back, so a
 * regression in the reader fails here rather than in someone's renderer.
 *
 *   adjacency: a triangle is referenced by exactly 3 vertices (~96%)
 *              mean fan size ~6 (closed triangulated 2-manifold)
 *              every face id < 2 x vertex count
 *   hair bind: 0 <= w0, 0 <= w1, w0 + w1 <= 1   (w2 is implied)
 *              no degenerate scalp triangle
 *              scalp index range shrinks per LOD
 */
#include <cstdio>
#include <cstdlib>
#include <vector>
#include <cstring>
#include "bf6_core.h"

static int adjacency(bf6_ctx* ctx, const char* res) {
    bf6_deform_adjacency* a = bf6_deform_adjacency_read(ctx, res);
    if (!a) { std::printf("  ADJACENCY %s -> null\n", res); return 1; }
    const int nv = a->vertex_count;
    int maxf = 0;
    for (int i = 0; i < a->face_count; i++) if (a->faces[i] > maxf) maxf = a->faces[i];
    std::vector<int> refs((size_t)maxf + 1, 0);
    for (int i = 0; i < a->face_count; i++) refs[a->faces[i]]++;
    long long three = 0, used = 0;
    for (size_t f = 0; f < refs.size(); f++) if (refs[f]) { used++; if (refs[f] == 3) three++; }
    const double mean = (double)a->face_count / (double)nv;
    const bool inrange = maxf < 2 * nv;
    std::printf("  vertices %6d  ids %7d  mean fan %.2f  max face id %6d (< 2x verts: %s)\n",
                nv, a->face_count, mean, maxf, inrange ? "yes" : "NO");
    std::printf("    faces referenced by exactly 3 vertices : %lld/%lld (%.1f%%)\n",
                three, used, 100.0 * (double)three / (double)(used ? used : 1));
    const bool pass = inrange && mean > 5.0 && mean < 7.0 &&
                      (double)three / (double)(used ? used : 1) > 0.85;
    std::printf("    => %s\n", pass ? "PASS" : "FAIL");
    bf6_free(ctx, a);
    return pass ? 0 : 1;
}

static int hairbind(bf6_ctx* ctx, const char* res) {
    bf6_hair_bind* b = bf6_hair_bind_read(ctx, res);
    if (!b) { std::printf("  HAIRBIND %s -> null\n", res); return 1; }
    if (b->lod_count == 0) {
        std::printf("  %s\n    no per-strand LOD binding (highdef tier binds every vertex) - EXPECTED\n", res);
        bf6_free(ctx, b); return 0;
    }
    long long okw = 0, totw = 0, degen = 0, tottri = 0;
    int prevmax = 1 << 30; bool shrinks = true;
    for (int L = 0; L < b->lod_count; L++) {
        const int ns = b->lod_strands[L];
        const int bo = b->lod_first_bary[L], to = b->lod_first_tri[L];
        int mx = 0;
        for (int s = 0; s < ns; s++) {
            const float w0 = b->bary[bo + s*2], w1 = b->bary[bo + s*2 + 1];
            totw++;
            if (w0 >= -1e-4f && w1 >= -1e-4f && w0 + w1 <= 1.0f + 1e-3f) okw++;
            const uint16_t a0 = b->tri[to + s*3], a1 = b->tri[to + s*3 + 1], a2 = b->tri[to + s*3 + 2];
            tottri++;
            if (a0 == a1 || a1 == a2 || a0 == a2) degen++;
            if (a0 > mx) mx = a0; if (a1 > mx) mx = a1; if (a2 > mx) mx = a2;
        }
        if (mx > prevmax) shrinks = false;
        prevmax = mx;
        std::printf("    lod %d  strands %5d  max scalp index %6d\n", L, ns, mx);
    }
    std::printf("    barycentric valid : %lld/%lld\n    degenerate triangles: %lld/%lld\n"
                "    index range shrinks per lod: %s\n", okw, totw, degen, tottri,
                shrinks ? "yes" : "NO");
    const bool pass = (okw == totw) && (degen == 0) && shrinks;
    std::printf("    => %s\n", pass ? "PASS" : "FAIL");
    bf6_free(ctx, b);
    return pass ? 0 : 1;
}

int main(int argc, char** argv) {
    if (argc < 3) { std::printf("usage: chardeform_test <game> adj:<res> | hair:<res> ...\n"); return 2; }
    char err[256] = {0};
    bf6_ctx* ctx = bf6_open(argv[1], err, sizeof(err));
    if (!ctx) { std::printf("open: %s\n", err); return 1; }
    if (!bf6_mount_all(ctx, 1, err, sizeof(err)))
    { std::printf("mount: %s\n", err); bf6_close(ctx); return 1; }
    int bad = 0;
    for (int i = 2; i < argc; i++) {
        const char* s = argv[i];
        if (!std::strncmp(s, "adj:", 4))       { std::printf("\nADJACENCY %s\n", s+4); bad += adjacency(ctx, s+4); }
        else if (!std::strncmp(s, "hair:", 5)) { std::printf("\nHAIRBIND %s\n", s+5); bad += hairbind(ctx, s+5); }
    }
    bf6_close(ctx);
    std::printf("\n%s\n", bad ? "SOME CHECKS FAILED" : "all checks passed");
    return bad ? 1 : 0;
}
