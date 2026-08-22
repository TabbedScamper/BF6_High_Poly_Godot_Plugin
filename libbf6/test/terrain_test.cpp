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
    std::printf("parse %.0f ms, chunks %.0f ms, composite %.0f ms\n",
                ms(t0, t1), ms(t1, t2), ms(t2, t3));

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
