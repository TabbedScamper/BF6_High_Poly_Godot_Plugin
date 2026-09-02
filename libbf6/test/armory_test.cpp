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
#include <chrono>
#include <cmath>

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
    bool want_prefix_census = false;
    bool want_dependency_control = false;
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
        else if (!std::strcmp(argv[i], "--prefix-census")) want_prefix_census = true;
        else if (!std::strcmp(argv[i], "--dependency-control")) want_dependency_control = true;
    }

    char err[512] = { 0 };
    bf6_ctx* c = bf6_open(game, err, (int)sizeof(err));
    if (!c) { std::printf("open failed: %s\n", err); return 1; }
    if (!bf6_mount_all(c, with_levels, err, (int)sizeof(err)))
    { std::printf("mount failed: %s\n", err); bf6_close(c); return 1; }

    bf6_armory_camera_mode overview{};
    bf6_armory_camera_mode fake_camera{};
    const bool camera_ok = bf6_armory_camera_mode_read(c, "weaponbehavior", &overview) != 0;
    const bool fake_camera_ok = bf6_armory_camera_mode_read(
        c, "__control_not_a_camera_mode", &fake_camera) != 0;
    const bool camera_lens_control = camera_ok &&
        std::fabs(overview.focal_length_mm - 35.0f) < 0.0001f &&
        std::fabs(overview.aperture - 1.05f) < 0.0001f &&
        std::fabs(overview.shutter - 3.0f) < 0.0001f &&
        std::fabs(overview.focus_distance - (-1.0f)) < 0.0001f;
    std::printf("armory camera      real=%d fake=%d anchor=%s look=%s pre=(%.6f %.6f %.6f) post=(%.6f %.6f %.6f) focal=%.3f aperture=%.3f shutter=%.3f focus=%.3f lenses=%d control=%d\n",
                camera_ok ? 1 : 0, fake_camera_ok ? 1 : 0,
                overview.anchor, overview.look_at,
                overview.pre_offset[0], overview.pre_offset[1], overview.pre_offset[2],
                overview.post_offset[0], overview.post_offset[1], overview.post_offset[2],
                overview.focal_length_mm, overview.aperture, overview.shutter,
                overview.focus_distance, overview.lens_candidates,
                camera_lens_control ? 1 : 0);

    // The slot vocabulary, read from the install rather than tabulated here.
    {
        const int ns = bf6_armory_slots(c, nullptr, 0);
        std::vector<bf6_armory_slot> slots(ns > 0 ? (size_t)ns : 0);
        const int gs = ns > 0 ? bf6_armory_slots(c, slots.data(), ns) : 0;
        std::printf("slot definitions   %d (read from the game, not hardcoded)\n", gs);
        int cos = 0;
        for (int i = 0; i < gs && i < (int)slots.size(); i++) if (slots[(size_t)i].is_player_facing) cos++;
        std::printf("  player-facing slots %d\n", cos);
        for (int i = 0; i < gs && i < (int)slots.size(); i++)
            std::printf("   %-30s 0x%08x%s\n", slots[(size_t)i].name, slots[(size_t)i].id,
                        slots[(size_t)i].is_player_facing ? "  IsPlayerFacing" : "");
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

    if (want_prefix_census)
    {
        static const char* needles[] = {
            "common/hardware", "common/gameplay", "common/ui", "common/characters",
            "-common/hardware", "-common/gameplay", "-common/ui", "-common/characters",
            "dpf_", "_mesh", "weapon", "wepatt", "projectile", "layerediconatlas"
        };
        std::printf("\npartition path substring census:\n");
        for (const char* needle : needles)
        {
            int count = 0;
            for (const std::string& name : names) if (name.find(needle) != std::string::npos) count++;
            std::printf("  %-28s %d\n", needle, count);
        }
    }

    int64_t att = 0;
    for (const bf6::ArmoryWeapon& w : a.weapons) att += (int64_t)w.attachments.size();
    std::printf("armory             %d weapons, %lld attachments, %lld rows\n",
                (int)a.weapons.size(), (long long)att, (long long)a.rows);

    if (want_dependency_control)
    {
        auto t0 = std::chrono::steady_clock::now();
        const int nai = bf6_armory_partition_index(c, nullptr, 0);
        const double armory_index_s = std::chrono::duration<double>(
            std::chrono::steady_clock::now() - t0).count();
        std::vector<bf6_partition> airows((size_t)nai);
        bf6_armory_partition_index(c, airows.data(), nai);
        std::map<std::string, std::string> armory_index;
        for (const bf6_partition& row : airows)
            if (row.guid && row.name) armory_index[row.guid] = row.name;

        t0 = std::chrono::steady_clock::now();
        const int ni = bf6_partition_index(c, nullptr, 0);
        const double index_s = std::chrono::duration<double>(
            std::chrono::steady_clock::now() - t0).count();
        std::vector<bf6_partition> irows((size_t)ni);
        bf6_partition_index(c, irows.data(), ni);
        int alias_mismatch = 0;
        std::vector<std::string> alias_examples;
        for (const bf6_partition& row : irows)
        {
            if (!row.guid || !row.name) continue;
            const auto it = armory_index.find(row.guid);
            if (it != armory_index.end() && it->second != row.name)
            {
                alias_mismatch++;
                if (alias_examples.size() < 20)
                    alias_examples.push_back(std::string(row.guid) + " target=" +
                                             it->second + " full=" + row.name);
            }
        }
        int weapons_with_md = 0, decoded = 0, meshes = 0, outside = 0;
        int stats_attempted = 0, stats_resolved = 0;
        int ui_attempted = 0, ui_resolved = 0;
        std::map<std::string, int> outside_paths;
        for (const bf6::ArmoryWeapon& w : a.weapons)
        {
            const std::string query = "md_" + w.name;
            const int nr = bf6_list_ebx(c, query.c_str(), nullptr, 0);
            if (nr <= 0) continue;
            std::vector<bf6_asset> rr((size_t)nr);
            const int ng = bf6_list_ebx(c, query.c_str(), rr.data(), nr);
            std::string mdp;
            for (int i = 0; i < ng; i++)
            {
                const std::string nm = rr[(size_t)i].name ? rr[(size_t)i].name : "";
                if (nm.find("/md_") == std::string::npos ||
                    nm.find("_bundle") != std::string::npos) continue;
                if (mdp.empty() || nm.size() < mdp.size()) mdp = nm;
            }
            if (mdp.empty()) continue;
            weapons_with_md++;
            std::vector<bf6_weapon_part> parts(256);
            const int np = bf6_weapon_default_parts(c, mdp.c_str(), parts.data(),
                                                    (int)parts.size());
            if (np < 0 || np > (int)parts.size()) continue;
            decoded++;
            for (int i = 0; i < np; i++)
            {
                const std::string path = parts[(size_t)i].mesh ? parts[(size_t)i].mesh : "";
                meshes++;
                const bool candidate =
                    path.find("common/hardware") != std::string::npos ||
                    path.find("common/gameplay") != std::string::npos ||
                    path.find("common/ui") != std::string::npos ||
                    path.find("weapon") != std::string::npos ||
                    path.find("projectile") != std::string::npos;
                if (!candidate) { outside++; outside_paths[path]++; }
            }

            static const char* stat_classes[] = {
                "assaultrifle", "carbine", "dmr", "boltaction", "mg", "smg",
                "secondary", "shotgun", "battlepickup", "battlepickups"
            };
            bool firearm = false;
            for (const char* cls : stat_classes) if (w.cls == cls) { firearm = true; break; }
            if (firearm)
            {
                bf6_weapon_base_stats stats{};
                stats_attempted++;
                if (bf6_base_weapon_stats(c, w.cls.c_str(), w.name.c_str(), &stats))
                    stats_resolved++;
                bf6_weapon_ui_info ui{};
                ui_attempted++;
                if (bf6_weapon_ui_info_read(c, w.name.c_str(), &ui)) ui_resolved++;
            }
        }
        std::printf("\ndependency filter control (full index is oracle):\n");
        std::printf("  armory index        %d partitions in %.3f s\n", nai, armory_index_s);
        std::printf("  full index          %d partitions in %.3f s\n", ni, index_s);
        std::printf("  shared-guid names   %d candidate/full mismatches\n", alias_mismatch);
        for (const std::string& ex : alias_examples) std::printf("    %s\n", ex.c_str());
        std::printf("  model definitions   %d found, %d decoded\n", weapons_with_md, decoded);
        std::printf("  resolved mesh refs  %d real, %d outside candidate\n", meshes, outside);
        std::printf("  base stats          %d/%d resolved\n", stats_resolved, stats_attempted);
        std::printf("  weapon UI info      %d/%d resolved\n", ui_resolved, ui_attempted);
        for (const auto& kv : outside_paths)
            std::printf("    OUTSIDE x%-3d %s\n", kv.second, kv.first.c_str());
    }

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
    return a.weapons.empty() || !camera_ok || fake_camera_ok || !camera_lens_control ? 1 : 0;
}
