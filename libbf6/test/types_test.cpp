/* Validation harness for module 4 (types).
 *
 * Not shipped. It dumps what the C core reads for a list of type guids, in a
 * line format the Python reference (typesdk.py, which the GDScript reader was
 * itself ported from) can be compared against exactly. A module is not done
 * until the two agree on every line.
 *
 *   types_test <exe> <guid-list-file> [--fields]
 *
 * The guid list is one guid per line, "eec133de-42e8-cfb5-ce15-c428de4d2f08".
 * Output, one type per line:
 *   T <guid> <nameHash> <flags> <size> <align> <typeEnum> <fieldCount> <signature> <superVA> <fields-kept>
 * and with --fields, each kept field after its type:
 *   F <guid> <nameHash> <flags> <offset> <typeVA>
 */
#include "types.h"

#include <cstdio>
#include <cstring>
#include <fstream>
#include <string>

using namespace bf6;

static bool parse_guid(const std::string& s, TypeGuid& out)
{
    // "eec133de-42e8-cfb5-ce15-c428de4d2f08" -> the same 16 bytes the file holds:
    // first three groups little-endian, the rest byte order as written.
    unsigned a = 0, b = 0, c = 0, d0 = 0, d1 = 0;
    unsigned e[6] = {0};
    if (std::sscanf(s.c_str(), "%8x-%4x-%4x-%2x%2x-%2x%2x%2x%2x%2x%2x",
            &a, &b, &c, &d0, &d1, &e[0], &e[1], &e[2], &e[3], &e[4], &e[5]) != 11)
        return false;
    out[0] = (uint8_t)(a & 0xFF);  out[1] = (uint8_t)((a >> 8) & 0xFF);
    out[2] = (uint8_t)((a >> 16) & 0xFF); out[3] = (uint8_t)((a >> 24) & 0xFF);
    out[4] = (uint8_t)(b & 0xFF);  out[5] = (uint8_t)((b >> 8) & 0xFF);
    out[6] = (uint8_t)(c & 0xFF);  out[7] = (uint8_t)((c >> 8) & 0xFF);
    out[8] = (uint8_t)d0; out[9] = (uint8_t)d1;
    for (int i = 0; i < 6; i++) out[10 + i] = (uint8_t)e[i];
    return true;
}

int main(int argc, char** argv)
{
    if (argc < 3)
    {
        std::fprintf(stderr, "usage: types_test <exe> <guid-list> [--fields]\n");
        return 2;
    }
    const bool want_fields = (argc > 3 && std::strcmp(argv[3], "--fields") == 0);

    TypeDb db;
    std::string err;
    if (!db.open(argv[1], err))
    {
        std::fprintf(stderr, "open failed: %s\n", err.c_str());
        return 1;
    }

    double bits = 0.0, zeros = 0.0;
    db.entropy(bits, zeros);
    std::fprintf(stderr,
        "typeinfo %s, %llu bytes, exe %llu bytes, entropy %.2f bits (%.1f%% zero)\n",
        db.typeinfo_found() ? "found" : "MISSING",
        (unsigned long long)db.typeinfo_size(), (unsigned long long)db.file_size(),
        bits, zeros);

    std::ifstream list(argv[2]);
    if (!list) { std::fprintf(stderr, "cannot read %s\n", argv[2]); return 2; }

    std::string line;
    int n = 0, hit = 0;
    while (std::getline(list, line))
    {
        while (!line.empty() && (line.back() == '\r' || line.back() == '\n')) line.pop_back();
        if (line.empty() || line[0] == '#') continue;
        TypeGuid g;
        if (!parse_guid(line, g)) continue;
        n++;

        const TypeLayout& L = db.layout_full(g);
        if (!L.valid) { std::printf("T %s MISS\n", line.c_str()); continue; }
        hit++;
        std::printf("T %s %08x %04x %u %u %u %u %08x %llx %zu\n",
            line.c_str(), L.name_hash, L.flags, (unsigned)L.size, (unsigned)L.align,
            (unsigned)L.type_enum, (unsigned)L.field_count, L.signature,
            (unsigned long long)L.super_va, L.fields.size());
        if (want_fields)
            for (const FieldInfo& f : L.fields)
                std::printf("F %s %08x %04x %u %llx\n", line.c_str(),
                    f.name_hash, f.flags, f.offset, (unsigned long long)f.type_va);
    }

    std::fprintf(stderr, "%d guid(s): %d resolved, %d missed. %d search(es), %d whole-file fallback(s).\n",
        n, hit, db.misses(), db.searches(), db.fallbacks());
    return 0;
}
