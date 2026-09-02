/* wavesel_test - how a sound picks its next variation.
 *
 * CONTROLS:
 *   1. THE ROLE RULE IS ASSERTED, not described: every `_fx_` asset must come
 *      back Random with history 3 and randomise true, and every `_areas_` asset
 *      must come back Rank with history 100 and randomise false. Three
 *      parameters switch together on the same boundary, so a misread of any one
 *      breaks the assertion.
 *   2. HISTORY IS A UInt32 READ RAW. Taking a 32-bit field through a float
 *      accessor silently corrupts it - that bug cost a session's confidence in
 *      a correct hash finding - so 100 must come back as exactly 100.
 *   3. A fabricated asset name returns nothing.
 */
#include <cstdio>
#include <cstring>
#include "bf6_core.h"

struct E { const char* path; int role; };  /* 0 = fx, 1 = area */

int main(int argc, char** argv) {
    if (argc < 2) { std::printf("usage: wavesel_test <game>\n"); return 2; }
    char err[256] = {0};
    bf6_ctx* ctx = bf6_open(argv[1], err, sizeof(err));
    if (!ctx) { std::printf("open: %s\n", err); return 1; }
    if (!bf6_mount_all(ctx, 1, err, sizeof(err))) { std::printf("mount: %s\n", err); return 1; }

    const char* B = "game/glaciermp/levels/mp_contaminated/sound/levels/aus/mp/contaminated/";
    const E real[] = {
        { "fx/bf03_fx_structural_stone_rubblefall_markers_01",                       0 },
        { "fx/bf03_fx_structural_stone_rockimpact-medium_markers_01",                0 },
        { "fx/bf03_fx_structural_stone_rockimpact-large_markers_01",                 0 },
        { "areas/exterior/bf03_levels_s2_mp_contaminated_areas_exterior-rocks_divisible_01", 1 },
        { "areas/exterior/bf03_levels_s2_mp_contaminated_areas_exterior-forest_divisible_01",1 },
    };
    int read = 0, violations = 0, fx = 0, area = 0;
    for (const E& e : real) {
        char path[640];
        std::snprintf(path, sizeof(path), "%s%s", B, e.path);
        bf6_wave_selection* w = bf6_wave_selection_read(ctx, path);
        if (!w || w->count < 1) { std::printf("  READ FAILED %s\n", e.path); violations++; continue; }
        const bf6_wave_selector& s = w->selectors[0];
        read++;
        const bool ok = e.role == 0
            ? (s.behavior == 0 && s.history_entry_count == 3   && s.randomize_candidates == 1)
            : (s.behavior == 1 && s.history_entry_count == 100 && s.randomize_candidates == 0);
        if (!ok) violations++;
        if (e.role == 0) fx++; else area++;
        std::printf("  %-58s %-6s %-7s hist %-4u rand %d  %s\n",
                    std::strrchr(e.path, '/') + 1, e.role ? "AREA" : "FX",
                    s.behavior == 0 ? "Random" : (s.behavior == 1 ? "Rank" : "none"),
                    s.history_entry_count, s.randomize_candidates, ok ? "ok" : "VIOLATES ROLE RULE");
        bf6_free(ctx, w);
    }
    int fake = bf6_wave_selection_read(ctx, "game/glaciermp/levels/mp_contaminated/sound/nope") ? 1 : 0;

    std::printf("\n  assets read      : %d of %d  (fx %d, area %d)\n", read, 5, fx, area);
    std::printf("  role violations  : %d   (must be 0 - FX Random/3/true, AREA Rank/100/false)\n", violations);
    std::printf("  fake name read   : %d   (must be 0)\n", fake);
    const bool pass = read == 5 && violations == 0 && !fake && fx == 3 && area == 2;
    std::printf("\n%s\n", pass ? "PASS" : "FAIL");
    bf6_close(ctx);
    return pass ? 0 : 1;
}
