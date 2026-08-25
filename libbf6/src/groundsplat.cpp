#include "groundsplat.h"

#include <algorithm>
#include <cstring>
#include <map>
#include <set>

#include "splat.h"
#include "terrainlayers.h"
#include "terrainstatic.h"
#include "terraincomposite.h"   // paint_colour_map
#include "terrainstaticmap.h"
#include "playablebounds.h"

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
    // RASTERISE THE PLAYABLE BOX, NOT THE WHOLE FOOTPRINT.
    //
    // A level's terrain reaches far past where a player can go: MP_Isolated
    // builds 8,192 m of ground of which 2,555 m is playable and the rest is
    // BACKDROP RING, authored with distance sheets that tile every hundred
    // metres because they are only ever seen from kilometres away. Spending
    // the raster on the ring costs twice over - the ring reads as a smear of
    // object textures where it is walked on, and the playable ground gets a
    // quarter of the resolution it could have had.
    //
    // Same raster over the box instead: on MP_Isolated that is 0.62 m a texel
    // rather than 2.00.
    float bcx = 0.f, bcz = 0.f, bsx = 0.f, bsz = 0.f;
    if (playable_box(level, bcx, bcz, bsx, bsz) && bsx > 1.f && bsz > 1.f) {
        // Square, because the raster is: take the larger side so nothing
        // playable falls outside it.
        const float side = bsx > bsz ? bsx : bsz;
        opt.rect_min[0] = bcx - side * 0.5f;
        opt.rect_min[1] = bcz - side * 0.5f;
        opt.rect_size   = side;
    }
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

    // The static table hands back an asset LEAF name; the resource wants the
    // full path, so it is looked up in the mount rather than assumed.
    auto res_for_name = [&src](const std::string& leaf) -> std::string {
        if (leaf.empty()) return std::string();
        for (const auto& kv : src.res()) {
            const size_t sl = kv.first.find_last_of('/');
            const std::string tail = sl == std::string::npos ? kv.first : kv.first.substr(sl + 1);
            if (tail == leaf) return kv.first;
        }
        return std::string();
    };

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

    // THE STATIC HALF OF THE TEXTURES.
    //
    // Only some layers name their sheet through the layer-graph depot. The
    // rest are bound statically out of the compositor's own BindingSet, and
    // on an urban map those are the road surfaces - a coverage list built
    // from the bindless path alone hands a renderer thirty materials of
    // which four have textures. Same join the bake uses.
    TerrainStaticTable stab;
    std::map<int, int> static_slot;
    {
        std::string se;
        if (stab.load(src, level, se)) {
            // OVER THE WHOLE PALETTE, not over the layers this raster
            // happens to reach. The join is ORDINAL - the nth static layer
            // takes the nth group - so dropping a layer that is off-window
            // slides every later layer onto its neighbour's sheet, which
            // looks plausible and is wrong. Same list the flattened bake
            // builds, deliberately, so the two paths cannot disagree.
            std::vector<int> need;
            for (size_t i = 0; i < tl.layers().size() && have_layers; i++) {
                const TerrainLayer& lay = tl.layers()[i];
                if (lay.empty) continue;
                if (!lay.material.base_color().empty()) continue;   // bindless already
                need.push_back((int)i);
            }
            static_slot = stab.assign(need);
        }
    }

    // WHICH LAYERS ARE MODIFIERS, not surfaces.
    //
    // A modifier layer has no colour of its own: its evaluator body multiplies
    // whatever is already accumulated, of the form
    //     lerp(acc, acc * grunge, coverage)
    // writing only base colour, smoothness and class - never normal, height or
    // alpha. MP_Aftermath's layer 23 is one, a global grunge pass whose splat
    // mask is 1.0 over 100% of the raster BY DESIGN.
    //
    // That is fatal to a top-N-layers-per-texel coverage: the modifier wins
    // slot 0 on 99.8% of texels, has no sheet, and the renderer falls back to
    // the aerial photograph for the whole map. The layer that should be
    // underneath is layer 0, the base field over 95.3% of it.
    //
    // So modifiers are dropped from the SURFACE selection. They are not
    // rendered as a tint yet, which is a real loss of grunge, but drawing the
    // ground and losing its dirt beats drawing a photograph of the ground.
    std::set<int> modifier_layers;
    // The table names modifiers directly: a case with cv -1 supplies no colour.
    // That is a better answer than inferring it from whichever group the
    // ordinal walk happened to land on.
    // A sublevel runs its parent's evaluator; see terrain_table_level.
    const std::string table_level = terrain_table_level(level);
    if (have_layers && static_layer_map_has(table_level)) {
        for (size_t i = 0; i < tl.layers().size(); i++) {
            if (tl.layers()[i].empty) continue;
            if (!tl.layers()[i].material.base_color().empty()) continue;
            int tcv = -1, tnh = -1, tthird = -1;
            if (static_layer_descriptors(table_level, (int)i, tcv, tnh, tthird) && tcv < 0)
                modifier_layers.insert((int)i);
        }
    }
    for (const auto& kv : static_slot) {
        if (kv.second < 0 || kv.second >= (int)stab.groups().size()) continue;
        if (stab.groups()[(size_t)kv.second].base_color < 0)
            modifier_layers.insert(kv.first);
    }

    // COMPACT THE LAYER SPACE. The coverage carries raw layer indices, which
    // run to 47 on some maps while a handful ever appear. A renderer binds one
    // sheet per material, so handing it 47 slots to fill with 13 textures
    // wastes most of an array; the indices are remapped to the layers that
    // actually reach the raster, in ascending order.
    std::map<int, int> layer_to_slot;
    for (int L = 0; L < 256; L++) {
        if (cov.layer_texels[L] == 0) continue;
        if (modifier_layers.count(L)) continue;      // see modifier_layers above
        // AN EMPTY PALETTE SLOT IS NOT A SURFACE EITHER.
        //
        // A layer index can be present in the splat with real coverage while
        // the palette has no layer there at all. mp_isolated's L53 is the
        // clearest case: absent between L52 and L54, no row in the evaluator
        // bytecode, and it wins the paint on 60.6% of the map. Elected as a
        // surface it resolves to nothing and the renderer falls back to the
        // aerial photograph for most of the level.
        //
        // Thirteen levels do this. On some of them the empty slot is WORSE
        // than a hole, because the depot is content-deduplicated and hands
        // back a plausible neighbouring texture instead of nothing, which is
        // silently wrong rather than visibly missing.
        if (have_layers && L < (int)tl.layers().size() && tl.layers()[(size_t)L].empty)
            continue;
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
            // THE BYTECODE TABLE FIRST, the ordinal walk only as a fallback.
            //
            // Which layer consumes which texture group is decided by the
            // compositor's compiled bytecode and by nothing in the shipped
            // data, so the ordinal walk that stood in for it - the k-th static
            // layer takes the k-th group - is right on some levels and wrong on
            // others. Measured against the bytecode by ground area it paints
            // the WRONG sheet over 98.8% of mp_abbasid, 45.6% of mp_isolated
            // and 16.8% of mp_badlands, while reporting every layer resolved.
            //
            // The table is the disassembly's own answer: descriptor index d is
            // SRV register t(d + 21), and evaluator case N is layer N. A
            // descriptor of -1 is a real answer meaning this case binds no
            // colour, which is a MODIFIER and must not become a surface.
            if (m.albedo_res.empty()) {
                int tcv = -1, tnh = -1, tthird = -1;
                if (static_layer_descriptors(table_level, L, tcv, tnh, tthird)) {
                    auto by_descriptor = [&stab](int d) -> std::string {
                        if (d < 0) return std::string();
                        for (const TerrainStaticGroup& g : stab.groups())
                            for (const TerrainStaticTexture& tx : g.tex)
                                if ((int)tx.descriptor == d) return tx.asset;
                        return std::string();
                    };
                    const std::string cv_asset = by_descriptor(tcv);
                    if (!cv_asset.empty()) m.albedo_res = res_for_name(cv_asset);
                    if (m.normal_res.empty()) {
                        const std::string nh_asset = by_descriptor(tnh);
                        if (!nh_asset.empty()) m.normal_res = res_for_name(nh_asset);
                    }
                }
            }
            if (m.albedo_res.empty()) {
                auto sit = static_slot.find(L);
                if (sit != static_slot.end() &&
                    sit->second >= 0 && sit->second < (int)stab.groups().size()) {
                    const TerrainStaticGroup& g = stab.groups()[(size_t)sit->second];
                    if (g.base_color >= 0)
                        m.albedo_res = res_for_name(g.tex[(size_t)g.base_color].asset);
                    if (m.normal_res.empty() && g.normal_height >= 0)
                        m.normal_res = res_for_name(g.tex[(size_t)g.normal_height].asset);
                }
            }
            m.metres_per_repeat = lay.material.metres_per_repeat(4.f);
            if (lay.material.uv_rotation_deg_set)
                m.uv_rotation_deg = lay.material.uv_rotation_deg;
            if (lay.material.tint_set) {
                m.tint[0] = lay.material.tint[0];
                m.tint[1] = lay.material.tint[1];
                m.tint[2] = lay.material.tint[2];
            }
            m.overlay = lay.material.overlay_strength_set
                      ? lay.material.overlay_strength : 1.f;

            // The evaluator's own constants, same reads the bake makes.
            m.base_height    = lay.material.base_height;
            m.displace_range = lay.material.displace_range;
            m.mask_ramp_exp  = lay.material.mask_ramp_exp_set &&
                               lay.material.mask_ramp_exp > 0.f
                             ? lay.material.mask_ramp_exp : 1.f;
            m.height_blend   = lay.material.height_blend;
            m.coord_scale[0] = lay.material.coord_scale_set &&
                               lay.material.coord_scale[0] != 0.f
                             ? lay.material.coord_scale[0] : 1.f;
            m.coord_scale[1] = lay.material.coord_scale_set &&
                               lay.material.coord_scale[1] != 0.f
                             ? lay.material.coord_scale[1] : 1.f;
            m.uv_offset[0]   = lay.material.uv_offset[0];
            m.uv_offset[1]   = lay.material.uv_offset[1];
        }
        out.materials.push_back(m);
        if (out.materials.size() >= 250) break;   // 255 is the "none" marker
    }

    out.size = cov.size;
    out.lo[0] = cov.lo[0]; out.lo[1] = cov.lo[1];
    out.hi[0] = cov.hi[0]; out.hi[1] = cov.hi[1];
    // Counted BELOW, not carried over. A texel can be non-empty in the raster
    // and still have nothing left once modifier layers are dropped, so the
    // raster's own count would understate it - and adding to it would count
    // the same texel twice.
    out.empty_texels = 0;

    // The aerial photograph over the same window. Not fatal when absent: some
    // levels ship no colour map, and the sheets still draw.
    paint_colour_map(sp, dir, fetch, cov.lo, cov.hi, cov.size, out.colour, nullptr);
    out.idx.assign((size_t)cov.size * cov.size * 4, 255);
    out.w.assign((size_t)cov.size * cov.size * 4, 0);

    for (size_t i = 0; i < (size_t)cov.size * cov.size; i++) {
        // COMPACTED, not copied slot for slot. The list is weight-sorted and a
        // consumer stops at the first zero, so a dropped layer must close the
        // gap behind it rather than leave a hole - otherwise dropping the
        // modifier in slot 0 would end the list before it began.
        int w_out = 0;
        for (int s = 0; s < 4; s++) {
            const uint8_t weight = cov.w[i * 4 + s];
            if (weight == 0) break;                 // weight-sorted, first zero ends it
            auto it = layer_to_slot.find(cov.idx[i * 4 + s]);
            if (it == layer_to_slot.end()) continue;
            out.idx[i * 4 + w_out] = (uint8_t)it->second;
            out.w[i * 4 + w_out]   = weight;
            w_out++;
        }
        if (w_out == 0) out.empty_texels++;
    }
    return true;
}

}  // namespace bf6
