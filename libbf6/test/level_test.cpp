/* Validation harness for level mounting.
 *
 * Not shipped. The mount order IS the correctness (first mount wins), so this
 * prints the order it chose and then proves the mount actually reaches data
 * that only exists inside that level.
 *
 *   level_test <game_dir> levels                     what the install carries
 *   level_test <game_dir> tocs  <level> [all]        the mount order
 *   level_test <game_dir> mount <level> [all]        mount and report reach
 */
#include "source.h"

#include <chrono>
#include <cstdio>
#include <cstring>
#include <string>

using namespace bf6;

int main(int argc, char** argv)
{
    if (argc < 3)
    {
        std::fprintf(stderr,
            "usage: level_test <game_dir> levels\n"
            "       level_test <game_dir> tocs  <level> [all]\n"
            "       level_test <game_dir> mount <level> [all]\n");
        return 2;
    }
    const std::string game = argv[1], mode = argv[2];
    const std::string level = argc > 3 ? argv[3] : std::string();
    const bool all = argc > 4 && std::strcmp(argv[4], "all") == 0;

    Source src;
    std::string err;
    if (!src.open(game, err)) { std::fprintf(stderr, "open: %s\n", err.c_str()); return 1; }

    if (mode == "levels")
    {
        for (const std::string& l : src.available_levels()) std::printf("%s\n", l.c_str());
        return 0;
    }

    using clk = std::chrono::steady_clock;
    const auto t0 = clk::now();
    const std::vector<std::string> tocs = src.find_tocs(level, all);
    const auto t1 = clk::now();

    if (mode == "tocs")
    {
        for (const std::string& t : tocs)
            std::printf("%s %s\n", Source::is_level_toc(t) ? "L" : "S", t.c_str());
        std::fprintf(stderr, "%zu toc(s) in %.0f ms\n", tocs.size(),
            std::chrono::duration<double, std::milli>(t1 - t0).count());
        return 0;
    }

    if (!src.mount_level(level, all, err))
    { std::fprintf(stderr, "mount_level: %s\n", err.c_str()); return 1; }
    const auto t2 = clk::now();

    std::printf("EBX=%zu RES=%zu\n", src.ebx_count(), src.res_count());

    // Does the mount actually REACH the level? A level's own root partition is
    // named after it, so finding one is the difference between "mounted
    // something" and "mounted this".
    size_t own = 0;
    std::string sample;
    const std::string needle = "levels/" + level;
    for (const auto& kv : src.ebx())
        if (kv.first.rfind(needle, 0) == 0 || kv.first.find("/" + level + "/") != std::string::npos)
        {
            if (own == 0) sample = kv.first;
            own++;
        }
    std::printf("OWN=%zu SAMPLE=%s\n", own, sample.c_str());

    std::fprintf(stderr, "find %.0f ms, mount %.0f ms\n",
        std::chrono::duration<double, std::milli>(t1 - t0).count(),
        std::chrono::duration<double, std::milli>(t2 - t1).count());
    return own ? 0 : 1;
}
