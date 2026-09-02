#include "source.h"

#include <cstdio>
#include <string>
#include <vector>

// Locate the first shipped TOC that makes a named EBX readable. This is a
// runtime diagnostic: it mounts the install's archives in Source's canonical
// order and never consumes or writes an extracted table.
int main(int argc, char** argv)
{
    if (argc < 3)
    {
        std::fprintf(stderr, "usage: asset_owner_test <game-dir> <ebx-name>\n");
        return 2;
    }

    bf6::Source src;
    std::string err;
    if (!src.open(argv[1], err))
    {
        std::fprintf(stderr, "open: %s\n", err.c_str());
        return 1;
    }

    const std::string asset = argv[2];
    const std::vector<std::string> tocs = src.find_tocs(std::string(), true);
    for (const std::string& toc : tocs)
    {
        std::string mount_err;
        if (!src.mount_toc(toc, mount_err)) continue;
        std::string read_err;
        if (!src.get_ebx(asset, read_err).empty())
        {
            std::printf("%s\n", toc.c_str());
            std::printf("bundle=%s\n", src.bundle_of_ebx(asset).c_str());
            return 0;
        }
    }

    std::fprintf(stderr, "not found after %zu TOCs\n", tocs.size());
    return 1;
}
