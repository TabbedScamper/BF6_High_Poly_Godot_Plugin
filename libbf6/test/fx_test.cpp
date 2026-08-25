/* Module FX: decode every placed effect on a level and dump one row per
 * emitter LAYER, in the same columns as data/fx_level_inventory.tsv, so the
 * two readers can be diffed column for column.
 *
 *   fx_test <game_dir> <MAP> [out.tsv]
 */
#include <cstdio>
#include <cstring>
#include <map>
#include <string>
#include <vector>

#include "source.h"
#include "types.h"
#include "fx.h"

using namespace bf6;

static const char* kLM[] = { "Emissive", "VertexLit", "GnomonLit" };
static const char* kAL[] = { "Screen", "Directional/CustomNormal",
                             "ScreenStretch/CustomEdge",
                             "FullRotationQuaternion/ForceEdge", "Emitter", "Up" };

// The named parameters the inventory carries, by PropertyId. Names are from
// data/fx_property_ids_v2.tsv (dictionary hunt, control 0 of 2,524 fake) and
// from ParticleTypeAsset, which ships 22 of them with type and tooltip.
struct Named { const char* name; uint32_t pid; };
static const Named kWant[] = {
    {"color0",0xA1C184C8},{"color1",0xA1C184C9},{"colormult",0x1EE568B8},
    {"randomcolormin",0xE5C35109},{"randomcolormax",0xE5C35217},
    {"opacity",0x39F20FDC},{"opacityoverlife",0x3D1607D4},
    {"basesize",0xBD355AD5},{"spawnsize",0x8A1C76DB},{"sizecurve",0x8B256B37},
    {"sizeoverlife",0x0AFB1F08},{"rotationspeed",0x2FD2E956},{"rotationoverlife",0x0C8950D9},
    {"userighttile",0xCB4FC2D2},{"disableframeblend",0x45056B2D},
    {"alphacullthreshold",0x1487F4B0},{"camerabias",0xBFF3F865},
    {"invzfademultiplier",0x141FF6C3},{"sunlightscale",0xF36E7E8B},
    {"locallightscale",0x209877EE},{"ambientlightscale",0x1558A27B},
    {"receivedshadowscale",0xEB0563F4},{"cloudshadowscale",0xFF6899EA},
    {"gnomonbacklight",0xCC64D81A},{"vertexbacklight",0xC0246618},
    {"lightmulttype",0x1F0B9D63},{"gnomonlightrigindex",0x27F4CED3},
    {"spawnspeed",0xCDB76C39},{"spawnspeedcurve",0x65A739AE},{"drag",0x7C7FD695},
    {"gravity",0xC46720E3},{"buoyancy",0x4E4BFB91},{"windstrength",0xE0A01AD4},
    {"randomforce",0x441BEE03},{"intensity",0xE4AABCEA},{"temperature",0x84477F09},
    {"emissiveintensitymult",0x80198B51},{"mirror",0x9CFC66BC},{"localspace",0xF11A114C},
};

int main(int argc, char** argv)
{
    if (argc < 3) { std::fprintf(stderr, "fx_test <game_dir> <MAP> [out.tsv]\n"); return 2; }
    const std::string game = argv[1], map = argv[2];

    Source src;
    std::string err;
    if (!src.open(game, err)) { std::fprintf(stderr, "open: %s\n", err.c_str()); return 1; }
    if (!src.mount_level(map, false, err)) { std::fprintf(stderr, "mount: %s\n", err.c_str()); return 1; }

    TypeDb types;
    bool ok = false;
    for (const std::string& p : TypeDb::exe_candidates(game))
        if (types.open(p, err)) { ok = true; break; }
    if (!ok) { std::fprintf(stderr, "types: %s\n", err.c_str()); return 1; }

    std::vector<FxPlacement> plc;
    std::vector<FxEffect>    eff;
    FxStats st;
    if (!fx_level_effects(src, types, map, plc, eff, st, err)) {
        std::fprintf(stderr, "fx: %s\n", err.c_str()); return 1;
    }

    std::fprintf(stderr,
        "%-16s placements=%lld effects=%lld layers=%lld graph=%lld atlas=%lld"
        " (ovr %lld tmpl %lld) grid=%lld rid=%lld res=%lld chunk=%lld lm=%lld al=%lld"
        " components=%lld\n",
        map.c_str(), (long long)st.placements, (long long)st.distinct_effects,
        (long long)st.layers, (long long)st.graph_resolved, (long long)st.atlas_resolved,
        (long long)st.atlas_override, (long long)st.atlas_template,
        (long long)st.grid_resolved, (long long)st.rid_present,
        (long long)st.res_resolved, (long long)st.chunk_named,
        (long long)st.lighting_model, (long long)st.alignment, (long long)st.components);

    FILE* f = stdout;
    if (argc > 3) { f = std::fopen(argv[3], "wb"); if (!f) { std::fprintf(stderr, "cannot write\n"); return 1; } }

    auto leaf = [](const std::string& s) {
        const size_t p = s.find_last_of("/\\");
        return p == std::string::npos ? s : s.substr(p + 1);
    };
    auto num = [](float v) {
        char b[48];
        std::snprintf(b, sizeof(b), "%g", (double)v);
        return std::string(b);
    };

    for (const FxEffect& e : eff)
        for (const FxLayer& L : e.layers) {
            std::string row;
            auto add = [&](const std::string& s) { if (!row.empty()) row += '\t'; row += s; };
            add(map);
            add(e.name);
            add(std::to_string(e.placements));
            add(num(e.cull_distance));
            add(std::to_string(e.max_instances));
            add(std::to_string(L.instance));
            add(leaf(L.graph));
            add(fx_family(L.graph));
            add(leaf(L.atlas.name));
            add(L.atlas.name.empty() ? "" : (L.atlas_from_override ? "override" : "graph"));
            add(L.atlas.cols   ? std::to_string(L.atlas.cols)   : "");
            add(L.atlas.frames ? std::to_string(L.atlas.frames) : "");
            add(L.atlas.name.empty() ? "" : (L.atlas.left_right ? "1" : "0"));
            char rid[32] = "";
            if (L.atlas.rid) std::snprintf(rid, sizeof(rid), "%016llx", (unsigned long long)L.atlas.rid);
            add(rid);
            add(L.lighting_model >= 0 && L.lighting_model < 3 ? kLM[L.lighting_model] : "");
            add(L.alignment >= 0 && L.alignment < 6 ? kAL[L.alignment] : "");
            // lighting_model_enumpath / alignment_enumpath. The oracle carries
            // the value NAMES read from an enumerator-INSTANCE import; that
            // path is deliberately not implemented here (see the report), so
            // the columns are emitted empty to keep the widths comparable and
            // are excluded from the agreement score rather than counted as
            // agreeing.
            add(""); add("");
            add(L.spawn_mode);
            add(L.has_spawn_rate ? num(L.spawn_rate) : "");
            add(std::to_string(L.particle_max));
            add(num(L.particle_life));
            add(num(L.emitter_life));
            add(num(L.max_spawn_distance));
            add(num(L.gpu_cull_distance));
            add(num(L.min_spawn_distance));
            add(num(L.preroll_time));
            add(std::to_string(L.draw_layer));
            add(std::to_string(L.sort_mode));
            char pos[64];
            std::snprintf(pos, sizeof(pos), "%.2f %.2f %.2f", L.local[9], L.local[10], L.local[11]);
            add(pos);

            std::map<uint32_t, const FxParam*> by;
            for (const FxParam& p : L.params) by[p.pid] = &p;
            for (const Named& w : kWant) {
                if (!w.pid) { add(""); continue; }
                auto it = by.find(w.pid);
                if (it == by.end()) { add(""); continue; }
                const FxParam& p = *it->second;
                if (p.type == FX_PARAM_INT)  { add(std::to_string(p.ivalue)); continue; }
                if (p.type == FX_PARAM_BOOL) { add(p.ivalue ? "True" : "False"); continue; }
                std::string s;
                for (int k = 0; k < fx_param_width(p.type); k++) {
                    if (k) s += ' ';
                    s += num(p.v[k]);
                }
                add(s);
            }
            std::fprintf(f, "%s\n", row.c_str());
        }
    if (f != stdout) std::fclose(f);
    return 0;
}
