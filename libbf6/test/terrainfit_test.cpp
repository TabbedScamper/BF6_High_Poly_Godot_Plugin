/* DOES THE REBUILT GROUND SIT WHERE THE MAP THINKS THE GROUND IS?
 *
 * Not shipped. A terrain that is uniformly too low looks exactly like a
 * terrain that is correct and a camera that is too high, and neither the
 * heightfield nor the placements can settle it alone. Together they can:
 * most props REST ON THE GROUND, so for a large enough sample the difference
 *
 *     placement origin y  -  terrain height under that placement
 *
 * is a distribution piled at zero. Its median is the vertical bias of the
 * rebuild, signed so that a positive number means the ground was built too
 * LOW (props float above it).
 *
 * The median rather than the mean, because the tail is real and one-sided:
 * lamps, signs, wires and roof furniture are genuinely metres up, and nothing
 * is genuinely metres under. A mean would follow them and report a bias that
 * is not there.
 *
 *   terrainfit_test <game_dir> <level> <exe>
 */
#include "source.h"
#include "terrain.h"
#include "types.h"
#include "walk.h"

#include <algorithm>
#include <cctype>
#include <cmath>
#include <cstdio>
#include <string>
#include <vector>

using namespace bf6;

int main(int argc, char** argv)
{
    if (argc < 4)
    {
        std::fprintf(stderr, "usage: terrainfit_test <game_dir> <level> <exe>\n");
        return 2;
    }
    Source src;
    std::string err;
    if (!src.open(argv[1], err)) { std::fprintf(stderr, "open: %s\n", err.c_str()); return 1; }
    if (!src.mount_level(argv[2], false, err)) { std::fprintf(stderr, "mount: %s\n", err.c_str()); return 1; }

    std::string want, lvl = argv[2];
    for (char& c : lvl) c = (char)std::tolower((unsigned char)c);
    for (const auto& kv : src.res())
    {
        std::string n = kv.first;
        for (char& c : n) c = (char)std::tolower((unsigned char)c);
        if (n.find("streamingtree") != std::string::npos && n.find(lvl) != std::string::npos)
        { want = kv.first; break; }
    }
    if (want.empty()) { std::fprintf(stderr, "no streaming tree\n"); return 1; }
    std::vector<uint8_t> res = src.get_res(want, err);
    Terrain t;
    if (res.empty() || !t.parse(res, err)) { std::fprintf(stderr, "terrain: %s\n", err.c_str()); return 1; }
    t.resolve_external([&](const std::string& guid) { std::string e; return src.get_chunk(guid, e); });
    TerrainGrid g;
    if (!t.composite(g, 0, err)) { std::fprintf(stderr, "composite: %s\n", err.c_str()); return 1; }

    TypeDb types;
    if (!types.open(argv[3], err)) { std::fprintf(stderr, "types: %s\n", err.c_str()); return 1; }
    Walk w(src, types);
    w.build_catalog();
    if (!w.run(argv[2], err)) { std::fprintf(stderr, "walk: %s\n", err.c_str()); return 1; }

    // AND THE SURFACE THE CONSUMER ACTUALLY DRAWS, which is not this grid.
    // Unreal builds a mesh of side `built` by taking every Nth sample, so the
    // ground under any point is the BILINEAR interpolation of the four coarse
    // samples around it - not the native height there. Point-sampling a
    // heightfield throws away every feature narrower than the step, and it does
    // not do so symmetrically: a raised roadbed or a kerb is a thin ridge, and
    // a thin ridge missed by the sampler leaves the surface at the level of the
    // ground BESIDE it. So the coarse surface is biased toward the low side of
    // the terrain wherever the fine structure is raised, which is exactly the
    // built-up part of a map.
    const int built = argc > 4 ? std::atoi(argv[4]) : 1025;
    const int step  = (g.size - 1) / (built - 1) > 0 ? (g.size - 1) / (built - 1) : 1;

    const double sx = g.hi[0] - g.lo[0], sz = g.hi[2] - g.lo[2];
    std::vector<double> d, dc, drop;
    d.reserve(w.rows().size());
    int outside = 0;

    for (const WalkRow& r : w.rows())
    {
        const double x = r.xf.m[3].x, y = r.xf.m[3].y, z = r.xf.m[3].z;
        const double fx = (x - g.lo[0]) / sx, fz = (z - g.lo[2]) / sz;
        if (fx < 0.0 || fx > 1.0 || fz < 0.0 || fz > 1.0) { outside++; continue; }
        const int ix = (int)(fx * (g.size - 1) + 0.5);
        const int iz = (int)(fz * (g.size - 1) + 0.5);
        const double h = (double)g.heights[(size_t)iz * g.size + ix] / 65536.0 * g.world_size_y;
        d.push_back(y - h);

        // The same point on the coarse surface. Vertex k of the built mesh is
        // native sample k*step, so the cell is found in coarse indices and the
        // four corners interpolated the way a triangle pair would.
        const double cxf = fx * (built - 1), czf = fz * (built - 1);
        const int cx0 = (int)cxf, cz0 = (int)czf;
        const int cx1 = cx0 + 1 < built ? cx0 + 1 : cx0, cz1 = cz0 + 1 < built ? cz0 + 1 : cz0;
        const double tx = cxf - cx0, tz = czf - cz0;
        auto coarse = [&](int cx, int cz)
        {
            const int nx = cx * step < g.size ? cx * step : g.size - 1;
            const int nz = cz * step < g.size ? cz * step : g.size - 1;
            return (double)g.heights[(size_t)nz * g.size + nx] / 65536.0 * g.world_size_y;
        };
        const double hc =
            coarse(cx0, cz0) * (1 - tx) * (1 - tz) + coarse(cx1, cz0) * tx * (1 - tz) +
            coarse(cx0, cz1) * (1 - tx) * tz       + coarse(cx1, cz1) * tx * tz;
        dc.push_back(y - hc);
        drop.push_back(h - hc);
    }
    if (d.empty()) { std::fprintf(stderr, "no placements landed on the grid\n"); return 1; }
    std::sort(d.begin(), d.end());

    auto q = [&](double f) { return d[(size_t)(f * (d.size() - 1))]; };
    std::printf("%zu placements sampled (%d outside the grid)\n", d.size(), outside);
    std::printf("  p05 %+.2f  p25 %+.2f  MEDIAN %+.2f  p75 %+.2f  p95 %+.2f  (metres above the rebuilt ground)\n",
                q(0.05), q(0.25), q(0.50), q(0.75), q(0.95));

    // How many sit within a hand's width of it. A correct rebuild puts a big
    // share of the map's props there; a biased one puts almost none.
    int near = 0, under = 0;
    for (double v : d) { if (std::fabs(v) <= 0.25) near++; if (v < -0.5) under++; }
    std::printf("  within 0.25 m of the ground: %d (%.1f%%);  more than 0.5 m UNDER it: %d (%.1f%%)\n",
                near, 100.0 * near / (double)d.size(), under, 100.0 * under / (double)d.size());
    std::sort(dc.begin(), dc.end());
    std::sort(drop.begin(), drop.end());
    auto qc = [&](double f) { return dc[(size_t)(f * (dc.size() - 1))]; };
    auto qd = [&](double f) { return drop[(size_t)(f * (drop.size() - 1))]; };
    int nearc = 0;
    for (double v : dc) if (std::fabs(v) <= 0.25) nearc++;

    std::printf("\nBUILT AT %d (every %dth sample), which is what Unreal draws:\n", built, step);
    std::printf("  p05 %+.2f  p25 %+.2f  MEDIAN %+.2f  p75 %+.2f  p95 %+.2f\n",
                qc(0.05), qc(0.25), qc(0.50), qc(0.75), qc(0.95));
    std::printf("  within 0.25 m of the ground: %d (%.1f%%)\n", nearc, 100.0 * nearc / (double)dc.size());
    std::printf("  how far the coarse surface sits BELOW the native one, under a prop:\n");
    std::printf("    p25 %+.2f  median %+.2f  p75 %+.2f  p95 %+.2f  max %+.2f m\n",
                qd(0.25), qd(0.50), qd(0.75), qd(0.95), drop.back());
    return 0;
}
