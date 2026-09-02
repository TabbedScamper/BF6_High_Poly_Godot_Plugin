/* vedump_test - RESEARCH ONLY. Dumps a level's VisualEnvironment presets raw.
 *
 * The RFL2 field NameHash is not reversible, so nothing here can name a field.
 * It emits (component type_guid, field hash, value) triples and leaves the
 * naming to a join against data/sdk_field_names.tsv. That join is what turned
 * an anonymous pile of floats into sun, sky, fog and exposure, and it is why
 * this exists separately from velight_test: the constants baked into
 * velighting.cpp were READ OFF THIS OUTPUT, and if the schema ever moves this
 * is what re-derives them.
 *
 * Lines:
 *   IMP  <level> <resolved partition name>          every level-root import
 *   VE   <level> <ve partition>                     a candidate preset
 *   INST <ve> <idx> <type_guid> <nfields>
 *   F    <type_guid> <hash> <kind> <value...>
 *   R    <type_guid> <hash> <import_idx> <guid> <path>
 *
 *   vedump_test <game_dir> <exe> <level> [level...]
 *
 * Field names are joined afterwards by the research-side `fieldnames.py`.
 * The runtime library deliberately carries no exported name dictionary.
 */
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

#include "bf6_core.h"
#include "ebx.h"
#include "source.h"
#include "types.h"

using namespace bf6;

static uint64_t g_total_fields = 0;
static uint64_t g_ref_candidates = 0;
static uint64_t g_ref_resolved = 0;
static uint64_t g_ref_control_hits = 0;

static void print_val(const EbxValue& v)
{
    switch (v.kind) {
    case EbxValue::Kind::Bool: std::printf("b %d", v.b ? 1 : 0); break;
    case EbxValue::Kind::Real: std::printf("f %.7g", v.f); break;
    case EbxValue::Kind::Int:  std::printf("i %lld", (long long)v.i); break;
    case EbxValue::Kind::Uint: std::printf("u %llu", (unsigned long long)v.u); break;
    case EbxValue::Kind::Str:  std::printf("s %s", v.s.c_str()); break;
    case EbxValue::Kind::ImportRef:
        std::printf("imp %s", v.import_path.empty() ? v.s.c_str() : v.import_path.c_str());
        break;
    case EbxValue::Kind::InstanceRef: std::printf("ref %d", (int)v.instance); break;
    case EbxValue::Kind::Struct: {
        std::printf("st %zu", v.fields.size());
        for (const auto& kv : v.fields) {
            std::printf(" %08x=", kv.first);
            if (kv.second.kind == EbxValue::Kind::Real) std::printf("%.7g", kv.second.f);
            else if (kv.second.kind == EbxValue::Kind::Bool) std::printf("%d", kv.second.b ? 1 : 0);
            else if (kv.second.kind == EbxValue::Kind::Int) std::printf("%lld", (long long)kv.second.i);
            else if (kv.second.kind == EbxValue::Kind::Uint) std::printf("%llu", (unsigned long long)kv.second.u);
            else std::printf("?");
        }
        break;
    }
    case EbxValue::Kind::Array: std::printf("a %zu", v.items.size()); break;
    case EbxValue::Kind::ResRef: std::printf("res %llu", (unsigned long long)v.u); break;
    case EbxValue::Kind::Unknown: std::printf("unk te=%u u=%u", (unsigned)v.te, (unsigned)v.u); break;
    default: std::printf("? 0"); break;
    }
}

static void dump_partition(Source& src, TypeDb& types, const std::string& name)
{
    std::string err;
    std::vector<uint8_t> raw = src.get_ebx(name, err);
    if (raw.empty()) return;
    Ebx e(types);
    e.set_guid_index(&src.partition_index());
    if (!e.parse(std::move(raw), err)) return;
    for (size_t i = 0; i < e.instance_count(); i++) {
        EbxValue d = e.read_instance(i);
        const std::string tg = TypeDb::guid_str(e.instance_type(i));
        std::printf("INST %s %zu %s %zu\n", name.c_str(), i, tg.c_str(), d.fields.size());
        const TypeLayout& lay = types.layout_full(e.instance_type(i));
        for (const auto& kv : d.fields) {
            ++g_total_fields;
            std::printf("F %s %08x ", tg.c_str(), kv.first);
            print_val(kv.second);
            // A Null field gets its RAW slot printed beside it. That is how the
            // VE's texture bindings were found: the type table describes those
            // fields with a null type_va, so the schema read reports them
            // absent, while the eight bytes at their offset hold an ordinary
            // odd import pointer (raw=f -> import 7). Without this the preset
            // looks like it binds no sky at all.
            uint64_t raw64 = 0;
            bool has_raw_import_candidate = false;
            if (kv.second.kind == EbxValue::Kind::Null) {
                for (const FieldInfo& fi : lay.fields) {
                    if (fi.name_hash != kv.first) continue;
                    const int64_t p = e.payload() + (int64_t)e.instance_offset(i) + (int64_t)fi.offset;
                    if (p >= 0 && p + 8 <= (int64_t)e.raw().size())
                        std::memcpy(&raw64, e.raw().data() + p, 8);
                    std::printf(" [off=%u te=%u va=%llx raw=%llx]", fi.offset,
                                (unsigned)fi.ftype_enum, (unsigned long long)fi.type_va,
                                (unsigned long long)raw64);
                    has_raw_import_candidate = (raw64 & 1ull) != 0;
                    break;
                }
            }
            std::printf("\n");
            if (has_raw_import_candidate) {
                ++g_ref_candidates;
                std::string partition_guid, path;
                if (e.import_ref(i, kv.first, partition_guid, path)) {
                    ++g_ref_resolved;
                    std::printf("R %s %08x %llu %s %s\n", tg.c_str(), kv.first,
                                (unsigned long long)(raw64 >> 1),
                                partition_guid.c_str(), path.empty() ? "-" : path.c_str());
                }

                // Null control: flip the high bit of the declaration hash and
                // ask the same instance for that field. A positional or
                // "nearest field" resolver can still return a convincing
                // import for this query; the declaration-keyed path must not.
                std::string control_guid, control_path;
                if (e.import_ref(i, kv.first ^ 0x80000000u,
                                 control_guid, control_path))
                    ++g_ref_control_hits;
            }
        }
    }
}

int main(int argc, char** argv)
{
    if (argc < 4) {
        std::fprintf(stderr, "usage: vedump_test <game_dir> <exe> <level> [level...]\n");
        return 2;
    }

    TypeDb types;
    std::string err;
    if (!types.open(argv[2], err)) { std::fprintf(stderr, "types: %s\n", err.c_str()); return 1; }

    for (int li = 3; li < argc; li++) {
        const std::string level = argv[li];
        Source src;
        if (!src.open(argv[1], err)) { std::fprintf(stderr, "open: %s\n", err.c_str()); return 1; }
        if (!src.mount_level(level.c_str(), false, err)) {
            std::printf("SKIP %s mount: %s\n", level.c_str(), err.c_str());
            continue;
        }

        // The level root partition: levels/<level>/<level>. Names in the mount
        // carry no extension; the partition index does.
        std::string root;
        for (const auto& kv : src.ebx()) {
            const std::string& n = kv.first;
            const size_t p = n.find("/levels/");
            std::string tail = (p == std::string::npos) ? n : n.substr(p + 8);
            std::string want = level + "/" + level;
            for (char& c : tail) c = (char)tolower((unsigned char)c);
            for (char& c : want) c = (char)tolower((unsigned char)c);
            if (tail == want) { root = n; break; }
        }
        std::printf("ROOT %s %s\n", level.c_str(), root.c_str());
        if (root.empty()) continue;

        std::vector<uint8_t> raw = src.get_ebx(root, err);
        if (raw.empty()) { std::printf("SKIP %s (root unreadable)\n", level.c_str()); continue; }
        Ebx e(types);
        e.set_guid_index(&src.partition_index());
        if (!e.parse(std::move(raw), err)) { std::printf("SKIP %s (root parse)\n", level.c_str()); continue; }

        const auto& gi = src.partition_index();
        std::vector<std::string> ves;
        for (size_t i = 0; i < e.import_count(); i++) {
            auto it = gi.find(e.import_at(i).partition);
            if (it == gi.end()) continue;
            std::string n = it->second;
            if (n.size() > 4 && n.compare(n.size() - 4, 4, ".ebx") == 0) n.resize(n.size() - 4);
            std::printf("IMP %s %s\n", level.c_str(), n.c_str());
            const size_t s = n.find_last_of('/');
            const std::string leaf = s == std::string::npos ? n : n.substr(s + 1);
            if (leaf.compare(0, 3, "ve_") == 0) {
                std::printf("VE %s %s\n", level.c_str(), n.c_str());
                ves.push_back(n);
            }
        }
        // Every ve_ partition the LEVEL ships, imported or not. The imported set
        // above is the game's own selection; this is the pool it selected from,
        // and printing both is what makes "the active preset" checkable rather
        // than asserted.
        const std::string lvl_dir = root.substr(0, root.find_last_of('/') + 1);
        for (const auto& kv : src.ebx()) {
            const std::string& n = kv.first;
            if (n.compare(0, lvl_dir.size(), lvl_dir) != 0) continue;
            const size_t s = n.find_last_of('/');
            const std::string leaf = s == std::string::npos ? n : n.substr(s + 1);
            if (leaf.compare(0, 3, "ve_") != 0) continue;
            bool imported = false;
            for (const std::string& v : ves) if (v == n) imported = true;
            std::printf("CAND %s %s %s\n", level.c_str(), imported ? "imported" : "unused",
                        n.c_str());
            if (!imported) ves.push_back(n);
        }
        for (const std::string& v : ves) dump_partition(src, types, v);
        std::printf("END %s\n", level.c_str());
        std::fflush(stdout);
    }
    std::printf("FIELD_STATS %llu raw hashed fields\n",
                (unsigned long long)g_total_fields);
    std::printf("REF_STATS %llu/%llu control_hits=%llu\n",
                (unsigned long long)g_ref_resolved,
                (unsigned long long)g_ref_candidates,
                (unsigned long long)g_ref_control_hits);
    return 0;
}
