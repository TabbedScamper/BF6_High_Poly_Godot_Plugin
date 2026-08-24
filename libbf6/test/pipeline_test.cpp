/* THE WHOLE PUBLIC PATH, THE WAY A CONSUMER ACTUALLY DRIVES IT.
 *
 * Not shipped. Every other test here reaches past the C ABI into the internal
 * classes, which is right for isolating one decoder and wrong for catching the
 * thing that actually breaks a release: a change that is correct in the module
 * and never reaches the caller, or one that makes the caller return null for
 * every mesh. Both look fine in a unit test.
 *
 * So this drives the exported functions in the order the add-on drives them:
 *
 *   bf6_open -> bf6_open_level -> bf6_level_instances -> bf6_read_mesh_scoped
 *
 * and reports what a renderer would get: sections, triangles, how many sections
 * carry a base colour, how many carry a non-white colour from the record, and
 * how many are alpha-tested or translucent. Numbers rather than a pass, because
 * "it returned a mesh" is not the question - "did the mesh come back with the
 * things we spent the week adding" is.
 *
 *   pipeline_test <game_dir> <level> <exe> [max_meshes]
 */
#include "bf6_core.h"

#include <cstdio>
#include <cstring>
#include <set>
#include <string>

int main(int argc, char** argv)
{
    if (argc < 4)
    {
        std::fprintf(stderr, "usage: pipeline_test <game_dir> <level> <exe> [max]\n");
        return 2;
    }
    const int limit = argc > 4 ? std::atoi(argv[4]) : 400;

    char err[512] = { 0 };
    bf6_ctx* ctx = bf6_open(argv[1], err, sizeof(err));
    if (!ctx) { std::fprintf(stderr, "bf6_open: %s\n", err); return 1; }

    // NONZERO IS THE FAILURE, not the success. Getting this backwards reports
    // a clean open as a failure with an empty error string, which reads as a
    // broken level rather than as a broken test.
    if (bf6_open_level(ctx, argv[2], argv[3], 0, err, sizeof(err)) != 0)
    { std::fprintf(stderr, "bf6_open_level: %s\n", err); return 1; }

    const int n = bf6_level_instances(ctx, argv[2], nullptr, 0);
    if (n <= 0) { std::fprintf(stderr, "no instances\n"); return 1; }
    bf6_instance* inst = new bf6_instance[(size_t)n];
    const int got = bf6_level_instances(ctx, argv[2], inst, n);
    std::printf("level opened: %d instance(s)\n", got);

    int meshes = 0, nulls = 0;
    long long sections = 0, tris = 0;
    int with_albedo = 0, tinted = 0, alpha_tested = 0, translucent = 0, with_normal = 0;
    std::set<std::string> seen;

    for (int i = 0; i < got && meshes < limit; i++)
    {
        if (!inst[i].res_name || !*inst[i].res_name) continue;
        // A PLACEMENT NAMES THE PROP, NOT THE MESH RESOURCE. res_name is the
        // ebx path; the geometry lives at that path minus the extension with
        // "_mesh" appended, which is the same transform the add-on applies.
        // Passing the ebx name straight through returns null for every asset
        // and looks exactly like a broken decoder.
        std::string res = inst[i].res_name;
        if (res.size() > 4 && res.compare(res.size() - 4, 4, ".ebx") == 0)
            res.resize(res.size() - 4);
        res += "_mesh";
        if (!seen.insert(res).second) continue;   // one read per asset

        bf6_mesh* m = bf6_read_mesh_scoped(ctx, res.c_str(), 0,
                                           inst[i].placing_bundle, inst[i].variation);
        if (!m) { nulls++; continue; }
        meshes++;
        sections += m->section_count;
        for (int s = 0; s < m->section_count; s++)
            tris += m->sections[s].index_count / 3;

        for (int k = 0; k < m->material_count; k++)
        {
            const bf6_material_desc& d = m->materials[k];
            bool alb = false, nrm = false;
            for (int t = 0; t < d.texture_count; t++)
            {
                if (d.textures[t].slot == BF6_TEX_ALBEDO) alb = true;
                if (d.textures[t].slot == BF6_TEX_NORMAL) nrm = true;
            }
            if (alb) with_albedo++;
            if (nrm) with_normal++;
            // Anything the record said about colour. White is the default, so
            // a count here is a count of records that actually carried one.
            if (d.base_color[0] != 1.f || d.base_color[1] != 1.f || d.base_color[2] != 1.f)
                tinted++;
            if (d.alpha_test)  alpha_tested++;
            if (d.translucent) translucent++;
        }
        bf6_free(ctx, m);
    }

    std::printf("read %d distinct mesh(es), %d returned null\n", meshes, nulls);
    std::printf("  sections %lld, triangles %lld\n", sections, tris);
    std::printf("  with a base colour texture : %d\n", with_albedo);
    std::printf("  with a normal              : %d\n", with_normal);
    std::printf("  colour from the record     : %d\n", tinted);
    std::printf("  alpha tested               : %d\n", alpha_tested);
    std::printf("  translucent                : %d\n", translucent);

    // The road layer, through the same public path.
    const int dn = bf6_level_decals(ctx, argv[2], nullptr, 0);
    if (dn > 0) {
        bf6_decal* dd = new bf6_decal[(size_t)dn];
        bf6_level_decals(ctx, argv[2], dd, dn);
        long long dtris = 0; int with_op = 0, with_cv = 0, planar = 0;
        for (int i = 0; i < dn; i++) {
            dtris += dd[i].vertex_count / 3;
            if (dd[i].opacity >= 0) with_op++;
            if (dd[i].albedo  >= 0) with_cv++;
            if (dd[i].planar) planar++;
        }
        std::printf("decals: %d record(s), %lld triangle(s)\n", dn, dtris);
        std::printf("  with a coverage sheet (the markings) : %d\n", with_op);
        std::printf("  with a base colour                   : %d\n", with_cv);
        std::printf("  planar fills                         : %d\n", planar);
        delete[] dd;
    } else {
        std::printf("decals: none\n");
    }

    delete[] inst;
    bf6_close(ctx);
    std::printf("closed cleanly\n");
    return meshes > 0 ? 0 : 1;
}
