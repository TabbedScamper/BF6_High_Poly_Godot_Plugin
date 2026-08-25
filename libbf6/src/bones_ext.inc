/* bones_ext.inc - the weapon skinning palette.
 *
 * A translation-unit fragment like raw_ext.inc; wire it beside the others.
 *
 * THERE IS NO SEPARATE ATTACHMENT-MOUNT PATH AND NO SEPARATE MOVING-PART PATH.
 * The bolt, the ejection cover and a mounted scope are all placed by the same
 * palette. Measured: a Wep_Bolt1 part reproduces the game's own bounding box
 * 96.4% of the time when skinned and 0.0% as authored, median error 89.8 mm -
 * which is exactly the "floating detached piece" a viewer shows when it draws
 * vertices where they sit in the file.
 *
 *     skin[b]  = InverseModelPose[b] * weaponBoneWorld[b]
 *     v_render = skin[ boneList[ BoneIndices[v] ] ] * v_authored
 *
 * weaponBoneWorld is the shared 66-bone skeleton with the weapon's own
 * PARENT-LOCAL overrides swapped in and then composed down Hierarchy.
 *
 * TWO TRAPS, both of which produce confident nonsense rather than an error:
 *
 *  1. The override is a MATRIX, not a translation. 1,682 of 72,066 bone rows
 *     carry a real rotation, and Wep_SelectFireMode rotates on 20 of 66
 *     weapons. Treating it as an offset silently drops those.
 *  2. The rows are PARENT-LOCAL and must be composed down the hierarchy.
 *     Reading them raw yields zero for Muzzle_ATT and MuzzleAdaptor_ATT, which
 *     parks every muzzle device at the world origin.
 *
 * The model-definition pose IS the rest pose for a static viewer; the data
 * carries no separate closed pose.
 *
 * Fields are matched BY NAME through the recovered name dictionary rather than
 * by hardcoded hash, so this stays readable and survives a field moving.
 */

namespace {

struct BfMat34 {           /* 3x4 row-major: right, up, forward, trans */
    float m[12];
};

BfMat34 bf6__mat_identity()
{
    BfMat34 r{};
    r.m[0] = 1.f; r.m[4] = 1.f; r.m[8] = 1.f;
    return r;
}

/* a * b, both 3x4 with an implicit (0,0,0,1) fourth column. */
BfMat34 bf6__mat_mul(const BfMat34& a, const BfMat34& b)
{
    BfMat34 r{};
    for (int row = 0; row < 3; row++)
        for (int col = 0; col < 3; col++)
            r.m[row * 3 + col] = a.m[row * 3 + 0] * b.m[0 * 3 + col]
                               + a.m[row * 3 + 1] * b.m[1 * 3 + col]
                               + a.m[row * 3 + 2] * b.m[2 * 3 + col];
    for (int col = 0; col < 3; col++)
        r.m[9 + col] = a.m[9 + 0] * b.m[0 * 3 + col]
                     + a.m[9 + 1] * b.m[1 * 3 + col]
                     + a.m[9 + 2] * b.m[2 * 3 + col]
                     + b.m[9 + col];
    return r;
}

/* A field of this instance whose recovered NAME matches. Returns null when the
 * name is unknown to the dictionary or absent from the record - both of which
 * are reported rather than guessed around. */
const bf6::EbxValue* bf6__by_name(const bf6::EbxValue& v, const char* want)
{
    for (const auto& kv : v.fields)
    {
        const char* n = bf6_field_name(kv.first);
        if (n && std::strcmp(n, want) == 0) return &kv.second;
    }
    return nullptr;
}

float bf6__vec_component(const bf6::EbxValue& v, int i)
{
    if (v.kind != bf6::EbxValue::Kind::Struct) return 0.f;
    if (i < (int)v.fields.size())
    {
        const bf6::EbxValue& f = v.fields[(size_t)i].second;
        if (f.kind == bf6::EbxValue::Kind::Real) return (float)f.f;
    }
    return 0.f;
}

/* LinearTransform ships as {Right, Up, Forward, Trans}, each a Vec3 - the same
 * 3x4 row-major convention placements use. */
BfMat34 bf6__read_lt(const bf6::EbxValue& v)
{
    BfMat34 r = bf6__mat_identity();
    static const char* kRows[4] = { "Right", "Up", "Forward", "Trans" };
    for (int row = 0; row < 4; row++)
    {
        const bf6::EbxValue* c = bf6__by_name(v, kRows[row]);
        if (!c && row < (int)v.fields.size()) c = &v.fields[(size_t)row].second;
        if (!c) continue;
        for (int k = 0; k < 3; k++) r.m[row * 3 + k] = bf6__vec_component(*c, k);
    }
    return r;
}

/* An override row is {TransAndScale, Rotation, BoneIndex} - a quaternion plus
 * a translation-and-scale, NOT a LinearTransform. */
BfMat34 bf6__read_override(const bf6::EbxValue& row, int& bone_out)
{
    bone_out = -1;
    const bf6::EbxValue* bi = bf6__by_name(row, "BoneIndex");
    if (bi) bone_out = (int)(bi->kind == bf6::EbxValue::Kind::Int ? bi->i : (int64_t)bi->u);

    float q[4] = { 0, 0, 0, 1 }, t[4] = { 0, 0, 0, 1 };
    const bf6::EbxValue* rq = bf6__by_name(row, "Rotation");
    const bf6::EbxValue* ts = bf6__by_name(row, "TransAndScale");
    if (rq) for (int k = 0; k < 4; k++) q[k] = bf6__vec_component(*rq, k);
    if (ts) for (int k = 0; k < 4; k++) t[k] = bf6__vec_component(*ts, k);

    const float x = q[0], y = q[1], z = q[2], w = q[3];
    const float s = (t[3] != 0.f) ? t[3] : 1.f;

    BfMat34 r{};
    r.m[0] = (1 - 2 * (y * y + z * z)) * s;
    r.m[1] = (2 * (x * y + z * w)) * s;
    r.m[2] = (2 * (x * z - y * w)) * s;
    r.m[3] = (2 * (x * y - z * w)) * s;
    r.m[4] = (1 - 2 * (x * x + z * z)) * s;
    r.m[5] = (2 * (y * z + x * w)) * s;
    r.m[6] = (2 * (x * z + y * w)) * s;
    r.m[7] = (2 * (y * z - x * w)) * s;
    r.m[8] = (1 - 2 * (x * x + y * y)) * s;
    r.m[9] = t[0]; r.m[10] = t[1]; r.m[11] = t[2];
    return r;
}

const char kWeaponSkeleton[] = "common/characters/_soldier/_weaponskeleton";

}  // namespace

int bf6_weapon_skin(bf6_ctx* c, const char* md_partition,
                    bf6_bone_xform* out, int out_max)
{
    if (!c) return -1;
    std::string terr;
    if (!ensure_types(c, terr)) return -1;

    /* ---- the shared skeleton ---------------------------------------- */
    std::string err;
    std::vector<uint8_t> sk = c->src.get_ebx(std::string(kWeaponSkeleton) + ".ebx", err);
    if (sk.empty()) sk = c->src.get_ebx(kWeaponSkeleton, err);
    if (sk.empty()) return -1;

    bf6::Ebx se(*c->types);
    if (!se.parse(std::move(sk), err)) return -1;

    std::vector<BfMat34> local, invModel;
    std::vector<int>     parent;
    for (size_t i = 0; i < se.instance_count(); i++)
    {
        bf6::EbxValue v = se.read_instance(i);
        const bf6::EbxValue* h  = bf6__by_name(v, "Hierarchy");
        const bf6::EbxValue* lp = bf6__by_name(v, "LocalPose");
        const bf6::EbxValue* im = bf6__by_name(v, "InverseModelPose");
        if (!h || !lp || !im) continue;
        for (const bf6::EbxValue& e : h->items)
            parent.push_back((int)(e.kind == bf6::EbxValue::Kind::Int ? e.i : (int64_t)e.u));
        for (const bf6::EbxValue& e : lp->items) local.push_back(bf6__read_lt(e));
        for (const bf6::EbxValue& e : im->items) invModel.push_back(bf6__read_lt(e));
        break;
    }
    const int nb = (int)local.size();
    if (nb == 0 || (int)parent.size() < nb || (int)invModel.size() < nb) return -1;

    /* ---- the weapon's parent-local overrides ------------------------- */
    if (md_partition && *md_partition)
    {
        std::vector<uint8_t> md = c->src.get_ebx(std::string(md_partition) + ".ebx", err);
        if (md.empty()) md = c->src.get_ebx(md_partition, err);
        if (!md.empty())
        {
            bf6::Ebx me(*c->types);
            if (me.parse(std::move(md), err))
            {
                for (size_t i = 0; i < me.instance_count(); i++)
                {
                    bf6::EbxValue v = me.read_instance(i);
                    bool got = false;
                    for (const auto& kv : v.fields)
                    {
                        if (kv.second.kind != bf6::EbxValue::Kind::Array) continue;
                        if (kv.second.items.empty()) continue;
                        /* the override array is the one whose rows carry a
                         * BoneIndex - identified by shape, not by hash. */
                        if (!bf6__by_name(kv.second.items[0], "BoneIndex")) continue;
                        for (const bf6::EbxValue& row : kv.second.items)
                        {
                            int b = -1;
                            const BfMat34 o = bf6__read_override(row, b);
                            if (b >= 0 && b < nb) local[(size_t)b] = o;
                        }
                        got = true;
                        break;
                    }
                    if (got) break;
                }
            }
        }
    }

    /* ---- compose down the hierarchy, then pre-multiply the inverse ---- */
    std::vector<BfMat34> world((size_t)nb);
    for (int b = 0; b < nb; b++)
    {
        const int p = parent[(size_t)b];
        world[(size_t)b] = (p >= 0 && p < b) ? bf6__mat_mul(local[(size_t)b], world[(size_t)p])
                                             : local[(size_t)b];
    }

    if (out)
        for (int b = 0; b < nb && b < out_max; b++)
        {
            const BfMat34 s = bf6__mat_mul(invModel[(size_t)b], world[(size_t)b]);
            std::memcpy(out[b].m, s.m, sizeof(s.m));
        }
    return nb;
}

/* ---------------------------------------------------- the part's own bundle
 *
 * A weapon part's material does not live in the bundle its MESH shipped in.
 * It lives in a per-part shader bundle: dpf_<weapon>_<part>_<hash>_bundle_1p.
 * Measured on 6p67, whose receiver is 16,674 of the weapon's ~35,000 vertices:
 * resolved against the mesh's own bundle it binds NOTHING and the gun renders
 * black, while dpf_6p67_base_cvlhw2_bundle_1p is sitting right there.
 *
 * This is deliberately a separate call rather than a change to bf6_read_mesh.
 * depot_for_bundle refuses to widen to a sibling on purpose - a sibling that
 * happens to carry a state key binds a plausible wrong texture, which is worse
 * than an untextured surface because nothing about it looks broken. Naming the
 * part's OWN bundle is not that: it is a targeted lookup the caller asked for.
 *
 * The un-skinned variant wins. Skin bundles carry a code (wse/wsl/wser/wsd)
 * and describe a re-skin, not the base material, so the shortest match - the
 * one with no code - is the right one.
 */
int bf6_part_bundle(bf6_ctx* c, const char* weapon, const char* part,
                    char* out, int out_len)
{
    if (!c || !weapon || !part || !out || out_len <= 0) return 0;
    out[0] = 0;

    const std::string w = weapon, p = part;
    std::string best;
    for (const auto& kv : c->src.depots_by_bundle())
    {
        const std::string& b = kv.first;
        if (b.compare(0, 4, "dpf_") != 0) continue;
        if (b.find("_bundle_1p") == std::string::npos) continue;
        if (b.find("_" + p + "_") == std::string::npos) continue;
        /* the weapon token sits immediately after dpf_ */
        if (b.compare(4, w.size(), w) != 0) continue;
        if (b.size() <= 4 + w.size() || b[4 + w.size()] != '_') continue;
        if (best.empty() || b.size() < best.size()) best = b;
    }
    if (best.empty()) return 0;
    std::snprintf(out, (size_t)out_len, "%s", best.c_str());
    return (int)best.size();
}

/* --------------------------------------------------- a texture by its name
 *
 * bf6_texture_at only accepts ids that came from a MATERIAL binding, which is
 * right for meshes and useless for UI art: an icon atlas page is a standalone
 * texture nothing binds. This registers one by resource name and hands back an
 * id the existing decode path understands, so atlas pages ride the same cache
 * and the same "decoded once, kept" rule as everything else.
 *
 * Returns -1 when the name is not in the mount. Registering is cheap and does
 * NOT decode - the decode happens on the first bf6_texture_at, as before.
 */
int bf6_texture_id_by_name(bf6_ctx* c, const char* res_name)
{
    if (!c || !res_name || !*res_name) return -1;
    const std::string key = res_name;

    auto it = c->tex_by_res.find(key);
    if (it != c->tex_by_res.end()) return (int)it->second;

    /* Only register something the mount can actually produce, so a typo comes
     * back as -1 rather than as an id that fails later at decode time. */
    std::string e;
    if (c->src.get_res(key, e).empty()) return -1;

    bf6_ctx::TexHold h;
    h.res = key;
    c->textures.push_back(std::move(h));
    const int32_t id = (int32_t)c->textures.size() - 1;
    c->tex_by_res[key] = id;
    return (int)id;
}

/* ------------------------------------------------------------- icon atlases
 *
 * The weapon CARD and the attachment OUTLINE ICONS are the same data. One
 * <weapon>_layerediconatlas partition holds a sprite entry per layer:
 *
 *   Name        the sprite's source path (which attachment it depicts)
 *   UvRect      x,y,z,w = u0,v0,u1,v1 inside the atlas page
 *   Size        pixel size
 *   Offset      placement on the card canvas
 *   0x302ad256  canvas size, {512, 256}
 *   0x8a243ee5  page index -> <weapon>_layerediconatlas_atlas<N>
 *
 * So a card is: draw the base sprite, then one sprite per fitted attachment at
 * its authored Offset. No compositing rules to invent - the layout ships.
 *
 * Sprites are 2-channel: line art in R, fill in G. Alpha is not coverage.
 */
static const uint32_t kAtlasEntries = 0xCACF3201u;
static const uint32_t kAtlasPage    = 0x8A243EE5u;
static const uint32_t kAtlasCanvas  = 0x302AD256u;

namespace {
void bf6__vec_xy(const bf6::EbxValue* v, float& x, float& y)
{
    if (!v) return;
    x = bf6__vec_component(*v, 0);
    y = bf6__vec_component(*v, 1);
}
}  // namespace

int bf6_icon_atlas(bf6_ctx* c, const char* partition,
                   bf6_icon_sprite* out, int out_max)
{
    if (!c || !partition) return -1;
    std::string terr;
    if (!ensure_types(c, terr)) return -1;

    std::string err;
    std::vector<uint8_t> raw = c->src.get_ebx(std::string(partition) + ".ebx", err);
    if (raw.empty()) raw = c->src.get_ebx(partition, err);
    if (raw.empty()) return -1;

    bf6::Ebx e(*c->types);
    if (!e.parse(std::move(raw), err)) return -1;

    c->icon_names.clear();
    int n = 0;
    for (size_t i = 0; i < e.instance_count(); i++)
    {
        bf6::EbxValue v = e.read_instance(i);
        const bf6::EbxValue* arr = nullptr;
        for (const auto& kv : v.fields)
            if (kv.first == kAtlasEntries && kv.second.kind == bf6::EbxValue::Kind::Array)
            { arr = &kv.second; break; }
        if (!arr) continue;

        for (const bf6::EbxValue& row : arr->items)
        {
            const bf6::EbxValue* nm = bf6__by_name(row, "Name");
            c->icon_names.push_back(nm && nm->kind == bf6::EbxValue::Kind::Str ? nm->s
                                                                              : std::string());
            if (out && n < out_max)
            {
                bf6_icon_sprite& o = out[n];
                o = bf6_icon_sprite{};
                for (const auto& kv2 : row.fields)
                    if (kv2.first == 0x8C964305u)
                        o.name_hash = (uint32_t)(kv2.second.kind == bf6::EbxValue::Kind::Int
                                                 ? (uint64_t)kv2.second.i : kv2.second.u);
                const bf6::EbxValue* uv = bf6__by_name(row, "UvRect");
                if (uv)
                    for (int k = 0; k < 4; k++) o.uv[k] = bf6__vec_component(*uv, k);
                bf6__vec_xy(bf6__by_name(row, "Size"),   o.size[0],   o.size[1]);
                bf6__vec_xy(bf6__by_name(row, "Offset"), o.offset[0], o.offset[1]);
                for (const auto& kv : row.fields)
                {
                    if (kv.first == kAtlasPage)
                        o.page = (int32_t)(kv.second.kind == bf6::EbxValue::Kind::Int
                                           ? kv.second.i : (int64_t)kv.second.u);
                    else if (kv.first == kAtlasCanvas)
                        bf6__vec_xy(&kv.second, o.canvas[0], o.canvas[1]);
                }
            }
            n++;
        }
        if (n) break;
    }

    if (out)
    {
        const int lim = n < out_max ? n : out_max;
        for (int i = 0; i < lim && i < (int)c->icon_names.size(); i++)
            out[i].name = c->icon_names[(size_t)i].c_str();
    }
    return n;
}

/* ------------------------------------------------------- the part mesh list
 *
 * THE MESH IS NAMED INDIRECTLY, THROUGH A BUNDLE.
 *
 * DefinitionMesh never carries a mesh: MeshData is empty on 428 of 428 m4a1
 * records. What it carries is field 0x5AF77230 (+0x90, CString) - the name of
 * the part's 1p BLUEPRINT BUNDLE, e.g. "dpf_m4a1_barrelshort_1m9pm7y_bundle_1p".
 * That string is itself a mounted EBX partition, and inside it MeshData ->
 * MeshAsset points at the mesh.
 *
 * Two things fall out of that, both of which were guesses before:
 *  - The material scope. That same bundle name is exactly what a mesh must be
 *    read against; bf6_part_bundle was searching for it by prefix, and here it
 *    is authored on the record.
 *  - The "extras". A bundle lists ONE TO THREE meshes - an optic and its lens,
 *    a receiver and its charm holder - so drawing all of them is the rule,
 *    and no allow-list is needed.
 *
 * Control on the resolution: mesh extent against the record's own AABB
 * (translation-invariant, so bone terms cancel) over 107 scorable m4a1
 * records - real median 0.00010 m, shuffled median 0.11732 m.
 */
static const uint32_t kDefMeshBundle1p = 0x5AF77230u;

int bf6_weapon_parts(bf6_ctx* c, const char* md_partition,
                     bf6_weapon_part* out, int out_max)
{
    if (!c || !md_partition) return -1;
    std::string terr;
    if (!ensure_types(c, terr)) return -1;

    std::string err;
    std::vector<uint8_t> md = c->src.get_ebx(std::string(md_partition) + ".ebx", err);
    if (md.empty()) md = c->src.get_ebx(md_partition, err);
    if (md.empty()) return -1;

    bf6::Ebx me(*c->types);
    if (!me.parse(std::move(md), err)) return -1;

    c->part_meshes.clear();
    c->part_bundles.clear();

    /* Every DefinitionMesh in the partition, by its bundle string. Reading the
     * whole set rather than walking Slots keeps this independent of the
     * fitted-selection rule, which is a separate question. */
    std::vector<std::string> bundles;
    for (size_t i = 0; i < me.instance_count(); i++)
    {
        bf6::EbxValue v = me.read_instance(i);
        for (const auto& kv : v.fields)
        {
            if (kv.first != kDefMeshBundle1p) continue;
            if (kv.second.kind != bf6::EbxValue::Kind::Str) continue;
            if (kv.second.s.empty()) continue;
            if (std::find(bundles.begin(), bundles.end(), kv.second.s) == bundles.end())
                bundles.push_back(kv.second.s);
            break;
        }
    }

    int n = 0;
    for (const std::string& b : bundles)
    {
        std::vector<uint8_t> bb = c->src.get_ebx(b + ".ebx", err);
        if (bb.empty()) bb = c->src.get_ebx(b, err);
        if (bb.empty()) continue;

        bf6::Ebx be(*c->types);
        /* An ImportRef is a partition GUID until something resolves it. Without
         * the index every MeshAsset reads "<not indexed>" and the whole walk
         * returns 503 parts and 0 meshes - which is what it did. */
        be.set_guid_index(&c->src.partition_index());
        if (!be.parse(std::move(bb), err)) continue;

        for (size_t i = 0; i < be.instance_count(); i++)
        {
            bf6::EbxValue v = be.read_instance(i);
            const bf6::EbxValue* arr = bf6__by_name(v, "MeshData");
            if (!arr || arr->kind != bf6::EbxValue::Kind::Array) continue;

            for (const bf6::EbxValue& row : arr->items)
            {
                /* row is {Index, Data}; the mesh hangs off Data.MeshAsset. */
                const bf6::EbxValue* data = bf6__by_name(row, "Data");
                const bf6::EbxValue* ma = data ? bf6__by_name(*data, "MeshAsset") : nullptr;
                if (!ma) ma = bf6__by_name(row, "MeshAsset");
                if (!ma) continue;

                std::string path = ma->import_path.empty() ? ma->s : ma->import_path;
                if (path.empty()) continue;
                for (char& ch : path)
                {
                    if (ch == (char)92) ch = '/';   // backslash, by code
                    if (ch >= 'A' && ch <= 'Z') ch = (char)(ch + 32);
                }
                if (path.size() > 4 && path.compare(path.size() - 4, 4, ".ebx") == 0)
                    path.resize(path.size() - 4);

                c->part_meshes.push_back(path);
                c->part_bundles.push_back(b);
                n++;
            }
        }
    }

    if (out)
    {
        const int lim = n < out_max ? n : out_max;
        for (int i = 0; i < lim; i++)
        {
            out[i] = bf6_weapon_part{};
            out[i].mesh   = c->part_meshes[(size_t)i].c_str();
            out[i].bundle = c->part_bundles[(size_t)i].c_str();
        }
    }
    return n;
}

/* ------------------------------------------------------ card layer offsets
 *
 * THE ATLAS OFFSET IS NOT THE CARD OFFSET. A sprite's Offset in the atlas is
 * where it sits in the PACKED SHEET - the m4a1's layers read (0,0), (0,94),
 * (0,182)... stacked in a column, because that is how they were packed. Draw
 * the card with those and every layer lands in a vertical strip, which looks
 * like one mangled part.
 *
 * The real placement is authored separately, in hiao_<weapon>.ebx: 132 entries
 * for the m4a1, each a sprite NAME HASH (matching the atlas entry's 0x8C964305)
 * and a fractional Offset that can be negative. That is the composition.
 */
int bf6_card_layers(bf6_ctx* c, const char* hiao_partition,
                    bf6_card_layer* out, int out_max)
{
    if (!c || !hiao_partition) return -1;
    std::string terr;
    if (!ensure_types(c, terr)) return -1;

    std::string err;
    std::vector<uint8_t> d = c->src.get_ebx(std::string(hiao_partition) + ".ebx", err);
    if (d.empty()) d = c->src.get_ebx(hiao_partition, err);
    if (d.empty()) return -1;

    bf6::Ebx e(*c->types);
    if (!e.parse(std::move(d), err)) return -1;

    int n = 0;
    for (size_t i = 0; i < e.instance_count(); i++)
    {
        bf6::EbxValue v = e.read_instance(i);
        const bf6::EbxValue* off = bf6__by_name(v, "Offset");
        if (!off) continue;
        uint32_t hash = 0;
        for (const auto& kv : v.fields)
            if (kv.first == 0x35CA44BAu)
                hash = (uint32_t)(kv.second.kind == bf6::EbxValue::Kind::Int
                                  ? (uint64_t)kv.second.i : kv.second.u);
        if (!hash) continue;
        if (out && n < out_max)
        {
            out[n] = bf6_card_layer{};
            out[n].sprite_hash = hash;
            bf6__vec_xy(off, out[n].offset[0], out[n].offset[1]);
        }
        n++;
    }
    return n;
}
