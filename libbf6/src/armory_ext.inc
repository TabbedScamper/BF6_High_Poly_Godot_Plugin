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
 *   0xB77123CC  a bool, true on camo_spo and charm only -> cosmetic
 *   0x7B26CEB7  a second bool, false on every slot seen so far
 *   0x0C59FA06  the partition's own path. The SAME field hash carries the
 *               source path on a layered icon atlas sprite entry, so it is a
 *               shared "name" field rather than a per-type accident.
 */
static const uint32_t kSlotFieldId     = 0xDE6F63B3u;
static const uint32_t kSlotFieldCosmet = 0xB77123CCu;
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
                const bf6::EbxValue* fc = v.field(kSlotFieldCosmet);
                const bf6::EbxValue* f2 = v.field(kSlotFieldFlag2);
                o.cosmetic = (fc && fc->b) ? 1 : 0;
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
