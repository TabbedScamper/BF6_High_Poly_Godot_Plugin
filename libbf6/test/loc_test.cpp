/* loc_test - validate CasLocator.cas_path against the Godot plugin.
 *
 *   loc_test <game_dir> <install_chunk_id> <cas_index>
 *
 * Prints the resolved path. The plugin's _loc.cas_path(chunk, index) for the
 * same inputs must print the same path.
 */
#include <cstdio>
#include <cstdlib>
#include <string>

#include "caslocator.h"

int main(int argc, char** argv) {
    if (argc < 4) {
        std::printf("usage: loc_test <game_dir> <install_chunk_id> <cas_index>\n");
        return 2;
    }
    std::string game = argv[1];
    uint32_t chunk = (uint32_t)std::strtoul(argv[2], nullptr, 10);
    int index = std::atoi(argv[3]);

    bf6::CasLocator loc;
    std::string err;
    if (!loc.open(game, err)) {
        std::printf("open failed: %s\n", err.c_str());
        return 1;
    }
    std::string p = loc.cas_path(chunk, index);
    std::printf("PATH=%s\n", p.c_str());
    return 0;
}
