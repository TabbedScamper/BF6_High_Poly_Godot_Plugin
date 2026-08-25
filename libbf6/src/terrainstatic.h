/* libbf6 internal - the terrain compositor's STATICALLY BOUND texture table.
 *
 * WHY THIS EXISTS. A terrain layer's textures reach the ComputeLayer evaluator
 * two ways. One is BINDLESS: the layer's ShaderLayerInfos row carries a
 * descriptor index the layer-graph depot fills, and `terrainlayers.h` decodes
 * that. The other is STATIC: the compositor's compute permutation binds the
 * sheets directly and the generated evaluator samples them by register. Only
 * the first was decoded anywhere in this library, so on mp_dumbo 34 of 47 layer
 * bodies - the whole street grid of Manhattan Bridge - arrived with no colour.
 *
 * THE CHAIN, transcribed from
 * BF6_Frostbite_Research/findings/terrain-static-texture-table-resolved.md:
 *
 *   level shaderstate_db -> compositor program 0x9F11D96B0FDF4773
 *     -> +0x60/+0x64 indexed by UberShaderIndex -> permutation id
 *     -> expressionshader/permutation<id>          (36-byte compute form)
 *     -> +0x00 -> expressionshader/permutationshareddata/<id>
 *     -> +0x18 -> CommonBindingSetId
 *     -> expressionshader/bindingset/<id>
 *          destination = DESCRIPTOR INDEX (steps by 1), paired with a Name32
 *     -> the level's ShaderBlockDepot: the ONE record carrying those Name32s
 *     -> texture FILE guid -> asset name via Source::partition_index()
 *
 * Note the destination semantic. In the ShaderLayerInfos set the destinations
 * are byte offsets into a row and step by 4; here they are descriptor indices
 * and step by 1 (`shaderlayerinfos-row-map-read-from-disk`).
 *
 * THE HARD PART: WHICH LAYER OWNS WHICH TRIPLE.
 *
 * The descriptor table names textures, not layers. The join was derived by
 * disassembling the shipped evaluator (dxc -dumpbin over the compositor's
 * CompiledBytecode) on mp_aftermath, mp_dumbo and mp_isolated and reading, per
 * top-level switch case, which texture registers that case samples. Evaluator
 * case N is layer N (`terrain-computelayer-case-is-layer-index`), so that
 * disassembly IS the ground truth. What it shows:
 *
 *   - Textures arrive in consecutive ao / nhs / cv triples, and the triples are
 *     consumed in DESCENDING descriptor order as the layer index RISES.
 *   - The layers that consume them are exactly the layers with no bindless
 *     base colour, taken in ascending index order. The k-th such layer gets the
 *     k-th group counted down from the top of the table.
 *   - The TOP group is allocated to layer 0 and never sampled: neither decoded
 *     evaluator has a `case 0` at all, layer 0 being a pass-through that
 *     preserves the incoming surface. So layer 0 is aligned but never painted.
 *   - Groups made only of the compositor's own utility sheets (perlin noise,
 *     the granite gradient, break-up masks, tiling noise, scatter noise, the
 *     interior/crater sheets) occupy NO slot: they are shared by many bodies.
 *     The bottom of every table is a prologue of exactly those, and nothing at
 *     or below the prologue is ever handed to a layer.
 *
 * HOW WELL IT HOLDS, measured against the disassembly rather than asserted:
 *
 *   mp_aftermath  15 of 16 layer/group pairs exact, 0 wrong, 1 missed
 *   mp_dumbo      19 of 20 layer/group pairs exact, 0 wrong, 1 missed
 *   mp_isolated    5 of 20 exact - correct for layers 0-5, then it DRIFTS
 *
 * The drift on isolated is honest and its cause is known: that map has static
 * layers (L9, L13) whose bodies sample nothing, and consuming layers (L25, L28)
 * this library reads as bindless, so the ordinal walk slips by one and then
 * paints every later layer with its neighbour's sheet. Nothing in the shipped
 * DATA distinguishes a static layer that consumes a group from one that does
 * not - only the bytecode does, and a bitcode parser is not in this library.
 * A caller that cannot tolerate a plausible-but-wrong ground should turn
 * TerrainBakeOpts::static_fallback off; the missing sheets then read as the
 * magenta hole they actually are.
 */
#ifndef LIBBF6_TERRAINSTATIC_H
#define LIBBF6_TERRAINSTATIC_H

#include <cstdint>
#include <map>
#include <string>
#include <vector>

namespace bf6 {

class Source;

// The role a sheet plays, read off the asset name's suffix - the same trick
// that named the prop depot slots. An unsuffixed sheet is Unknown, never
// guessed at, because a normal map promoted to base colour is worse than none.
enum class TerrainTexRole {
    Unknown,
    BaseColor,        // _cv
    NormalHeight,     // _nhs, _noh
    AmbientOcclusion, // _ao
    Opacity,          // _op
    Smoothness,       // _cs
    Mixed             // _mxx
};

const char* terrain_tex_role_name(TerrainTexRole r);

struct TerrainStaticTexture {
    uint32_t       descriptor = 0;
    uint32_t       name32 = 0;
    std::string    file_guid;   // resolves through Source::partition_index()
    std::string    asset;       // leaf asset name, ".ebx" stripped
    std::string    stem;        // asset leaf with the role suffix removed
    TerrainTexRole role = TerrainTexRole::Unknown;
};

// One material's worth of consecutive descriptors, in DESCENDING order.
struct TerrainStaticGroup {
    std::vector<TerrainStaticTexture> tex;
    int  base_color = -1;      // index into tex, -1 when the group binds none
    int  normal_height = -1;
    int  third = -1;           // the ao / op / cs map
    bool utility = false;      // every member is a compositor-owned shared sheet
    int  top = 0;              // highest descriptor in the group
    const std::string& stem() const;
};

class TerrainStaticTable {
public:
    // `src` must already have the level mounted. False only when the chain
    // cannot be opened; a table that resolves partly still loads and says so.
    bool load(Source& src, const std::string& level, std::string& err,
              int ubershader = 0);

    // descriptor index -> texture, for every declared descriptor that resolved.
    const std::map<uint32_t, TerrainStaticTexture>& textures() const { return tex_; }
    // Material groups, DESCENDING (groups()[0] is the top of the table).
    // Utility-only groups and everything inside the prologue are already gone:
    // this is the allocation list a layer walk consumes.
    const std::vector<TerrainStaticGroup>& groups() const { return groups_; }

    // ---- the layer join ----------------------------------------------------
    // `static_layers`: the palette's layer indices, ASCENDING, that have no
    // bindless base colour and are not empty slots. Returns layer -> index into
    // groups(). Layer 0 is aligned but never mapped - see the header note.
    std::map<int, int> assign(const std::vector<int>& static_layers) const;

    // ---- provenance, so a wrong table shows up as a named resource ---------
    uint64_t     binding_set() const { return binding_set_; }
    const std::string& depot_res() const { return depot_res_; }
    size_t       depot_record() const { return depot_rec_; }
    size_t       declared() const { return declared_; }   // descriptors declared
    size_t       resolved() const { return tex_.size(); } // ...that named a texture
    int          prologue_top() const { return prologue_top_; }

private:
    std::map<uint32_t, TerrainStaticTexture> tex_;
    std::vector<TerrainStaticGroup>          groups_;
    uint64_t    binding_set_ = 0;
    std::string depot_res_;
    size_t      depot_rec_ = 0, declared_ = 0;
    int         prologue_top_ = -1;
};

// WHICH TABLE ROW A SUBLEVEL USES.
//
// terrainstaticmap.h is keyed by the level whose evaluator was disassembled, and
// several shipped levels are SUBLEVELS that mount somebody else's terrain: all
// seven mp_granite_<x>_portal levels stream the parent's
// terrain_mp_granite_8k_512tile_01_copy tree and therefore run the parent's
// evaluator with the parent's register allocation. Keyed exactly they miss the
// table and fall back to the ordinal walk.
//
// Returns the longest covered name that is a prefix of `level` at an UNDERSCORE
// boundary, or `level` lowercased when the table covers it directly or not at
// all. mp_aftermath_portal has a row of its own and keeps it. Lives here rather
// than in terrainstaticmap.cpp because that file is generated.
std::string terrain_table_level(const std::string& level);

}  // namespace bf6

#endif
