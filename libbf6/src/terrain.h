/* libbf6 internal - the level heightfield (module 10, heights half).
 *
 * Ported from bf6_terrain.gd, which was written from
 * BF6_Frostbite_Research/formats/TERRAIN.md sections 2-4.
 *
 *   RES 0x22FE8AC8, one per level, named "...streamingtree..."
 *     +0x00  34-byte container header (NodeCount at +0x19)
 *     +0x22  typed blocks: u8 type, i32 size, payload - 0xFF ends the list
 *            block 0 = heights, 2 = density, 1 = splat, 4/5 = masks
 *     then   the chunk directory quadtree (NOT a typed block)
 *
 * A height node is a world AABB plus xs*xs u16 samples, and those samples can
 * be INLINE in the resource, in the node's OWN chunk, or packed into the
 * PARENT's paired chunk with the four children in REVERSED order. All three
 * occur on shipped maps, so all three are handled.
 *
 * The splat (block 1), which is what colours the ground, is a separate and
 * much larger job. This is the shape of the land only.
 */
#ifndef LIBBF6_TERRAIN_H
#define LIBBF6_TERRAIN_H

#include <cstdint>
#include <functional>
#include <map>
#include <string>
#include <vector>

namespace bf6 {

struct TerrainNode {
    uint64_t key = 0;
    float    lo[3] = {0, 0, 0};
    float    hi[3] = {0, 0, 0};
    int      depth = 0;
    bool     external = false;      // samples live in a chunk, not inline
    std::vector<uint16_t> values;   // xs*xs when resolved
};

struct TerrainGrid {
    int      size = 0;              // samples per side
    std::vector<uint16_t> heights;  // row-major, size*size
    float    lo[3] = {0, 0, 0};     // world bounds the grid spans
    float    hi[3] = {0, 0, 0};
    float    world_size_y = 0.f;    // the header's height scale
};

class Terrain {
public:
    // Chunk bytes by guid hex. The reader tries both the plain and the reversed
    // spelling, because a chunk id is stored one way and indexed the other in
    // places, and getting it wrong fails on a SUBSET of nodes rather than all
    // of them, which is the worst kind to find later.
    using FetchChunk = std::function<std::vector<uint8_t>(const std::string&)>;

    bool parse(const std::vector<uint8_t>& res, std::string& err);
    int  resolve_external(const FetchChunk& fetch);

    // Paint every node carrying heights into one square grid, deepest last, so
    // the finest data available wins everywhere. size 0 asks for the resolution
    // the TREE actually holds rather than a number we picked.
    bool composite(TerrainGrid& out, int size, std::string& err) const;

    // Samples per side the deepest nodes support: 2^depth nodes across, each
    // carrying (xs - 1 - 2*border) of its own ground, plus the closing line.
    int native_size() const;

    int    samples_per_side() const { return xs_; }
    int    border() const { return border_; }
    size_t node_count() const { return nodes_.size(); }
    size_t nodes_with_values() const;

private:
    bool find_block(const std::vector<uint8_t>& res, int want, std::vector<uint8_t>& out,
                    std::string& err) const;
    bool read_block_header(const std::vector<uint8_t>& b, std::string& err);
    bool walk_nodes(const std::vector<uint8_t>& b, std::string& err);
    bool read_node(const std::vector<uint8_t>& b, size_t& p, uint64_t key, int depth,
                   std::string& err);
    bool read_chunk_directory(const std::vector<uint8_t>& res, std::string& err);
    bool read_dir_node(const std::vector<uint8_t>& res, size_t& p, uint64_t key,
                       std::string& err);

    struct DirEntry {
        uint32_t    primary_size = 0, paired_size = 0;
        std::string primary, paired;
    };

    int    xs_ = 0, border_ = 0, node_count_ = 0;
    float  world_size_y_ = 0.f;
    size_t packed_bytes_ = 0, section_bytes_ = 0, density_bytes_ = 0, data_size_ = 0;
    std::vector<TerrainNode>        nodes_;
    std::map<uint64_t, DirEntry>    dir_;
};

}  // namespace bf6

#endif
