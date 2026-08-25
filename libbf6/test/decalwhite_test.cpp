// Which decal records would a consumer draw as a SOLID quad?
//
// The add-on paints a record that has no colour SHEET but does carry an
// authored colour constant. That is right, but it only works if the record
// also binds a COVERAGE mask: with no mask the opacity sampler falls back to
// white, coverage is 1 everywhere, and the result is a solid rectangle in the
// tint colour instead of a shape. Near-white tints then read as white boxes.
#include "bf6_core.h"
#include <cstdio>
#include <vector>

int main(int argc, char** argv)
{
    if (argc < 3) { std::printf("usage: decalwhite_test <game_dir> <level> [exe]\n"); return 2; }
    char err[512] = { 0 };
    bf6_ctx* c = bf6_open(argv[1], err, (int)sizeof(err));
    if (!c) { std::printf("open failed: %s\n", err); return 1; }
    if (bf6_open_level(c, argv[2], argc > 3 ? argv[3] : nullptr, 0,
                       err, (int)sizeof(err)) != 0)
        std::printf("note: open_level said %s\n", err);

    const int n = bf6_level_decals(c, argv[2], nullptr, 0);
    if (n <= 0) { std::printf("no decals (%d)\n", n); return 0; }
    std::vector<bf6_decal> v((size_t)n);
    const int got = bf6_level_decals(c, argv[2], v.data(), n);

    int painted = 0, paintedNoMask = 0, sheetNoDecode = 0, solidRisk = 0;
    float wr = 0, wg = 0, wb = 0;
    std::printf("%s: %d decal record(s)\n", argv[2], got);
    std::printf("\nrecords the add-on now PAINTS (no sheet, but a tint):\n");
    for (int i = 0; i < got; i++)
    {
        const bf6_decal& d = v[(size_t)i];
        if (d.albedo >= 0) continue;
        if (!d.has_tint && !d.has_tint2) continue;
        painted++;
        const float* T = d.has_tint ? d.tint : d.tint2;
        if (d.opacity < 0)
        {
            paintedNoMask++;
            // A bright tint with no mask is the one that reads as white.
            const float lum = 0.2126f * T[0] + 0.7152f * T[1] + 0.0722f * T[2];
            if (lum > 0.5f)
            {
                solidRisk++;
                if (solidRisk <= 8)
                    std::printf("  SOLID slot %-4d tint (%.3f %.3f %.3f) lum %.2f  "
                                "aabb y %.1f..%.1f\n",
                                d.asset_slot, T[0], T[1], T[2], lum,
                                d.aabb_min[1], d.aabb_max[1]);
                wr += T[0]; wg += T[1]; wb += T[2];
            }
        }
    }
    // The other way to get a solid quad: a record that HAS a colour sheet but
    // binds no coverage mask. The opacity sampler then falls back to white,
    // coverage reads 1 everywhere, and the whole rectangle draws.
    int sheetNoMask = 0, sheetNoMaskHigh = 0;
    std::printf("\nrecords WITH a colour sheet but NO coverage mask:\n");
    for (int i = 0; i < got; i++)
    {
        const bf6_decal& d = v[(size_t)i];
        if (d.albedo < 0 || d.opacity >= 0) continue;
        sheetNoMask++;
        // Carrier decks on this level sit at and above about y = 100.
        if (d.aabb_min[1] > 90.f)
        {
            sheetNoMaskHigh++;
            if (sheetNoMaskHigh <= 10)
                std::printf("  slot %-4d y %7.1f..%7.1f  x %8.1f  z %8.1f  ao %d nrm %d chan %d\n",
                            d.asset_slot, d.aabb_min[1], d.aabb_max[1],
                            d.aabb_min[0], d.aabb_min[2], d.ao, d.normal, d.mask_channel);
        }
    }
    std::printf("  total with a sheet and no mask   %d\n", sheetNoMask);
    std::printf("  ...of those above y=90 (decks)   %d\n", sheetNoMaskHigh);

    std::printf("\n  painted total          %d\n", painted);
    std::printf("  ...of those NO mask    %d   <- drawn as a solid rectangle\n", paintedNoMask);
    std::printf("  ...and bright with it  %d   <- these read as WHITE\n", solidRisk);
    if (solidRisk)
        std::printf("  mean bright tint       (%.3f %.3f %.3f)\n",
                    wr / solidRisk, wg / solidRisk, wb / solidRisk);
    bf6_close(c);
    return 0;
}
