/* Validation harness for module 5 (EBX).
 *
 * Not shipped. Pulls a real EBX partition out of the install, decodes every
 * instance, and prints one flattened line per value so the Python reference
 * (ebx.py + ebx_deser.py) can be compared line for line.
 *
 *   ebx_test <game_dir> <toc> <exe> list                 names in this toc
 *   ebx_test <game_dir> <toc> <exe> dump <name> <out>    the raw partition
 *   ebx_test <game_dir> <toc> <exe> read <name>          the decode, flattened
 *
 * Value lines are  V <instance> <path> <value>, path being name hashes joined
 * by '.' with array indices in brackets. Floats print %.9g, which is exactly
 * what the Python side prints, so a float32 round trip cannot disagree.
 */
#include "ebx.h"
#include "source.h"
#include "types.h"

#include <chrono>
#include <cstdio>
#include <cstring>
#include <string>

using namespace bf6;

static void put_value(const EbxValue& v, const std::string& path, size_t inst);

static void put_line(size_t inst, const std::string& path, const std::string& val)
{
    std::printf("V %zu %s %s\n", inst, path.c_str(), val.c_str());
}

static std::string escape(const std::string& s)
{
    std::string o;
    o.reserve(s.size() + 2);
    for (unsigned char c : s)
    {
        if (c == '\\') o += "\\\\";
        else if (c == '\n') o += "\\n";
        else if (c == '\r') o += "\\r";
        else if (c == ' ')  o += "\\s";
        else if (c < 0x20 || c > 0x7E)
        {
            char b[8];
            std::snprintf(b, sizeof(b), "\\x%02x", c);
            o += b;
        }
        else o += (char)c;
    }
    return o.empty() ? std::string("\"\"") : o;
}

static void put_value(const EbxValue& v, const std::string& path, size_t inst)
{
    char buf[64];
    switch (v.kind)
    {
    case EbxValue::Kind::Null: put_line(inst, path, "null"); break;
    case EbxValue::Kind::Bool: put_line(inst, path, v.b ? "true" : "false"); break;
    case EbxValue::Kind::Int:
        std::snprintf(buf, sizeof(buf), "%lld", (long long)v.i);
        put_line(inst, path, buf);
        break;
    case EbxValue::Kind::Uint:
        std::snprintf(buf, sizeof(buf), "%llu", (unsigned long long)v.u);
        put_line(inst, path, buf);
        break;
    case EbxValue::Kind::Real:
        std::snprintf(buf, sizeof(buf), "%.9g", v.f);
        put_line(inst, path, buf);
        break;
    case EbxValue::Kind::Str: put_line(inst, path, escape(v.s)); break;
    case EbxValue::Kind::Guid:
    {
        std::string h;
        for (uint8_t b : v.guid)
        {
            char t[3];
            std::snprintf(t, sizeof(t), "%02x", b);
            h += t;
        }
        put_line(inst, path, "guid:" + h);
        break;
    }
    case EbxValue::Kind::ResRef:
        std::snprintf(buf, sizeof(buf), "resref:%016llx", (unsigned long long)v.u);
        put_line(inst, path, buf);
        break;
    case EbxValue::Kind::InstanceRef:
        std::snprintf(buf, sizeof(buf), "inst:%d", v.instance);
        put_line(inst, path, buf);
        break;
    case EbxValue::Kind::ImportRef:
        put_line(inst, path, "import:" + v.s);
        break;
    case EbxValue::Kind::Unknown:
        std::snprintf(buf, sizeof(buf), "te%02x:%llu", v.te, (unsigned long long)v.u);
        put_line(inst, path, buf);
        break;
    case EbxValue::Kind::Struct:
    {
        put_line(inst, path, "struct:" + TypeDb::guid_str(v.guid));
        for (const auto& kv : v.fields)
        {
            char h[16];
            std::snprintf(h, sizeof(h), "%08x", kv.first);
            put_value(kv.second, path.empty() ? h : path + "." + h, inst);
        }
        break;
    }
    case EbxValue::Kind::Array:
    {
        std::snprintf(buf, sizeof(buf), "array:%zu", v.items.size());
        put_line(inst, path, buf);
        for (size_t i = 0; i < v.items.size(); i++)
        {
            std::snprintf(buf, sizeof(buf), "[%zu]", i);
            put_value(v.items[i], path + buf, inst);
        }
        break;
    }
    }
}

int main(int argc, char** argv)
{
    if (argc < 5)
    {
        std::fprintf(stderr,
            "usage: ebx_test <game_dir> <toc> <exe> list\n"
            "       ebx_test <game_dir> <toc> <exe> dump <name> <out>\n"
            "       ebx_test <game_dir> <toc> <exe> read <name>\n");
        return 2;
    }
    const std::string mode = argv[4];

    Source src;
    std::string err;
    if (!src.open(argv[1], err)) { std::fprintf(stderr, "open: %s\n", err.c_str()); return 1; }
    if (!src.mount_toc(argv[2], err)) { std::fprintf(stderr, "mount: %s\n", err.c_str()); return 1; }

    if (mode == "list")
    {
        for (const auto& kv : src.ebx()) std::printf("%s\n", kv.first.c_str());
        std::fprintf(stderr, "%zu ebx\n", src.ebx().size());
        return 0;
    }
    if (argc < 6) { std::fprintf(stderr, "need a name\n"); return 2; }

    std::vector<uint8_t> bytes = src.get_ebx(argv[5], err);
    if (bytes.empty()) { std::fprintf(stderr, "get_ebx: %s\n", err.c_str()); return 1; }

    if (mode == "dump")
    {
        if (argc < 7) { std::fprintf(stderr, "need an output path\n"); return 2; }
        FILE* o = std::fopen(argv[6], "wb");
        if (!o) { std::fprintf(stderr, "cannot write %s\n", argv[6]); return 1; }
        std::fwrite(bytes.data(), 1, bytes.size(), o);
        std::fclose(o);
        std::fprintf(stderr, "%zu bytes\n", bytes.size());
        return 0;
    }

    using clk = std::chrono::steady_clock;
    auto ms = [](clk::time_point x, clk::time_point y)
    { return std::chrono::duration<double, std::milli>(y - x).count(); };

    const auto t0 = clk::now();
    TypeDb types;
    if (!types.open(argv[3], err)) { std::fprintf(stderr, "types: %s\n", err.c_str()); return 1; }

    const auto t1 = clk::now();

    Ebx ebx(types);
    if (!ebx.parse(std::move(bytes), err)) { std::fprintf(stderr, "parse: %s\n", err.c_str()); return 1; }

    std::printf("P %s %zu %zu\n", ebx.partition_guid().c_str(),
                ebx.instance_count(), ebx.exported_count());
    for (size_t i = 0; i < ebx.instance_count(); i++)
    {
        std::printf("I %zu %s %s\n", i, TypeDb::guid_str(ebx.instance_type(i)).c_str(),
                    ebx.instance_guid(i).c_str());
        const EbxValue v = ebx.read_instance(i);
        for (const auto& kv : v.fields)
        {
            char h[16];
            std::snprintf(h, sizeof(h), "%08x", kv.first);
            put_value(kv.second, h, i);
        }
    }
    const auto t2 = clk::now();
    std::fprintf(stderr, "%zu instance(s), %llu nested field(s), %llu array element(s)\n",
                 ebx.instance_count(), (unsigned long long)Ebx::n_nested,
                 (unsigned long long)Ebx::n_arr_elem);
    std::fprintf(stderr, "exe %.0f ms, parse+decode %.0f ms\n", ms(t0, t1), ms(t1, t2));
    return 0;
}
