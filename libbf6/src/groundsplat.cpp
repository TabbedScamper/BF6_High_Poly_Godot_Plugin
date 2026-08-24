#include "groundsplat.h"

#include <algorithm>
#include <cstring>
#include <map>

#include "splat.h"
#include "terrainlayers.h"

namespace bf6 {

bool ground_coverage(Source& src, const std::string& level, int size,
                     GroundCoverage& out, std::string& err)
{
    out = GroundCoverage();
    if (size <= 0) size = 2048;

    // ---- the streaming tree, and block 1 out of it -------------------------
    std::string lvl = level;
    for (char& c : lvl) c = (char)tolower((unsigned char)c);
    std::string tree;
    for (const auto& kv : src.res()) {
        std::string n = kv.first;
        for (char& c : n) c = (char)tolower((unsigned char)c);
        if (n.find("streamingtree") != std::string::npos &&
            n.find(lvl) != std::string::npos) { tree = kv.first; break; }
    }
    if (tree.empty()) { err = "no streaming tree for " + level; return false; }

    std::vector<uint8_t> res = src.get_res(tree, err);
    if (res.empty()) { err = "streaming tree unreadable"; return false; }

    std::vector<uint8_t> b1;
    if (!Splat::find_block(res, 1, b1, err)) return false;

    Splat sp;
    if (!sp.parse(b1, err)) return false;

    SplatChunkDir dir;
    if (!Splat::read_chunk_dir(res, dir, err)) return false;
    if (!sp.detect_layout(dir, err)) return false;

    auto fetch = [&src](const std::string& g) {
        std::string e;
        return src.get_chunk(g, e);
    };

    SplatCoverage cov;
    SplatCompositeOpts opt;
    if (!sp.composite(dir, fetch, size, cov, err, opt)) return false;

    // ---- the materials those layer indices refer to ------------------------
    TerrainLayers tl;
    std::string le;
    const bool have_layers = tl.load(src, level, le);
    if (!have_layers && !le.empty()) {
        // Not fatal: coverage without materials still tells a renderer the
        // shape of the ground, and saying so beats failing the whole call.
        err = "layers: " + le;
    }

    // guid -> resource name, the same walk every other consumer does
    const std::map<std::string, std::string>& gi = src.partition_index();
    auto res_for_guid = [&gi](const std::string& g) -> std::string {
        if (g.empty()) return std::string();
        auto it = gi.find(g);
        if (it == gi.end()) return std::string();
        std::string n = it->second;
        if (n.size() > 4 && n.compare(n.size() - 4, 4, ".ebx") == 0) n.resize(n.size() - 4);
        return n;
    };

    // COMPACT THE LAYER SPACE. The coverage carries raw layer indices, which
    // run to 47 on some maps while a handful ever appear. A renderer binds one
    // sheet per material, so handing it 47 slots to fill with 13 textures
    // wastes most of an array; the indices are remapped to the layers that
    // actually reach the raster, in ascending order.
    std::map<int, int> layer_to_slot;
    for (int L = 0; L < 256; L++) {
        if (cov.layer_texels[L] == 0) continue;
        const int slot = (int)out.materials.size();
        layer_to_slot[L] = slot;

        GroundMaterial m;
        m.layer = L;
        if (have_layers && L < (int)tl.layers().size()) {
            const TerrainLayer& lay = tl.layers()[(size_t)L];
            // base_color() hands back the texture's FILE GUID, not a resource
            // name - the depot stores guids and the partition index is what
            // turns one into something get_res can open. Handing the guid
            // straight to a renderer gives it a name that resolves to nothing
            // and looks like an unbound layer.
            m.albedo_res = res_for_guid(lay.material.base_color());
            m.normal_res = res_for_guid(lay.material.normal_height());
            m.metres_per_repeat = lay.material.metres_per_repeat(4.f);
            if (lay.material.uv_rotation_deg_set)
                m.uv_rotation_deg = lay.material.uv_rotation_deg;
            if (lay.material.tint_set) {
                m.tint[0] = lay.material.tint[0];
                m.tint[1] = lay.material.tint[1];
                m.tint[2] = lay.material.tint[2];
            }
        }
        out.materials.push_back(m);
        if (out.materials.size() >= 250) break;   // 255 is the "none" marker
    }

    out.size = cov.size;
    out.lo[0] = cov.lo[0]; out.lo[1] = cov.lo[1];
    out.hi[0] = cov.hi[0]; out.hi[1] = cov.hi[1];
    out.empty_texels = cov.empty_texels;
    out.idx.assign((size_t)cov.size * cov.size * 4, 255);
    out.w.assign((size_t)cov.size * cov.size * 4, 0);

    for (size_t i = 0; i < (size_t)cov.size * cov.size; i++)
        for (int s = 0; s < 4; s++) {
            const uint8_t weight = cov.w[i * 4 + s];
            if (weight == 0) break;                 // weight-sorted, first zero ends it
            auto it = layer_to_slot.find(cov.idx[i * 4 + s]);
            if (it == layer_to_slot.end()) continue;
            out.idx[i * 4 + s] = (uint8_t)it->second;
            out.w[i * 4 + s]   = weight;
        }
    return true;
}

}  // namespace bf6
