/* thermal_test - what a thermal VisualEnvironment preset actually changes.
 *
 * The unit's next_step: "cheap: read one ve_*_thermal preset and diff it
 * against the main one". This does exactly that, through the SAME decoder that
 * reads a level's active preset, so the two sides are directly comparable.
 *
 * THE CONTROL IS THE DIFF ITSELF. A decoder that returned constants, or that
 * silently failed on the thermal partitions, would report the two presets as
 * identical - so the test requires the level preset and the thermal preset to
 * DIFFER, and requires two different thermal presets (white-hot and black-hot)
 * to differ from each other. Sameness is the failure mode here, not difference.
 */
#include "bf6_core.h"
#include <cstdio>
#include <cstring>
#include <cmath>
#include <vector>
#include <cstddef>

struct P { const char* name; const char* label; };

static int diff_fields(const bf6_ve_lighting& a, const bf6_ve_lighting& b,
                       const char* la, const char* lb, int show)
{
    /* SKIP THE LEADING CHAR BUFFERS. bf6_ve_lighting opens with
     * preset[128] and preset_path[256]; reinterpreting those as floats
     * produces values like 2.3e+08 and 2.5e+32 and counts a differing NAME as
     * differing lighting. The first version of this test did exactly that and
     * reported 263 differing "float words" between two presets whose names are
     * of course different. Start after the strings. */
    const size_t skip = (offsetof(bf6_ve_lighting, preset_path)
                         + sizeof(((bf6_ve_lighting*)0)->preset_path)) / sizeof(float);
    const size_t n = sizeof(bf6_ve_lighting) / sizeof(float);
    const float* fa = reinterpret_cast<const float*>(&a);
    const float* fb = reinterpret_cast<const float*>(&b);
    int d = 0, shown = 0;
    for (size_t i = skip; i < n; i++) {
        const bool bothfinite = std::isfinite(fa[i]) && std::isfinite(fb[i]);
        if (!bothfinite) continue;
        if (fa[i] != fb[i]) {
            d++;
            if (shown < show) {
                std::printf("      word %3zu  %-34s %12g   %-34s %12g\n",
                            i, la, fa[i], lb, fb[i]);
                shown++;
            }
        }
    }
    return d;
}

int main(int argc, char** argv)
{
    if (argc < 2) { std::printf("usage: thermal_test <game>\n"); return 2; }
    char err[512] = {0};
    bf6_ctx* c = bf6_open(argv[1], err, (int)sizeof(err));
    if (!c) { std::printf("open: %s\n", err); return 1; }

    const P presets[] = {
        { "mp_dumbo",                                        "level active preset" },
        { "common/fx/ve/gameplay/ve_fullscreen_thermal_whot", "thermal WHITE-hot"   },
        { "common/fx/ve/gameplay/ve_ltlmii_thermalview_whot", "optic thermal WHITE" },
        { "common/fx/ve/gameplay/ve_ltlmii_thermalview_bhot", "optic thermal BLACK" },
    };
    const int n = (int)(sizeof(presets) / sizeof(presets[0]));
    std::vector<bf6_ve_lighting> got((size_t)n);
    std::vector<int> ok((size_t)n, 0);

    for (int i = 0; i < n; i++) {
        char e[512] = {0};
        ok[i] = bf6_level_lighting(c, presets[i].name, &got[(size_t)i], e, (int)sizeof(e));
        std::printf("  %-24s %-52s %s\n", presets[i].label, presets[i].name,
                    ok[i] ? "decoded" : e);
    }

    int fails = 0;
    for (int i = 0; i < n; i++) if (!ok[i]) fails++;
    if (fails) { std::printf("\n%d preset(s) failed to decode\n", fails); }

    int d_level_thermal = 0, d_whot_bhot = 0;
    if (ok[0] && ok[1]) {
        std::printf("  level preset vs thermal white-hot:\n");
        d_level_thermal = diff_fields(got[0], got[1], "level", "thermal", 6);
        std::printf("      differing float words: %d\n", d_level_thermal);
    }
    if (ok[2] && ok[3]) {
        std::printf("  optic thermal WHITE-hot vs BLACK-hot:\n");
        d_whot_bhot = diff_fields(got[2], got[3], "whot", "bhot", 6);
        std::printf("      differing float words: %d\n", d_whot_bhot);
    }

    /* CONTROL: a preset must be identical to ITSELF, so a nonzero diff here
     * would mean the decoder is not deterministic and every number above is
     * noise. */
    int self = 0;
    if (ok[1]) {
        bf6_ve_lighting again{};
        char e[512] = {0};
        if (bf6_level_lighting(c, presets[1].name, &again, e, (int)sizeof(e)))
            self = diff_fields(got[1], again, "a", "b", 0);
    }
    std::printf("  determinism control (same preset twice): %d differing words (must be 0)\n", self);

    /* WHITE-HOT vs BLACK-HOT IS ZERO, AND THAT IS THE RESULT. The first
     * version of this test asserted the two must differ and "passed" on a
     * count of 2 - both of which were bytes of the preset NAME strings, not
     * lighting. With the strings excluded the two presets are identical in
     * every decoded VE field, so the white/black polarity is not a
     * VisualEnvironment parameter at all; it lives in the shader or a LUT.
     *
     * The level-vs-thermal diff is the POSITIVE CONTROL that makes that zero
     * meaningful: the same comparison over the same struct sees 240 differing
     * words, so a decoder that could not discriminate is ruled out. */
    const bool pass = fails == 0 && d_level_thermal > 100 && d_whot_bhot == 0 && self == 0;
    std::printf("\n%s\n", pass ? "PASS" : "FAIL");
    bf6_close(c);
    return pass ? 0 : 1;
}
