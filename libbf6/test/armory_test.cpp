// Build the armory in C++, straight from an install, and emit it for
// comparison against the Python pipeline's armory_db.json.
//
// The Python side is the ORACLE here, not a rival: it has been feeding a
// working previewer for months, so any disagreement is this port's bug until
// proven otherwise. Emitting JSON rather than asserting internally is
// deliberate - the comparison belongs in a script that can diff every row and
// say which ones moved, not in a pass/fail that hides the detail.
//
//   armory_test <game_dir> [--json out.json] [--costs] [--nolevels]
//
// --costs reads the point cost of every attachment. That is one decompressed
// read per row and it is the slow half, so it is opt-in.
#include "bf6_core.h"
#include "armory.h"

#include <cstdio>
#include <cstring>
#include <cstdlib>
#include <string>
#include <vector>
#include <map>

// Cost is Int32 at absolute file offset 0x80 of the attachment partition,
// verified against the reflected read on 5,502 of 5,502 rows. Reading it raw
// means the roster needs no type schema at all.
static const int64_t kCostOffset = 0x80;

static int32_t read_cost(bf6_ctx* c, const std::string& ebx)
{
    if (ebx.empty()) return -1;
    const uint8_t* p = nullptr;
    const int64_t n = bf6_read_raw(c, BF6_RAW_EBX, ebx.c_str(), &p);
    if (n < kCostOffset + 4 || !p) return -1;
    int32_t v = 0;
    std::memcpy(&v, p + kCostOffset, 4);
    return v;
}

static void json_escape(const std::string& s, std::string& out)
{
    for (char ch : s)
    {
        if (ch == '"' || ch == '\\') { out += '\\'; out += ch; }
        else if ((unsigned char)ch < 0x20) { char b[8]; std::snprintf(b, sizeof(b), "\\u%04x", ch); out += b; }
        else out += ch;
    }
}

int main(int argc, char** argv)
{
    if (argc < 2)
    {
        std::printf("usage: armory_test <game_dir> [--json out.json] [--costs]\n");
        return 2;
    }
    const char* game = argv[1];
    const char* jsonOut = nullptr;
    bool want_costs = false;
    // Levels ON by default. They more than double the mount (190,005 ebx
    // to 465,469) and cost time, but the armory is WRONG without them:
    // 315 compatibility rows ship only inside level archives, and their
    // absence is silent - the table just comes out short.
    int with_levels = 1;
    for (int i = 2; i < argc; i++)
    {
        if (!std::strcmp(argv[i], "--json") && i + 1 < argc) jsonOut = argv[++i];
        else if (!std::strcmp(argv[i], "--costs")) want_costs = true;
        else if (!std::strcmp(argv[i], "--nolevels")) with_levels = 0;
    }

    char err[512] = { 0 };
    bf6_ctx* c = bf6_open(game, err, (int)sizeof(err));
    if (!c) { std::printf("open failed: %s\n", err); return 1; }
    if (!bf6_mount_all(c, with_levels, err, (int)sizeof(err)))
    { std::printf("mount failed: %s\n", err); bf6_close(c); return 1; }

    // The slot vocabulary, read from the install rather than tabulated here.
    {
        const int ns = bf6_armory_slots(c, nullptr, 0);
        std::vector<bf6_armory_slot> slots(ns > 0 ? (size_t)ns : 0);
        const int gs = ns > 0 ? bf6_armory_slots(c, slots.data(), ns) : 0;
        std::printf("slot definitions   %d (read from the game, not hardcoded)\n", gs);
        int cos = 0;
        for (int i = 0; i < gs && i < (int)slots.size(); i++) if (slots[(size_t)i].cosmetic) cos++;
        std::printf("  cosmetic slots   %d\n", cos);
        for (int i = 0; i < gs && i < (int)slots.size(); i++)
            std::printf("   %-30s 0x%08x%s\n", slots[(size_t)i].name, slots[(size_t)i].id,
                        slots[(size_t)i].cosmetic ? "  cosmetic" : "");
        std::printf("\n");
    }

    const int total = bf6_list_ebx(c, nullptr, nullptr, 0);
    std::vector<bf6_asset> rows((size_t)total);
    const int got = bf6_list_ebx(c, nullptr, rows.data(), total);
    std::printf("mounted            %d ebx partitions\n", got);

    std::vector<std::string> names;
    names.reserve((size_t)got);
    for (int i = 0; i < got; i++)
        if (rows[(size_t)i].name) names.emplace_back(rows[(size_t)i].name);

    bf6::Armory a = bf6::armory_from_names(names);

    int64_t att = 0;
    for (const bf6::ArmoryWeapon& w : a.weapons) att += (int64_t)w.attachments.size();
    std::printf("armory             %d weapons, %lld attachments, %lld rows\n",
                (int)a.weapons.size(), (long long)att, (long long)a.rows);

    std::printf("slot codes seen    ");
    for (const std::string& s : a.slot_codes) std::printf("%s ", s.c_str());
    std::printf("\n");

    // By class, so a missing category is obvious at a glance.
    std::map<std::string, int> byCls;
    for (const bf6::ArmoryWeapon& w : a.weapons) byCls[w.cls]++;
    std::printf("\nby class:\n");
    for (const auto& kv : byCls) std::printf("  %-14s %d\n", kv.first.c_str(), kv.second);

    if (want_costs)
    {
        std::printf("\nreading costs (one decompressed read per row)...\n");
        int64_t read = 0, nonzero = 0, failed = 0;
        for (bf6::ArmoryWeapon& w : a.weapons)
            for (bf6::ArmoryAttachment& at : w.attachments)
            {
                at.cost = read_cost(c, at.ebx);
                if (at.cost < 0) failed++;
                else { read++; if (at.cost > 0) nonzero++; }
            }
        std::printf("  cost read on %lld rows, %lld non-zero, %lld unreadable\n",
                    (long long)read, (long long)nonzero, (long long)failed);
    }

    if (jsonOut)
    {
        std::string j = "{\n \"weapons\": {\n";
        bool firstW = true;
        for (const bf6::ArmoryWeapon& w : a.weapons)
        {
            if (!firstW) j += ",\n";
            firstW = false;
            j += "  \""; json_escape(w.cls + "/" + w.name, j); j += "\": {\n   \"slots\": {";
            bool firstS = true;
            for (const auto& sk : w.slots)
            {
                if (!firstS) j += ",";
                firstS = false;
                j += "\n    \""; json_escape(sk.first, j); j += "\": [";
                for (size_t i = 0; i < sk.second.size(); i++)
                {
                    if (i) j += ", ";
                    j += "\""; json_escape(sk.second[i], j); j += "\"";
                }
                j += "]";
            }
            j += "\n   },\n   \"costs\": {";
            bool firstC = true;
            for (const bf6::ArmoryAttachment& at : w.attachments)
            {
                if (at.cost < 0) continue;
                if (!firstC) j += ", ";
                firstC = false;
                j += "\""; json_escape(at.slot + "/" + at.name, j);
                j += "\": " + std::to_string(at.cost);
            }
            j += "}\n  }";
        }
        j += "\n }\n}\n";
        FILE* f = std::fopen(jsonOut, "wb");
        if (!f) { std::printf("could not write %s\n", jsonOut); bf6_close(c); return 1; }
        std::fwrite(j.data(), 1, j.size(), f);
        std::fclose(f);
        std::printf("\nwrote %s (%zu bytes)\n", jsonOut, j.size());
    }

    bf6_close(c);
    return a.weapons.empty() ? 1 : 0;
}
