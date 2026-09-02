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
 * Field hashes are part of the install read path. Their names were recovered
 * once from the guarded dictionary and are recorded here for readability;
 * the runtime never consumes that exported dictionary.
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

static const uint32_t kBoneHierarchy        = 0xBC1B3E30u;
static const uint32_t kBoneLocalPose        = 0x0B50D1D9u;
static const uint32_t kBoneInverseModelPose = 0xBA751AE2u;
static const uint32_t kBoneIndex            = 0xB1C23DA7u;
static const uint32_t kBoneRight            = 0xC478CC3Bu;
static const uint32_t kBoneUp               = 0xBF151EF9u;
static const uint32_t kBoneForward          = 0x695D12A4u;
static const uint32_t kBoneTrans            = 0xBC4B07B4u;
static const uint32_t kBoneRotation         = 0x0471C1B9u;
static const uint32_t kBoneTransAndScale    = 0x3DFBD5F9u;

/* Field hashes are the shipped read path. Their recovered names are comments,
 * not runtime inputs; the guarded research dictionary is an oracle only. */
static const uint32_t kFieldName      = 0x0C59FA06u;
static const uint32_t kFieldUvRect    = 0xE7472135u;
static const uint32_t kFieldSize      = 0xC998527Du;
static const uint32_t kFieldOffset    = 0x4FF541E4u;
static const uint32_t kFieldMeshData  = 0x5DAC6980u;
static const uint32_t kFieldDataA     = 0x50F33881u;
static const uint32_t kFieldDataB     = 0x9588283Cu;
static const uint32_t kFieldMeshAsset = 0x1B4A547Cu;

const bf6::EbxValue* bf6__by_hash(const bf6::EbxValue& v,
                                  uint32_t primary, uint32_t alternate = 0)
{
    const bf6::EbxValue* out = v.field(primary);
    return !out && alternate ? v.field(alternate) : out;
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
    static const uint32_t kRows[4] = { kBoneRight, kBoneUp, kBoneForward, kBoneTrans };
    for (int row = 0; row < 4; row++)
    {
        const bf6::EbxValue* c = v.field(kRows[row]);
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
    const bf6::EbxValue* bi = row.field(kBoneIndex);
    if (bi) bone_out = (int)(bi->kind == bf6::EbxValue::Kind::Int ? bi->i : (int64_t)bi->u);

    float q[4] = { 0, 0, 0, 1 }, t[4] = { 0, 0, 0, 1 };
    const bf6::EbxValue* rq = row.field(kBoneRotation);
    const bf6::EbxValue* ts = row.field(kBoneTransAndScale);
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

bool bf6__weapon_pose(bf6_ctx* c, const char* md_partition,
                      std::vector<std::string>& names,
                      std::vector<BfMat34>& world,
                      std::vector<BfMat34>* inverse_model)
{
    std::string terr;
    if (!c || !ensure_types(c, terr)) return false;

    std::string err;
    std::vector<uint8_t> sk = c->src.get_ebx(std::string(kWeaponSkeleton) + ".ebx", err);
    if (sk.empty()) sk = c->src.get_ebx(kWeaponSkeleton, err);
    if (sk.empty()) return false;
    bf6::Ebx se(*c->types);
    if (!se.parse(std::move(sk), err)) return false;

    static const uint32_t kBoneNames = 0x059E9A54u;
    std::vector<BfMat34> local, inv;
    std::vector<int> parent;
    for (size_t i = 0; i < se.instance_count(); ++i)
    {
        const bf6::EbxValue v = se.read_instance(i);
        const bf6::EbxValue* h = v.field(kBoneHierarchy);
        const bf6::EbxValue* lp = v.field(kBoneLocalPose);
        const bf6::EbxValue* im = v.field(kBoneInverseModelPose);
        const bf6::EbxValue* nm = v.field(kBoneNames);
        if (!h || !lp || !im || !nm || nm->kind != bf6::EbxValue::Kind::Array)
            continue;
        for (const bf6::EbxValue& e : h->items)
            parent.push_back((int)(e.kind == bf6::EbxValue::Kind::Int ? e.i : (int64_t)e.u));
        for (const bf6::EbxValue& e : lp->items) local.push_back(bf6__read_lt(e));
        for (const bf6::EbxValue& e : im->items) inv.push_back(bf6__read_lt(e));
        for (const bf6::EbxValue& e : nm->items)
            names.push_back(e.kind == bf6::EbxValue::Kind::Str ? e.s : std::string());
        break;
    }
    const int nb = (int)local.size();
    if (nb == 0 || (int)parent.size() < nb || (int)inv.size() < nb ||
        (int)names.size() < nb) return false;

    if (md_partition && *md_partition)
    {
        std::vector<uint8_t> md = c->src.get_ebx(std::string(md_partition) + ".ebx", err);
        if (md.empty()) md = c->src.get_ebx(md_partition, err);
        if (!md.empty())
        {
            bf6::Ebx me(*c->types);
            if (me.parse(std::move(md), err))
                for (size_t i = 0; i < me.instance_count(); ++i)
                {
                    const bf6::EbxValue v = me.read_instance(i);
                    bool got = false;
                    for (const auto& kv : v.fields)
                    {
                        if (kv.second.kind != bf6::EbxValue::Kind::Array ||
                            kv.second.items.empty() ||
                            !kv.second.items[0].field(kBoneIndex)) continue;
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

    world.resize((size_t)nb);
    for (int b = 0; b < nb; ++b)
    {
        const int p = parent[(size_t)b];
        world[(size_t)b] = (p >= 0 && p < b)
            ? bf6__mat_mul(local[(size_t)b], world[(size_t)p]) : local[(size_t)b];
    }
    if (inverse_model) *inverse_model = std::move(inv);
    return true;
}

}  // namespace

int bf6_weapon_skin(bf6_ctx* c, const char* md_partition,
                    bf6_bone_xform* out, int out_max)
{
    std::vector<std::string> names;
    std::vector<BfMat34> world, invModel;
    if (!bf6__weapon_pose(c, md_partition, names, world, &invModel)) return -1;
    const int nb = (int)world.size();

    if (out)
        for (int b = 0; b < nb && b < out_max; b++)
        {
            const BfMat34 s = bf6__mat_mul(invModel[(size_t)b], world[(size_t)b]);
            std::memcpy(out[b].m, s.m, sizeof(s.m));
        }
    return nb;
}

int bf6_weapon_bone_transform(bf6_ctx* c, const char* md_partition,
                              const char* bone_name, bf6_bone_xform* out)
{
    if (!c || !bone_name || !*bone_name || !out) return 0;
    std::vector<std::string> names;
    std::vector<BfMat34> world;
    if (!bf6__weapon_pose(c, md_partition, names, world, nullptr)) return 0;
    for (size_t i = 0; i < names.size() && i < world.size(); ++i)
        if (names[i] == bone_name)
        {
            std::memcpy(out->m, world[i].m, sizeof(out->m));
            return 1;
        }
    *out = bf6_bone_xform{};
    return 0;
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
static const uint32_t kAtlasPlace   = 0xFC4B205Fu;

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
            const bf6::EbxValue* nm = bf6__by_hash(row, kFieldName);
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
                const bf6::EbxValue* uv = bf6__by_hash(row, kFieldUvRect);
                if (uv)
                    for (int k = 0; k < 4; k++) o.uv[k] = bf6__vec_component(*uv, k);
                bf6__vec_xy(bf6__by_hash(row, kFieldSize),   o.size[0],   o.size[1]);
                bf6__vec_xy(bf6__by_hash(row, kFieldOffset), o.offset[0], o.offset[1]);
                for (const auto& kv : row.fields)
                {
                    if (kv.first == kAtlasPage)
                        o.page = (int32_t)(kv.second.kind == bf6::EbxValue::Kind::Int
                                           ? kv.second.i : (int64_t)kv.second.u);
                    else if (kv.first == kAtlasCanvas)
                        bf6__vec_xy(&kv.second, o.canvas[0], o.canvas[1]);
                    else if (kv.first == kAtlasPlace)
                        bf6__vec_xy(&kv.second, o.placement[0], o.placement[1]);
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
static const uint32_t kMeshDefSlots     = 4265094687u;
static const uint32_t kMeshSlotMeshes   = 3280051868u;
static const uint32_t kMeshSlotDefault  = 2548700451u;
static const uint32_t kMeshSlotType     = 1693403371u;
static const uint32_t kMeshSlotSocket   = 3778210562u;
static const uint32_t kRecordUnlock     = 1887819232u;
static const uint32_t kRecordBindings   = 546520075u;
static const uint32_t kRecordTags       = 252274761u;
static const uint32_t kBindingTransform = 3824396538u;
static const uint32_t kBindingBone      = 4117705232u;
static const uint32_t kSocketTransform  = 1341473252u;

struct BfPartChoice {
    std::string bundle;
    float offset[3] = { 0.f, 0.f, 0.f };
    bool has_offset = false;
};

static std::string bf6__alnum_lower(const std::string& s)
{
    std::string o;
    for (unsigned char c : s)
        if (c >= 'a' && c <= 'z') o.push_back((char)c);
        else if (c >= 'A' && c <= 'Z') o.push_back((char)(c + 32));
        else if (c >= '0' && c <= '9') o.push_back((char)c);
    return o;
}

static bool bf6__slot_group_matches(const std::string& code, const std::string& path)
{
    const std::string p = bf6__alnum_lower(path);
    if (code == "scp") return p.find("sight") != std::string::npos &&
                              p.find("secondarysight") == std::string::npos;
    if (code == "sca") return p.find("secondarysight") != std::string::npos ||
                              p.find("offsetreflextrigger") != std::string::npos;
    if (code == "mzl") return p.find("muzzle") != std::string::npos;
    if (code == "brl") return p.find("barrel") != std::string::npos;
    if (code == "mag") return p.find("magazine") != std::string::npos;
    if (code == "amo") return p.find("ammo") != std::string::npos;
    if (code == "btm") return p.find("bottomrailattachment") != std::string::npos;
    if (code == "top") return p.find("toprailattachment") != std::string::npos;
    if (code == "rgt") return p.find("rightrailattachment") != std::string::npos;
    if (code == "lft") return p.find("leftrailattachment") != std::string::npos;
    if (code == "erg") return p.find("ergonomic") != std::string::npos ||
                              p.find("railcover") != std::string::npos ||
                              p.find("trigger") != std::string::npos;
    return false;
}

static bool bf6__optional_group(const std::string& path)
{
    const std::string p = bf6__alnum_lower(path);
    if (p.find("secondarysight") != std::string::npos ||
        p.find("offsetreflextrigger") != std::string::npos) return true;
    if (p.find("ironsight") == std::string::npos && p.find("sight") != std::string::npos)
        return true;
    return p.find("muzzle") != std::string::npos ||
           p.find("bottomrailattachment") != std::string::npos ||
           p.find("toprailattachment") != std::string::npos ||
           p.find("rightrailattachment") != std::string::npos ||
           p.find("leftrailattachment") != std::string::npos ||
           p.find("ergonomic") != std::string::npos;
}

static int bf6__fit_score(const std::string& token, const std::string& bundle,
                          const std::string& unlock)
{
    std::string t = bf6__alnum_lower(token);
    // Audited from the older previewer's verified design-name -> art-name
    // join. These are genuine renamed identities, not fuzzy guesses. Keeping
    // the tiny mapping beside the live graph walk lets new ordinary names
    // continue to resolve directly, while an unknown token still scores zero.
    static const std::pair<const char*, const char*> aliases[] = {
        { "uglmount", "m320base" }, { "kacverticalgrip", "kabroomstick" },
        { "zenitcork1", "rk1" }, { "trijiconrco", "trijiconm150" },
        { "cantedreflex", "cantedreddot" }, { "eflxmini", "eotechelfx" },
        { "g43magnifier", "eotechg43" }, { "trijiconmro", "mro" },
        { "regular", "magazine" }, { "fast", "magmapull" },
        { "lt706qdharrisbipod", "lt706harris" }
    };
    for (const auto& a : aliases) if (t == a.first) { t = a.second; break; }
    if (t.size() < 3) return 0;
    const std::string b = bf6__alnum_lower(bundle);
    const std::string u = bf6__alnum_lower(unlock);
    // Deliberately no fuzzy nearest-neighbour fallback. A fake id is the
    // negative control: it must score zero and retain the authored default.
    if (b.find(t) != std::string::npos) return 2000 - (int)(b.size() - t.size());
    if (u.find(t) != std::string::npos) return 1800 - (int)(u.size() - t.size());

    // Some design ids concatenate the same exact identity components in a
    // different order than the art unlock. For example the shipped M4 factory
    // package asks for `m4qdflashhider`, while its authored unlock is
    // `u_att_flashhider_kacm4qd`. This is not a fuzzy/name-distance join: every
    // character of the requested id must be covered by non-overlapping exact
    // substrings of at least four characters. The competing M4QD MAMS record
    // therefore cannot match because it does not contain `flashhider`.
    auto component_score = [&t](const std::string& source) -> int {
        std::string remain = t;
        std::string hay = source;
        int components = 0;
        while (!remain.empty())
        {
            size_t best_r = std::string::npos, best_h = std::string::npos;
            size_t best_n = 0;
            for (size_t r = 0; r < remain.size(); ++r)
                for (size_t h = 0; h < hay.size(); ++h)
                {
                    size_t n = 0;
                    while (r + n < remain.size() && h + n < hay.size() &&
                           remain[r + n] == hay[h + n]) ++n;
                    if (n > best_n) { best_r = r; best_h = h; best_n = n; }
                }
            if (best_n < 4) return 0;
            remain.erase(best_r, best_n);
            hay.erase(best_h, best_n);
            ++components;
        }
        return 1600 - (int)(source.size() - t.size()) - components;
    };
    const int bundle_components = component_score(b);
    const int unlock_components = component_score(u);
    return bundle_components > unlock_components ? bundle_components : unlock_components;
}

static int bf6__nested_tag_count(const bf6::EbxValue& v)
{
    if (v.kind == bf6::EbxValue::Kind::Array)
    {
        int n = 0;
        for (const bf6::EbxValue& e : v.items)
            n += (e.kind == bf6::EbxValue::Kind::Struct ||
                  e.kind == bf6::EbxValue::Kind::Array) ? bf6__nested_tag_count(e) : 1;
        return n;
    }
    if (v.kind == bf6::EbxValue::Kind::Struct)
    {
        int n = 0;
        for (const auto& f : v.fields) n += bf6__nested_tag_count(f.second);
        return n;
    }
    return 0;
}

// MeshSlot.Default is the FACTORY-PACKAGE presentation, not the bare stock
// weapon. On M4A1 that default is a front-folded iron sight because the game's
// factory package carries an optic. For a no-optional-attachments card/model,
// choose the authored untagged, non-folded iron record instead. Once a real
// optic resolves, choose a folded rendition; a canted sight prefers the
// dedicated front-folded rendition. Name terms only break ties after the
// visibility-tag population, so this is not a free-form fuzzy join.
static int bf6__iron_choice(bf6::Ebx& e, const bf6::EbxValue& meshes,
                            bool primary_optic, bool canted_optic, int fallback)
{
    int best = fallback;
    long long best_score = LLONG_MIN;
    for (int mi = 0; mi < (int)meshes.items.size(); mi++)
    {
        const bf6::EbxValue& ref = meshes.items[(size_t)mi];
        if (ref.kind != bf6::EbxValue::Kind::InstanceRef || ref.instance < 0 ||
            ref.instance >= (int)e.instance_count()) continue;
        const bf6::EbxValue part = e.read_instance((size_t)ref.instance);
        const bf6::EbxValue* bv = part.field(kDefMeshBundle1p);
        std::string pg, unlock;
        e.import_ref((size_t)ref.instance, kRecordUnlock, pg, unlock);
        const std::string name = bf6__alnum_lower(
            (bv && bv->kind == bf6::EbxValue::Kind::Str ? bv->s : std::string()) + unlock);
        if (name.find("ironsight") == std::string::npos &&
            name.find("irons") == std::string::npos) continue;
        const bool folded = name.find("folded") != std::string::npos;
        const bool front_folded = name.find("frontfolded") != std::string::npos;
        const bool skinned = name.find("wse") != std::string::npos ||
                             name.find("wsl") != std::string::npos ||
                             name.find("wsd") != std::string::npos ||
                             name.find("wser") != std::string::npos;
        const bf6::EbxValue* tags = part.field(kRecordTags);
        const int tag_count = tags ? bf6__nested_tag_count(*tags) : 0;
        long long score = skinned ? -100000 : 0;
        if (!primary_optic && !canted_optic)
        {
            score += folded ? -1000000 : 1000000;
            score -= (long long)tag_count * 1000;
        }
        else
        {
            score += folded ? 1000000 : -1000000;
            if (canted_optic) score += front_folded ? 100000 : 0;
            score += (long long)tag_count * 10;
        }
        score -= (long long)name.size();
        if (score > best_score) { best_score = score; best = mi; }
    }
    return best;
}

static BfPartChoice bf6__part_choice(const bf6::Ebx& e, int part_index,
                                     const bf6::EbxValue& part,
                                     const std::string& bundle,
                                     const float group_offset[3])
{
    BfPartChoice out; out.bundle = bundle;
    const bf6::EbxValue* bindings = part.field(kRecordBindings);
    if (!bindings || bindings->kind != bf6::EbxValue::Kind::Array ||
        bindings->items.empty()) return out;
    const bf6::EbxValue& binding = bindings->items[0];
    const bf6::EbxValue* bone = binding.field(kBindingBone);
    if (!bone || bone->kind != bf6::EbxValue::Kind::ImportRef) return out;
    const bf6::EbxValue* lt = binding.field(kBindingTransform);
    if (!lt) return out;
    const BfMat34 m = bf6__read_lt(*lt);
    for (int k = 0; k < 3; k++) out.offset[k] = m.m[9 + k] + group_offset[k];
    out.has_offset = true;
    (void)e; (void)part_index;
    return out;
}

static int bf6__part_bundles_to_meshes(bf6_ctx* c,
                                        const std::vector<BfPartChoice>& choices,
                                        bf6_weapon_part* out, int out_max)
{
    std::string err;
    int n = 0;
    for (const BfPartChoice& choice : choices)
    {
        const std::string& b = choice.bundle;
        std::vector<uint8_t> bb = c->src.get_ebx(b + ".ebx", err);
        if (bb.empty()) bb = c->src.get_ebx(b, err);
        if (bb.empty()) continue;

        bf6::Ebx be(*c->types);
        be.set_guid_index(&c->src.armory_partition_index());
        if (!be.parse(std::move(bb), err)) continue;
        for (size_t i = 0; i < be.instance_count(); i++)
        {
            bf6::EbxValue v = be.read_instance(i);
            const bf6::EbxValue* arr = bf6__by_hash(v, kFieldMeshData);
            if (!arr || arr->kind != bf6::EbxValue::Kind::Array) continue;
            for (const bf6::EbxValue& row : arr->items)
            {
                const bf6::EbxValue* data = bf6__by_hash(row, kFieldDataA, kFieldDataB);
                const bf6::EbxValue* ma = data ? bf6__by_hash(*data, kFieldMeshAsset) : nullptr;
                if (!ma) ma = bf6__by_hash(row, kFieldMeshAsset);
                if (!ma) continue;
                std::string path = ma->import_path.empty() ? ma->s : ma->import_path;
                if (path.empty()) continue;
                for (char& ch : path)
                {
                    if (ch == (char)92) ch = '/';
                    if (ch >= 'A' && ch <= 'Z') ch = (char)(ch + 32);
                }
                if (path.size() > 4 && path.compare(path.size() - 4, 4, ".ebx") == 0)
                    path.resize(path.size() - 4);
                c->part_meshes.push_back(path);
                c->part_bundles.push_back(b);
                for (int k = 0; k < 3; k++) c->part_attach_offsets.push_back(choice.offset[k]);
                c->part_has_attach_offset.push_back(choice.has_offset ? 1 : 0);
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
            out[i].mesh = c->part_meshes[(size_t)i].c_str();
            out[i].bundle = c->part_bundles[(size_t)i].c_str();
            for (int k = 0; k < 3; k++)
                out[i].attach_offset[k] = c->part_attach_offsets[(size_t)i * 3 + (size_t)k];
            out[i].has_attach_offset = c->part_has_attach_offset[(size_t)i];
        }
    }
    return n;
}

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
    c->part_attach_offsets.clear();
    c->part_has_attach_offset.clear();

    /* Every DefinitionMesh in the partition, by its bundle string. Reading the
     * whole set rather than walking Slots keeps this independent of the
     * fitted-selection rule, which is a separate question. */
    std::vector<BfPartChoice> bundles;
    for (size_t i = 0; i < me.instance_count(); i++)
    {
        bf6::EbxValue v = me.read_instance(i);
        for (const auto& kv : v.fields)
        {
            if (kv.first != kDefMeshBundle1p) continue;
            if (kv.second.kind != bf6::EbxValue::Kind::Str) continue;
            if (kv.second.s.empty()) continue;
            bool duplicate = false;
            for (const BfPartChoice& b : bundles) if (b.bundle == kv.second.s) { duplicate = true; break; }
            if (!duplicate) { BfPartChoice b; b.bundle = kv.second.s; bundles.push_back(b); }
            break;
        }
    }

    return bf6__part_bundles_to_meshes(c, bundles, out, out_max);
}

static int bf6__weapon_configured_parts(bf6_ctx* c, const char* md_partition,
                                        const bf6_weapon_fit* fits, int fit_count,
                                        bool suppress_optional_defaults,
                                        bf6_weapon_part* out, int out_max)
{
    if (!c || !md_partition) return -1;
    std::string terr;
    if (!ensure_types(c, terr)) return -1;
    std::string err;
    std::vector<uint8_t> raw = c->src.get_ebx(std::string(md_partition) + ".ebx", err);
    if (raw.empty()) raw = c->src.get_ebx(md_partition, err);
    if (raw.empty()) return -1;
    bf6::Ebx e(*c->types);
    e.set_guid_index(&c->src.armory_partition_index());
    if (!e.parse(std::move(raw), err) || e.instance_count() == 0) return -1;

    std::vector<BfPartChoice> bundles;
    const bf6::EbxValue root = e.read_instance(0);
    const bf6::EbxValue* slots = root.field(kMeshDefSlots);
    if (!slots || slots->kind != bf6::EbxValue::Kind::Array) return -1;

    // Resolve requested slot codes up front. Visibility decisions must depend
    // on a real authored match, never merely on the presence of an input
    // string: the fake-id control must not fold or remove anything.
    std::set<std::string> resolved_fit_codes;
    for (int fi = 0; fi < fit_count; fi++)
    {
        if (!fits || !fits[fi].slot || !fits[fi].attachment || !*fits[fi].attachment) continue;
        for (const bf6::EbxValue& sr : slots->items)
        {
            if (sr.kind != bf6::EbxValue::Kind::InstanceRef || sr.instance < 0 ||
                sr.instance >= (int)e.instance_count()) continue;
            const bf6::EbxValue slot = e.read_instance((size_t)sr.instance);
            const bf6::EbxValue* st = slot.field(kMeshSlotType);
            const bf6::EbxValue* meshes = slot.field(kMeshSlotMeshes);
            const std::string group = st && st->kind == bf6::EbxValue::Kind::ImportRef ?
                                      st->import_path : std::string();
            if (!meshes || meshes->kind != bf6::EbxValue::Kind::Array ||
                !bf6__slot_group_matches(fits[fi].slot, group)) continue;
            for (const bf6::EbxValue& cr : meshes->items)
            {
                if (cr.kind != bf6::EbxValue::Kind::InstanceRef || cr.instance < 0 ||
                    cr.instance >= (int)e.instance_count()) continue;
                const bf6::EbxValue cand = e.read_instance((size_t)cr.instance);
                const bf6::EbxValue* cb = cand.field(kDefMeshBundle1p);
                std::string pg, unlock;
                e.import_ref((size_t)cr.instance, kRecordUnlock, pg, unlock);
                if (bf6__fit_score(fits[fi].attachment,
                    cb && cb->kind == bf6::EbxValue::Kind::Str ? cb->s : std::string(),
                    unlock) > 0)
                { resolved_fit_codes.insert(fits[fi].slot); break; }
            }
        }
    }
    for (const bf6::EbxValue& sr : slots->items)
    {
        if (sr.kind != bf6::EbxValue::Kind::InstanceRef || sr.instance < 0 ||
            sr.instance >= (int)e.instance_count()) continue;
        const bf6::EbxValue slot = e.read_instance((size_t)sr.instance);
        const bf6::EbxValue* meshes = slot.field(kMeshSlotMeshes);
        const bf6::EbxValue* def = slot.field(kMeshSlotDefault);
        if (!meshes || meshes->kind != bf6::EbxValue::Kind::Array || meshes->items.empty()) continue;
        int index = 0;
        if (def)
        {
            if (def->kind == bf6::EbxValue::Kind::Int) index = (int)def->i;
            else if (def->kind == bf6::EbxValue::Kind::Uint) index = (int)def->u;
        }
        if (index < 0 || index >= (int)meshes->items.size()) continue;
        std::string group_path;
        const bf6::EbxValue* st = slot.field(kMeshSlotType);
        if (st && st->kind == bf6::EbxValue::Kind::ImportRef) group_path = st->import_path;

        const std::string group_norm = bf6__alnum_lower(group_path);
        if (suppress_optional_defaults && group_norm.find("ironsight") != std::string::npos)
            index = bf6__iron_choice(e, *meshes,
                resolved_fit_codes.find("scp") != resolved_fit_codes.end(),
                resolved_fit_codes.find("sca") != resolved_fit_codes.end(), index);

        // Resolve only inside the selected slot's authored group. Unknown ids
        // are intentionally a no-op; selecting the nearest-looking record is
        // how a convincing wrong laser gets mounted to the wrong rail.
        int best_score = 0, best_index = index;
        for (int fi = 0; fi < fit_count; fi++)
        {
            if (!fits || !fits[fi].slot || !fits[fi].attachment || !*fits[fi].attachment) continue;
            if (!bf6__slot_group_matches(fits[fi].slot, group_path)) continue;
            for (int mi = 0; mi < (int)meshes->items.size(); mi++)
            {
                const bf6::EbxValue& cand_ref = meshes->items[(size_t)mi];
                if (cand_ref.kind != bf6::EbxValue::Kind::InstanceRef || cand_ref.instance < 0 ||
                    cand_ref.instance >= (int)e.instance_count()) continue;
                const bf6::EbxValue cand = e.read_instance((size_t)cand_ref.instance);
                const bf6::EbxValue* cb = cand.field(kDefMeshBundle1p);
                std::string unlock;
                std::string pg;
                e.import_ref((size_t)cand_ref.instance, kRecordUnlock, pg, unlock);
                const int score = bf6__fit_score(fits[fi].attachment,
                    cb && cb->kind == bf6::EbxValue::Kind::Str ? cb->s : std::string(), unlock);
                if (score > best_score) { best_score = score; best_index = mi; }
            }
        }

        // Zero optional attachments is a real presentation, distinct from the
        // game's factory package. Structural groups (base, barrel, magazine,
        // iron sights and rail covers) retain their authored defaults.
        if (suppress_optional_defaults && best_score == 0 && bf6__optional_group(group_path))
            continue;

        const bf6::EbxValue& mr = meshes->items[(size_t)best_index];
        if (mr.kind != bf6::EbxValue::Kind::InstanceRef || mr.instance < 0 ||
            mr.instance >= (int)e.instance_count()) continue;
        const bf6::EbxValue part = e.read_instance((size_t)mr.instance);
        const bf6::EbxValue* bv = part.field(kDefMeshBundle1p);
        if (!bv || bv->kind != bf6::EbxValue::Kind::Str || bv->s.empty()) continue;

        float group_offset[3] = { 0.f, 0.f, 0.f };
        const bf6::EbxValue* socket_ref = slot.field(kMeshSlotSocket);
        if (socket_ref && socket_ref->kind == bf6::EbxValue::Kind::InstanceRef &&
            socket_ref->instance >= 0 && socket_ref->instance < (int)e.instance_count())
        {
            const bf6::EbxValue socket = e.read_instance((size_t)socket_ref->instance);
            const bf6::EbxValue* slt = socket.field(kSocketTransform);
            if (slt)
            {
                const BfMat34 sm = bf6__read_lt(*slt);
                for (int k = 0; k < 3; k++) group_offset[k] = sm.m[9 + k];
            }
        }
        bool duplicate = false;
        for (const BfPartChoice& b : bundles) if (b.bundle == bv->s) { duplicate = true; break; }
        if (!duplicate)
            bundles.push_back(bf6__part_choice(e, mr.instance, part, bv->s, group_offset));
    }

    c->part_meshes.clear();
    c->part_bundles.clear();
    c->part_attach_offsets.clear();
    c->part_has_attach_offset.clear();
    return bf6__part_bundles_to_meshes(c, bundles, out, out_max);
}

int bf6_weapon_default_parts(bf6_ctx* c, const char* md_partition,
                             bf6_weapon_part* out, int out_max)
{
    return bf6__weapon_configured_parts(c, md_partition, nullptr, 0, false, out, out_max);
}

int bf6_weapon_factory_fits(bf6_ctx* c, const char* equipment_partition,
                            bf6_weapon_fit* out, int out_max)
{
    if (!c || !equipment_partition || out_max < 0) return -1;
    std::string terr;
    if (!ensure_types(c, terr)) return -1;

    std::string err;
    std::vector<uint8_t> raw = c->src.get_ebx(std::string(equipment_partition) + ".ebx", err);
    if (raw.empty()) raw = c->src.get_ebx(equipment_partition, err);
    if (raw.empty()) return 0;

    bf6::Ebx e(*c->types);
    e.set_guid_index(&c->src.armory_partition_index());
    if (!e.parse(std::move(raw), err) || e.instance_count() == 0) return -1;

    static const uint32_t kEquipmentGrants = 0x844F8184u; // field 2219803012
    static const uint32_t kGrantorUnlock   = 0xF86E0433u; // field 4167959603
    static const uint32_t kGrantedItem     = 0xD28DFB00u; // field 3532520192
    static const uint32_t kFactoryItems    = 0x3538F6ADu;

    auto stem = [](std::string path) {
        const size_t slash = path.find_last_of("/\\");
        if (slash != std::string::npos) path.erase(0, slash + 1);
        const size_t dot = path.find_last_of('.');
        if (dot != std::string::npos) path.erase(dot);
        for (char& ch : path) if (ch >= 'A' && ch <= 'Z') ch = (char)(ch + 32);
        return path;
    };

    const std::string eq = stem(equipment_partition);
    static const std::string kEqPrefix = "equipment_";
    if (eq.compare(0, kEqPrefix.size(), kEqPrefix) != 0) return 0;
    const std::string weapon = eq.substr(kEqPrefix.size());
    const std::string itemPrefix = "attachment_" + weapon + "_";

    c->factory_fit_slots.clear();
    c->factory_fit_tokens.clear();
    c->factory_fit_rows.clear();

    const bf6::EbxValue root = e.read_instance(0);
    std::vector<std::pair<std::string, std::string>> found;
    auto add_item = [&](const bf6::EbxValue& item)
    {
        if (item.kind != bf6::EbxValue::Kind::ImportRef) return;
        const std::string granted = stem(item.import_path);
        if (granted.compare(0, itemPrefix.size(), itemPrefix) != 0) return;
        const std::string tail = granted.substr(itemPrefix.size());
        if (tail.size() <= 4 || tail[3] != '_') return;
        const std::string slot = tail.substr(0, 3);
        const std::string token = tail.substr(4);
        if (token.empty()) return;
        for (const auto& f : found) if (f.first == slot) return;
        found.emplace_back(slot, token);
    };

    // Current retail equipment records carry the resolved Factory membership
    // directly: five attachment imports on M4A1, byte-for-byte the same five
    // established independently by the package Identifier join.  Prefer it
    // because the executable's present reflection describes Grant.Unlock as a
    // null field even though older shipped schemas exposed the import there.
    const bf6::EbxValue* direct = root.field(kFactoryItems);
    if (direct && direct->kind == bf6::EbxValue::Kind::Array)
        for (const bf6::EbxValue& item : direct->items) add_item(item);

    // Older records used the grants table. Keep that exact read path as a
    // compatibility fallback, but never mix both paths.
    const bf6::EbxValue* grants = root.field(kEquipmentGrants);
    if (found.empty() && grants && grants->kind == bf6::EbxValue::Kind::Array)
    for (const bf6::EbxValue& grant : grants->items)
    {
        if (grant.kind != bf6::EbxValue::Kind::Struct) continue;
        const bf6::EbxValue* by = grant.field(kGrantorUnlock);
        const bf6::EbxValue* item = grant.field(kGrantedItem);
        if (!by || !item || by->kind != bf6::EbxValue::Kind::ImportRef ||
            item->kind != bf6::EbxValue::Kind::ImportRef) continue;
        const std::string grantor = stem(by->import_path);
        if (grantor.find("_pkg_factory") == std::string::npos) continue;
        add_item(*item);
    }

    std::sort(found.begin(), found.end());
    c->factory_fit_slots.reserve(found.size());
    c->factory_fit_tokens.reserve(found.size());
    for (const auto& f : found)
    {
        c->factory_fit_slots.push_back(f.first);
        c->factory_fit_tokens.push_back(f.second);
    }
    c->factory_fit_rows.resize(found.size());
    for (size_t i = 0; i < found.size(); ++i)
    {
        c->factory_fit_rows[i].slot = c->factory_fit_slots[i].c_str();
        c->factory_fit_rows[i].attachment = c->factory_fit_tokens[i].c_str();
    }
    const int count = (int)c->factory_fit_rows.size();
    if (out && out_max > 0)
        for (int i = 0; i < count && i < out_max; ++i) out[i] = c->factory_fit_rows[(size_t)i];
    return count;
}

int bf6_weapon_configured_parts(bf6_ctx* c, const char* md_partition,
                                const bf6_weapon_fit* fits, int fit_count,
                                bf6_weapon_part* out, int out_max)
{
    if (fit_count < 0 || (fit_count > 0 && !fits)) return -1;
    return bf6__weapon_configured_parts(c, md_partition, fits, fit_count, true, out, out_max);
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
        const bf6::EbxValue* off = bf6__by_hash(v, kFieldOffset);
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
