#include "meshset.h"

#include <cstring>

namespace bf6 {

static const int BASE         = 16;    // every stored offset is relative to this
static const int SECTION_SIZE = 368;
static const int DECL_SIZE    = 100;

// PackedByteArray decode_* are little-endian; match them.
static uint16_t u16(const uint8_t* d, size_t at) {
    return (uint16_t)(d[at] | (d[at + 1] << 8));
}
static uint32_t u32(const uint8_t* d, size_t at) {
    return uint32_t(d[at]) | (uint32_t(d[at + 1]) << 8) |
           (uint32_t(d[at + 2]) << 16) | (uint32_t(d[at + 3]) << 24);
}
static int32_t s32(const uint8_t* d, size_t at) { return (int32_t)u32(d, at); }
static uint64_t u64(const uint8_t* d, size_t at) {
    uint64_t v = 0;
    for (int k = 0; k < 8; k++) v |= (uint64_t)d[at + k] << (8 * k);
    return v;
}
static int64_t s64(const uint8_t* d, size_t at) { return (int64_t)u64(d, at); }

static std::string cstr(const uint8_t* d, size_t len, int64_t off) {
    if (off <= 0 || (size_t)off >= len) return std::string();
    size_t e = (size_t)off;
    while (e < len && d[e] != 0) e++;
    return std::string((const char*)d + off, e - off);
}

// 100-byte GeometryDeclaration -> elements + streams.
static MeshDecl decl_at(const uint8_t* d, size_t len, int64_t off) {
    MeshDecl md;
    if (off < 0 || (size_t)off + DECL_SIZE > len) return md;
    uint8_t ne = d[off + 96];
    uint8_t ns = d[off + 97];
    for (int i = 0; i < ne && i < 16; i++) {
        size_t p = (size_t)off + i * 4;
        md.elements.push_back({d[p], d[p + 1], d[p + 2], d[p + 3]});
    }
    for (int i = 0; i < ns && i < 16; i++) {
        size_t p = (size_t)off + 64 + i * 2;
        md.streams.push_back({d[p], d[p + 1]});
    }
    return md;
}

static std::vector<MeshSection> sections_at(const uint8_t* d, size_t len,
                                            int64_t off, int count) {
    std::vector<MeshSection> out;
    for (int i = 0; i < count; i++) {
        size_t p = (size_t)off + (size_t)i * SECTION_SIZE;
        if (p + SECTION_SIZE > len) break;
        MeshSection s;
        s.index = i;
        s.material = cstr(d, len, s64(d, p + 0x08) + BASE);
        s.bones_per_vertex = d[p + 0x1A];
        MeshDecl decl = decl_at(d, len, p + 0x64);
        if (s.bones_per_vertex > 0) {
            // Skinned: the second declaration supersedes the first, but only if
            // it actually declares formats.
            MeshDecl d2 = decl_at(d, len, p + 0xC8);
            bool any = false;
            for (const auto& e : d2.elements) if (e[1] != 0) { any = true; break; }
            if (any) decl = d2;
        }
        s.state_key     = u64(d, p + 0x130);
        s.material_id   = u16(d, p + 0x1C);
        s.stride        = d[p + 0x1E];
        s.prim_count    = u32(d, p + 0x20);
        s.start_index   = u32(d, p + 0x24);
        s.vertex_offset = u32(d, p + 0x28);
        s.vertex_count  = u32(d, p + 0x2C);
        s.decl  = decl;
        s.decl0 = decl_at(d, len, p + 0x64);
        s.decl1 = decl_at(d, len, p + 0xC8);
        out.push_back(std::move(s));
    }
    return out;
}

MeshSet meshset_parse(const uint8_t* d, size_t len, std::string& err) {
    MeshSet ms;
    if (len < (size_t)BASE + 0xA0) { err = "too short to be a MeshSet"; return ms; }

    int lod_stride = (int)u32(d, 0);
    if (lod_stride != 176 && lod_stride != 192) lod_stride = 176;
    ms.lod_stride = lod_stride;

    int h = BASE;
    int64_t lod_offs[6];
    for (int i = 0; i < 6; i++) lod_offs[i] = s64(d, h + 0x20 + i * 8);

    ms.name = cstr(d, len, s64(d, h + 0x60) + BASE);
    ms.mesh_type = d[h + 0x6C];
    ms.lod_count = u16(d, h + 0x9C);
    ms.section_count = u16(d, h + 0x9E);

    int nl = ms.lod_count < 6 ? ms.lod_count : 6;
    for (int li = 0; li < nl; li++) {
        int64_t lo = lod_offs[li] + BASE;
        if (lo <= 0 || (size_t)lo >= len - (size_t)lod_stride) continue;
        int sec_count = (int)u32(d, lo + 0x08);
        int64_t sec_off = s64(d, lo + 0x0C) + BASE;
        int idx_fmt = (int)u32(d, lo + 0x54);
        int idx_size = s32(d, lo + 0x58);
        int vtx_size = s32(d, lo + 0x5C);
        if (sec_count > 4096 || sec_off <= 0 || (size_t)sec_off >= len) continue;

        MeshLod lod;
        lod.index = li;
        lod.section_count = sec_count;
        lod.sections = sections_at(d, len, sec_off, sec_count);
        lod.idx32 = (idx_fmt == 46);
        lod.index_size = idx_size;
        lod.vertex_size = vtx_size;
        std::memcpy(lod.chunk_id.data(), d + lo + 0x74, 16);
        lod.inline_offset = u32(d, lo + 0x84);
        lod.name = cstr(d, len, s64(d, lo + 0x94) + BASE);
        ms.lods.push_back(std::move(lod));
    }
    ms.size = len;
    ms.ok = true;
    return ms;
}

}  // namespace bf6
