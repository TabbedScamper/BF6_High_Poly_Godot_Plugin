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

// Vertex-element usage codes.
static const int U_POS = 1, U_NORMAL = 6, U_UV0 = 33, U_UV4 = 37;

static int fmt_size(int fmt) {
    switch (fmt) {
        case 1: return 4;  case 2: return 8;  case 3: return 12; case 4: return 16;
        case 5: return 2;  case 6: return 4;  case 7: return 6;  case 8: return 8;
        case 10: case 11: case 12: case 13: return 4;
        case 14: return 2; case 15: return 4; case 16: return 6; case 17: return 8;
        case 18: return 2; case 19: return 4; case 20: return 6; case 21: return 8;
        case 22: return 4; case 23: return 8; case 24: return 4; case 25: return 8;
        case 50: return 1;
    }
    return 0;
}
static int fmt_components(int fmt) {
    switch (fmt) {
        case 1: case 5: case 14: case 18: case 50: return 1;
        case 2: case 6: case 15: case 19: case 22: case 24: return 2;
        case 3: case 7: case 16: case 20: return 3;
        case 4: case 8: case 10: case 11: case 12: case 13:
        case 17: case 21: case 23: case 25: return 4;
    }
    return 0;
}

static float half_to_float(uint16_t h) {
    uint32_t sign = (h & 0x8000) << 16;
    uint32_t exp = (h >> 10) & 0x1F;
    uint32_t man = h & 0x3FF;
    uint32_t bits;
    if (exp == 0) {
        if (man == 0) { bits = sign; }
        else {
            exp = 127 - 15 + 1;
            while ((man & 0x400) == 0) { man <<= 1; exp--; }
            man &= 0x3FF;
            bits = sign | (exp << 23) | (man << 13);
        }
    } else if (exp == 0x1F) {
        bits = sign | 0x7F800000 | (man << 13);
    } else {
        bits = sign | ((exp + (127 - 15)) << 23) | (man << 13);
    }
    float f; std::memcpy(&f, &bits, 4); return f;
}

static float f32(const uint8_t* d, size_t at) {
    uint32_t u = u32(d, at); float f; std::memcpy(&f, &u, 4); return f;
}
static int16_t rd_s16(const uint8_t* d, size_t at) { return (int16_t)u16(d, at); }

// Decode one vertex element across `count` vertices -> (floats, components).
// SoA per stream: each stream's sub-buffer sits back to back from `base`.
static std::pair<std::vector<float>, int> read_attr(
    const uint8_t* buf, size_t buflen, int base, int count,
    const std::array<uint8_t, 4>& el, const std::vector<std::array<uint8_t, 2>>& streams) {
    std::vector<float> out;
    int fmt = el[1], off = el[2], si = el[3];
    if (si >= (int)streams.size()) return {out, 0};
    int sstride = streams[si][0];
    int size = fmt_size(fmt);
    if (size == 0 || sstride == 0) return {out, 0};
    size_t sbase = (size_t)base;
    for (int s = 0; s < si; s++) sbase += (size_t)streams[s][0] * count;
    if (sbase + (size_t)(count - 1) * sstride + off + size > buflen) return {out, 0};
    int comps = fmt_components(fmt);
    if (comps == 0) return {out, 0};
    out.resize((size_t)count * comps);
    for (int i = 0; i < count; i++) {
        size_t p = sbase + (size_t)i * sstride + off;
        int o = i * comps;
        switch (fmt) {
            case 1: case 2: case 3: case 4:
                for (int c = 0; c < comps; c++) out[o + c] = f32(buf, p + c * 4); break;
            case 5: case 6: case 7: case 8:
                for (int c = 0; c < comps; c++) out[o + c] = half_to_float(u16(buf, p + c * 2)); break;
            case 14: case 15: case 16: case 17:
                for (int c = 0; c < comps; c++) out[o + c] = (float)rd_s16(buf, p + c * 2); break;
            case 18: case 19: case 20: case 21:
                for (int c = 0; c < comps; c++) out[o + c] = (float)rd_s16(buf, p + c * 2) / 32767.0f; break;
            case 22: case 23:
                for (int c = 0; c < comps; c++) out[o + c] = (float)u16(buf, p + c * 2); break;
            case 24: case 25:
                for (int c = 0; c < comps; c++) out[o + c] = (float)u16(buf, p + c * 2) / 65535.0f; break;
            case 11: case 13:
                for (int c = 0; c < comps; c++) out[o + c] = (float)buf[p + c] / 255.0f; break;
            case 10: case 12:
                for (int c = 0; c < comps; c++) out[o + c] = (float)buf[p + c]; break;
            default: return {std::vector<float>(), 0};
        }
    }
    return {out, comps};
}

// Triangle indices for one section, CCW->CW wound, degenerate/out-of-range dropped.
static std::vector<uint32_t> read_indices(
    const uint8_t* buf, size_t buflen, int vsize, int isize, bool idx32,
    int start, int prim_count, int vcount, int voff) {
    std::vector<uint32_t> out;
    int stride = idx32 ? 4 : 2;
    int need = prim_count * 3;
    size_t first = (size_t)vsize + (size_t)start * stride;
    if (first + (size_t)need * stride > (size_t)vsize + isize) return out;
    if (first + (size_t)need * stride > buflen) return out;

    std::vector<int64_t> raw(need);
    if (idx32) for (int i = 0; i < need; i++) raw[i] = u32(buf, first + i * 4);
    else       for (int i = 0; i < need; i++) raw[i] = u16(buf, first + i * 2);

    // Some LOD0s store vertex-buffer-absolute indices; retry minus voff.
    int64_t hi = 0;
    for (int64_t v : raw) if (v > hi) hi = v;
    if (hi >= vcount && voff > 0) {
        bool ok = true;
        for (int i = 0; i < need; i++) { int64_t v2 = raw[i] - voff; if (v2 < 0 || v2 >= vcount) { ok = false; break; } }
        if (ok) for (int i = 0; i < need; i++) raw[i] -= voff;
    }

    out.resize(need);
    int w = 0;
    for (int t = 0; t < prim_count; t++) {
        int64_t a = raw[t * 3], b = raw[t * 3 + 1], c = raw[t * 3 + 2];
        if (a < 0 || b < 0 || c < 0 || a >= vcount || b >= vcount || c >= vcount) continue;
        if (a == b || b == c || a == c) continue;
        out[w] = (uint32_t)a; out[w + 1] = (uint32_t)c; out[w + 2] = (uint32_t)b;  // swap for CW
        w += 3;
    }
    out.resize(w);
    return out;
}

std::vector<MeshGeomSection> meshset_read_lod(const MeshSet& ms, int lod,
                                              const uint8_t* chunk, size_t clen,
                                              std::string& err) {
    std::vector<MeshGeomSection> out;
    if (lod < 0 || lod >= (int)ms.lods.size()) { err = "lod out of range"; return out; }
    const MeshLod& L = ms.lods[lod];
    int vsize = L.vertex_size, isize = L.index_size;
    if ((int64_t)clen < (int64_t)vsize + isize) { err = "geometry short"; return out; }

    for (const MeshSection& s : L.sections) {
        int vcount = s.vertex_count, pcount = s.prim_count;
        if (pcount == 0 || vcount == 0) continue;
        std::string low = s.material;
        for (char& ch : low) if (ch >= 'A' && ch <= 'Z') ch += 32;
        if (low.find("shadow") != std::string::npos || low.find("zonly") != std::string::npos ||
            low.find("depth") != std::string::npos) continue;

        int voff = s.vertex_offset;
        std::vector<float> pos, nrm;
        int pos_comps = 0, nrm_comps = 0;
        std::vector<std::pair<std::vector<float>, int>> uv_sets;
        for (const auto& el : s.decl.elements) {
            int usage = el[0];
            if (usage == U_POS && pos.empty()) {
                auto r = read_attr(chunk, clen, voff, vcount, el, s.decl.streams);
                if (!r.first.empty()) { pos = std::move(r.first); pos_comps = r.second; }
            } else if (usage == U_NORMAL && nrm.empty()) {
                auto r = read_attr(chunk, clen, voff, vcount, el, s.decl.streams);
                if (!r.first.empty()) { nrm = std::move(r.first); nrm_comps = r.second; }
            } else if (usage >= U_UV0 && usage <= 36) {
                auto r = read_attr(chunk, clen, voff, vcount, el, s.decl.streams);
                if (!r.first.empty() && r.second >= 2) uv_sets.push_back({std::move(r.first), r.second});
            }
        }
        if (pos.empty() || pos_comps < 3) continue;

        MeshGeomSection g;
        g.material = s.material; g.state_key = s.state_key; g.material_id = s.material_id;
        g.positions.resize((size_t)vcount * 3);
        for (int i = 0; i < vcount; i++) {
            int o = i * pos_comps;
            g.positions[i * 3] = pos[o]; g.positions[i * 3 + 1] = pos[o + 1]; g.positions[i * 3 + 2] = pos[o + 2];
        }
        if (!uv_sets.empty()) {   // default.tc0: the first declared texcoord
            const auto& src = uv_sets[0].first; int c = uv_sets[0].second;
            g.uv0.resize((size_t)vcount * 2);
            for (int i = 0; i < vcount; i++) { g.uv0[i * 2] = src[i * c]; g.uv0[i * 2 + 1] = src[i * c + 1]; }
        }
        if (nrm_comps >= 3) {
            g.normals.resize((size_t)vcount * 3);
            for (int i = 0; i < vcount; i++) {
                int o = i * nrm_comps;
                g.normals[i * 3] = nrm[o]; g.normals[i * 3 + 1] = nrm[o + 1]; g.normals[i * 3 + 2] = nrm[o + 2];
            }
        }
        g.indices = read_indices(chunk, clen, vsize, isize, L.idx32, s.start_index, pcount, vcount, voff);
        if (g.indices.empty()) continue;
        out.push_back(std::move(g));
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
