/* vista_test - the far-LOD impostor (backdrop building) material contract,
 * on the exact meshes the research hub's finding was proven on.
 *
 * far-lod-impostors-bind-colour-at-wrap-overlay-slot, Aftermath M_Vista,
 * statically recovered shaders:
 *   - colour is the wrap slot's vst_*_c atlas, sampled on UV0, unflipped
 *   - the pixel shader reads RGB only: NO alpha test, however binary the
 *     sheet's alpha looks
 *   - the paired vst_*_nsm is RG normal / B wetness / A smoothness, and the
 *     desc must say so (normal_is_nsm) or a consumer unpacks it as a plain
 *     normal map and lights wetness as metal
 *
 *   vista_test <game_dir>
 */
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>
#include "bf6_core.h"

static int fail_count = 0;
#define CHECK(cond, ...) do { \
    if (cond) { std::printf("  ok   " __VA_ARGS__); std::printf("\n"); } \
    else      { std::printf("  FAIL " __VA_ARGS__); std::printf("\n"); fail_count++; } \
} while (0)

static void check_mesh(bf6_ctx* ctx, const char* stem, int lod)
{
    std::vector<bf6_cat_entry> cat(64);
    const int n = bf6_catalogue(ctx, stem, cat.data(), (int)cat.size());
    std::string res;
    for (int i = 0; i < n && i < (int)cat.size(); i++) {
        const std::string r = cat[i].res_name;
        if (r.size() >= 5 && r.compare(r.size() - 5, 5, "_mesh") == 0) { res = r; break; }
    }
    std::printf("%s (lod %d)\n", stem, lod);
    if (res.empty()) { std::printf("  FAIL no _mesh in the catalogue for this stem\n"); fail_count++; return; }
    std::printf("  res %s\n", res.c_str());

    bf6_mesh* m = bf6_read_mesh(ctx, res.c_str(), lod);
    if (!m) { std::printf("  FAIL bf6_read_mesh returned null\n"); fail_count++; return; }

    // The vista sections are the ones whose material carries an albedo AND a
    // normal binding with the nsm flag; a mesh can also hold non-vista
    // sections at this LOD, so the contract is "at least one, and every
    // flagged one obeys all of it".
    int vista_sections = 0, albedo_ok = 0, nsm_ok = 0, alpha_ok = 0, decode_ok = 0;
    for (int i = 0; i < m->material_count; i++) {
        const bf6_material_desc& md = m->materials[i];
        if (!md.normal_is_nsm) continue;
        vista_sections++;
        int albedo_tex = -1, normal_tex = -1;
        for (int t = 0; t < md.texture_count; t++) {
            if (md.textures[t].slot == BF6_TEX_ALBEDO) albedo_tex = md.textures[t].texture;
            if (md.textures[t].slot == BF6_TEX_NORMAL) normal_tex = md.textures[t].texture;
        }
        if (albedo_tex >= 0) albedo_ok++;
        if (normal_tex >= 0) nsm_ok++;
        if (md.alpha_test == 0) alpha_ok++;
        const bf6_texture* a = albedo_tex >= 0 ? bf6_texture_at(ctx, albedo_tex) : nullptr;
        const bf6_texture* nm = normal_tex >= 0 ? bf6_texture_at(ctx, normal_tex) : nullptr;
        if (a && nm) decode_ok++;
    }
    CHECK(vista_sections > 0, "vista (nsm-flagged) sections: %d", vista_sections);
    CHECK(albedo_ok == vista_sections, "wrap-slot albedo bound on all: %d of %d", albedo_ok, vista_sections);
    CHECK(nsm_ok == vista_sections, "nsm normal bound on all: %d of %d", nsm_ok, vista_sections);
    CHECK(alpha_ok == vista_sections, "NO alpha test on any: %d of %d", alpha_ok, vista_sections);
    CHECK(decode_ok == vista_sections, "both sheets decode: %d of %d", decode_ok, vista_sections);
    bf6_free(ctx, m);
}

int main(int argc, char** argv)
{
    if (argc < 2) { std::printf("usage: vista_test <game_dir>\n"); return 2; }
    char err[512] = {0};
    bf6_ctx* ctx = bf6_open(argv[1], err, sizeof(err));
    if (!ctx) { std::printf("open: %s\n", err); return 1; }
    if (bf6_open_level(ctx, "mp_aftermath", nullptr, 0, err, sizeof(err)) != 0) {
        std::printf("open_level: %s\n", err); bf6_close(ctx); return 1;
    }

    // The exact mesh the finding's static shader recovery ran on (LOD3), and
    // the one its binding table was first measured on (LOD4).
    check_mesh(ctx, "euu_panoramabuilding_topparta_01", 3);
    check_mesh(ctx, "euu_blockbuildingtopfacade_01_1280x1664_c90_indest", 4);

    bf6_close(ctx);
    std::printf(fail_count == 0 ? "PASS\n" : "FAIL (%d)\n", fail_count);
    return fail_count == 0 ? 0 : 1;
}
