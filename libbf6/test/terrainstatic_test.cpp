/* terrainstatic_test - the missing half of the terrain compositor's textures.
 *
 * A layer's material reaches the evaluator two ways. One is a BINDLESS
 * descriptor index the layer-graph depot fills, which terrainlayers.h already
 * decodes. The other is STATIC binding out of the compute permutation's
 * COMMON BindingSet - 26 of 40 layer bodies on Aftermath, and on an urban map
 * it is the asphalt: the streets come out untextured without it.
 *
 * This was the harness that proved the chain. It now drives the library module
 * that owns it (src/terrainstatic.h) rather than re-implementing it, and adds
 * the part that decides whether a bake is right or merely plausible: the join
 * from a descriptor triple to a LAYER INDEX, printed next to each layer's
 * bindless state so a slipped ordinal is visible as a named material rather
 * than as bad pixels.
 *
 *   terrainstatic_test <game_dir> <level> [ubershader]
 */
#include <cstdio>
#include <string>
#include <vector>

#include "source.h"
#include "terrainlayers.h"
#include "terrainstatic.h"

using namespace bf6;

int main(int argc, char** argv)
{
    if (argc < 3)
    { std::fprintf(stderr, "usage: terrainstatic_test <game_dir> <level> [ubershader]\n"); return 2; }
    const int want_idx = argc > 3 ? std::atoi(argv[3]) : 0;
    const std::string level = argv[2];

    Source src;
    std::string err;
    if (!src.open(argv[1], err)) { std::fprintf(stderr, "open: %s\n", err.c_str()); return 1; }
    if (!src.mount_level(level, false, err))
    { std::fprintf(stderr, "mount: %s\n", err.c_str()); return 1; }

    TerrainStaticTable st;
    if (!st.load(src, level, err, want_idx))
    { std::printf("static table: %s\n", err.c_str()); return 1; }

    std::printf("%s ubershader %d: common BindingSet %llu\n", level.c_str(), want_idx,
                (unsigned long long)st.binding_set());
    std::printf("%zu descriptor(s) declared, %zu resolve to a texture\n",
                st.declared(), st.resolved());
    std::printf("depot %s record %zu\n", st.depot_res().c_str(), st.depot_record());
    std::printf("utility prologue ends at descriptor %d\n\n", st.prologue_top());

    std::printf("%-6s %-10s %-14s %s\n", "desc", "name32", "role", "texture");
    for (const auto& kv : st.textures())
        std::printf("%-6u %08x   %-14s %s\n", kv.first, kv.second.name32,
                    terrain_tex_role_name(kv.second.role), kv.second.asset.c_str());

    std::printf("\n%zu material group(s), descending:\n", st.groups().size());
    for (size_t g = 0; g < st.groups().size(); g++)
    {
        const TerrainStaticGroup& G = st.groups()[g];
        std::printf("  g%-3zu top %-4d %-38s", g, G.top,
                    G.base_color >= 0 ? G.tex[(size_t)G.base_color].stem.c_str()
                                      : "(no colour)");
        for (const TerrainStaticTexture& t : G.tex) std::printf(" %u", t.descriptor);
        std::printf("\n");
    }

    // ---- the join --------------------------------------------------------
    TerrainLayers tl;
    std::string perr;
    if (!tl.load(src, level, perr)) { std::printf("\npalette: %s\n", perr.c_str()); return 0; }

    std::vector<int> statics;
    for (size_t i = 0; i < tl.layers().size(); i++)
        if (!tl.layers()[i].empty && tl.layers()[i].material.base_color().empty())
            statics.push_back((int)i);
    std::printf("\nLIVE DXIL LAYER JOIN  (%zu layers, %zu bindless colours, "
                "%zu with no bindless colour)\n",
                tl.layer_count(), tl.with_base_color_count(), statics.size());
    std::printf("bytecode %s, derived register base %d (real/runner hits %d/%d), "
                "attributed/unattributed samples %d/%d\n",
                st.bytecode_guid().c_str(), st.register_base(),
                st.register_base_hits(), st.register_base_runner_up_hits(),
                st.attributed_samples(), st.unattributed_samples());
    int painted = 0;
    for (size_t i = 0; i < tl.layers().size(); i++)
    {
        const TerrainLayer& L = tl.layers()[i];
        if (L.empty) continue;
        if (!L.material.base_color().empty()) continue;
        int cv = -1, nh = -1, third = -1;
        if (!st.layer_descriptors((int)i, cv, nh, third)) {
            std::printf("  L%-3zu  -\n", i); continue;
        }
        const auto tx = st.textures().find((uint32_t)cv);
        std::printf("  L%-3zu  d%-3d/%-3d/%-3d %s\n", i, cv, nh, third,
                    tx == st.textures().end() ? "(modifier or unresolved colour)"
                                              : tx->second.stem.c_str());
        if (cv >= 0) painted++;
    }
    std::printf("\n%d of %zu statically bound layer(s) receive a colour sheet\n",
                painted, statics.size());
    return 0;
}
