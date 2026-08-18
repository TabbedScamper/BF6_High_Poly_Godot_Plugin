/* libbf6 internal - MeshSet decoder (module 6, geometry).
 *
 * Ported from bf6_meshset.gd. A MeshSet resource describes a mesh's LODs and
 * sections; the vertex/index bytes live in a referenced chunk. This header holds
 * the parse (metadata) half; read_lod (the actual buffers) follows.
 *
 * Independent of EBX and the type schema - it works from the resource bytes
 * alone, which is why one mesh can be decoded without a full level walk.
 */
#ifndef LIBBF6_MESHSET_H
#define LIBBF6_MESHSET_H

#include <array>
#include <cstdint>
#include <string>
#include <vector>

namespace bf6 {

struct MeshDecl {
    std::vector<std::array<uint8_t, 4>> elements;   // usage, fmt, off, stream
    std::vector<std::array<uint8_t, 2>> streams;    // stride, classification
};

struct MeshSection {
    int         index = 0;
    std::string material;
    uint64_t    state_key = 0;
    uint16_t    material_id = 0;
    uint8_t     stride = 0;
    uint32_t    prim_count = 0;
    uint32_t    start_index = 0;
    uint32_t    vertex_offset = 0;
    uint32_t    vertex_count = 0;
    uint8_t     bones_per_vertex = 0;
    MeshDecl    decl;      // the declaration describing positions
    MeshDecl    decl0, decl1;
};

struct MeshLod {
    int          index = 0;
    int          section_count = 0;
    std::vector<MeshSection> sections;
    bool         idx32 = false;
    int          index_size = 0;
    int          vertex_size = 0;
    std::array<uint8_t, 16> chunk_id{};
    std::string  name;
    uint32_t     inline_offset = 0;
};

struct MeshSet {
    bool         ok = false;
    std::string  name;
    uint8_t      mesh_type = 0;
    int          lod_count = 0;
    int          section_count = 0;
    int          lod_stride = 0;
    std::vector<MeshLod> lods;
    size_t       size = 0;
};

MeshSet meshset_parse(const uint8_t* d, size_t len, std::string& err);

}  // namespace bf6
#endif
