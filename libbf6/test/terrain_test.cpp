/* Validation harness for module 10 (heights).
 *
 * Not shipped. Reads a level's heightfield and reports the tree it came out of.
 * There is no reference dump to diff against here, so the checks are the ones
 * the format itself makes falsifiable:
 *
 *  - the node walk is specified as byte-exact, so a desync fails rather than
 *    returning plausible nodes;
 *  - the header carries an identity between two of its own fields, checked;
 *  - EVERY value node must resolve to samples, because "the walk succeeded and
 *    nothing carries heights" is exactly what a wrong chunk spelling looks like;
 *  - the composited grid's height range and world span are printed, because a
 *    stride error shows up as a shape that is wrong at a glance long before it
 *    shows up as bad pixels.
 *
 *   terrain_test <game_dir> <level> [out.pgm]
 */
#include "source.h"
#include "terrain.h"

#include <chrono>
#include <cstdio>
#include <string>
#include <string>

using namespace bf6;

int main(int argc, char** argv)
{
    if (argc < 3)
    {
        std::fprintf(stderr, "usage: terrain_test <game_dir> <level> [out.pgm]\n");
        return 2;
    }
    const std::string game = argv[1], level = argv[2];

    using clk = std::chrono::steady_clock;
    auto ms = [](clk::time_point a, clk::time_point b)
    { return std::chrono::duration<double, std::milli>(b - a).count(); };

    Source src;
    std::string err;
    if (!src.open(game, err)) { std::fprintf(stderr, "open: %s\n", err.c_str()); return 1; }
    if (!src.mount_level(level, false, err)) { std::fprintf(stderr, "mount: %s\n", err.c_str()); return 1; }

    std::string want, lvl = level;
    for (char& c : lvl) c = (char)std::tolower((unsigned char)c);
    for (const auto& kv : src.res())
    {
        std::string n = kv.first;
        for (char& c : n) c = (char)std::tolower((unsigned char)c);
        if (n.find("streamingtree") != std::string::npos && n.find(lvl) != std::string::npos)
        { want = kv.first; break; }
    }
    if (want.empty()) { std::fprintf(stderr, "no streaming tree for %s\n", level.c_str()); return 1; }
    std::printf("tree: %s\n", want.c_str());

    std::vector<uint8_t> res = src.get_res(want, err);
    if (res.empty()) { std::fprintf(stderr, "get_res: %s\n", err.c_str()); return 1; }
    std::printf("resource: %zu bytes\n", res.size());

    const auto t0 = clk::now();
    Terrain t;
    if (!t.parse(res, err)) { std::fprintf(stderr, "parse: %s\n", err.c_str()); return 1; }
    const auto t1 = clk::now();

    const size_t inline_vals = t.nodes_with_values();
    const int got = t.resolve_external([&](const std::string& guid)
    {
        std::string e;
        return src.get_chunk(guid, e);
    });
    const auto t2 = clk::now();

    std::printf("nodes: %zu (%zu inline, %d resolved from chunks, %zu with heights)\n",
                t.node_count(), inline_vals, got, t.nodes_with_values());
    std::printf("samples per side: %d, pad border: %d, native grid: %d\n",
                t.samples_per_side(), t.border(), t.native_size());

    if (t.nodes_with_values() == 0)
    {
        std::fprintf(stderr, "no node carries heights: the chunk spelling or the "
                             "directory is wrong, not the walk\n");
        return 1;
    }

    TerrainGrid g;
    if (!t.composite(g, 0, err)) { std::fprintf(stderr, "composite: %s\n", err.c_str()); return 1; }
    const auto t3 = clk::now();

    uint16_t lo = 65535, hi = 0;
    uint64_t zero = 0;
    for (uint16_t h : g.heights) { lo = h < lo ? h : lo; hi = h > hi ? h : hi; if (!h) zero++; }
    std::printf("grid %d x %d, heights %u..%u, %.1f%% unpainted\n", g.size, g.size,
                lo, hi, 100.0 * (double)zero / (double)g.heights.size());
    std::printf("world x %.1f..%.1f  y %.1f..%.1f  z %.1f..%.1f  (%.0f x %.0f m)\n",
                g.lo[0], g.hi[0], g.lo[1], g.hi[1], g.lo[2], g.hi[2],
                g.hi[0] - g.lo[0], g.hi[2] - g.lo[2]);
    // THE HEIGHT DECODE, SETTLED BY THE DATA RATHER THAN BY WHICH FORMULA
    // LOOKS REASONABLE. The spec says y = u16 / 65536 * WorldSizeY, a pure
    // scale through zero. A consumer that instead fits a line from the AABB's
    // y range onto the raw range gets the two endpoints right and sags
    // everywhere in between, because the minimum raw value is not zero. If the
    // spec's rule holds, both of these print as the AABB's own y bounds.
    std::printf("height scale %.3f: raw %u -> %.2f (aabb lo %.2f), raw %u -> %.2f (aabb hi %.2f)\n",
                g.world_size_y,
                lo, (double)lo / 65536.0 * g.world_size_y, g.lo[1],
                hi, (double)hi / 65536.0 * g.world_size_y, g.hi[1]);
    {
        // And what the AABB-fitted line would have said at the middle of the
        // range, which is where the two disagree most.
        const double mid = 0.5 * ((double)lo + (double)hi);
        const double truth = mid / 65536.0 * g.world_size_y;
        const double fitted = g.lo[1] + (g.hi[1] - g.lo[1]) * (mid - lo) / (double)(hi - lo);
        std::printf("  at mid raw %.0f: spec %.2f, aabb-fitted %.2f  (fitted is %.2f m low)\n",
                    mid, truth, fitted, truth - fitted);
    }
    std::printf("parse %.0f ms, chunks %.0f ms, composite %.0f ms\n",
                ms(t0, t1), ms(t1, t2), ms(t2, t3));

    // A RAW DUMP, for comparing this ground against another one numerically.
    // The pgm below is 8-bit and normalised, which is fine for looking at the
    // shape and useless for asking whether the ground sits at the right
    // height. This writes the grid as it is, with the world box and the height
    // scale in front of it, so a consumer can reconstruct metres.
    if (argc > 3 && std::string(argv[3]).size() > 4 &&
        std::string(argv[3]).substr(std::string(argv[3]).size() - 4) == ".raw")
    {
        FILE* f = std::fopen(argv[3], "wb");
        if (f)
        {
            std::fwrite(&g.size, 4, 1, f);
            std::fwrite(g.lo, 4, 3, f);
            std::fwrite(g.hi, 4, 3, f);
            std::fwrite(&g.world_size_y, 4, 1, f);
            std::fwrite(g.heights.data(), 2, g.heights.size(), f);
            std::fclose(f);
            std::printf("wrote %s (%d x %d raw u16)\n", argv[3], g.size, g.size);
        }
        return 0;
    }

    if (argc > 3)
    {
        // A greyscale image of the ground, so the shape can be looked at
        // directly. Downsampled to something openable.
        const int step = g.size > 2048 ? g.size / 1024 : 1;
        const int w = g.size / step;
        FILE* f = std::fopen(argv[3], "wb");
        if (f)
        {
            std::fprintf(f, "P5\n%d %d\n255\n", w, w);
            for (int z = 0; z < w; z++)
                for (int x = 0; x < w; x++)
                {
                    const uint16_t h = g.heights[(size_t)(z * step) * (size_t)g.size + (size_t)(x * step)];
                    const uint8_t px = hi > lo ? (uint8_t)(255.0 * (h - lo) / (hi - lo)) : 0;
                    std::fwrite(&px, 1, 1, f);
                }
            std::fclose(f);
            std::printf("wrote %s (%d x %d)\n", argv[3], w, w);
        }
    }
    return 0;
}
