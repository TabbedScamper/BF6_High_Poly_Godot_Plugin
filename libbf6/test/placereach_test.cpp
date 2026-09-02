/* placereach_test - WHAT DOES THE PLACEMENT GRAPH ACTUALLY REACH?
 *
 * `static-placements-prefabs` came out of a connectivity audit as one of ten
 * ISOLATED units - no finding shared with any other unit - despite being
 * `implemented` and map_value 5. Placements are the graph a level is made of,
 * so isolation is a claim worth testing rather than accepting.
 *
 * This classifies every placement's owning partition by path family. If the
 * placement walk only ever reached art, the unit really would be a leaf. If it
 * reaches gamemodes, schematics, UI and hardware, then it is a hub and the
 * isolation was bookkeeping.
 */
#include "bf6_core.h"
#include <cstdio>
#include <cstring>
#include <map>
#include <string>
#include <vector>

static const char* family(const char* p)
{
    if (!p) return "(none)";
    struct R { const char* needle; const char* name; };
    static const R rules[] = {
        { "/gamemodes/",   "gameplay: gamemodes"   },
        { "_schematic",    "gameplay: schematics"  },
        { "/modbuilder/",  "gameplay: modbuilder"  },
        { "/gameplay/",    "gameplay: misc"        },
        { "/ui/",          "ui"                    },
        { "/hardware/",    "hardware (weapons/vehicles)" },
        { "/characters/",  "characters"            },
        { "/fx/",          "fx"                    },
        { "/sound/",       "audio"                 },
        { "/environment/", "art: environment"      },
        { "/levels/",      "art: level layers"     },
        { "/animations/",  "animation"             },
    };
    for (const R& r : rules) if (std::strstr(p, r.needle)) return r.name;
    return "other";
}

int main(int argc, char** argv)
{
    if (argc < 3) { std::printf("usage: placereach_test <game> <level-root-ebx>\n"); return 2; }
    char err[512] = {0};
    bf6_ctx* c = bf6_open(argv[1], err, (int)sizeof(err));
    if (!c) { std::printf("open: %s\n", err); return 1; }
    if (!bf6_mount_all(c, 1, err, (int)sizeof(err))) { std::printf("mount: %s\n", err); return 1; }

    const int n = bf6_asset_instances(c, argv[2], nullptr, 0, err, (int)sizeof(err));
    if (n <= 0) { std::printf("walk: %s\n", err[0] ? err : "no placements"); return 1; }
    std::vector<bf6_instance> rows((size_t)n);
    if (bf6_asset_instances(c, argv[2], rows.data(), n, err, (int)sizeof(err)) != n) {
        std::printf("second read changed count\n"); return 1;
    }

    std::map<std::string, int> fam;
    int with_source = 0;
    for (const bf6_instance& r : rows) {
        if (r.source) with_source++;
        fam[family(r.source)]++;
    }
    std::printf("  placements %d   with a source partition %d\n", n, with_source);
    int gameplay = 0, art = 0;
    for (const auto& kv : fam) {
        std::printf("    %-32s %6d\n", kv.first.c_str(), kv.second);
        if (kv.first.rfind("gameplay", 0) == 0) gameplay += kv.second;
        if (kv.first.rfind("art", 0) == 0) art += kv.second;
    }
    std::printf("  reaching GAMEPLAY partitions: %d   ART partitions: %d\n", gameplay, art);

    /* CONTROL: the walk must be deterministic and must reject a fake root. */
    char e2[512] = {0};
    const int fake = bf6_asset_instances(c, "game/glaciermp/levels/mp_nowhere/mp_nowhere",
                                         nullptr, 0, e2, (int)sizeof(e2));
    std::printf("  fabricated level root placements: %d (must be <= 0)\n", fake);

    const bool pass = n > 1000 && gameplay > 0 && art > 0 && fake <= 0;
    std::printf("\n%s\n", pass ? "PASS" : "FAIL");
    bf6_close(c);
    return pass ? 0 : 1;
}
