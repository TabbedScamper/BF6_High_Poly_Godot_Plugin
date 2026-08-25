// How large does the tint MULTIPLIER get on records that have a colour sheet?
// A consumer that binds it straight into a colour tint blows the sheet out.
#include "bf6_core.h"
#include <cstdio>
#include <vector>
int main(int argc, char** argv)
{
    if (argc < 3) { std::printf("usage: <game_dir> <level> [exe]\n"); return 2; }
    char err[512] = {0};
    bf6_ctx* c = bf6_open(argv[1], err, (int)sizeof(err));
    if (!c) { std::printf("open failed: %s\n", err); return 1; }
    bf6_open_level(c, argv[2], argc > 3 ? argv[3] : nullptr, 0, err, (int)sizeof(err));
    const int n = bf6_level_decals(c, argv[2], nullptr, 0);
    std::vector<bf6_decal> v((size_t)(n > 0 ? n : 1));
    const int got = n > 0 ? bf6_level_decals(c, argv[2], v.data(), n) : 0;
    int sheetTint = 0, over1 = 0, over4 = 0, over1Deck = 0;
    float mx = 0.f;
    for (int i = 0; i < got; i++)
    {
        const bf6_decal& d = v[(size_t)i];
        if (d.albedo < 0 || !d.has_tint) continue;
        sheetTint++;
        float m = d.tint[0];
        if (d.tint[1] > m) m = d.tint[1];
        if (d.tint[2] > m) m = d.tint[2];
        if (m > mx) mx = m;
        if (m > 1.f)
        {
            over1++;
            if (m > 4.f) over4++;
            if (d.aabb_min[1] > 90.f)
            {
                over1Deck++;
                if (over1Deck <= 8)
                    std::printf("  BLOWN slot %-4d tint (%7.3f %7.3f %7.3f)  y %6.1f  x %8.1f z %8.1f\n",
                                d.asset_slot, d.tint[0], d.tint[1], d.tint[2],
                                d.aabb_min[1], d.aabb_min[0], d.aabb_min[2]);
            }
        }
    }
    std::printf("\n  records with a sheet AND a tint : %d\n", sheetTint);
    std::printf("  ...tint exceeds 1.0             : %d\n", over1);
    std::printf("  ...tint exceeds 4.0             : %d\n", over4);
    std::printf("  ...of the >1.0, above y=90      : %d\n", over1Deck);
    std::printf("  largest tint channel on level   : %.3f\n", mx);
    bf6_close(c);
    return 0;
}
