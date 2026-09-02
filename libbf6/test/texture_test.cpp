/* Validation harness for module 7 (textures).
 *
 * Not shipped. Decodes every texture matching a search and reports what came
 * out, because the failures this format has are all "plausible but wrong":
 * a transposed non-square texture, a chunk read short, an sRGB flag on a linear
 * normal map. So the checks are the ones that catch those:
 *
 *  - the byte count must equal what the format and dimensions demand, exactly;
 *  - non-square textures are counted separately, since a transposition is
 *    invisible on the square ones;
 *  - the chunk the header chose is reported, so a size heuristic standing in
 *    for the header bit would show up as the wrong chunk being used.
 *
 *   texture_test <game_dir> <level> <search> [max]
 */
#include "source.h"
#include "texture.h"

#include <algorithm>
#include <chrono>
#include <cstdio>
#include <cstring>
#include <map>
#include <string>

using namespace bf6;

int main(int argc, char** argv)
{
    if (argc < 4)
    {
        std::fprintf(stderr, "usage: texture_test <game_dir> <level> <search> [max]\n");
        return 2;
    }
    const std::string search = argv[3];
    const int limit = argc > 4 ? std::atoi(argv[4]) : 200;

    Source src;
    std::string err;
    if (!src.open(argv[1], err)) { std::fprintf(stderr, "open: %s\n", err.c_str()); return 1; }
    if (!src.mount_level(argv[2], false, err)) { std::fprintf(stderr, "mount: %s\n", err.c_str()); return 1; }

    auto fetch = [&](const std::string& guid) {
        std::string e;
        return src.get_chunk(guid, e);
    };

    int ok = 0, bad = 0, nonsquare = 0, streamed = 0, srgb = 0;
    std::map<int, int> by_dxgi;
    std::map<std::string, int> failures;
    const auto t0 = std::chrono::steady_clock::now();

    for (const auto& kv : src.res())
    {
        if (ok + bad >= limit) break;
        if (kv.first.find(search) == std::string::npos) continue;

        std::vector<uint8_t> res = src.get_res(kv.first, err);
        if (res.empty()) continue;

        TextureHeader h;
        if (!Texture::read_header(res, h)) continue;

        TextureImage img;
        std::string e;
        if (!Texture::decode(res, fetch, img, 0, e))
        {
            bad++;
            failures[e]++;
            if (bad <= 12)
            {
                const char* which = Texture::which_chunk(h);
                const std::string guid = std::strcmp(which, "streamed") == 0 ? h.streamed : h.embedded;
                const std::vector<uint8_t> payload = guid.empty() ? std::vector<uint8_t>() : fetch(guid);
                std::printf("  REFUSED %-60s fmt %-3d %5d x %-5d x %-3d mips %-2d %s %8zu bytes: %s\n",
                            kv.first.substr(kv.first.size() > 60 ? kv.first.size() - 60 : 0).c_str(),
                            h.format, h.width, h.height, h.slices, h.mipcount, which,
                            payload.size(), e.c_str());
            }
            continue;
        }
        ok++;
        by_dxgi[img.dxgi]++;
        if (img.width != img.height) nonsquare++;
        if (img.srgb) srgb++;
        if (std::strcmp(Texture::which_chunk(h), "streamed") == 0) streamed++;

        if (ok <= 8)
            std::printf("  %-70s %5d x %-5d dxgi %-3d %s %8zu bytes\n",
                        kv.first.substr(kv.first.size() > 70 ? kv.first.size() - 70 : 0).c_str(),
                        img.width, img.height, img.dxgi, img.srgb ? "sRGB  " : "linear",
                        img.blocks.size());
    }
    const double ms = std::chrono::duration<double, std::milli>(
        std::chrono::steady_clock::now() - t0).count();

    std::printf("\n%d decoded, %d refused, %.0f ms\n", ok, bad, ms);
    std::printf("  %d non-square (a transposition is invisible on square ones)\n", nonsquare);
    std::printf("  %d took the streamed chunk, %d flagged sRGB\n", streamed, srgb);
    std::printf("  formats:");
    for (const auto& kv : by_dxgi) std::printf(" dxgi%d=%d", kv.first, kv.second);
    std::printf("\n");
    for (const auto& kv : failures) std::printf("  refused: %s (x%d)\n", kv.first.c_str(), kv.second);
    return ok > 0 ? 0 : 1;
}
