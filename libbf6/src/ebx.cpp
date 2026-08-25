#include "ebx.h"

#include <algorithm>
#include <cstring>

namespace bf6 {

uint64_t Ebx::n_inst = 0, Ebx::n_top = 0, Ebx::n_nested = 0, Ebx::n_arr_elem = 0;
void Ebx::reset_counts() { n_inst = n_top = n_nested = n_arr_elem = 0; }

namespace {

template <typename T>
T rd(const std::vector<uint8_t>& d, int64_t off)
{
    T v{};
    std::memcpy(&v, d.data() + off, sizeof(T));
    return v;
}

bool fits(const std::vector<uint8_t>& d, int64_t off, int64_t n)
{
    return off >= 0 && off + n <= (int64_t)d.size();
}

int64_t align_up(int64_t v, int64_t a)
{
    return a ? ((v + a - 1) & ~(a - 1)) : v;
}

std::string guid_string(const uint8_t* b)
{
    TypeGuid g{};
    std::memcpy(g.data(), b, 16);
    return TypeDb::guid_str(g);
}

// A NUL-terminated read that stops at a bound, matching the reference exactly:
// no terminator, or one beyond the bound, both mean "take the whole bounded
// span", which is where the original byte loop stopped.
std::string bounded_str(const std::vector<uint8_t>& d, int64_t from, int64_t limit)
{
    if (from < 0 || from >= (int64_t)d.size()) return "";
    const int64_t stop = std::min<int64_t>((int64_t)d.size(), limit);
    int64_t e = from;
    while (e < stop && d[(size_t)e] != 0) e++;
    return std::string((const char*)d.data() + from, (size_t)(e - from));
}

}  // namespace

uint32_t ebx_elem_size(uint8_t te)
{
    switch (te)
    {
    case 0x0A:                      // Bool - flat bytes, NOT u32
    case 0x0B: case 0x0C: return 1; // Int8 / Uint8
    case 0x0D: case 0x0E: return 2; // Int16 / Uint16
    case 0x0F: case 0x10: case 0x08: return 4;   // Int32 / Uint32 / enum
    case 0x11: case 0x12: return 8; // Int64 / Uint64
    case 0x13: return 4;            // Float32
    case 0x14: return 8;            // Float64
    default:   return 4;
    }
}

bool Ebx::parse(std::vector<uint8_t> bytes, std::string& err)
{
    err.clear();
    data_ = std::move(bytes);
    const std::vector<uint8_t>& d = data_;
    if (d.size() < 12 || std::memcmp(d.data(), "RIFF", 4) != 0)
    { err = "not a RIFF file"; return false; }

    int64_t ebxd_off = -1, ebxd_size = 0, efix_off = -1;
    for (int64_t o = 12; o + 8 <= (int64_t)d.size();)
    {
        char cid[5] = {0};
        std::memcpy(cid, d.data() + o, 4);
        const uint32_t sz = rd<uint32_t>(d, o + 4);
        if (std::strcmp(cid, "EBXD") == 0) { ebxd_off = o + 8; ebxd_size = sz; }
        else if (std::strcmp(cid, "EFIX") == 0) { efix_off = o + 8; }
        o += 8 + (int64_t)sz;
        if (o % 2 == 1) o++;
    }
    (void)ebxd_size;
    if (ebxd_off < 0 || efix_off < 0) { err = "not a RIFF-EBX partition"; return false; }

    payload_ = align_up(ebxd_off, 16);

    int64_t s = efix_off;
    auto need = [&](int64_t n) { return fits(d, s, n); };
    if (!need(16)) { err = "truncated EFIX"; return false; }
    partition_guid_ = guid_string(d.data() + s);
    s += 16;

    auto read_u32 = [&](uint32_t& out) -> bool
    {
        if (!need(4)) return false;
        out = rd<uint32_t>(d, s);
        s += 4;
        return true;
    };

    uint32_t n = 0;
    if (!read_u32(n)) { err = "truncated EFIX"; return false; }
    type_guids_.clear();
    for (uint32_t i = 0; i < n; i++)
    {
        if (!need(16)) { err = "truncated type guid table"; return false; }
        TypeGuid g{};
        std::memcpy(g.data(), d.data() + s, 16);
        type_guids_.push_back(g);
        s += 16;
    }
    if (!read_u32(n)) { err = "truncated EFIX"; return false; }
    type_signatures_.clear();
    for (uint32_t i = 0; i < n; i++)
    {
        uint32_t v = 0;
        if (!read_u32(v)) { err = "truncated signature table"; return false; }
        type_signatures_.push_back(v);
    }

    uint32_t exported = 0;
    if (!read_u32(exported)) { err = "truncated EFIX"; return false; }
    exported_instance_count_ = exported;

    if (!read_u32(n)) { err = "truncated EFIX"; return false; }
    instance_offsets_.clear();
    for (uint32_t i = 0; i < n; i++)
    {
        uint32_t v = 0;
        if (!read_u32(v)) { err = "truncated instance table"; return false; }
        instance_offsets_.push_back(v);
    }

    // pointer offsets: read to advance. resource-ref offsets: kept, they name
    // where the resource ids sit in the payload.
    if (!read_u32(n)) { err = "truncated EFIX"; return false; }
    s += (int64_t)n * 4;
    if (!read_u32(n)) { err = "truncated EFIX"; return false; }
    std::vector<uint32_t> res_off;
    for (uint32_t i = 0; i < n; i++)
    {
        uint32_t v = 0;
        if (!read_u32(v)) { err = "truncated resource-ref table"; return false; }
        res_off.push_back(v);
    }

    if (!read_u32(n)) { err = "truncated EFIX"; return false; }
    imports_.clear();
    for (uint32_t i = 0; i < n; i++)
    {
        if (!need(32)) { err = "truncated import table"; return false; }
        Import im;
        im.partition = guid_string(d.data() + s);
        im.instance  = guid_string(d.data() + s + 16);
        imports_.push_back(std::move(im));
        s += 32;
    }
    // The remaining EFIX tables are not needed; EBXD is what matters.

    resource_refs_.clear();
    for (uint32_t off : res_off)
        if (fits(d, ebxd_off + (int64_t)off, 8))
            resource_refs_.push_back(rd<uint64_t>(d, ebxd_off + (int64_t)off));

    inst_map_.clear();
    inst_type_.assign(instance_offsets_.size(), -1);
    for (size_t i = 0; i < instance_offsets_.size(); i++)
    {
        const uint32_t off = instance_offsets_[i];
        inst_map_[off] = i;
        const int64_t p = payload_ + (int64_t)off;
        if (fits(d, p, 2))
        {
            const uint16_t tr = rd<uint16_t>(d, p);
            if (tr < type_guids_.size()) inst_type_[i] = (int32_t)tr;
        }
    }
    return true;
}

std::string Ebx::instance_guid(size_t i) const
{
    if (i >= exported_instance_count_ || i >= instance_offsets_.size()) return "";
    const int64_t off = payload_ + (int64_t)instance_offsets_[i];
    if (off < 16 || off > (int64_t)data_.size()) return "";
    return guid_string(data_.data() + off - 16);
}

TypeGuid Ebx::instance_type(size_t i) const
{
    TypeGuid g{};
    if (i < inst_type_.size() && inst_type_[i] >= 0)
        g = type_guids_[(size_t)inst_type_[i]];
    return g;
}

const TypeLayout& Ebx::layout(const TypeGuid& g)
{
    return types_.layout_full(g);
}

EbxValue Ebx::read_instance(size_t idx, const std::vector<uint32_t>* want)
{
    n_inst++;
    EbxValue empty;
    if (idx >= instance_offsets_.size() || inst_type_[idx] < 0) return empty;
    const TypeGuid& g = type_guids_[(size_t)inst_type_[idx]];
    const int64_t base = payload_ + (int64_t)instance_offsets_[idx];
    if (!want || want->empty()) return read_struct(g, base, 0);
    return read_struct_only(g, base, 0, *want);
}

// read_struct with a field filter. Kept as its own function rather than a
// branch inside read_struct: that one runs for every nested struct at every
// depth, and paying a lookup per field there to serve a filter that only ever
// applies at the top would make the common path slower.
EbxValue Ebx::read_struct_only(const TypeGuid& g, int64_t base, int depth,
                               const std::vector<uint32_t>& want)
{
    EbxValue out;
    const TypeLayout& lay = layout(g);
    if (!lay.valid || depth > kEbxMaxDepth) return out;
    out.kind = EbxValue::Kind::Struct;
    out.guid = g;
    for (const FieldInfo& f : lay.fields)
    {
        if (std::find(want.begin(), want.end(), f.name_hash) == want.end()) continue;
        n_top++;
        const int64_t pos = base + (int64_t)f.offset;
        if (!fits(data_, pos, 8)) { out.fields.emplace_back(f.name_hash, EbxValue{}); continue; }
        out.fields.emplace_back(f.name_hash, decode(pos, f.type_va, depth));
    }
    return out;
}

EbxValue Ebx::read_struct(const TypeGuid& g, int64_t base, int depth)
{
    EbxValue out;
    const TypeLayout& lay = layout(g);
    if (!lay.valid || depth > kEbxMaxDepth) return out;
    out.kind = EbxValue::Kind::Struct;
    out.guid = g;
    for (const FieldInfo& f : lay.fields)
    {
        // Counted here and not in read_struct_only: this is the decoder the
        // `want` filter does NOT reach, so this number is the filter's blind
        // spot measured directly.
        n_nested++;
        const int64_t pos = base + (int64_t)f.offset;
        // A FIELD THAT LANDS OUTSIDE THE FILE MUST NOT COST THE WHOLE INSTANCE.
        // An instance is many fields and the one being looked for is rarely the
        // broken one. Losing a street light because a SIBLING field was
        // unreadable is how 395 placements went missing while every step still
        // reported success.
        if (!fits(data_, pos, 8)) { out.fields.emplace_back(f.name_hash, EbxValue{}); continue; }
        out.fields.emplace_back(f.name_hash, decode(pos, f.type_va, depth));
    }
    return out;
}

EbxValue Ebx::decode(int64_t pos, uint64_t type_va, int depth)
{
    EbxValue v;
    const ResolvedType rt = types_.resolve(type_va);
    if (!rt.valid) return v;

    switch (rt.te)
    {
    case 0x04: return read_array(pos, rt.elem_va, depth);
    case 0x03: case 0x01: return pointer_ref(pos);          // Class / DbObject
    case 0x02: return read_struct(rt.guid, pos, depth + 1); // inline struct
    case 0x07:
        v.kind = EbxValue::Kind::Str;
        v.s = cstring(pos);
        return v;
    case 0x17:
        v.kind = EbxValue::Kind::ResRef;
        v.u = fits(data_, pos, 8) ? rd<uint64_t>(data_, pos) : 0;
        return v;
    case 0x06:   // inline name, bounded at 32 bytes
        v.kind = EbxValue::Kind::Str;
        v.s = bounded_str(data_, pos, pos + 32);
        return v;
    case 0x15:
        v.kind = EbxValue::Kind::Guid;
        if (fits(data_, pos, 16)) std::memcpy(v.guid.data(), data_.data() + pos, 16);
        return v;
    default:
        break;
    }

    // The scalar set, listed rather than inferred. decode() and scalar() have
    // DIFFERENT defaults in the reference and that difference is load-bearing:
    // an unhandled type enum here is reported as unknown, while an unhandled
    // ARRAY ELEMENT falls back to a u32. Collapsing the two turned every such
    // element into null, which the validation caught on six partitions.
    switch (rt.te)
    {
    case 0x0A: case 0x0B: case 0x0C: case 0x0D: case 0x0E:
    case 0x0F: case 0x10: case 0x08: case 0x11: case 0x12:
    case 0x13: case 0x14:
        return scalar(pos, rt.te);
    default:
        break;
    }
    v.kind = EbxValue::Kind::Unknown;
    v.te   = rt.te;
    v.u    = fits(data_, pos, 4) ? rd<uint32_t>(data_, pos) : 0;
    return v;
}

EbxValue Ebx::pointer_ref(int64_t pos)
{
    EbxValue v;
    if (!fits(data_, pos, 4)) return v;

    // THE RELATIVE OFFSET IS A SIGNED 32-BIT VALUE in an 8-byte slot, the upper
    // half zero. Read 8 bytes wide and every NEGATIVE offset, a reference to an
    // instance earlier in the payload, becomes a huge positive that lands
    // nowhere, so the ref silently resolves to null instead of erroring.
    //
    // Most references point backward, so that lost nearly all of them:
    //   gameplay.ebx   517 of 533 negative -> 16 resolved (3%)
    //   mil_hemtt_01   298 of 303 negative ->  4 resolved (1%)
    //   mp_dumbo.ebx    49 of  50 negative ->  1 resolved (2%)
    // Reading signed 32 instead: 885 of 886, every partition.
    //
    // It hid because a level walk never needs an internal ref: it recurses
    // through blueprint IMPORTS, which take the `idx & 1` branch and were
    // always right. Only a rule following one specific edge noticed, and then
    // it looked like missing data rather than a bad read.
    const int32_t idx = rd<int32_t>(data_, pos);
    if (idx == 0) return v;

    if (idx & 1)
    {
        const int32_t i = idx >> 1;
        if (i < 0 || (size_t)i >= imports_.size()) return v;
        v.kind = EbxValue::Kind::ImportRef;
        v.s    = imports_[(size_t)i].partition;
        v.import_path = "<not indexed>";
        if (guid_index_)
        {
            auto it = guid_index_->find(v.s);
            if (it != guid_index_->end()) v.import_path = it->second;
        }
        return v;
    }

    v.kind = EbxValue::Kind::InstanceRef;
    const int64_t inst_off = (pos + idx) - payload_;
    if (inst_off >= 0 && inst_off <= 0xFFFFFFFFll)
    {
        auto it = inst_map_.find((uint32_t)inst_off);
        if (it != inst_map_.end()) v.instance = (int32_t)it->second;
    }
    return v;
}

bool Ebx::import_ref(size_t idx, uint32_t name_hash,
                     std::string& partition_guid, std::string& path)
{
    partition_guid.clear();
    path.clear();
    if (idx >= instance_offsets_.size() || inst_type_[idx] < 0) return false;
    const TypeLayout& lay = layout(type_guids_[(size_t)inst_type_[idx]]);
    if (!lay.valid) return false;
    for (const FieldInfo& f : lay.fields)
    {
        if (f.name_hash != name_hash) continue;
        const int64_t pos = payload_ + (int64_t)instance_offsets_[idx] + (int64_t)f.offset;
        if (!fits(data_, pos, 8)) return false;
        // Eight bytes, not four. The slot IS eight wide; the low half alone
        // answers for every index the game ships, and reading the whole thing
        // costs nothing and does not depend on that staying true.
        const int64_t v = rd<int64_t>(data_, pos);
        if (v == 0 || !(v & 1)) return false;
        const int64_t i = v >> 1;
        if (i < 0 || (size_t)i >= imports_.size()) return false;
        partition_guid = imports_[(size_t)i].partition;
        if (guid_index_)
        {
            auto it = guid_index_->find(partition_guid);
            if (it != guid_index_->end()) path = it->second;
        }
        return true;
    }
    return false;
}

int32_t Ebx::int_pointer(size_t idx, uint32_t name_hash)
{
    if (idx >= instance_offsets_.size() || inst_type_[idx] < 0) return -1;
    const TypeLayout& lay = layout(type_guids_[(size_t)inst_type_[idx]]);
    if (!lay.valid) return -1;
    for (const FieldInfo& f : lay.fields)
    {
        if (f.name_hash != name_hash) continue;
        const int64_t pos = payload_ + (int64_t)instance_offsets_[idx] + (int64_t)f.offset;
        if (!fits(data_, pos, 4)) return -1;
        const int32_t rel = rd<int32_t>(data_, pos);
        if (rel == 0) return -1;
        const int64_t inst_off = (pos + rel) - payload_;
        if (inst_off < 0 || inst_off > 0xFFFFFFFFll) return -1;
        auto it = inst_map_.find((uint32_t)inst_off);
        return it == inst_map_.end() ? -1 : (int32_t)it->second;
    }
    return -1;
}

std::string Ebx::cstring(int64_t pos) const
{
    if (!fits(data_, pos, 8)) return "";
    const int64_t off = rd<int64_t>(data_, pos);
    if (off == -1) return "";
    const int64_t loc = pos + off;
    if (loc < 0 || loc >= (int64_t)data_.size()) return "";
    return bounded_str(data_, loc, loc + 512);
}

EbxValue Ebx::read_array(int64_t pos, uint64_t elem_va, int depth)
{
    EbxValue out;
    out.kind = EbxValue::Kind::Array;
    if (!fits(data_, pos, 4)) return out;

    const int32_t aoff = rd<int32_t>(data_, pos);
    const int64_t array_data = (pos + 4) + aoff - 8;
    if (!fits(data_, array_data, 4)) return out;
    const int32_t count = rd<int32_t>(data_, array_data);
    if (count < 0 || (uint32_t)count > kEbxMaxArray) return out;

    const int64_t elem = array_data + 4;
    const ResolvedType rt = elem_va ? types_.resolve(elem_va) : ResolvedType{};
    const uint8_t te = rt.valid ? rt.te : 0x10;
    n_arr_elem += (uint64_t)count;

    if (te == 0x02)
    {
        const TypeLayout& lay = layout(rt.guid);
        if (!lay.valid) return out;
        const int64_t sz = align_up(lay.size, std::max<int64_t>(1, lay.align));
        for (int32_t i = 0; i < count; i++)
            out.items.push_back(read_struct(rt.guid, elem + (int64_t)i * sz, depth + 1));
    }
    else if (te == 0x03 || te == 0x01)
    {
        for (int32_t i = 0; i < count; i++)
            out.items.push_back(pointer_ref(elem + (int64_t)i * 8));
    }
    else if (te == 0x07)
    {
        for (int32_t i = 0; i < count; i++)
        {
            EbxValue v;
            v.kind = EbxValue::Kind::Str;
            v.s = cstring(elem + (int64_t)i * 8);
            out.items.push_back(std::move(v));
        }
    }
    else
    {
        // ELEMENT STRIDE FOLLOWS THE ELEMENT TYPE. This once read every
        // non-struct, non-pointer, non-string array as a 4-byte u32, which is
        // right for ints and wrong for everything narrower. A bool array is
        // flat bytes, so a 4-byte stride reads element i from elem+i*4 and runs
        // four times past the end into whatever follows. The values that come
        // back are plausible and meaningless.
        //
        // Cost, measured on mp_dumbo: StaticModelGroup `Visible` is a bool
        // array, so 5,762 instances were judged not-visible from garbage and
        // dropped, building facades among them, which is why rooms had their
        // windows and fittings but no walls.
        const int64_t sz = ebx_elem_size(te);
        for (int32_t i = 0; i < count; i++)
        {
            const int64_t p = elem + (int64_t)i * sz;
            if (!fits(data_, p, sz)) break;
            out.items.push_back(scalar(p, te));
        }
    }
    return out;
}

EbxValue Ebx::scalar(int64_t p, uint8_t te) const
{
    EbxValue v;
    switch (te)
    {
    case 0x0A: v.kind = EbxValue::Kind::Bool; v.b = fits(data_, p, 1) && data_[(size_t)p] != 0; break;
    case 0x0B: v.kind = EbxValue::Kind::Int;  v.i = fits(data_, p, 1) ? (int8_t)data_[(size_t)p] : 0; break;
    case 0x0C: v.kind = EbxValue::Kind::Uint; v.u = fits(data_, p, 1) ? data_[(size_t)p] : 0; break;
    case 0x0D: v.kind = EbxValue::Kind::Int;  v.i = fits(data_, p, 2) ? rd<int16_t>(data_, p) : 0; break;
    case 0x0E: v.kind = EbxValue::Kind::Uint; v.u = fits(data_, p, 2) ? rd<uint16_t>(data_, p) : 0; break;
    case 0x0F: v.kind = EbxValue::Kind::Int;  v.i = fits(data_, p, 4) ? rd<int32_t>(data_, p) : 0; break;
    case 0x10: case 0x08:
               v.kind = EbxValue::Kind::Uint; v.u = fits(data_, p, 4) ? rd<uint32_t>(data_, p) : 0; break;
    case 0x11: v.kind = EbxValue::Kind::Int;  v.i = fits(data_, p, 8) ? rd<int64_t>(data_, p) : 0; break;
    case 0x12: v.kind = EbxValue::Kind::Uint; v.u = fits(data_, p, 8) ? rd<uint64_t>(data_, p) : 0; break;
    case 0x13: v.kind = EbxValue::Kind::Real; v.f = fits(data_, p, 4) ? rd<float>(data_, p) : 0.0f; break;
    case 0x14: v.kind = EbxValue::Kind::Real; v.f = fits(data_, p, 8) ? rd<double>(data_, p) : 0.0; break;
    default:
        // A u32, matching both references. An array whose element type is not
        // one of the above still reads as SOMETHING; returning null here made
        // real values disappear.
        v.kind = EbxValue::Kind::Uint;
        v.u = fits(data_, p, 4) ? rd<uint32_t>(data_, p) : 0;
        break;
    }
    return v;
}

}  // namespace bf6
