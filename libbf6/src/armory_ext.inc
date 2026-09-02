/* armory_ext.inc - the weapon customization slot vocabulary, READ FROM THE
 * GAME rather than tabulated in our source.
 *
 * A translation-unit fragment like raw_ext.inc; wire it beside the others.
 *
 * WHY IT EXISTS. The first cut of the armory reader carried an 11-entry table
 * of three-letter slot codes (scp, mzl, mag...) lifted from FILENAMES. That
 * table was wrong in two ways at once. It was incomplete - the game ships 43
 * slot definitions, not 11 - and it was a different vocabulary from the one
 * the game uses: `mzl` is a filename abbreviation, `MuzzleDevice` is the slot.
 * Anything built on the abbreviations inherits a lossy view and silently
 * misses every slot that has no filename form, cosmetics among them.
 *
 * The real vocabulary is authored, one partition per slot, under
 * Common/Gameplay/Weapons/Template/DefinitionSlots_Weapons/. Each carries an
 * id, its own path, and a flag. So enumerate them.
 *
 * THE ID IS AUTHORED, NOT DERIVED. It is not a hash of the slot's name: djb2,
 * djb2-xor, FNV-1, FNV-1a and CRC32 were each tried over the bare name, the
 * capitalised name and the full path, and none reproduces a single id. It is
 * an opaque identifier that has to be read. That is exactly why it must come
 * from the record and cannot be computed by a consumer.
 */

/* Field hashes on a slot definition record, confirmed on all 43:
 *   0xDE6F63B3  the slot id, Uint32, authored
 *   0xB77123CC  IsPlayerFacing, bool (recovered name; semantics not inferred)
 *   0x7B26CEB7  a second bool, false on every slot seen so far
 *   0x0C59FA06  the partition's own path. The SAME field hash carries the
 *               source path on a layered icon atlas sprite entry, so it is a
 *               shared "name" field rather than a per-type accident.
 */
static const uint32_t kSlotFieldId     = 0xDE6F63B3u;
static const uint32_t kSlotFieldPlayerFacing = 0xB77123CCu;
static const uint32_t kSlotFieldFlag2  = 0x7B26CEB7u;
static const uint32_t kSlotFieldPath   = 0x0C59FA06u;

static const char kSlotDefPrefix[] =
    "common/gameplay/weapons/template/definitionslots_weapons/";

int bf6_armory_slots(bf6_ctx* c, bf6_armory_slot* out, int out_max)
{
    if (!c) return -1;

    std::string terr;
    if (!ensure_types(c, terr)) return -1;

    /* One mount, one pass. The shell-loop version of this re-mounted the
     * install per slot and cost 15 s each; the whole point of reading from an
     * install is that the mount is paid once. */
    const int total = bf6_list_ebx(c, kSlotDefPrefix, nullptr, 0);
    if (total <= 0) return 0;
    std::vector<bf6_asset> rows((size_t)total);
    const int got = bf6_list_ebx(c, kSlotDefPrefix, rows.data(), total);

    /* Sorted, because mount order is a hash order: without this the same
     * install enumerates its slots in a different order every run. */
    std::vector<std::string> names;
    names.reserve((size_t)got);
    for (int i = 0; i < got; i++)
        if (rows[(size_t)i].name) names.emplace_back(rows[(size_t)i].name);
    std::sort(names.begin(), names.end());

    c->armory_slot_names.clear();
    c->armory_slot_names.reserve(names.size());

    int n = 0;
    for (const std::string& nm : names)
    {
        std::string err;
        std::vector<uint8_t> raw = c->src.get_ebx(nm + ".ebx", err);
        if (raw.empty()) raw = c->src.get_ebx(nm, err);
        if (raw.empty()) continue;

        bf6::Ebx e(*c->types);
        if (!e.parse(std::move(raw), err)) continue;

        for (size_t i = 0; i < e.instance_count(); i++)
        {
            bf6::EbxValue v = e.read_instance(i);
            const bf6::EbxValue* fid = v.field(kSlotFieldId);
            if (!fid) continue;

            /* The leaf of the path is the slot's own name. Taking it from the
             * record's path rather than from the mount key keeps the name and
             * the id from two different reads of the same record. */
            std::string leaf = nm;
            const size_t sl = leaf.find_last_of('/');
            if (sl != std::string::npos) leaf = leaf.substr(sl + 1);
            const bf6::EbxValue* fp = v.field(kSlotFieldPath);
            if (fp && fp->kind == bf6::EbxValue::Kind::Str && !fp->s.empty())
            {
                const size_t s2 = fp->s.find_last_of('/');
                if (s2 != std::string::npos) leaf = fp->s.substr(s2 + 1);
            }

            c->armory_slot_names.push_back(leaf);
            if (out && n < out_max)
            {
                bf6_armory_slot& o = out[n];
                o = bf6_armory_slot{};
                o.id       = (uint32_t)(fid->kind == bf6::EbxValue::Kind::Uint ? fid->u
                                                                              : (uint64_t)fid->i);
                o.name     = c->armory_slot_names.back().c_str();
                const bf6::EbxValue* fc = v.field(kSlotFieldPlayerFacing);
                const bf6::EbxValue* f2 = v.field(kSlotFieldFlag2);
                o.is_player_facing = (fc && fc->b) ? 1 : 0;
                o.flag2    = (f2 && f2->b) ? 1 : 0;
            }
            n++;
            break;      /* one slot definition per partition */
        }
    }

    /* The name pointers above alias a vector that just grew. Re-point them
     * now that it has stopped moving, or every name but the last is dangling -
     * and a dangling char* prints plausible garbage rather than crashing. */
    if (out)
    {
        const int lim = n < out_max ? n : out_max;
        for (int i = 0; i < lim && i < (int)c->armory_slot_names.size(); i++)
            out[i].name = c->armory_slot_names[(size_t)i].c_str();
    }
    return n;
}

/* ---------------------------------------------------- the screen's own order
 *
 * The armory is not laid out in code. BFUIWeaponCustomizationViewManagerConfig
 * ships a 12-entry ORDERED array, one per attachment category, and that order
 * is the presentation order on screen:
 *
 *     Sight, Magazine, OpticAccessory, Barrel, Muzzle, UnderBarrel,
 *     Flashlight, Rangefinder, Launcher, Laser, Ammunition, LeftRail
 *
 * Note it is NOT alphabetical and NOT the navigation order - a separate
 * asset carries the same twelve labels in a different permutation for input
 * indexing, and using that one puts the screen in the wrong order.
 *
 * Fields, confirmed by reading the record:
 *   0x3338FC90  the ordered array
 *   0xD49AEE0E  the entry's label CString
 *   0x64EF48EB  PointerRef to the attachmentcategory_* asset
 */
static const uint32_t kCfgOrderedArray = 0x3338FC90u;
static const uint32_t kCfgEntryLabel   = 0xD49AEE0Eu;
static const uint32_t kCfgEntryCategory = 0x64EF48EBu;
static const uint32_t kAttachmentCategory = 0xFE77E9A9u;
static const uint32_t kAttachmentUnlock = 0x157A7D74u;

static const char kArmoryConfig[] =
    "common/ui/static/config/bfuiweaponcustomizationviewmanagerconfig";

int bf6_armory_categories(bf6_ctx* c, const char** out, int out_max)
{
    if (!c) return -1;
    std::string terr;
    if (!ensure_types(c, terr)) return -1;

    std::string err;
    std::vector<uint8_t> raw = c->src.get_ebx(std::string(kArmoryConfig) + ".ebx", err);
    if (raw.empty()) raw = c->src.get_ebx(kArmoryConfig, err);
    if (raw.empty()) return -1;

    bf6::Ebx e(*c->types);
    if (!e.parse(std::move(raw), err)) return -1;

    c->armory_category_names.clear();
    for (size_t i = 0; i < e.instance_count(); i++)
    {
        bf6::EbxValue v = e.read_instance(i);
        const bf6::EbxValue* arr = v.field(kCfgOrderedArray);
        if (!arr || arr->kind != bf6::EbxValue::Kind::Array) continue;
        for (const bf6::EbxValue& row : arr->items)
        {
            const bf6::EbxValue* lab = row.field(kCfgEntryLabel);
            if (lab && lab->kind == bf6::EbxValue::Kind::Str && !lab->s.empty())
                c->armory_category_names.push_back(lab->s);
        }
        if (!c->armory_category_names.empty()) break;
    }

    const int n = (int)c->armory_category_names.size();
    if (out)
        for (int i = 0; i < n && i < out_max; i++)
            out[i] = c->armory_category_names[(size_t)i].c_str();
    return n;
}

int bf6_armory_category_bindings(bf6_ctx* c, const char* weapon,
                                 bf6_armory_category_binding* out, int out_max)
{
    if (!c || !weapon) return -1;
    std::string terr;
    if (!ensure_types(c, terr)) return -1;

    const auto lower = [](std::string s) {
        for (char& ch : s)
            if (ch >= 'A' && ch <= 'Z') ch = (char)(ch + ('a' - 'A'));
        return s;
    };
    const auto no_ext = [](std::string s) {
        if (s.size() > 4 && s.compare(s.size() - 4, 4, ".ebx") == 0)
            s.resize(s.size() - 4);
        return s;
    };
    const auto imported_category = [&](bf6::Ebx& ebx, size_t instance,
                                       const bf6::EbxValue& v) {
        for (uint32_t field : { kAttachmentCategory, kAttachmentUnlock })
        {
            const bf6::EbxValue* ref = v.field(field);
            std::string partition, importedPath;
            if (ref && ref->kind == bf6::EbxValue::Kind::ImportRef)
                importedPath = ref->import_path;
            if (importedPath.empty() || importedPath == "<not indexed>")
                ebx.import_ref(instance, field, partition, importedPath);
            if (importedPath.empty() || importedPath == "<not indexed>") continue;
            const std::string path = lower(no_ext(importedPath));
            const size_t slash = path.find_last_of("/\\");
            const std::string leaf = slash == std::string::npos
                ? path : path.substr(slash + 1);
            if (leaf.compare(0, 19, "attachmentcategory_") == 0)
                return path;
        }
        return std::string();
    };

    struct Evidence { std::map<std::string, int> code_counts; };
    std::map<std::string, Evidence> evidence;
    const std::string bare = lower(weapon);
    const std::string prefix = "attachment_" + bare + "_";
    const int assetCount = bf6_list_ebx(c, prefix.c_str(), nullptr, 0);
    std::vector<bf6_asset> assets((size_t)(assetCount > 0 ? assetCount : 0));
    const int assetGot = assetCount > 0
        ? bf6_list_ebx(c, prefix.c_str(), assets.data(), assetCount) : 0;
    for (int ai = 0; ai < assetGot; ++ai)
    {
        if (!assets[(size_t)ai].name) continue;
        std::string path = lower(assets[(size_t)ai].name);
        const size_t slash = path.find_last_of("/\\");
        const std::string stem = no_ext(slash == std::string::npos
            ? path : path.substr(slash + 1));
        if (stem.compare(0, prefix.size(), prefix) != 0) continue;
        const size_t codeEnd = stem.find('_', prefix.size());
        if (codeEnd == std::string::npos) continue;
        const std::string code = stem.substr(prefix.size(), codeEnd - prefix.size());
        if (code.empty() || code.size() >= 8)
            continue;

        std::string err;
        std::vector<uint8_t> raw = c->src.get_ebx(path + ".ebx", err);
        if (raw.empty()) raw = c->src.get_ebx(path, err);
        if (raw.empty()) continue;
        bf6::Ebx e(*c->types);
        e.set_guid_index(&c->src.armory_partition_index());
        if (!e.parse(std::move(raw), err)) continue;
        for (size_t ii = 0; ii < e.instance_count(); ++ii)
        {
            const std::string category = imported_category(e, ii, e.read_instance(ii));
            if (category.empty()) continue;
            evidence[category].code_counts[code]++;
            break;
        }
    }

    std::string err;
    std::vector<uint8_t> raw = c->src.get_ebx(std::string(kArmoryConfig) + ".ebx", err);
    if (raw.empty()) raw = c->src.get_ebx(kArmoryConfig, err);
    if (raw.empty()) return -1;
    bf6::Ebx e(*c->types);
    e.set_guid_index(&c->src.armory_partition_index());
    if (!e.parse(std::move(raw), err)) return -1;

    std::vector<bf6_armory_category_binding> rows;
    for (size_t ii = 0; ii < e.instance_count() && rows.empty(); ++ii)
    {
        const bf6::EbxValue v = e.read_instance(ii);
        const bf6::EbxValue* arr = v.field(kCfgOrderedArray);
        if (!arr || arr->kind != bf6::EbxValue::Kind::Array) continue;
        // The shipped Rime partition predates the executable schema.  Its
        // reflection-decoded label is sound, but the category field is a
        // convincing null.  The partition-proven layout is root+48 -> array,
        // then 16-byte rows with the category PointerRef at +0.
        const std::vector<uint8_t>& bytes = e.raw();
        const int64_t arrayField = e.payload() + (int64_t)e.instance_offset(ii) + 48;
        if (arrayField < 0 || arrayField + 4 > (int64_t)bytes.size()) continue;
        int32_t arrayOffset = 0;
        std::memcpy(&arrayOffset, bytes.data() + arrayField, sizeof(arrayOffset));
        const int64_t arrayData = arrayField + 4 + (int64_t)arrayOffset - 8;
        if (arrayData < 0 || arrayData + 4 > (int64_t)bytes.size()) continue;
        int32_t rawCount = 0;
        std::memcpy(&rawCount, bytes.data() + arrayData, sizeof(rawCount));
        if (rawCount < 0 || rawCount != (int32_t)arr->items.size()) continue;
        const int64_t firstRow = arrayData + 4;
        if (firstRow < 0 || firstRow + (int64_t)rawCount * 16 > (int64_t)bytes.size())
            continue;

        for (size_t itemIndex = 0; itemIndex < arr->items.size(); ++itemIndex)
        {
            const bf6::EbxValue& item = arr->items[itemIndex];
            const bf6::EbxValue* label = item.field(kCfgEntryLabel);
            if (!label || label->kind != bf6::EbxValue::Kind::Str) continue;

            std::string categoryPartition, categoryPath;
            if (!e.import_ref_at(firstRow + (int64_t)itemIndex * 16,
                                 categoryPartition, categoryPath) ||
                categoryPath.empty() || categoryPath == "<not indexed>")
                continue;

            bf6_armory_category_binding row{};
            put_str(row.label, sizeof(row.label), label->s);
            const std::string category = lower(no_ext(categoryPath));
            put_str(row.category_asset, sizeof(row.category_asset), category);

            const auto ev = evidence.find(category);
            if (ev != evidence.end())
            {
                int total = 0, best = 0;
                std::string bestCode;
                for (const auto& pair : ev->second.code_counts)
                {
                    total += pair.second;
                    if (pair.second > best)
                    { best = pair.second; bestCode = pair.first; }
                }
                row.evidence_rows = total;
                row.conflicting_rows = total - best;
                if (best > 0 && row.conflicting_rows == 0)
                    put_str(row.code, sizeof(row.code), bestCode);
            }

            std::string categoryErr;
            std::vector<uint8_t> categoryRaw = c->src.get_ebx(category + ".ebx", categoryErr);
            if (categoryRaw.empty()) categoryRaw = c->src.get_ebx(category, categoryErr);
            if (!categoryRaw.empty())
            {
                bf6::Ebx ce(*c->types);
                if (ce.parse(std::move(categoryRaw), categoryErr))
                    for (size_t ci = 0; ci < ce.instance_count(); ++ci)
                    {
                        const bf6::EbxValue cv = ce.read_instance(ci);
                        const bf6::EbxValue* id = cv.field(kSlotFieldId);
                        if (!id) continue;
                        row.category_id = (uint32_t)(id->kind == bf6::EbxValue::Kind::Uint
                            ? id->u : (uint64_t)id->i);
                        break;
                    }
            }
            rows.push_back(row);
        }
    }

    const int total = (int)rows.size();
    if (out && out_max > 0)
        for (int i = 0; i < total && i < out_max; ++i) out[i] = rows[(size_t)i];
    return total;
}

/* ---------------------------------------------------- base weapon statistics
 * Verified read path from findings/armory-base-weapon-stats-read-path.  The
 * four displayed bars are deliberately not surfaced: they are expression
 * delegate results, not authored numbers. */
namespace {

const bf6::EbxValue* bf6__armory_find(const bf6::EbxValue& v, uint32_t hash)
{
    const bf6::EbxValue* direct = v.field(hash);
    if (direct) return direct;
    for (const auto& kv : v.fields)
    {
        const bf6::EbxValue* hit = bf6__armory_find(kv.second, hash);
        if (hit) return hit;
    }
    for (const bf6::EbxValue& item : v.items)
    {
        const bf6::EbxValue* hit = bf6__armory_find(item, hash);
        if (hit) return hit;
    }
    return nullptr;
}

bool bf6__armory_number(const bf6::EbxValue* v, double& out)
{
    if (!v) return false;
    if (v->kind == bf6::EbxValue::Kind::Real) { out = v->f; return true; }
    if (v->kind == bf6::EbxValue::Kind::Int)  { out = (double)v->i; return true; }
    if (v->kind == bf6::EbxValue::Kind::Uint) { out = (double)v->u; return true; }
    return false;
}

bool bf6__armory_find_number(const bf6::EbxValue& v, uint32_t hash, double& out)
{
    if (bf6__armory_number(v.field(hash), out)) return true;
    for (const auto& kv : v.fields)
        if (bf6__armory_find_number(kv.second, hash, out)) return true;
    for (const bf6::EbxValue& item : v.items)
        if (bf6__armory_find_number(item, hash, out)) return true;
    return false;
}

const bf6::EbxValue* bf6__armory_find_value(const bf6::EbxValue& v, uint32_t hash)
{
    const bf6::EbxValue* direct = v.field(hash);
    if (direct && direct->kind != bf6::EbxValue::Kind::Null) return direct;
    for (const auto& kv : v.fields)
    {
        const bf6::EbxValue* hit = bf6__armory_find_value(kv.second, hash);
        if (hit) return hit;
    }
    for (const bf6::EbxValue& item : v.items)
    {
        const bf6::EbxValue* hit = bf6__armory_find_value(item, hash);
        if (hit) return hit;
    }
    return nullptr;
}

} // namespace

int bf6_armory_camera_mode_read(bf6_ctx* c, const char* mode,
                                bf6_armory_camera_mode* out)
{
    if (!c || !mode || !*mode || !out) return 0;
    *out = bf6_armory_camera_mode{};
    std::string terr;
    if (!ensure_types(c, terr)) return 0;

    std::string leaf(mode);
    for (char& ch : leaf) if (ch >= 'A' && ch <= 'Z') ch += 'a' - 'A';
    const std::string path = "game/glacierflow/flow_mainmenu/camera/" + leaf;
    std::string err;
    std::vector<uint8_t> raw = c->src.get_ebx(path + ".ebx", err);
    if (raw.empty()) raw = c->src.get_ebx(path, err);
    if (raw.empty()) return 0;

    bf6::Ebx ebx(*c->types);
    if (!ebx.parse(std::move(raw), err)) return 0;
    std::vector<bf6::EbxValue> inst;
    inst.reserve(ebx.instance_count());
    for (size_t i = 0; i < ebx.instance_count(); ++i)
        inst.push_back(ebx.read_instance(i));

    /* Proven field hashes from the current shipped schema. The graph order is
     * the control: the constant Offset controller before LookAtTarget is pre,
     * and the one after is post. Runtime CameraVec3Asset offsets carry a
     * non-null Asset pointer and are deliberately excluded here. */
    static const uint32_t kLayers   = 0x4DE0B6DEu;
    static const uint32_t kAnchor   = 0x2701D17Au;
    static const uint32_t kLookAt   = 0x98430D6Cu;
    static const uint32_t kPos      = 0x4FF541E4u;
    static const uint32_t kRot      = 0x3C929AEAu;
    static const uint32_t kValue    = 0x8CF424E7u;
    static const uint32_t kAsset    = 0xEC4C3E7Fu;
    static const uint32_t kX        = 0x3901DB14u;
    static const uint32_t kY        = 0x42FC0F5Eu;
    static const uint32_t kZ        = 0x32A99B9Cu;
    /* Typed LensPropertiesCameraControllerData schema.  These three hashes
     * collide with different names in other SDK type scopes, so the global
     * hash dictionary alone is not a valid semantic oracle here.  The values
     * and the controller graph order jointly identify them: the default
     * weaponbehavior branch is f/1.05, shutter 3, autofocus -1. */
    static const uint32_t kFocal    = 0xF9E2FB8Bu; /* FocalLength   */
    static const uint32_t kAperture = 0xA84B9DBBu; /* Aperture      */
    static const uint32_t kShutter  = 0x6B8F4F87u; /* ShutterSpeed  */
    static const uint32_t kFocus    = 0xA271028Du; /* FocusDistance */

    auto scalar = [](const bf6::EbxValue* v, float& dst) -> bool
    {
        if (!v) return false;
        if (v->kind == bf6::EbxValue::Kind::Real) { dst = (float)v->f; return true; }
        if (v->kind == bf6::EbxValue::Kind::Int)  { dst = (float)v->i; return true; }
        if (v->kind == bf6::EbxValue::Kind::Uint) { dst = (float)v->u; return true; }
        return false;
    };
    auto wrapped_scalar = [&](const bf6::EbxValue& v, uint32_t hash, float& dst)
    {
        const bf6::EbxValue* w = v.field(hash);
        return w && scalar(w->field(kValue), dst);
    };
    auto constant_vec = [&](const bf6::EbxValue& v, uint32_t hash, float dst[3])
    {
        const bf6::EbxValue* w = v.field(hash);
        if (!w) return false;
        const bf6::EbxValue* asset = w->field(kAsset);
        if (asset && asset->kind != bf6::EbxValue::Kind::Null) return false;
        const bf6::EbxValue* xyz = w->field(kValue);
        return xyz && scalar(xyz->field(kX), dst[0]) &&
                      scalar(xyz->field(kY), dst[1]) &&
                      scalar(xyz->field(kZ), dst[2]);
    };
    auto copy_string = [](char* dst, size_t cap, const bf6::EbxValue* v)
    {
        if (v && v->kind == bf6::EbxValue::Kind::Str)
            std::snprintf(dst, cap, "%s", v->s.c_str());
    };

    const bf6::EbxValue* controller_order = nullptr;
    for (const bf6::EbxValue& v : inst)
    {
        const bf6::EbxValue* a = v.field(kLayers);
        if (!a || a->kind != bf6::EbxValue::Kind::Array) continue;
        bool has_anchor = false, has_look = false;
        for (const bf6::EbxValue& ref : a->items)
        {
            if (ref.kind != bf6::EbxValue::Kind::InstanceRef ||
                ref.instance < 0 || ref.instance >= (int)inst.size()) continue;
            const bf6::EbxValue& target = inst[(size_t)ref.instance];
            has_anchor |= target.field(kAnchor) != nullptr;
            has_look   |= target.field(kLookAt) != nullptr;
        }
        if (has_anchor && has_look) { controller_order = a; break; }
    }
    if (!controller_order) return 0;

    bool seen_look = false, have_pre = false, have_post = false;
    for (const bf6::EbxValue& ref : controller_order->items)
    {
        if (ref.kind != bf6::EbxValue::Kind::InstanceRef ||
            ref.instance < 0 || ref.instance >= (int)inst.size()) continue;
        const bf6::EbxValue& v = inst[(size_t)ref.instance];
        copy_string(out->anchor, sizeof(out->anchor), v.field(kAnchor));
        if (v.field(kLookAt))
        {
            copy_string(out->look_at, sizeof(out->look_at), v.field(kLookAt));
            seen_look = true;
        }

        float pos[3]{};
        if (!constant_vec(v, kPos, pos)) continue;
        float rot[3]{};
        (void)constant_vec(v, kRot, rot);
        if (!seen_look && !have_pre)
        {
            for (int j = 0; j < 3; ++j)
            { out->pre_offset[j] = pos[j]; out->pre_rotation_degrees[j] = rot[j]; }
            have_pre = true;
        }
        else if (seen_look && !have_post)
        {
            for (int j = 0; j < 3; ++j)
            { out->post_offset[j] = pos[j]; out->post_rotation_degrees[j] = rot[j]; }
            have_post = true;
        }
    }

    bool have_lens = false;
    auto take_lens = [&](const bf6::EbxValue& v) -> bool
    {
        float focal = 0.f;
        if (!wrapped_scalar(v, kFocal, focal)) return false;
        out->focal_length_mm = focal;
        (void)wrapped_scalar(v, kAperture, out->aperture);
        (void)wrapped_scalar(v, kShutter, out->shutter);
        (void)wrapped_scalar(v, kFocus, out->focus_distance);
        return true;
    };

    /* Follow the same authored evaluation order used for offsets.  The
     * overview mode's lens is a nested Layers controller whose child order is
     * zoom branch 0..3: [f/1.05, f/0.80, f/0.55, f/0.48].  A flat instance
     * scan encounters branch 2 first and silently chooses the wrong camera. */
    for (const bf6::EbxValue& ref : controller_order->items)
    {
        if (ref.kind != bf6::EbxValue::Kind::InstanceRef ||
            ref.instance < 0 || ref.instance >= (int)inst.size()) continue;
        const bf6::EbxValue& v = inst[(size_t)ref.instance];
        if (take_lens(v)) { have_lens = true; break; }
        const bf6::EbxValue* nested = v.field(kLayers);
        if (!nested || nested->kind != bf6::EbxValue::Kind::Array) continue;
        for (const bf6::EbxValue& child : nested->items)
        {
            if (child.kind != bf6::EbxValue::Kind::InstanceRef ||
                child.instance < 0 || child.instance >= (int)inst.size()) continue;
            if (take_lens(inst[(size_t)child.instance]))
            { have_lens = true; break; }
        }
        if (have_lens) break;
    }

    /* Count every authored branch as a diagnostic/control, independently of
     * which branch is active by default. */
    for (const bf6::EbxValue& v : inst)
    {
        float focal = 0.f;
        if (!wrapped_scalar(v, kFocal, focal)) continue;
        ++out->lens_candidates;
    }
    std::snprintf(out->mode, sizeof(out->mode), "%s", leaf.c_str());
    return out->anchor[0] && out->look_at[0] && have_pre && have_post && have_lens;
}

int bf6_armory_camera_sensor_read(bf6_ctx* c,
                                  bf6_armory_camera_sensor* out)
{
    if (!c || !out) return 0;
    *out = bf6_armory_camera_sensor{};
    std::string terr;
    if (!ensure_types(c, terr)) return 0;

    /* Shipped CameraBodyData schema, not the executable reflection hashes.
     * The live EBX closes as four fields: these two scalars, null parent and
     * the asset path.  Using the exe's 55F9054E/AC8A63CD pair returns a clean
     * empty result, the same old-schema trap documented for Rime. */
    static const uint32_t kSensorWidth  = 0xEAA04968u;
    static const uint32_t kSensorHeight = 0x711D03DEu;
    static const uint32_t kValue        = 0x8CF424E7u;
    auto scalar = [](const bf6::EbxValue* v, float& dst) -> bool
    {
        if (!v) return false;
        if (v->kind == bf6::EbxValue::Kind::Real) { dst = (float)v->f; return true; }
        if (v->kind == bf6::EbxValue::Kind::Int)  { dst = (float)v->i; return true; }
        if (v->kind == bf6::EbxValue::Kind::Uint) { dst = (float)v->u; return true; }
        return false;
    };
    auto property_scalar = [&](const bf6::EbxValue* v, float& dst) -> bool
    {
        if (scalar(v, dst)) return true;
        return v && scalar(v->field(kValue), dst);
    };

    /* Do not bake Camera_DefaultBody's path into the tool.  The name itself is
     * authored and survives in the mounted Source table, so discover it and
     * then use the two typed field hashes as the structural gate. */
    std::set<std::string> seen_partitions;
    bool have_sensor = false;
    bool conflicting_sensor = false;
    for (const auto& kv : c->src.ebx())
    {
        std::string lower = kv.first;
        for (char& ch : lower)
            if (ch >= 'A' && ch <= 'Z') ch = (char)(ch + ('a' - 'A'));
        if (lower.find("camera_defaultbody") == std::string::npos) continue;

        std::string err;
        std::vector<uint8_t> raw = c->src.get_ebx(kv.first, err);
        if (raw.empty()) continue;
        bf6::Ebx ebx(*c->types);
        if (!ebx.parse(std::move(raw), err)) continue;
        if (!seen_partitions.insert(ebx.partition_guid()).second) continue;
        for (size_t i = 0; i < ebx.instance_count(); ++i)
        {
            const bf6::EbxValue v = ebx.read_instance(i);
            float width = 0.f, height = 0.f;
            if (!property_scalar(bf6__armory_find_value(v, kSensorWidth), width) ||
                !property_scalar(bf6__armory_find_value(v, kSensorHeight), height) ||
                !(width > 0.f) || !(height > 0.f)) continue;
            ++out->candidates;
            if (!have_sensor)
            {
                std::snprintf(out->asset, sizeof(out->asset), "%s", kv.first.c_str());
                out->width_mm = width;
                out->height_mm = height;
                have_sensor = true;
            }
            else if (std::fabs(out->width_mm - width) > 1e-6f ||
                     std::fabs(out->height_mm - height) > 1e-6f)
                conflicting_sensor = true;
            /* Two live DefaultBody aliases currently ship with distinct
             * partition GUIDs but the same gate. Prefer the flow-owned alias
             * used by this rig while retaining the candidate count/control. */
            if (kv.first.compare(0, 17, "game/glacierflow/") == 0)
                std::snprintf(out->asset, sizeof(out->asset), "%s", kv.first.c_str());
        }
    }
    return have_sensor && !conflicting_sensor;
}

int bf6_armory_camera_modes(bf6_ctx* c, bf6_armory_camera_mode* out,
                            int out_max)
{
    if (!c) return 0;
    static const char* kPrefix = "game/glacierflow/flow_mainmenu/camera/weapon";
    std::vector<std::string> leaves;
    for (const auto& kv : c->src.ebx())
    {
        if (kv.first.compare(0, std::strlen(kPrefix), kPrefix) != 0) continue;
        std::string leaf = kv.first;
        const size_t slash = leaf.find_last_of('/');
        if (slash != std::string::npos) leaf.erase(0, slash + 1);
        if (leaf.size() > 4 && leaf.compare(leaf.size()-4, 4, ".ebx") == 0)
            leaf.resize(leaf.size()-4);
        bf6_armory_camera_mode mode{};
        if (!bf6_armory_camera_mode_read(c, leaf.c_str(), &mode)) continue;
        leaves.push_back(std::move(leaf));
    }
    std::sort(leaves.begin(), leaves.end());
    leaves.erase(std::unique(leaves.begin(), leaves.end()), leaves.end());

    int written = 0;
    for (const std::string& leaf : leaves)
    {
        bf6_armory_camera_mode mode{};
        if (!bf6_armory_camera_mode_read(c, leaf.c_str(), &mode)) continue;
        if (out && written < out_max) out[written] = mode;
        ++written;
    }
    return written;
}

/* ----------------------------------------- per-weapon camera correction graph
 *
 * The graph is intentionally decoded here rather than copied into a table.
 * SupportedTypes supplies the ordered weapon ImportRefs and the ResRef field
 * supplies the current graph resource.  The five tail literals are used as a
 * structural gate, not as offsets: a patch may move the pool while retaining
 * the authored 8 x vec3, 128-byte-record representation. */
namespace {

uint16_t bf6__camera_u16(const std::vector<uint8_t>& b, size_t p)
{
    return p + 2 <= b.size() ? (uint16_t)(b[p] | ((uint16_t)b[p+1] << 8)) : 0;
}

uint32_t bf6__camera_u32(const std::vector<uint8_t>& b, size_t p)
{
    return p + 4 <= b.size() ? (uint32_t)b[p] | ((uint32_t)b[p+1] << 8) |
        ((uint32_t)b[p+2] << 16) | ((uint32_t)b[p+3] << 24) : 0;
}

float bf6__camera_f32(const std::vector<uint8_t>& b, size_t p)
{
    const uint32_t u = bf6__camera_u32(b, p);
    float f = 0.f;
    std::memcpy(&f, &u, sizeof(f));
    return f;
}

std::string bf6__camera_weapon_leaf(std::string path)
{
    for (char& ch : path)
        if (ch >= 'A' && ch <= 'Z') ch = (char)(ch + ('a' - 'A'));
    if (path.size() > 4 && path.compare(path.size()-4, 4, ".ebx") == 0)
        path.resize(path.size()-4);
    const size_t slash = path.find_last_of("/\\");
    if (slash != std::string::npos) path.erase(0, slash + 1);
    if (path.compare(0, 2, "u_") == 0) path.erase(0, 2);
    return path;
}

bool bf6__camera_graph_rows(bf6_ctx* c,
                            std::vector<bf6_armory_camera_weapon_correction>& rows)
{
    static const char kSetup[] =
        "common/ui/weapons/uiviewmodel/menuweapon/weaponattachments_camerasetup";
    static const uint32_t kGraph = 0xAA4FA860u;
    static const uint32_t kSupportedTypes = 0xA2734E52u;
    std::string terr, err;
    if (!c || !ensure_types(c, terr)) return false;
    std::vector<uint8_t> raw = c->src.get_ebx(std::string(kSetup) + ".ebx", err);
    if (raw.empty()) raw = c->src.get_ebx(kSetup, err);
    if (raw.empty()) return false;

    bf6::Ebx e(*c->types);
    e.set_guid_index(&c->src.armory_partition_index());
    if (!e.parse(std::move(raw), err)) return false;
    uint64_t rid = 0;
    std::vector<std::string> weapons;
    struct WeaponRef { uint32_t reg; std::string partition, instance; };
    std::vector<WeaponRef> weaponRefs;
    for (size_t i = 0; i < e.instance_count(); ++i)
    {
        const bf6::EbxValue v = e.read_instance(i);
        const bf6::EbxValue* graph = bf6__armory_find_value(v, kGraph);
        if (graph && graph->kind == bf6::EbxValue::Kind::ResRef) rid = graph->u;
        const bf6::EbxValue* supported = bf6__armory_find_value(v, kSupportedTypes);
        if (!supported || supported->kind != bf6::EbxValue::Kind::Array) continue;
        for (size_t supportedIndex = 0; supportedIndex < supported->items.size(); ++supportedIndex)
        {
            const bf6::EbxValue& ref = supported->items[supportedIndex];
            const bf6::EbxValue* asset = ref.field(0x8CF424E7u);
            if (!asset || asset->kind != bf6::EbxValue::Kind::ImportRef) continue;
            if (supportedIndex >= 8)
            {
                const bf6::EbxValue* reg = ref.field(0xFC636C1Fu);
                double offset = -1.0;
                if (!reg || !bf6__armory_find_number(*reg, 0x4FF541E4u, offset) ||
                    offset < 0.0 || offset > 4294967295.0) return false;
                weaponRefs.push_back({(uint32_t)offset, asset->s, asset->import_instance});
            }
            std::string leaf = bf6__camera_weapon_leaf(asset->import_path);
            /* The first eight imports are CameraVec3Assets.  Weapon unlock
             * partitions are named U_<weapon>; use that authored discriminator
             * and require the EFIX instance half as an independent integrity
             * gate rather than assuming every later import is a weapon. */
            std::string original = asset->import_path;
            for (char& ch : original)
                if (ch >= 'A' && ch <= 'Z') ch = (char)(ch + ('a' - 'A'));
            const size_t slash = original.find_last_of("/\\");
            const std::string imported = slash == std::string::npos
                ? original : original.substr(slash + 1);
            if (imported.compare(0, 2, "u_") != 0 || leaf.empty() ||
                asset->import_instance.empty()) continue;
            weapons.push_back(std::move(leaf));
        }
    }
    if (weapons.empty() && !weaponRefs.empty())
    {
        std::sort(weaponRefs.begin(), weaponRefs.end(), [](const WeaponRef& a, const WeaponRef& b) {
            return a.reg < b.reg;
        });
        for (size_t i = 1; i < weaponRefs.size(); ++i)
            if (weaponRefs[i-1].reg == weaponRefs[i].reg) return false;
        const auto& boundedIndex = c->src.armory_partition_index();
        std::map<std::string, std::string> namesByRef;
        std::set<std::string> partitions;
        for (const auto& ref : weaponRefs) partitions.insert(ref.partition);
        for (const std::string& partition : partitions)
        {
            const auto owner = boundedIndex.find(partition);
            if (owner == boundedIndex.end()) return false;
            std::string ownerPath = owner->second;
            if (ownerPath.size() > 4 && ownerPath.compare(ownerPath.size()-4,4,".ebx") == 0)
                ownerPath.resize(ownerPath.size()-4);
            std::vector<uint8_t> ownerRaw = c->src.get_ebx(ownerPath + ".ebx", err);
            if (ownerRaw.empty()) ownerRaw = c->src.get_ebx(ownerPath, err);
            bf6::Ebx ownerEbx(*c->types);
            if (ownerRaw.empty() || !ownerEbx.parse(std::move(ownerRaw), err)) return false;
            for (size_t oi = 0; oi < ownerEbx.exported_count(); ++oi)
            {
                const bf6::EbxValue ov = ownerEbx.read_instance(oi);
                const bf6::EbxValue* name = ov.field(0x0C59FA06u);
                if (!name || name->kind != bf6::EbxValue::Kind::Str ||
                    name->s.size() < 3 || name->s.compare(0,2,"U_") != 0) continue;
                const std::string key = partition + "/" + ownerEbx.instance_guid(oi);
                if (!namesByRef.emplace(key, name->s).second) return false;
            }
        }
        for (const auto& ref : weaponRefs)
        {
            const auto hit = namesByRef.find(ref.partition + "/" + ref.instance);
            if (hit == namesByRef.end()) return false;
            weapons.push_back(bf6__camera_weapon_leaf(hit->second));
        }
    }
    if (!rid || weapons.empty()) return false;
    std::set<std::string> unique(weapons.begin(), weapons.end());
    if (unique.size() != weapons.size()) return false;

    char resName[512]{};
    if (!bf6_res_by_rid(c, rid, resName, (int)sizeof(resName))) return false;
    raw = c->src.get_res(resName, err);
    if (raw.size() < 0x50) return false;

    const uint32_t f24 = bf6__camera_u32(raw, 0x24);
    const uint32_t f2c = bf6__camera_u32(raw, 0x2c);
    const uint16_t f38 = bf6__camera_u16(raw, 0x38);
    const uint16_t f3a = bf6__camera_u16(raw, 0x3a);
    const uint16_t f3c = bf6__camera_u16(raw, 0x3c);
    const uint16_t f3e = bf6__camera_u16(raw, 0x3e);
    const uint16_t f40 = bf6__camera_u16(raw, 0x40);
    const uint16_t f42 = bf6__camera_u16(raw, 0x42);
    const uint64_t typed = (uint64_t)(f3e + f40 + f42) * 4u;
    const uint64_t regionBase = ((uint64_t)f24 + 3u +
        ((typed + 0x5fu) & ~0xfull)) & ~3ull;
    if (regionBase < f24) return false;
    const uint64_t constantBase = regionBase - f24;
    const uint64_t table = regionBase +
        ((uint64_t)f2c + (uint64_t)(f38 + f3a) * 2u) * 4u;
    const uint64_t imageAt = (table + (uint64_t)f3c * 8u + 0xfull) & ~0xfull;
    if (constantBase + f24 > raw.size() || regionBase + (uint64_t)f2c*4u > raw.size() ||
        table > raw.size() || imageAt > raw.size()) return false;

    const uint32_t refCount = (uint32_t)weapons.size();
    /* The current image writes zero extension after refCount and after the
     * final 256, while the single-record count between them is a u32. */
    const uint32_t signature[7] = { 8u, 128u, refCount, 0u, 1u, 256u, 0u };
    size_t signatureAt = 0;
    int signatureHits = 0;
    for (size_t p = (size_t)constantBase;
         p + sizeof(signature) <= (size_t)(constantBase + f24); p += 4)
    {
        bool match = true;
        for (int k = 0; k < 7; ++k)
            if (bf6__camera_u32(raw, p + (size_t)k*4u) != signature[k])
                { match = false; break; }
        if (match) { signatureAt = p; ++signatureHits; }
    }
    if (signatureHits != 1) return false;

    /* The first record is the all-zero default. Every authored weapon record
     * precedes the tail metadata and record i+1 belongs to weapon ref i. */
    const uint32_t recordCount = refCount > 0 ? refCount - 1u : 0u;
    if ((uint64_t)recordCount * 128u > f24 ||
        constantBase + (uint64_t)recordCount*128u > signatureAt) return false;
    for (uint32_t r = 0; r < recordCount; ++r)
        for (int s = 0; s < BF6_ARMORY_CAMERA_CORRECTION_COUNT; ++s)
            if (bf6__camera_u32(raw, (size_t)constantBase + (size_t)r*128u +
                                      (size_t)s*16u + 12u) != 0u)
                return false; /* padded vec3, not four arbitrary floats */

    rows.clear();
    rows.reserve(refCount);
    for (uint32_t i = 0; i < refCount; ++i)
    {
        bf6_armory_camera_weapon_correction row{};
        std::snprintf(row.weapon, sizeof(row.weapon), "%s", weapons[(size_t)i].c_str());
        row.reference_index = (int32_t)i;
        row.record_index = (int32_t)(i + 1u);
        row.has_record = (i + 1u < recordCount) ? 1 : 0;
        if (row.has_record)
            for (int s = 0; s < BF6_ARMORY_CAMERA_CORRECTION_COUNT; ++s)
                for (int axis = 0; axis < 3; ++axis)
                {
                    const float f = bf6__camera_f32(raw, (size_t)constantBase +
                        (size_t)(i+1u)*128u + (size_t)s*16u + (size_t)axis*4u);
                    if (!std::isfinite(f)) return false;
                    row.correction[s][axis] = f;
                }
        rows.push_back(row);
    }
    return true;
}

float bf6__aslo_scalar(const bf6::EbxValue& v, int component)
{
    if (v.kind != bf6::EbxValue::Kind::Struct) return 0.f;
    if (component < 0 || component >= (int)v.fields.size()) return 0.f;
    const bf6::EbxValue& f = v.fields[(size_t)component].second;
    if (f.kind == bf6::EbxValue::Kind::Real) return (float)f.f;
    if (f.kind == bf6::EbxValue::Kind::Int) return (float)f.i;
    if (f.kind == bf6::EbxValue::Kind::Uint) return (float)f.u;
    return 0.f;
}

} // namespace

int bf6_armory_camera_weapon_corrections(
    bf6_ctx* c, bf6_armory_camera_weapon_correction* out, int out_max)
{
    std::vector<bf6_armory_camera_weapon_correction> rows;
    if (!bf6__camera_graph_rows(c, rows)) return -1;
    if (out && out_max > 0)
        for (int i = 0; i < (int)rows.size() && i < out_max; ++i)
            out[i] = rows[(size_t)i];
    return (int)rows.size();
}

int bf6_armory_camera_weapon_correction_read(
    bf6_ctx* c, const char* weapon, bf6_armory_camera_weapon_correction* out)
{
    if (!c || !weapon || !*weapon || !out) return 0;
    std::string wanted = bf6__camera_weapon_leaf(weapon);
    std::vector<bf6_armory_camera_weapon_correction> rows;
    if (!bf6__camera_graph_rows(c, rows)) return 0;
    for (const auto& row : rows)
        if (wanted == row.weapon) { *out = row; return 1; }
    *out = bf6_armory_camera_weapon_correction{};
    return 0;
}

int bf6_armory_slot_anchors(bf6_ctx* c, const char* weapon,
                            bf6_armory_slot_anchor* out, int out_max)
{
    if (!c || !weapon || !*weapon) return -1;
    std::string terr;
    if (!ensure_types(c, terr)) return -1;
    const std::string bare = bf6__camera_weapon_leaf(weapon);
    const std::string wanted = "aslo_" + bare;
    const int n = bf6_list_ebx(c, wanted.c_str(), nullptr, 0);
    if (n <= 0) return 0;
    std::vector<bf6_asset> assets((size_t)n);
    const int got = bf6_list_ebx(c, wanted.c_str(), assets.data(), n);
    std::string path;
    for (int i = 0; i < got; ++i)
    {
        const std::string candidate = assets[(size_t)i].name ? assets[(size_t)i].name : "";
        if (bf6__camera_weapon_leaf(candidate) == wanted)
        {
            const size_t slash = candidate.find_last_of("/\\");
            const std::string parent = slash == std::string::npos ? "" :
                candidate.substr(0, slash);
            const size_t parentSlash = parent.find_last_of("/\\");
            const std::string parentLeaf = parentSlash == std::string::npos ? parent :
                parent.substr(parentSlash + 1);
            std::string lowParent = parentLeaf;
            for (char& ch : lowParent)
                if (ch >= 'A' && ch <= 'Z') ch = (char)(ch + ('a' - 'A'));
            if (lowParent == bare) { path = candidate; break; }
        }
    }
    if (path.empty()) return 0;

    std::string err;
    std::vector<uint8_t> raw = c->src.get_ebx(path + ".ebx", err);
    if (raw.empty()) raw = c->src.get_ebx(path, err);
    if (raw.empty()) return -1;
    bf6::Ebx e(*c->types);
    if (!e.parse(std::move(raw), err)) return -1;
    static const uint32_t kRows = 0xB39AB445u;
    static const uint32_t kCategory = 0xEBE2BDFCu;
    static const uint32_t kLineOffset = 0xE579814Eu;
    static const uint32_t kPosition = 0xB0D52F03u;
    std::vector<bf6_armory_slot_anchor> rows;
    for (size_t i = 0; i < e.instance_count() && rows.empty(); ++i)
    {
        const bf6::EbxValue root = e.read_instance(i);
        const bf6::EbxValue* arr = root.field(kRows);
        if (!arr || arr->kind != bf6::EbxValue::Kind::Array) continue;
        for (const bf6::EbxValue& value : arr->items)
        {
            const bf6::EbxValue* cat = value.field(kCategory);
            const bf6::EbxValue* pos = value.field(kPosition);
            const bf6::EbxValue* line = value.field(kLineOffset);
            if (!cat || !pos || !line) return -1;
            bf6_armory_slot_anchor row{};
            row.category_id = (uint32_t)(cat->kind == bf6::EbxValue::Kind::Uint
                ? cat->u : (uint64_t)cat->i);
            for (int k = 0; k < 3; ++k) row.position[k] = bf6__aslo_scalar(*pos, k);
            for (int k = 0; k < 2; ++k) row.line_offset[k] = bf6__aslo_scalar(*line, k);
            row.has_position = (row.position[0] != 0.f || row.position[1] != 0.f ||
                                row.position[2] != 0.f) ? 1 : 0;
            rows.push_back(row);
        }
    }
    if (rows.empty()) return -1;
    if (out && out_max > 0)
        for (int i = 0; i < (int)rows.size() && i < out_max; ++i)
            out[i] = rows[(size_t)i];
    return (int)rows.size();
}

int bf6_weapon_point_budget(bf6_ctx* c, const char* weapon)
{
    if (!c || !weapon || !*weapon) return -1;
    std::string terr;
    if (!ensure_types(c, terr)) return -1;

    std::string bare(weapon);
    for (char& ch : bare)
        if (ch >= 'A' && ch <= 'Z') ch = (char)(ch + ('a' - 'A'));
    const std::string wanted = "equipment_" + bare;

    const int count = bf6_list_ebx(c, wanted.c_str(), nullptr, 0);
    if (count <= 0) return -1;
    std::vector<bf6_asset> assets((size_t)count);
    const int got = bf6_list_ebx(c, wanted.c_str(), assets.data(), count);
    std::string equipment;
    for (int i = 0; i < got; ++i)
    {
        std::string path = assets[(size_t)i].name ? assets[(size_t)i].name : "";
        std::string leaf = path;
        const size_t slash = leaf.find_last_of("/\\");
        if (slash != std::string::npos) leaf.erase(0, slash + 1);
        if (leaf.size() > 4 && leaf.compare(leaf.size() - 4, 4, ".ebx") == 0)
            leaf.resize(leaf.size() - 4);
        for (char& ch : leaf)
            if (ch >= 'A' && ch <= 'Z') ch = (char)(ch + ('a' - 'A'));
        if (leaf == wanted) { equipment = path; break; }
    }
    if (equipment.empty()) return -1;

    std::string err;
    std::vector<uint8_t> raw = c->src.get_ebx(equipment + ".ebx", err);
    if (raw.empty()) raw = c->src.get_ebx(equipment, err);
    if (raw.empty()) return -1;
    bf6::Ebx e(*c->types);
    if (!e.parse(std::move(raw), err)) return -1;

    static const uint32_t kPointBudget = 0x3CE3B411u;
    for (size_t i = 0; i < e.instance_count(); ++i)
    {
        const bf6::EbxValue v = e.read_instance(i);
        const bf6::EbxValue* hit = bf6__armory_find(v, kPointBudget);
        if (!hit) continue;
        const int64_t value = hit->kind == bf6::EbxValue::Kind::Uint
            ? (int64_t)hit->u : hit->i;
        if (value > 0 && value <= 10000) return (int)value;
    }
    return -1;
}

int bf6_attachment_weight(bf6_ctx* c, const char* attachment_ebx)
{
    if (!c || !attachment_ebx || !*attachment_ebx) return -1;
    std::string terr;
    if (!ensure_types(c, terr)) return -1;

    std::string err;
    std::vector<uint8_t> raw = c->src.get_ebx(
        std::string(attachment_ebx) + ".ebx", err);
    if (raw.empty()) raw = c->src.get_ebx(attachment_ebx, err);
    if (raw.empty()) return -1;

    bf6::Ebx e(*c->types);
    e.set_guid_index(&c->src.armory_partition_index());
    if (!e.parse(std::move(raw), err)) return -1;

    static const char* kAttachmentRecord =
        "a6a8168e-d508-da18-0929-05ed1a3684cf";
    static const uint32_t kWeight = 0x6EE865A5u;
    int matches = 0;
    int64_t answer = -1;
    for (size_t i = 0; i < e.instance_count(); ++i)
    {
        if (bf6::TypeDb::guid_str(e.instance_type(i)) != kAttachmentRecord)
            continue;
        const bf6::EbxValue v = e.read_instance(i);
        const bf6::EbxValue* field = v.field(kWeight);
        if (!field) continue;
        if (field->kind == bf6::EbxValue::Kind::Int) answer = field->i;
        else if (field->kind == bf6::EbxValue::Kind::Uint) answer = (int64_t)field->u;
        else return -1;
        ++matches;
    }
    if (matches != 1 || answer < 0 || answer > INT32_MAX) return -1;
    return (int)answer;
}

int bf6_base_weapon_stats(bf6_ctx* c, const char* weapon_class,
                          const char* weapon, bf6_weapon_base_stats* out)
{
    if (!c || !weapon || !out) return 0;
    *out = bf6_weapon_base_stats{};
    std::string terr;
    if (!ensure_types(c, terr)) { std::fprintf(stderr, "base stats: types %s\n", terr.c_str()); return 0; }

    const std::string bare = weapon;
    const int n = bf6_list_ebx(c, (bare + "_wb").c_str(), nullptr, 0);
    if (n <= 0) { std::fprintf(stderr, "base stats: no wb query %s\n", weapon); return 0; }
    std::vector<bf6_asset> rows((size_t)n);
    const int got = bf6_list_ebx(c, (bare + "_wb").c_str(), rows.data(), n);
    std::string wbPath;
    for (int i = 0; i < got; i++)
    {
        const std::string p = rows[(size_t)i].name ? rows[(size_t)i].name : "";
        const size_t slash = p.find_last_of('/');
        const std::string leaf = slash == std::string::npos ? p : p.substr(slash + 1);
        if (leaf == bare + "_wb" && (wbPath.empty() || p.size() < wbPath.size())) wbPath = p;
    }
    if (wbPath.empty()) { std::fprintf(stderr, "base stats: no exact wb among %d\n", got); return 0; }

    std::string err;
    std::vector<uint8_t> raw = c->src.get_ebx(wbPath + ".ebx", err);
    if (raw.empty()) raw = c->src.get_ebx(wbPath, err);
    if (raw.empty()) { std::fprintf(stderr, "base stats: wb read %s: %s\n", wbPath.c_str(), err.c_str()); return 0; }
    bf6::Ebx wb(*c->types);
    wb.set_guid_index(&c->src.armory_partition_index());
    if (!wb.parse(std::move(raw), err)) { std::fprintf(stderr, "base stats: wb parse %s\n", err.c_str()); return 0; }

    double rof = 0.0, mag = 0.0;
    bool haveRof = false, haveMag = false;
    std::string projectile;
    for (size_t i = 0; i < wb.instance_count(); i++)
    {
        const bf6::EbxValue v = wb.read_instance(i);
        if (!haveRof) haveRof = bf6__armory_find_number(v, 348430420u, rof);
        if (!haveMag) haveMag = bf6__armory_find_number(v, 2132983732u, mag);
        if (projectile.empty())
        {
            const bf6::EbxValue* p = bf6__armory_find_value(v, 2156779116u);
            if (p)
            {
                projectile = p->import_path.empty() ? p->s : p->import_path;
                if (projectile == "<not indexed>")
                {
                    const auto& pi = c->src.armory_partition_index();
                    const auto it = pi.find(p->s);
                    if (it != pi.end()) projectile = it->second;
                    else std::fprintf(stderr, "unresolved ProjectileData guid %s (%zu indexed)\n",
                                      p->s.c_str(), pi.size());
                }
            }
        }
        if (haveRof && haveMag && !projectile.empty()) break;
    }
    if (!haveRof || !haveMag || projectile.empty() || projectile == "<not indexed>")
    { std::fprintf(stderr, "base stats: wb leaves rof=%d mag=%d projectile=%s\n", haveRof, haveMag, projectile.c_str()); return 0; }

    if (projectile.size() > 4 && projectile.compare(projectile.size() - 4, 4, ".ebx") == 0)
        projectile.resize(projectile.size() - 4);

    raw = c->src.get_ebx(projectile + ".ebx", err);
    if (raw.empty()) raw = c->src.get_ebx(projectile, err);
    if (raw.empty()) { std::fprintf(stderr, "base stats: projectile read %s: %s\n", projectile.c_str(), err.c_str()); return 0; }
    bf6::Ebx pe(*c->types);
    if (!pe.parse(std::move(raw), err)) { std::fprintf(stderr, "base stats: projectile parse %s\n", err.c_str()); return 0; }

    double damage = -1.0;
    for (size_t i = 0; i < pe.instance_count() && damage < 0.0; i++)
    {
        const bf6::EbxValue root = pe.read_instance(i);
        const bf6::EbxValue* curve = bf6__armory_find_value(root, 1611197233u);
        if (!curve) continue;
        bf6::EbxValue target;
        const bf6::EbxValue* cv = curve;
        if (curve->kind == bf6::EbxValue::Kind::InstanceRef && curve->instance >= 0 &&
            curve->instance < (int32_t)pe.instance_count())
        {
            target = pe.read_instance((size_t)curve->instance);
            cv = &target;
        }
        const bf6::EbxValue* points = bf6__armory_find_value(*cv, 3992743414u);
        if (!points || points->kind != bf6::EbxValue::Kind::Array || points->items.empty()) continue;
        const bf6::EbxValue* y = bf6__armory_find_value(points->items.front(), 1123815262u);
        bf6__armory_number(y, damage);
    }
    if (damage < 0.0)
    {
        // Some stock ProjectileData records (M4A1 is one) ship the verified
        // curve field null even though their FloatCurve instances are local.
        // Accept a fallback only when every non-empty local curve agrees at
        // x=0. This is a control, not a blind first-curve pick: disagreement
        // leaves damage unavailable rather than displaying a guess.
        bool haveConsensus = false, disagree = false;
        double consensus = 0.0;
        for (size_t i = 0; i < pe.instance_count(); i++)
        {
            const bf6::EbxValue v = pe.read_instance(i);
            const bf6::EbxValue* points = bf6__armory_find_value(v, 3992743414u);
            if (!points || points->kind != bf6::EbxValue::Kind::Array || points->items.empty()) continue;
            double px = -1.0, py = -1.0;
            if (!bf6__armory_find_number(points->items.front(), 956422932u, px) ||
                !bf6__armory_find_number(points->items.front(), 1123815262u, py) || px != 0.0)
                continue;
            if (!haveConsensus) { consensus = py; haveConsensus = true; }
            else if (std::fabs(consensus - py) > 0.0001) disagree = true;
        }
        if (haveConsensus && !disagree) damage = consensus;
    }
    if (damage < 0.0) { std::fprintf(stderr, "base stats: no controlled damage curve in %s\n", projectile.c_str()); return 0; }

    out->damage = (int32_t)damage;              /* screen truncates, does not round */
    out->rate_of_fire = (int32_t)rof;
    out->magazine = (int32_t)mag;
    const std::string cls = weapon_class ? weapon_class : "";
    if (cls != "mg" && cls != "shotgun") out->magazine -= 1; /* closed-bolt chamber */
    return 1;
}

/* --------------------------------------------------------- localization UI
 * The shipped table is deliberately decoded here rather than exported beside
 * the executable.  Its two chunk GUIDs are fields of fs_us_loc; the histogram
 * is the byte->Unicode alphabet and the binary chunk is a sid/offset table. */
namespace {

static uint32_t bf6__u32le(const std::vector<uint8_t>& b, size_t p)
{
    if (p + 4 > b.size()) return 0;
    return (uint32_t)b[p] | ((uint32_t)b[p + 1] << 8) |
           ((uint32_t)b[p + 2] << 16) | ((uint32_t)b[p + 3] << 24);
}

static uint16_t bf6__u16le(const std::vector<uint8_t>& b, size_t p)
{
    if (p + 2 > b.size()) return 0;
    return (uint16_t)((uint16_t)b[p] | ((uint16_t)b[p + 1] << 8));
}

static void bf6__utf8(std::string& out, uint32_t cp)
{
    if (cp < 0x80) out.push_back((char)cp);
    else if (cp < 0x800)
    {
        out.push_back((char)(0xC0 | (cp >> 6)));
        out.push_back((char)(0x80 | (cp & 63)));
    }
    else
    {
        out.push_back((char)(0xE0 | (cp >> 12)));
        out.push_back((char)(0x80 | ((cp >> 6) & 63)));
        out.push_back((char)(0x80 | (cp & 63)));
    }
}

static bool bf6__ensure_loc_en(bf6_ctx* c)
{
    if (c->loc_en_tried) return !c->loc_en.empty();
    c->loc_en_tried = true;
    std::string terr, err;
    if (!ensure_types(c, terr)) return false;
    const char* path = "common/localization/languages/fs_us_loc";
    std::vector<uint8_t> raw = c->src.get_ebx(std::string(path) + ".ebx", err);
    if (raw.empty()) raw = c->src.get_ebx(path, err);
    if (raw.empty()) return false;
    bf6::Ebx e(*c->types);
    if (!e.parse(std::move(raw), err)) return false;
    std::string binGuid, histGuid;
    for (size_t i = 0; i < e.instance_count(); i++)
    {
        const bf6::EbxValue v = e.read_instance(i);
        const bf6::EbxValue* bv = v.field(206566248u);   // BinaryChunk
        const bf6::EbxValue* hv = v.field(3183768524u); // HistogramChunk
        if (bv && bv->kind == bf6::EbxValue::Kind::Guid) binGuid = bf6__resolve_guid(c, bv->guid);
        if (hv && hv->kind == bf6::EbxValue::Kind::Guid) histGuid = bf6__resolve_guid(c, hv->guid);
        if (!binGuid.empty() && !histGuid.empty()) break;
    }
    if (binGuid.empty() || histGuid.empty()) return false;
    const std::vector<uint8_t> bin = c->src.get_chunk(binGuid, err);
    const std::vector<uint8_t> hist = c->src.get_chunk(histGuid, err);
    if (bin.size() < 20 || hist.size() < 524 || bf6__u32le(bin, 0) != 0x00039000u ||
        bf6__u32le(hist, 0) != 0x00039001u) return false;
    const uint32_t count = bf6__u32le(bin, 8);
    const uint32_t table = bf6__u32le(bin, 12);
    const uint32_t data = bf6__u32le(bin, 16);
    if ((uint64_t)table + (uint64_t)count * 8u != data ||
        (uint64_t)table + ((uint64_t)count + 1u) * 8u > bin.size()) return false;
    uint32_t cp[256]{};
    for (int i = 0; i < 256; i++) cp[i] = bf6__u16le(hist, 12 + (size_t)i * 2);
    for (int i = 0; i < 128; i++) cp[i] = (uint32_t)i;
    for (int i = 128; i < 256; i++) if (!cp[i]) cp[i] = 0xFFFDu;
    const size_t base = (size_t)data + 8;
    for (uint32_t i = 0; i <= count; i++)
    {
        const uint32_t sid = bf6__u32le(bin, (size_t)table + (size_t)i * 8);
        const uint32_t off = bf6__u32le(bin, (size_t)table + (size_t)i * 8 + 4);
        size_t p = base + off;
        if (p >= bin.size()) continue;
        std::string s;
        while (p < bin.size() && bin[p]) bf6__utf8(s, cp[bin[p++]]);
        c->loc_en[sid] = std::move(s);
    }
    return !c->loc_en.empty();
}

static uint32_t bf6__ui_sid(const bf6::Ebx& e, const bf6::EbxValue* v)
{
    if (!v) return 0;
    bf6::EbxValue owned;
    if (v->kind == bf6::EbxValue::Kind::InstanceRef && v->instance >= 0 &&
        v->instance < (int)e.instance_count()) { owned = const_cast<bf6::Ebx&>(e).read_instance((size_t)v->instance); v = &owned; }
    const bf6::EbxValue* sh = bf6__armory_find_value(*v, 1026853258u);
    if (!sh) return 0;
    return (uint32_t)(sh->kind == bf6::EbxValue::Kind::Uint ? sh->u : (uint64_t)sh->i);
}

static bool bf6__ui_contains_hiao(const bf6::EbxValue& v, const std::string& bare)
{
    const bf6::EbxValue* h = v.field(1029689975u);
    if (h && h->kind == bf6::EbxValue::Kind::ImportRef)
    {
        std::string p = h->import_path.empty() ? h->s : h->import_path;
        for (char& ch : p) if (ch >= 'A' && ch <= 'Z') ch = (char)(ch + 32);
        if (p.find("hiao_" + bare) != std::string::npos) return true;
    }
    for (const auto& kv : v.fields)
        if (bf6__ui_contains_hiao(kv.second, bare)) return true;
    for (const bf6::EbxValue& item : v.items)
        if (bf6__ui_contains_hiao(item, bare)) return true;
    return false;
}

static const bf6::EbxValue* bf6__ui_find_hiao(const bf6::EbxValue& v, const std::string& bare)
{
    if (v.field(4251553617u) && bf6__ui_contains_hiao(v, bare)) return &v;
    for (const auto& kv : v.fields)
    {
        const bf6::EbxValue* hit = bf6__ui_find_hiao(kv.second, bare);
        if (hit) return hit;
    }
    for (const bf6::EbxValue& item : v.items)
    {
        const bf6::EbxValue* hit = bf6__ui_find_hiao(item, bare);
        if (hit) return hit;
    }
    return nullptr;
}

} // namespace

const char* bf6_localized_string(bf6_ctx* c, uint32_t string_id)
{
    if (!c || !bf6__ensure_loc_en(c)) return nullptr;
    const auto it = c->loc_en.find(string_id);
    return it == c->loc_en.end() ? nullptr : it->second.c_str();
}

int bf6_weapon_ui_info_read(bf6_ctx* c, const char* weapon, bf6_weapon_ui_info* out)
{
    if (!c || !weapon || !out || !bf6__ensure_loc_en(c)) return 0;
    *out = bf6_weapon_ui_info{};
    std::string bare = weapon;
    for (char& ch : bare) if (ch >= 'A' && ch <= 'Z') ch = (char)(ch + 32);
    const int n = bf6_list_ebx(c, "uiweaponabilitymetadata", nullptr, 0);
    if (n <= 0) return 0;
    std::vector<bf6_asset> rows((size_t)n);
    const int got = bf6_list_ebx(c, "uiweaponabilitymetadata", rows.data(), n);
    for (int ri = 0; ri < got; ri++)
    {
        const std::string path = rows[(size_t)ri].name ? rows[(size_t)ri].name : "";
        std::string err;
        std::vector<uint8_t> raw = c->src.get_ebx(path + ".ebx", err);
        if (raw.empty()) raw = c->src.get_ebx(path, err);
        if (raw.empty()) continue;
        bf6::Ebx e(*c->types);
        e.set_guid_index(&c->src.armory_partition_index());
        if (!e.parse(std::move(raw), err)) continue;
        for (size_t i = 0; i < e.instance_count(); i++)
        {
            const bf6::EbxValue root = e.read_instance(i);
            const bf6::EbxValue* row = bf6__ui_find_hiao(root, bare);
            if (!row) continue;
            uint32_t ids[3] = {
                bf6__ui_sid(e, row->field(4251553617u)),
                bf6__ui_sid(e, row->field(1225723344u)),
                bf6__ui_sid(e, row->field(4173741287u))
            };
            // These three LocalizedString pointers are declared with a null
            // reflection type on this retail image and therefore deserialize
            // as Null.  They are ordinary internal PointerRefs in the bytes;
            // use the explicit raw-pointer door for the top-level entry.
            const uint32_t sidFields[3] = { 4251553617u, 1225723344u, 4173741287u };
            if (row == &root)
                for (int k = 0; k < 3; k++) if (!ids[k])
                {
                    const int32_t pi = e.int_pointer(i, sidFields[k]);
                    if (pi >= 0 && pi < (int32_t)e.instance_count())
                    {
                        const bf6::EbxValue loc = e.read_instance((size_t)pi);
                        ids[k] = bf6__ui_sid(e, &loc);
                    }
                }
            c->weapon_ui_strings.clear();
            c->weapon_ui_strings.reserve(7);
            for (uint32_t id : ids)
            {
                const auto it = c->loc_en.find(id);
                c->weapon_ui_strings.push_back(!id || it == c->loc_en.end() ? std::string() : it->second);
            }
            const auto fit = c->loc_en.find(3038496759u);
            c->weapon_ui_strings.push_back(fit == c->loc_en.end() ? "FACTORY" : fit->second);
            const bf6::EbxValue* traits = row->field(2357172511u);
            if (traits && traits->kind == bf6::EbxValue::Kind::Array)
                for (const bf6::EbxValue& tr : traits->items)
                {
                    if (c->weapon_ui_strings.size() >= 7) break;
                    const uint32_t sid = bf6__ui_sid(e, &tr);
                    const auto it = c->loc_en.find(sid);
                    c->weapon_ui_strings.push_back(it == c->loc_en.end() ? std::string() : it->second);
                }
            out->name = c->weapon_ui_strings[0].c_str();
            out->description = c->weapon_ui_strings[1].c_str();
            out->class_label = c->weapon_ui_strings[2].c_str();
            out->factory_label = c->weapon_ui_strings[3].c_str();
            out->trait_count = (int32_t)c->weapon_ui_strings.size() - 4;
            for (int k = 0; k < out->trait_count && k < 3; k++)
                out->traits[k] = c->weapon_ui_strings[(size_t)k + 4].c_str();
            return out->name && *out->name ? 1 : 0;
        }
    }
    return 0;
}

int bf6_weapon_navigation_rows(bf6_ctx* c,
                               bf6_weapon_navigation_row* out, int out_max)
{
    if (!c) return -1;
    std::string terr;
    if (!ensure_types(c, terr)) return -1;

    static const char kConfig[] =
        "common/ui/weapons/assets/mainmenu_weaponcollectionviewmanagerconfig";
    static const uint32_t kCollection = 0x069e4642u;
    static const uint32_t kOrdinal = 0xcc6c5a12u;
    static const uint32_t kSortIndex = 0x9dab9fe4u;
    static const uint32_t kIcon = 0xa8f9a5a7u;
    const auto integer = [](const bf6::EbxValue* value) -> int64_t {
        if (!value) return 0;
        if (value->kind == bf6::EbxValue::Kind::Uint)
            return (int64_t)value->u;
        if (value->kind == bf6::EbxValue::Kind::Real)
            return (int64_t)value->f;
        return value->i;
    };

    std::string err;
    std::vector<uint8_t> raw = c->src.get_ebx(std::string(kConfig) + ".ebx", err);
    if (raw.empty()) raw = c->src.get_ebx(kConfig, err);
    if (raw.empty()) return -1;

    bf6::Ebx e(*c->types);
    e.set_guid_index(&c->src.armory_partition_index());
    if (!e.parse(std::move(raw), err)) return -1;

    std::vector<bf6_weapon_navigation_row> rows;
    for (size_t instance = 0; instance < e.instance_count() && rows.empty();
         ++instance)
    {
        const bf6::EbxValue root = e.read_instance(instance);
        const bf6::EbxValue* collection = root.field(kCollection);
        if (!collection || collection->kind != bf6::EbxValue::Kind::Array)
            continue;
        rows.reserve(collection->items.size());
        for (const bf6::EbxValue& value : collection->items)
        {
            const bf6::EbxValue* ordinal = value.field(kOrdinal);
            const bf6::EbxValue* sortIndex = value.field(kSortIndex);
            const bf6::EbxValue* icon = value.field(kIcon);
            if (!ordinal || !sortIndex || !icon ||
                icon->kind != bf6::EbxValue::Kind::ImportRef ||
                icon->import_path.empty())
            {
                rows.clear();
                break;
            }
            bf6_weapon_navigation_row row{};
            row.ordinal = (int32_t)integer(ordinal);
            row.sort_index = (int32_t)integer(sortIndex);
            put_str(row.icon_asset, sizeof(row.icon_asset), icon->import_path);
            rows.push_back(row);
        }
    }
    if (rows.empty()) return -1;
    if (out && out_max > 0)
        for (int i = 0; i < (int)rows.size() && i < out_max; ++i)
            out[i] = rows[(size_t)i];
    return (int)rows.size();
}

/* The attachment catalogue: aam_<weapon>.ebx joined to its description assets.
 *
 * The entry type carries the description POINTER, the sort order and an author
 * string of the form "<WEAPON> - <SLOT> - <Display Name>". The slot code comes
 * out of that string, which is a parse of a debug name and is treated as such:
 * a row whose author string does not split into three parts is dropped rather
 * than guessed at.
 */
static const char* const kAamEntryType = "e549b128-de84-116b-ed1a-c93f54dd40dd";
static const uint32_t kAamFieldDesc   = 0x85b318a1u;  /* -> the ad_ asset  */
static const uint32_t kAamFieldOrder  = 0xc9a39085u;  /* display order     */
static const uint32_t kAamFieldAuthor = 0x55aded8du;  /* "W - SLOT - Name" */
static const uint32_t kAamFieldNameSid = 0xfd698f51u; /* raw LocalizedString pointer */

/* On the description asset. */
static const uint32_t kAdFieldLayered = 0xf0aecf83u;  /* weapon silhouette */
static const uint32_t kAdFieldIcon    = 0x651ab360u;  /* per-category      */
static const uint32_t kAdFieldAtlas   = 0x0b86ea6au;  /* atlas import      */
static const uint32_t kAdFieldIndex   = 0xb94a3c65u;  /* entry index       */
static const uint32_t kAdStringId     = 0x3d34898au;  /* on a ccf82429 row */
static const uint32_t kAdFieldTitle   = 0x33a358a7u;  /* raw title pointer */
static const uint32_t kAdFieldBody    = 0x490f0dd0u;  /* DescriptionSid    */

namespace {

/* The last path component. rime_ext.inc has one of these but is included
 * after this file, so it is not in scope here. */
std::string bf6__aam_stem(const std::string& path)
{
    const size_t sl = path.find_last_of("/\\");
    size_t a = sl == std::string::npos ? 0 : sl + 1;
    size_t b = path.size();
    if (b >= a + 4 && path.compare(b - 4, 4, ".ebx") == 0) b -= 4;
    return path.substr(a, b - a);
}

/* AN INTEGER MAY ARRIVE IN EITHER HALF OF THE VALUE.
 *
 * EbxValue keeps signed and unsigned in SEPARATE members, so reading .i on a
 * field the schema calls unsigned yields 0 - and 0 is a legal index, so the
 * mistake produces a complete-looking result that puts every attachment on the
 * first sprite of the right atlas. That is exactly what it did.
 */
int64_t bf6__aam_int(const bf6::EbxValue* v)
{
    if (!v) return 0;
    if (v->kind == bf6::EbxValue::Kind::Uint) return (int64_t)v->u;
    if (v->kind == bf6::EbxValue::Kind::Real) return (int64_t)v->f;
    return v->i;
}

/* Resolve exactly one LocalizedStringId value through the live English table.
 * This deliberately accepts an InstanceRef rather than walking every string
 * instance in a partition: partition instance order is not UI semantics. */
std::string bf6__aam_localized(bf6_ctx* c, const bf6::Ebx& e,
                               const bf6::EbxValue* value)
{
    const uint32_t sid = bf6__ui_sid(e, value);
    if (!sid) return {};
    const auto it = c->loc_en.find(sid);
    return it == c->loc_en.end() ? std::string() : it->second;
}

/* These two UIItemDescription pointers hit the same retail schema mismatch as
 * NameSid: reflection reports null even though the raw relative pointer is
 * present. Resolve that pointer by its named field rather than confusing the
 * neighbouring trait/stat arrays for user-facing copy. */
std::string bf6__aam_localized_pointer(bf6_ctx* c, bf6::Ebx& e,
                                       size_t instance, uint32_t field)
{
    const bf6::EbxValue root = e.read_instance(instance);
    std::string text = bf6__aam_localized(c, e, root.field(field));
    if (!text.empty()) return text;
    const int32_t pi = e.int_pointer(instance, field);
    if (pi < 0 || pi >= (int32_t)e.instance_count()) return {};
    const bf6::EbxValue loc = e.read_instance((size_t)pi);
    return bf6__aam_localized(c, e, &loc);
}

/* Fold a display name to the only key that joins it to a roster token. */
std::string bf6__aam_key(const std::string& s)
{
    std::string out;
    for (char ch : s)
        if (std::isalnum((unsigned char)ch))
            out.push_back((char)std::tolower((unsigned char)ch));
    return out;
}

/* Read {atlas import path, index} out of one of the two icon references. */
void bf6__aam_icon(bf6_ctx* c, const bf6::Ebx& e, const bf6::EbxValue& root,
                   uint32_t field, char* atlas_out, size_t atlas_cap,
                   int32_t& index_out)
{
    index_out = -1;
    const bf6::EbxValue* ref = root.field(field);
    if (!ref || ref->kind != bf6::EbxValue::Kind::Struct) return;
    if (const bf6::EbxValue* ix = ref->field(kAdFieldIndex))
        index_out = (int32_t)bf6__aam_int(ix);
    const bf6::EbxValue* at = ref->field(kAdFieldAtlas);
    if (!at || at->kind != bf6::EbxValue::Kind::ImportRef) { index_out = -1; return; }
    /* The import resolves through the live guid index; without a path there is
     * nothing for a caller to open, so the index is withdrawn too rather than
     * handed back pointing at nothing. */
    std::string p = at->import_path;
    if (p.empty()) { index_out = -1; return; }
    if (p.size() > 4 && p.compare(p.size() - 4, 4, ".ebx") == 0) p.resize(p.size() - 4);
    put_str(atlas_out, atlas_cap, p);
    (void)c; (void)e;
}

}  // namespace

int bf6_weapon_attachment_catalogue(bf6_ctx* c, const char* weapon,
                                    bf6_attachment_catalogue_row* out, int out_max)
{
    if (!c || !weapon || !*weapon) return -1;
    std::string terr;
    if (!ensure_types(c, terr)) return -1;
    if (!bf6__ensure_loc_en(c)) return -1;

    /* The asset sits beside the weapon, whose folder the roster knows. Find it
     * by name rather than assuming a class folder. */
    std::string bare = weapon;
    for (char& ch : bare) if (ch >= 'A' && ch <= 'Z') ch = (char)(ch + 32);
    const std::string want = "aam_" + bare;
    const int n = bf6_list_ebx(c, want.c_str(), nullptr, 0);
    if (n <= 0) return -1;
    std::vector<bf6_asset> rows((size_t)n);
    const int got = bf6_list_ebx(c, want.c_str(), rows.data(), n);

    std::string path;
    for (int i = 0; i < got; i++)
    {
        const std::string nm = rows[(size_t)i].name ? rows[(size_t)i].name : "";
        if (bf6__aam_stem(nm) == want) { path = nm; break; }
    }
    if (path.empty()) return -1;

    std::string err;
    std::vector<uint8_t> raw = c->src.get_ebx(path + ".ebx", err);
    if (raw.empty()) raw = c->src.get_ebx(path, err);
    if (raw.empty()) return -1;

    bf6::Ebx e(*c->types);
    e.set_guid_index(&c->src.armory_partition_index());
    if (!e.parse(std::move(raw), err)) return -1;

    c->catalogue.clear();
    for (size_t i = 0; i < e.instance_count(); i++)
    {
        if (bf6::TypeDb::guid_str(e.instance_type(i)) != kAamEntryType) continue;
        const bf6::EbxValue v = e.read_instance(i);

        const bf6::EbxValue* au = v.field(kAamFieldAuthor);
        if (!au || au->kind != bf6::EbxValue::Kind::Str || au->s.empty()) continue;

        /* "<WEAPON> - <SLOT> - <Name>". Three parts or it is not a row we can
         * place, and a row we cannot place is dropped, not guessed. */
        std::vector<std::string> parts;
        {
            const std::string& s = au->s;
            size_t a = 0;
            for (;;)
            {
                const size_t b = s.find(" - ", a);
                parts.push_back(s.substr(a, b == std::string::npos ? std::string::npos : b - a));
                if (b == std::string::npos) break;
                a = b + 3;
            }
        }
        if (parts.size() < 3) continue;

        bf6_attachment_catalogue_row r{};
        std::string slot = parts[1];
        for (char& ch : slot) if (ch >= 'A' && ch <= 'Z') ch = (char)(ch + 32);
        put_str(r.slot, sizeof(r.slot), slot);

        std::string label = parts[2];
        for (size_t k = 3; k < parts.size(); k++) label += " - " + parts[k];
        put_str(r.name, sizeof(r.name), label);
        put_str(r.name_key, sizeof(r.name_key), bf6__aam_key(label));

        /* NameSid is an ordinary internal PointerRef, but this retail image's
         * reflection describes it with a null type. The normal read therefore
         * returns a convincing `null`; int_pointer is the existing raw-pointer
         * door for precisely this schema mismatch. Keep the author label only
         * as a truthful fallback and as the independent roster join key. */
        const bf6::EbxValue* nameValue = v.field(kAamFieldNameSid);
        std::string displayName = bf6__aam_localized(c, e, nameValue);
        if (displayName.empty())
        {
            const int32_t pi = e.int_pointer(i, kAamFieldNameSid);
            if (pi >= 0 && pi < (int32_t)e.instance_count())
            {
                const bf6::EbxValue loc = e.read_instance((size_t)pi);
                displayName = bf6__aam_localized(c, e, &loc);
            }
        }
        if (!displayName.empty()) put_str(r.name, sizeof(r.name), displayName);

        if (const bf6::EbxValue* o = v.field(kAamFieldOrder))
            r.order = (int32_t)bf6__aam_int(o);
        r.icon_index = r.layered_index = -1;

        /* The description asset carries the art and the localised strings. */
        const bf6::EbxValue* d = v.field(kAamFieldDesc);
        if (d && d->kind == bf6::EbxValue::Kind::ImportRef && !d->import_path.empty())
        {
            std::string ap = d->import_path;
            if (ap.size() > 4 && ap.compare(ap.size() - 4, 4, ".ebx") == 0) ap.resize(ap.size() - 4);
            {
                std::string stem = bf6__aam_stem(ap);
                if (stem.size() > 3 && stem.compare(0, 3, "ad_") == 0) stem = stem.substr(3);
                put_str(r.ad_stem, sizeof(r.ad_stem), bf6__aam_key(stem));
            }
            std::string aerr;
            std::vector<uint8_t> araw = c->src.get_ebx(ap + ".ebx", aerr);
            if (araw.empty()) araw = c->src.get_ebx(ap, aerr);
            if (!araw.empty())
            {
                bf6::Ebx ae(*c->types);
                ae.set_guid_index(&c->src.armory_partition_index());
                if (ae.parse(std::move(araw), aerr) && ae.instance_count())
                {
                    const bf6::EbxValue av = ae.read_instance(0);
                    bf6__aam_icon(c, ae, av, kAdFieldIcon, r.icon_atlas,
                                  sizeof(r.icon_atlas), r.icon_index);
                    bf6__aam_icon(c, ae, av, kAdFieldLayered, r.layered_atlas,
                                  sizeof(r.layered_atlas), r.layered_index);

                    const std::string body = bf6__aam_localized_pointer(
                        c, ae, 0, kAdFieldBody);
                    const std::string title = bf6__aam_localized_pointer(
                        c, ae, 0, kAdFieldTitle);
                    put_str(r.description, sizeof(r.description), body);
                    put_str(r.detail_title, sizeof(r.detail_title), title);
                }
            }
        }
        c->catalogue.push_back(r);
    }

    const int total = (int)c->catalogue.size();
    if (out && out_max > 0)
        for (int i = 0; i < total && i < out_max; i++) out[i] = c->catalogue[(size_t)i];
    return total;
}

/* Every weapon's in-game name, in one pass.
 *
 * bf6_weapon_ui_info_read answers for ONE weapon and rescans every
 * uiweaponabilitymetadata partition to do it. A roster of 185 entries wants the
 * table, not 185 searches - so this walks the same partitions once and keys
 * each row by the weapon its hiao import names.
 *
 * The key comes from the import PATH rather than from any string on the row:
 * `.../hiao_m4a1.ebx` -> `m4a1`, which is the same token the roster is built
 * from, so the two join exactly instead of by resemblance.
 */
static const uint32_t kUiHiaoField  = 1029689975u;
static const uint32_t kUiNameSid    = 4251553617u;
static const uint32_t kUiDescSid    = 1225723344u;
static const uint32_t kUiClassSid   = 4173741287u;
static const uint32_t kUiFactorySid = 3038496759u;

namespace {

/* Depth-first: every row that carries a name sid AND an hiao import, paired. */
void bf6__ui_collect_rows(const bf6::Ebx& e, const bf6::EbxValue& v,
                          std::vector<std::pair<std::string, const bf6::EbxValue*>>& out,
                          int depth)
{
    if (depth > 6) return;
    if (v.field(kUiNameSid))
    {
        /* Find the hiao import anywhere beneath this row. */
        const bf6::EbxValue* h = bf6__armory_find_value(v, kUiHiaoField);
        if (h && h->kind == bf6::EbxValue::Kind::ImportRef)
        {
            std::string p = h->import_path.empty() ? h->s : h->import_path;
            for (char& ch : p) if (ch >= 'A' && ch <= 'Z') ch = (char)(ch + 32);
            const size_t at = p.find("hiao_");
            if (at != std::string::npos)
            {
                std::string bare = p.substr(at + 5);
                const size_t dot = bare.find(".ebx");
                if (dot != std::string::npos) bare.resize(dot);
                if (!bare.empty()) out.emplace_back(bare, &v);
            }
        }
    }
    for (const auto& kv : v.fields) bf6__ui_collect_rows(e, kv.second, out, depth + 1);
    for (const bf6::EbxValue& it : v.items) bf6__ui_collect_rows(e, it, out, depth + 1);
}

}  // namespace

int bf6_weapon_names(bf6_ctx* c, bf6_weapon_name_row* out, int out_max)
{
    if (!c || !bf6__ensure_loc_en(c)) return -1;
    std::string terr;
    if (!ensure_types(c, terr)) return -1;

    // This API follows the normal C count/fill contract. The first call builds
    // the table directly from the mounted install; the second must serve that
    // same immutable result. Clearing and rebuilding here made every consumer
    // decompress and parse the entire UIWeaponAbilityMetadata population
    // twice, adding several seconds before the first armory frame.
    if (!c->weapon_names.empty())
    {
        const int total = (int)c->weapon_names.size();
        if (out && out_max > 0)
            for (int i = 0; i < total && i < out_max; ++i)
                out[i] = c->weapon_names[(size_t)i];
        return total;
    }

    const int n = bf6_list_ebx(c, "uiweaponabilitymetadata", nullptr, 0);
    if (n <= 0) return -1;
    std::vector<bf6_asset> parts((size_t)n);
    const int got = bf6_list_ebx(c, "uiweaponabilitymetadata", parts.data(), n);

    c->weapon_names.clear();
    for (int i = 0; i < got; i++)
    {
        const std::string path = parts[(size_t)i].name ? parts[(size_t)i].name : "";
        if (path.empty()) continue;
        std::string err;
        std::vector<uint8_t> raw = c->src.get_ebx(path + ".ebx", err);
        if (raw.empty()) raw = c->src.get_ebx(path, err);
        if (raw.empty()) continue;

        bf6::Ebx e(*c->types);
        e.set_guid_index(&c->src.armory_partition_index());
        if (!e.parse(std::move(raw), err)) continue;

        for (size_t k = 0; k < e.instance_count(); k++)
        {
            const bf6::EbxValue root = e.read_instance(k);
            std::vector<std::pair<std::string, const bf6::EbxValue*>> found;
            bf6__ui_collect_rows(e, root, found, 0);
            for (const auto& fr : found)
            {
                bf6_weapon_name_row r{};
                put_str(r.weapon, sizeof(r.weapon), fr.first);

                uint32_t ids[3] = {
                    bf6__ui_sid(e, fr.second->field(kUiNameSid)),
                    bf6__ui_sid(e, fr.second->field(kUiDescSid)),
                    bf6__ui_sid(e, fr.second->field(kUiClassSid))
                };
                /* The three LocalizedString pointers are declared with a null
                 * reflection type on this image and deserialize as Null. On the
                 * root instance the raw-pointer door recovers them; on a nested
                 * row it does not apply, and a row with no name is dropped
                 * rather than reported with an empty one. */
                if (fr.second == &root)
                {
                    static const uint32_t sidFields[3] =
                        { kUiNameSid, kUiDescSid, kUiClassSid };
                    for (int q = 0; q < 3; q++) if (!ids[q])
                    {
                        const int32_t pi = e.int_pointer(k, sidFields[q]);
                        if (pi >= 0 && pi < (int32_t)e.instance_count())
                        {
                            const bf6::EbxValue loc = e.read_instance((size_t)pi);
                            ids[q] = bf6__ui_sid(e, &loc);
                        }
                    }
                }

                const auto nm = c->loc_en.find(ids[0]);
                if (nm == c->loc_en.end() || nm->second.empty()) continue;
                put_str(r.name, sizeof(r.name), nm->second);
                const auto cl = c->loc_en.find(ids[2]);
                if (cl != c->loc_en.end()) put_str(r.class_label, sizeof(r.class_label), cl->second);
                /* The grid's second line is the package label, not the weapon
                 * class.  It is one shipped localisation entry shared by all
                 * factory rows.  An absent entry stays absent: putting the
                 * English word "FACTORY" here would turn a failed runtime
                 * read into a convincing-looking success. */
                const auto factory = c->loc_en.find(kUiFactorySid);
                if (factory != c->loc_en.end())
                    put_str(r.factory_label, sizeof(r.factory_label),
                            factory->second);

                /* The finished grid silhouette is also imported by this same
                 * metadata row. Several PointerRef fields deserialize as Null
                 * under the executable schema, so use the existing raw import
                 * door on root rows and accept only the authored archetype
                 * TextureAsset edge. This is the exact weapon->image join;
                 * punctuation and historical token aliases need no filename
                 * normalization. */
                for (const auto& field : fr.second->fields)
                {
                    std::string iconPath;
                    if (field.second.kind == bf6::EbxValue::Kind::ImportRef)
                        iconPath = field.second.import_path.empty()
                            ? field.second.s : field.second.import_path;
                    else if (fr.second == &root)
                    {
                        std::string partition;
                        e.import_ref(k, field.first, partition, iconPath);
                    }
                    std::string lower = iconPath;
                    for (char& ch : lower)
                        if (ch >= 'A' && ch <= 'Z') ch = (char)(ch + 32);
                    const size_t slash = lower.find_last_of("/\\");
                    const std::string leaf = slash == std::string::npos
                        ? lower : lower.substr(slash + 1);
                    static const std::string suffix = "_archetype_icon.ebx";
                    if (leaf.size() > suffix.size() &&
                        leaf.compare(leaf.size() - suffix.size(),
                                     suffix.size(), suffix) == 0)
                    {
                        if (lower.size() > 4 &&
                            lower.compare(lower.size() - 4, 4, ".ebx") == 0)
                            lower.resize(lower.size() - 4);
                        put_str(r.icon_asset, sizeof(r.icon_asset), lower);
                        break;
                    }
                }

                /* This is a distinct import from the composed card image.
                 * MainMenu_WeaponCollectionViewManagerConfig carries this
                 * category icon, and the navigation generator joins through
                 * it. Keep the field identity explicit: scanning for a
                 * filename resemblance would silently bind unrelated HUD
                 * icons present on a few non-weapon metadata rows. */
                static const uint32_t kUiCategoryIcon = 0x16ae44efu;
                const bf6::EbxValue* category =
                    fr.second->field(kUiCategoryIcon);
                std::string categoryPath;
                if (category && category->kind == bf6::EbxValue::Kind::ImportRef)
                    categoryPath = category->import_path.empty()
                        ? category->s : category->import_path;
                else if (fr.second == &root)
                {
                    std::string partition;
                    e.import_ref(k, kUiCategoryIcon, partition, categoryPath);
                }
                for (char& ch : categoryPath)
                    if (ch >= 'A' && ch <= 'Z') ch = (char)(ch + 32);
                if (categoryPath.size() > 4 &&
                    categoryPath.compare(categoryPath.size() - 4, 4, ".ebx") == 0)
                    categoryPath.resize(categoryPath.size() - 4);
                put_str(r.category_icon_asset,
                        sizeof(r.category_icon_asset), categoryPath);
                c->weapon_names.push_back(r);
            }
        }
    }

    const int total = (int)c->weapon_names.size();
    if (out && out_max > 0)
        for (int i = 0; i < total && i < out_max; i++) out[i] = c->weapon_names[(size_t)i];
    return total;
}
