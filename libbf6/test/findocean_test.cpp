/* findocean_test - locate the ocean simulation's shaders by NAME across the
 * whole mount (res and ebx), not just the expression-shader families.
 *
 *   findocean_test <game_dir> <level> [needle...]
 */
#include <algorithm>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

#include "source.h"

using namespace bf6;

static std::string lower(std::string s)
{ for (char& c : s) c = (char)tolower((unsigned char)c); return s; }

int main(int argc, char** argv)
{
    if (argc < 3) { std::fprintf(stderr, "usage: findocean_test <game_dir> <level> [needles...]\n"); return 2; }
    std::vector<std::string> needles;
    for (int i = 3; i < argc; i++) needles.push_back(lower(argv[i]));
    if (needles.empty())
        needles = { "ocean", "wave", "fft", "watersim", "water_sim", "spectrum",
                    "displacement", "wetmap", "disturb" };

    Source src;
    std::string err;
    if (!src.open(argv[1], err)) { std::fprintf(stderr, "open: %s\n", err.c_str()); return 1; }
    if (!src.mount_level(argv[2], false, err)) { std::fprintf(stderr, "mount: %s\n", err.c_str()); return 1; }

    std::printf("mount: %zu res, %zu ebx\n", src.res_count(), src.ebx_count());
    for (const std::string& nd : needles) {
        std::vector<std::string> hits;
        for (const auto& kv : src.res())
            if (lower(kv.first).find(nd) != std::string::npos) hits.push_back(kv.first);
        std::sort(hits.begin(), hits.end());
        std::printf("\n=== RES containing \"%s\": %zu\n", nd.c_str(), hits.size());
        for (size_t i = 0; i < hits.size() && i < 25; i++)
            std::printf("   %s\n", hits[i].c_str());

        std::vector<std::string> eh;
        for (const auto& kv : src.ebx())
            if (lower(kv.first).find(nd) != std::string::npos) eh.push_back(kv.first);
        std::sort(eh.begin(), eh.end());
        std::printf("=== EBX containing \"%s\": %zu\n", nd.c_str(), eh.size());
        for (size_t i = 0; i < eh.size() && i < 15; i++)
            std::printf("   %s\n", eh[i].c_str());
    }
    return 0;
}
