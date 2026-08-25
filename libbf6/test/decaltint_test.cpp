// Is a decal's authored colour a MULTIPLIER or the colour ITSELF?
//
// The claim under test is that one field means two things depending on whether
// a colour sheet is bound: a multiplier over the sheet when there is one, and
// the absolute colour when there is not. If that is right, the two populations
// must separate on how often the value exceeds 1.0 - a multiplier is free to,
// an absolute linear colour essentially never does.
//
// Also prints the packed-mask channel histogram, which should be capped at four
// distinct values because the sheets are four-channel atlases.
#include "bf6_core.h"
#include <cstdio>
#include <vector>

int main(int argc, char** argv)
{
    if (argc < 3) { std::printf("usage: decaltint_test <game_dir> <level> [exe]\n"); return 2; }
    char err[512] = { 0 };
    bf6_ctx* c = bf6_open(argv[1], err, (int)sizeof(err));
    if (!c) { std::printf("open failed: %s\n", err); return 1; }
    // Returns 0 on SUCCESS, and a failure is advisory: the decal resource only
    // needs the archives mounted. On the installed build the walk stops at the
    // encrypted type table and the mount is still good.
    if (bf6_open_level(c, argv[2], argc > 3 ? argv[3] : nullptr, 0,
                       err, (int)sizeof(err)) != 0)
        std::printf("note: open_level said %s; continuing on the mount alone\n", err);

    const int n = bf6_level_decals(c, argv[2], nullptr, 0);
    if (n <= 0) { std::printf("%s: no decal records (%d)\n", argv[2], n); return 0; }
    std::vector<bf6_decal> rows((size_t)n);
    const int got = bf6_level_decals(c, argv[2], rows.data(), n);

    int coloured = 0, colourless = 0;
    int t1_col = 0, t1_nocol = 0, t2_col = 0, t2_nocol = 0;
    int over1_col = 0, over1_nocol = 0;
    float max_col = 0.f, max_nocol = 0.f;
    int mask = 0, ao = 0, bare = 0, chan[5] = { 0, 0, 0, 0, 0 };

    for (int i = 0; i < got; i++)
    {
        const bf6_decal& d = rows[(size_t)i];
        const bool has_sheet = d.albedo >= 0;
        if (has_sheet) coloured++; else colourless++;

        if (d.has_tint)
        {
            (has_sheet ? t1_col : t1_nocol)++;
            for (int k = 0; k < 3; k++)
            {
                const float v = d.tint[k];
                if (has_sheet) { if (v > max_col) max_col = v; }
                else           { if (v > max_nocol) max_nocol = v; }
            }
            const bool over = d.tint[0] > 1.f || d.tint[1] > 1.f || d.tint[2] > 1.f;
            if (over) (has_sheet ? over1_col : over1_nocol)++;
        }
        if (d.has_tint2) (has_sheet ? t2_col : t2_nocol)++;

        if (!has_sheet)
        {
            if (d.opacity >= 0) mask++;
            if (d.ao >= 0) ao++;
            if (d.opacity < 0 && d.ao < 0 && !d.has_tint && !d.has_tint2) bare++;
        }
        chan[(d.mask_channel >= 0 && d.mask_channel <= 3) ? d.mask_channel + 1 : 0]++;
    }

    std::printf("%s: %d record(s), %d with a colour sheet, %d without\n",
                argv[2], got, coloured, colourless);
    std::printf("  tint  present: %4d with a sheet, %4d without\n", t1_col, t1_nocol);
    std::printf("  tint2 present: %4d with a sheet, %4d without   (expected ~0 with)\n",
                t2_col, t2_nocol);
    std::printf("  MULTIPLIER TEST, share of tinted records with any channel over 1.0:\n");
    if (t1_col)   std::printf("    with a sheet: %5.1f%%  (max channel %.3f)\n",
                              100.0 * over1_col / t1_col, max_col);
    if (t1_nocol) std::printf("    without     : %5.1f%%  (max channel %.3f)\n",
                              100.0 * over1_nocol / t1_nocol, max_nocol);
    std::printf("  colourless records carrying: mask %d, ao %d, nothing at all %d\n",
                mask, ao, bare);
    std::printf("  packed mask channel: unset %d, 0:%d 1:%d 2:%d 3:%d\n",
                chan[0], chan[1], chan[2], chan[3], chan[4]);
    bf6_close(c);
    return 0;
}
