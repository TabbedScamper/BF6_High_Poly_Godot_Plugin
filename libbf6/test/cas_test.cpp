/* cas_test - validate the C CAS reader against the Godot plugin.
 *
 *   cas_test <game_dir> <cas_path> <offset> <size>
 *
 * Prints  len=<n> fnv=<hex>  for the decompressed reference. The same
 * (path, offset, size) fed to the plugin's BF6Cas.read must produce the same
 * len and the same FNV-1a hash. FNV-1a is used both sides because it is trivial
 * to implement identically in GDScript and needs no library.
 */
#include <cstdio>
#include <cstdlib>
#include <string>
#include <vector>

#include "cas.h"
#include "oodle.h"

int main(int argc, char** argv) {
    if (argc < 5) {
        std::printf("usage: cas_test <game_dir> <cas_path> <offset> <size>\n");
        return 2;
    }
    std::string game = argv[1];
    std::string path = argv[2];
    long long off = std::atoll(argv[3]);
    long long sz  = std::atoll(argv[4]);

    if (!bf6::oodle_open(game)) {
        std::printf("oodle_open failed: %s\n", bf6::oodle_error().c_str());
        return 1;
    }
    std::string err;
    std::vector<uint8_t> d = bf6::cas_read(path, off, sz, false, err);
    if (d.empty()) {
        std::printf("cas_read failed: %s\n", err.c_str());
        return 1;
    }
    uint64_t h = 1469598103934665603ULL;  // FNV-1a 64 offset basis
    for (uint8_t b : d) { h ^= b; h *= 1099511628211ULL; }
    std::printf("len=%zu fnv=%016llx\n", d.size(), (unsigned long long)h);

    // Optional: write the exact bytes so the plugin's output can be cmp'd.
    if (argc >= 6) {
        FILE* o = std::fopen(argv[5], "wb");
        if (o) { std::fwrite(d.data(), 1, d.size(), o); std::fclose(o); }
    }
    return 0;
}
