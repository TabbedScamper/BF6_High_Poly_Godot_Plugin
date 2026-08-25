/* ebxdump_ext.inc - read one EBX partition THROUGH THE REFLECTION and hand
 * back a readable tree.
 *
 * A translation-unit fragment, like raw_ext.inc: it needs bf6_ctx and the
 * TypeDb the context owns, and neither exists outside bf6_core.cpp. Wire it
 * beside the others, before the closing `}  // extern "C"`.
 *
 * WHY IT EXISTS. bf6_read_raw hands back bytes, and reading a field out of
 * bytes means knowing a fixed offset. Fixed offsets are how you write a reader
 * that works today and breaks on the next patch WITHOUT SAYING SO: the
 * attachment cost sits at 0x80 in an attachment partition, but 0x80 in a slot
 * definition partition is the middle of the partition's own name string. The
 * same read produces a plausible integer from both.
 *
 * The schema is right there in the executable. Using it costs one call and
 * removes the entire class of error, so this exposes it rather than shipping
 * another offset table.
 *
 * This is a DIAGNOSTIC door: it formats to text, which is what a person
 * exploring a record wants. A consumer that needs values in a loop should get
 * a typed entry point instead of parsing this back.
 */

namespace {

void bf6__dump_val(const bf6::EbxValue& v, int depth, int max_depth,
                   std::string& out)
{
    char buf[256];
    const std::string pad((size_t)depth * 2 + 4, ' ');

    using K = bf6::EbxValue::Kind;
    switch (v.kind)
    {
    case K::Bool:  out += v.b ? "true" : "false"; break;
    case K::Int:   std::snprintf(buf, sizeof(buf), "%lld", (long long)v.i); out += buf; break;
    case K::Uint:  std::snprintf(buf, sizeof(buf), "%llu", (unsigned long long)v.u); out += buf; break;
    case K::Real:  std::snprintf(buf, sizeof(buf), "%.6g", v.f); out += buf; break;
    case K::Str:   out += "\"" + v.s + "\""; break;
    case K::Guid:  out += "guid"; break;
    case K::ResRef:
        std::snprintf(buf, sizeof(buf), "resref %016llx", (unsigned long long)v.u);
        out += buf; break;
    case K::InstanceRef:
        std::snprintf(buf, sizeof(buf), "-> instance %d", (int)v.instance);
        out += buf; break;
    case K::ImportRef:
        // The resolved path is the useful half: it is how one record names
        // another, and following it by hand is the whole job of a walk.
        out += "import " + (v.import_path.empty() ? v.s : v.import_path);
        break;
    case K::Array:
        std::snprintf(buf, sizeof(buf), "[%d]", (int)v.items.size());
        out += buf;
        if (depth >= max_depth) break;
        for (size_t i = 0; i < v.items.size() && i < 64; i++)
        {
            out += "\n" + pad;
            std::snprintf(buf, sizeof(buf), "%2d: ", (int)i);
            out += buf;
            bf6__dump_val(v.items[i], depth + 1, max_depth, out);
        }
        if (v.items.size() > 64) out += "\n" + pad + "...";
        break;
    case K::Struct:
        std::snprintf(buf, sizeof(buf), "{%d}", (int)v.fields.size());
        out += buf;
        if (depth >= max_depth) break;
        for (const auto& kv : v.fields)
        {
            out += "\n" + pad;
            {
                /* Name first when we have it: a reader should see
                 * "Identifier" and not have to carry 0xDE6F63B3 in their head. */
                const char* fn = bf6_field_name(kv.first);
                if (fn) std::snprintf(buf, sizeof(buf), "%-28s ", fn);
                else    std::snprintf(buf, sizeof(buf), "0x%08x %-17s ", kv.first, "");
                out += buf;
            }
            bf6__dump_val(kv.second, depth + 1, max_depth, out);
        }
        break;
    case K::Unknown:
        std::snprintf(buf, sizeof(buf), "unknown(te=%u raw=%u)", v.te, (unsigned)v.u);
        out += buf; break;
    default: out += "null"; break;
    }
}

}  // namespace


/* ---------------------------------------------------- field-name dictionary
 *
 * BF6 strips type and field NAMES from its reflection and keys everything by
 * an opaque u32. It also CHANGED THE HASH FUNCTION, so the names cannot be
 * recovered by hashing candidates: djb2, fnv1, fnv1a, crc32, murmur, xxhash
 * and city all fail over every basis, prime, case and encoding.
 *
 * They are recoverable the other way round. Frostbite type GUIDs are stable
 * across titles, so BF6's baked reflection joins against older games' named
 * dumps by GUID for types and by (matched GUID, field OFFSET) for fields.
 * That is what data/fieldname_dict.json holds: 20,614 nameHash -> Name pairs,
 * with nothing hardcoded and nothing guessed.
 *
 * Loading it turns a dump full of magic numbers into one a person can read,
 * and it catches mislabelling: 0xB77123CC is IsPlayerFacing, not the
 * "cosmetic flag" it was first called from looking at which slots set it.
 */
static std::map<uint32_t, std::string> g_fieldNames;
static bool g_fieldNamesTried = false;

static void bf6__load_field_names()
{
    if (g_fieldNamesTried) return;
    g_fieldNamesTried = true;

    /* Beside the exe, then the previewer's data dir. Absent is not an error:
     * the dump falls back to raw hashes, which is what it did before. */
    const char* cands[] = {
        "assets/fieldname_dict.json",
        "fieldname_dict.json",
        "C:/PortalSDK_1.4.2.0/GodotProject/User_Created/tools/bf6-weapon-previewer/data/fieldname_dict.json",
    };
    for (const char* c : cands)
    {
        FILE* f = fopen(c, "rb");
        if (!f) continue;
        std::string j;
        char buf[8192];
        size_t n;
        while ((n = fread(buf, 1, sizeof(buf), f)) > 0) j.append(buf, n);
        fclose(f);

        /* Flat {"<decimal hash>": "Name", ...}; scanned rather than parsed to
         * avoid dragging a JSON dependency into the core for one file. */
        size_t i = 0;
        while (true)
        {
            const size_t k0 = j.find('"', i);
            if (k0 == std::string::npos) break;
            const size_t k1 = j.find('"', k0 + 1);
            if (k1 == std::string::npos) break;
            const size_t c0 = j.find('"', k1 + 1);
            if (c0 == std::string::npos) break;
            const size_t c1 = j.find('"', c0 + 1);
            if (c1 == std::string::npos) break;
            const std::string key = j.substr(k0 + 1, k1 - k0 - 1);
            const std::string val = j.substr(c0 + 1, c1 - c0 - 1);
            if (!key.empty() && key.find_first_not_of("0123456789") == std::string::npos)
                g_fieldNames[(uint32_t)strtoul(key.c_str(), nullptr, 10)] = val;
            i = c1 + 1;
        }
        if (!g_fieldNames.empty()) return;
    }
}

const char* bf6_field_name(uint32_t name_hash)
{
    bf6__load_field_names();
    auto it = g_fieldNames.find(name_hash);
    return it == g_fieldNames.end() ? nullptr : it->second.c_str();
}

int64_t bf6_ebx_dump(bf6_ctx* c, const char* name, int max_depth,
                     char* out, int out_len)
{
    if (!c || !name || !out || out_len <= 0) return -1;

    /* Load the schema on demand. bf6_open does not build one - the level
     * readers do - so a caller that only wants to read a record would
     * otherwise be told the schema is missing when it is merely unbuilt.
     * ensure_types already exists for exactly this and reports the EA App
     * encrypted case properly rather than resolving everything to null. */
    std::string terr;
    if (!ensure_types(c, terr))
    {
        std::snprintf(out, (size_t)out_len, "no type schema: %s", terr.c_str());
        return -1;
    }

    std::string err;
    std::vector<uint8_t> raw = c->src.get_ebx(std::string(name) + ".ebx", err);
    if (raw.empty()) raw = c->src.get_ebx(name, err);
    if (raw.empty())
    {
        std::snprintf(out, (size_t)out_len, "not in the mount: %s", name);
        return -1;
    }

    bf6::Ebx e(*c->types);
    if (!e.parse(std::move(raw), err))
    {
        std::snprintf(out, (size_t)out_len, "parse failed: %s", err.c_str());
        return -1;
    }

    std::string s;
    char buf[512];
    std::snprintf(buf, sizeof(buf), "%s\n  partition %s\n  instances %d (exported %d)\n",
                  name, e.partition_guid().c_str(),
                  (int)e.instance_count(), (int)e.exported_count());
    s += buf;

    for (size_t i = 0; i < e.instance_count(); i++)
    {
        /* Retail reflection strips type NAMES, so a type is only ever its
         * guid here. Printing the guid is not a fallback, it is the identity. */
        const bf6::TypeGuid tg = e.instance_type(i);
        const std::string tn = bf6::TypeDb::guid_str(tg);
        std::snprintf(buf, sizeof(buf), "\n  [%d] type %s\n    ", (int)i, tn.c_str());
        s += buf;
        bf6::EbxValue v = e.read_instance(i);
        bf6__dump_val(v, 0, max_depth <= 0 ? 3 : max_depth, s);
        s += "\n";
    }

    const int64_t need = (int64_t)s.size() + 1;
    std::snprintf(out, (size_t)out_len, "%s", s.c_str());
    return need;
}
