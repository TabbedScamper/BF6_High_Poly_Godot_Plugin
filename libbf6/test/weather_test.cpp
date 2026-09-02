/* weather_test - the global weather variable database.
 *
 * CONTROLS:
 *   1. EXACT count: 21 variables, measured on the independent dump path.
 *   2. THE HASH IS RE-DERIVED, not trusted: every variable's stored NameHash
 *      must equal bf6_name_hash(its DebugName). This is a THIRD independent
 *      subsystem for that hash after footprint biome themes and telemetry
 *      members, and it runs against the installed game every time.
 *   3. FADE WINDOW SANITY: fade_low <= fade_high on every variable, and all
 *      three floats finite. A misread struct breaks the ordering immediately.
 *   4. THE VOCABULARY MUST CONTAIN THE STORM: Global_Storm_Active is the whole
 *      point of the unit - a storm is a variable, not an entity - so its
 *      presence is asserted rather than described.
 *   5. A fabricated asset name returns nothing.
 */
#include <cstdio>
#include <cstring>
#include <cmath>
#include "bf6_core.h"

int main(int argc, char** argv) {
    if (argc < 2) { std::printf("usage: weather_test <game>\n"); return 2; }
    char err[256] = {0};
    bf6_ctx* ctx = bf6_open(argv[1], err, sizeof(err));
    if (!ctx) { std::printf("open: %s\n", err); return 1; }
    if (!bf6_mount_all(ctx, 1, err, sizeof(err))) { std::printf("mount: %s\n", err); return 1; }

    bf6_weather* w = bf6_weather_read(ctx, "globals/weather/weatherstatevariabledatabase");
    if (!w) { std::printf("read failed\n"); return 1; }

    int hash_ok = 0, bad_fade = 0, named = 0;
    bool has_storm = false, has_lightning = false, has_wind = false;
    for (int i = 0; i < w->count; i++) {
        const bf6_weather_var& v = w->vars[i];
        const char* n = (v.name_index >= 0 && v.name_index < w->name_count)
                      ? w->names[v.name_index] : "";
        if (*n) named++;
        if (*n && bf6_name_hash(n) == v.name_hash) hash_ok++;
        if (!std::isfinite(v.default_value) || !std::isfinite(v.fade_low) ||
            !std::isfinite(v.fade_high) || v.fade_low > v.fade_high) bad_fade++;
        if (!std::strcmp(n, "Global_Storm_Active"))      has_storm = true;
        if (!std::strcmp(n, "Cont_HasLightningstrikes")) has_lightning = true;
        if (!std::strcmp(n, "GlobalWindTransition"))     has_wind = true;
        std::printf("  %-28s hash 0x%08X  default %-6g fade [%g, %g]\n",
                    n, v.name_hash, v.default_value, v.fade_low, v.fade_high);
    }
    int fake = bf6_weather_read(ctx, "globals/weather/nosuchdatabase") ? 1 : 0;

    std::printf("\n  variables            : %d   (must be 21)\n", w->count);
    std::printf("  named                : %d\n", named);
    std::printf("  NameHash == djb2exact: %d of %d   (must be all)\n", hash_ok, named);
    std::printf("  bad fade windows     : %d   (must be 0)\n", bad_fade);
    std::printf("  Global_Storm_Active  : %s   (a storm is a VARIABLE)\n", has_storm ? "present" : "MISSING");
    std::printf("  Cont_HasLightningstrikes / GlobalWindTransition : %s / %s\n",
                has_lightning ? "present" : "MISSING", has_wind ? "present" : "MISSING");
    std::printf("  fake name read       : %d   (must be 0)\n", fake);

    const bool pass = w->count == 21 && named == 21 && hash_ok == 21 &&
                      bad_fade == 0 && has_storm && has_lightning && has_wind && !fake;
    std::printf("\n%s\n", pass ? "PASS" : "FAIL");
    bf6_free(ctx, w);
    bf6_close(ctx);
    return pass ? 0 : 1;
}
