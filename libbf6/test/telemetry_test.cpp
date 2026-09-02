/* telemetry_test - read every game mode's scoring telemetry enum in ONE mount.
 *
 * CONTROLS:
 *   1. a fabricated asset name must return nothing;
 *   2. every member must have a non-empty name and the set must be free of
 *      duplicates within a mode - a mis-selected instance would repeat one;
 *   3. values must form a contiguous 0..n-1 set once sorted, which is what an
 *      enum is; a wrong instance filter breaks that immediately.
 */
#include <cstdio>
#include <cstring>
#include <set>
#include <string>
#include <vector>
#include "bf6_core.h"

int main(int argc, char** argv)
{
    if (argc < 2) { std::printf("usage: telemetry_test <game> [asset...]\n"); return 2; }
    char err[256] = {0};
    bf6_ctx* c = bf6_open(argv[1], err, sizeof(err));
    if (!c) { std::printf("open: %s\n", err); return 1; }
    if (!bf6_mount_all(c, 1, err, sizeof(err))) { std::printf("mount: %s\n", err); return 1; }

    const char* modes[] = {
        /* the shipped list, read from gamemodescoringsettings/ rather than guessed */
        "bt", "cq", "domination", "escalation", "koth", "operation",
        "payload", "rush", "sabotage", "squaddm", "strikepoint", "teamdm"
    };
    int found = 0, total_members = 0, bad_name = 0, dup = 0, noncontig = 0;
    for (const char* m : modes) {
        char path[256];
        std::snprintf(path, sizeof(path),
                      "common/telemetry/gamemodescoringsettings/%s_scoringtelemetryenum", m);
        bf6_telemetry_enum* e = bf6_telemetry_enum_read(c, path);
        if (!e) continue;
        found++; total_members += e->count;
        std::set<std::string> names; std::set<int> vals;
        for (int i = 0; i < e->count; i++) {
            const bf6_telemetry_member& mem = e->members[i];
            if (!mem.name || !*mem.name) bad_name++;
            else if (!names.insert(mem.name).second) dup++;
            vals.insert(mem.value);
        }
        bool contig = true;
        int want = 0;
        for (int v : vals) { if (v != want++) { contig = false; break; } }
        if (!contig) noncontig++;
        std::printf("  %-14s members=%-3d values %s  ", m, e->count,
                    contig ? "0..n-1 " : "NONCONTIG");
        for (int i = 0; i < e->count && i < 6; i++)
            std::printf("%s(%d) ", e->members[i].name, e->members[i].value);
        std::printf("\n");
    }

    /* Does the same reader generalise to a DIFFERENT enum family? The round
     * folder ships <mode>roundreasontelemetryenum assets. If the member record
     * is shared, these read with no change. */
    const char* rounds[] = {"escalation", "payload", "strikepoint"};
    int round_found = 0;
    for (const char* r : rounds) {
        char path[256];
        std::snprintf(path, sizeof(path), "common/telemetry/round/%sroundreasontelemetryenum", r);
        bf6_telemetry_enum* e = bf6_telemetry_enum_read(c, path);
        if (!e) { std::printf("  round %-12s NOT READ\n", r); continue; }
        round_found++; total_members += e->count;
        std::printf("  round %-12s members=%-3d  ", r, e->count);
        for (int i = 0; i < e->count && i < 6; i++)
            std::printf("%s(%d) ", e->members[i].name, e->members[i].value);
        std::printf("\n");
    }

    /* control: fabricated names */
    const char* fake[] = {
        "common/telemetry/gamemodescoringsettings/notarealmode_scoringtelemetryenum",
        "common/telemetry/gamemodescoringsettings/cq_scoringtelemetryenum_BOGUS"
    };
    int fake_hits = 0;
    for (const char* f : fake) {
        bf6_telemetry_enum* e = bf6_telemetry_enum_read(c, f);
        if (e && e->count > 0) fake_hits++;
        std::printf("  CONTROL %-62s %s\n", f, e ? (e->count ? "RESOLVED (BAD)" : "empty") : "null");
    }

    std::printf("\n  modes read       %d of %d\n", found, (int)(sizeof(modes)/sizeof(*modes)));
    std::printf("  members total    %d\n", total_members);
    std::printf("  empty names      %d   duplicates %d   non-contiguous %d\n", bad_name, dup, noncontig);
    std::printf("  fake resolved    %d  (must be 0)\n", fake_hits);
    std::printf("  round-reason enums read %d of 3 with the SAME reader\n", round_found);
    const bool pass = found > 0 && total_members > 0 && !bad_name && !dup && !noncontig && !fake_hits;
    std::printf("\n  => %s\n", pass ? "PASS" : "FAIL");
    bf6_close(c);
    return pass ? 0 : 1;
}
