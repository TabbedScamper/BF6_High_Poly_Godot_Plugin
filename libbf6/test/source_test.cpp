/* source_test - validate the mount end to end: name -> decompressed bytes.
 *
 *   source_test <game_dir> <toc_path>                  list res_count + names
 *   source_test <game_dir> <toc_path> <res_name> <out> read one, write bytes
 */
#include <cstdio>
#include <cstdlib>
#include <string>

#include "source.h"

int main(int argc, char** argv) {
    if (argc < 3) {
        std::printf("usage: source_test <game_dir> <toc_path> [res_name] [out]\n");
        return 2;
    }
    bf6::Source src;
    std::string err;
    if (!src.open(argv[1], err)) { std::printf("open failed: %s\n", err.c_str()); return 1; }
    if (!src.mount_toc(argv[2], err)) { std::printf("mount failed: %s\n", err.c_str()); return 1; }

    std::printf("RES_COUNT=%zu EBX_COUNT=%zu\n", src.res_count(), src.ebx_count());

    if (argc < 5) {
        int n = 0;
        for (const auto& kv : src.res()) {
            std::printf("RES %s (dsize=%u)\n", kv.first.c_str(), kv.second.dsize);
            if (++n >= 200000) break;
        }
        return 0;
    }

    auto it = src.res().find(argv[3]);
    if (it != src.res().end()) {
        const bf6::CasLoc& l = it->second.loc;
        std::printf("LOC chunk=%u cas=%u off=%u size=%u dsize=%u\n",
                    l.chunk_id, l.cas_ix, l.off, l.size, it->second.dsize);
    } else {
        std::printf("name not in res table\n");
    }
    std::vector<uint8_t> d = src.get_res(argv[3], err);
    if (d.empty()) { std::printf("get_res failed: %s\n", err.c_str()); return 1; }
    uint64_t h = 1469598103934665603ULL;
    for (uint8_t b : d) { h ^= b; h *= 1099511628211ULL; }
    std::printf("len=%zu fnv=%016llx\n", d.size(), (unsigned long long)h);
    FILE* o = std::fopen(argv[4], "wb");
    if (o) { std::fwrite(d.data(), 1, d.size(), o); std::fclose(o); }
    return 0;
}
