/* Validation harness for module 9 (the placement walk).
 *
 * Not shipped. Walks a level out of the install and prints one line per row, in
 * the form the Godot plugin's own cached walk can be printed in, so the two can
 * be compared row for row. That cache is the right oracle: it was produced by
 * the reader that ships and has been looked at in the editor on real maps.
 *
 *   walk_test <game_dir> <exe> <level> [--all-levels]
 *
 * R <mesh> <kind> <var> <12 transform floats, %.6g>
 */
#include "walk.h"

#include <chrono>
#include <cstdio>
#include <cstring>
#include <string>

using namespace bf6;

int main(int argc, char** argv)
{
    if (argc < 4)
    {
        std::fprintf(stderr, "usage: walk_test <game_dir> <exe> <level> [--all-levels]\n");
        return 2;
    }
    const bool asset = argc > 4 && std::strcmp(argv[4], "--asset") == 0;
    const bool all = asset || (argc > 4 && std::strcmp(argv[4], "--all-levels") == 0);

    using clk = std::chrono::steady_clock;
    auto ms = [](clk::time_point a, clk::time_point b)
    { return std::chrono::duration<double, std::milli>(b - a).count(); };

    Source src;
    std::string err;
    const auto t0 = clk::now();
    if (!src.open(argv[1], err)) { std::fprintf(stderr, "open: %s\n", err.c_str()); return 1; }
    if (!src.mount_level(asset ? std::string() : std::string(argv[3]), all, err))
    { std::fprintf(stderr, "mount: %s\n", err.c_str()); return 1; }
    const auto t1 = clk::now();

    TypeDb types;
    if (!types.open(argv[2], err)) { std::fprintf(stderr, "types: %s\n", err.c_str()); return 1; }
    const auto t2 = clk::now();

    Walk w(src, types);
    w.build_catalog();
    const auto t3 = clk::now();

    if (!w.run(argv[3], err)) { std::fprintf(stderr, "walk: %s\n", err.c_str()); return 1; }
    const auto t4 = clk::now();

    for (const WalkRow& r : w.rows())
    {
        std::printf("R %s %s %s %s", r.mesh.c_str(), r.kind.c_str(),
                    r.var.empty() ? "-" : r.var.c_str(), r.src.c_str());
        for (int i = 0; i < 4; i++)
            std::printf(" %.6g %.6g %.6g", r.xf.m[i].x, r.xf.m[i].y, r.xf.m[i].z);
        std::printf("\n");
    }

    std::fprintf(stderr,
        "root %s\n"
        "rows %zu  partitions %llu  instances %llu (skipped %llu, unresolved types %llu)\n"
        "smg %llu (hidden %llu, unresolved %llu)  leaf %llu  excluded %llu  destruction %llu\n"
        "subworld %llu (skipped %llu, unresolved %llu)  cycles %llu  missing %llu  parse-fail %llu\n"
        "mount %.0f ms, types %.0f ms, catalog %.0f ms, walk %.0f ms\n",
        w.root.c_str(), w.rows().size(),
        (unsigned long long)w.n_partitions, (unsigned long long)w.n_instances,
        (unsigned long long)w.n_skipped, (unsigned long long)w.n_unresolved,
        (unsigned long long)w.n_smg, (unsigned long long)w.n_smg_hidden,
        (unsigned long long)w.n_smg_unresolved, (unsigned long long)w.n_leaf,
        (unsigned long long)w.n_excluded, (unsigned long long)w.n_destruction,
        (unsigned long long)w.n_subworld, (unsigned long long)w.n_subworld_skipped,
        (unsigned long long)w.n_subworld_unresolved, (unsigned long long)w.n_cycles,
        (unsigned long long)w.n_missing, (unsigned long long)w.n_parse_fail,
        ms(t0, t1), ms(t1, t2), ms(t2, t3), ms(t3, t4));
    return 0;
}
