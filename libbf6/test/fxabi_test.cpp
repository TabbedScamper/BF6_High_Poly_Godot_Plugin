/* The FX decode over the C ABI, the way a binding will call it.
 *   fxabi_test <game_dir> <MAP> [effect-substring]
 */
#include <cstdio>
#include <cstring>
#include <vector>
#include "bf6_core.h"

int main(int argc, char** argv)
{
    if (argc < 3) { std::fprintf(stderr, "fxabi_test <game_dir> <MAP>\n"); return 2; }
    char err[512] = "";
    bf6_ctx* c = bf6_open(argv[1], err, (int)sizeof(err));
    if (!c) { std::fprintf(stderr, "open: %s\n", err); return 1; }
    if (bf6_open_level(c, argv[2], nullptr, 0, err, (int)sizeof(err)) != 0) {
        std::fprintf(stderr, "level: %s\n", err); return 1;
    }

    bf6_fx_stats st{};
    const int n = bf6_level_fx(c, argv[2], nullptr, 0, &st, err, (int)sizeof(err));
    if (n <= 0) { std::fprintf(stderr, "fx: %s\n", err); return 1; }
    std::printf("%s: %d layers  placements=%d effects=%d graph=%d atlas=%d"
                " (ovr %d tmpl %d) rid=%d res=%d chunk=%d lm=%d al=%d\n",
                argv[2], n, st.placements, st.distinct_effects, st.graph_resolved,
                st.atlas_resolved, st.atlas_override, st.atlas_template,
                st.rid_present, st.res_resolved, st.chunk_named,
                st.lighting_model, st.alignment);

    std::vector<bf6_fx_layer> rows((size_t)n);
    bf6_level_fx(c, argv[2], rows.data(), n, nullptr, err, (int)sizeof(err));

    int with_sheet = 0, first_sheet = -1;
    for (int i = 0; i < n; i++) {
        if (!rows[(size_t)i].atlas_chunk) continue;
        with_sheet++;
        if (first_sheet < 0) first_sheet = i;
    }
    std::printf("rows with a resolvable sheet: %d\n", with_sheet);

    // Optional placement audit for one effect/layer family. Search every
    // authored identity string, not just the effect leaf: water foam commonly
    // has a generic effect name and is identified by its graph or atlas.
    // This stays in the test harness: it is evidence for an engine binding,
    // never a staged runtime input. A fake substring is the zero-hit control.
    if (argc > 3) {
        const char* q = argv[3];
        int matched = 0;
        for (int i = 0; i < n; i++) {
            const bf6_fx_layer& L = rows[(size_t)i];
            const bool hit =
                (L.effect      && std::strstr(L.effect, q)) ||
                (L.effect_path && std::strstr(L.effect_path, q)) ||
                (L.graph       && std::strstr(L.graph, q)) ||
                (L.family      && std::strstr(L.family, q)) ||
                (L.atlas       && std::strstr(L.atlas, q)) ||
                (L.atlas_res   && std::strstr(L.atlas_res, q));
            if (!L.effect_path || !hit) continue;
            bool seen = false;
            for (int j = 0; j < i; j++)
                if (rows[(size_t)j].effect_path && !std::strcmp(rows[(size_t)j].effect_path, L.effect_path))
                    seen = true;
            if (seen) continue;
            matched++;
            const int np = bf6_fx_placements(c, argv[2], L.effect_path, nullptr, 0);
            std::vector<float> xf((size_t)np * 12);
            const int got = bf6_fx_placements(c, argv[2], L.effect_path, xf.data(), np);
            std::printf("MATCH row=%d effect=%s layer=%d family=%s placements=%d\n"
                        "  graph=%s\n  atlas=%s %dx%d cols=%d frames=%d params=%d\n",
                        i, L.effect ? L.effect : "", L.layer,
                        L.family ? L.family : "", got,
                        L.graph ? L.graph : "", L.atlas ? L.atlas : "",
                        L.atlas_width, L.atlas_height, L.atlas_cols,
                        L.atlas_frames, L.param_count);
            for (int k = 0; k < got; k++) {
                const float* m = xf.data() + (size_t)k * 12;
                std::printf("  P %d %.3f %.3f %.3f\n", k, m[9], m[10], m[11]);
            }
        }
        std::printf("CONTROL substring=%s matched=%d\n", q, matched);
    }

    if (first_sheet >= 0) {
        const bf6_fx_layer& L = rows[(size_t)first_sheet];
        std::printf("row %d  %s / layer %d  graph=%s family=%s\n", first_sheet,
                    L.effect, L.layer, L.graph, L.family);
        std::printf("   sheet %s  %dx%d cols=%d frames=%d lr=%d rid=%016llx  params=%d\n",
                    L.atlas, L.atlas_width, L.atlas_height, L.atlas_cols,
                    L.atlas_frames, L.atlas_left_right,
                    (unsigned long long)L.atlas_rid, L.param_count);
        for (int f : { 0, 1, L.atlas_frames - 1 }) {
            float uv[4];
            bf6_fx_frame_uv(&L, f, uv);
            std::printf("   frame %-4d uv = (%.6f, %.6f) .. (%.6f, %.6f)\n",
                        f, uv[0], uv[1], uv[2], uv[3]);
        }
        const uint8_t* px = nullptr; int32_t sz = 0;
        if (bf6_fx_atlas_mip0(c, argv[2], first_sheet, &px, &sz, err, (int)sizeof(err)))
            std::printf("   mip0 %d bytes, first block %02x %02x %02x %02x\n",
                        sz, px[0], px[1], px[2], px[3]);
        else
            std::printf("   mip0 failed: %s\n", err);

        // Where the effect is placed.
        const int np = bf6_fx_placements(c, argv[2], L.effect_path, nullptr, 0);
        std::vector<float> xf((size_t)np * 12);
        bf6_fx_placements(c, argv[2], L.effect_path, xf.data(), np);
        std::printf("   placed %d time(s); first at (%.2f, %.2f, %.2f)\n", np,
                    np ? xf[9] : 0.f, np ? xf[10] : 0.f, np ? xf[11] : 0.f);
    }

    // The parameter read rule, on one lit layer.
    for (int i = 0; i < n; i++) {
        const bf6_fx_layer& L = rows[(size_t)i];
        if (L.lighting_model < 0 || L.param_count < 4) continue;
        std::printf("lit row %d %s L%d  lighting_model=%d alignment=%d, first 4 params:\n",
                    i, L.effect, L.layer, L.lighting_model, L.alignment);
        for (int k = 0; k < 4; k++) {
            const bf6_fx_param& p = L.params[k];
            const int w = (p.type == 1) ? 2 : (p.type == 2) ? 3 : (p.type == 3) ? 4 : 1;
            std::printf("   pid=0x%08X type=%d cb=%d ", p.pid, p.type, p.cb_offset);
            if (p.type == 4 || p.type == 5) std::printf("ivalue=%d\n", p.ivalue);
            else {
                std::printf("v =");
                for (int q = 0; q < w; q++) std::printf(" %g", (double)p.v[q]);
                std::printf("\n");
            }
        }
        break;
    }
    bf6_close(c);
    return 0;
}
