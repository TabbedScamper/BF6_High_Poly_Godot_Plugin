/* meshset_test - validate MeshSet parse AND geometry decode against the plugin.
 *   meshset_test <game_dir> <toc_path> <res_name>
 */
#include <cstdio>
#include <string>
#include "source.h"
#include "meshset.h"

static uint64_t fnv(const void* p, size_t n) {
    const uint8_t* b = (const uint8_t*)p;
    uint64_t h = 1469598103934665603ULL;
    for (size_t i = 0; i < n; i++) { h ^= b[i]; h *= 1099511628211ULL; }
    return h;
}

int main(int argc, char** argv) {
    if (argc < 4) { std::printf("usage: meshset_test <game> <toc> <res>\n"); return 2; }
    bf6::Source src; std::string err;
    if (!src.open(argv[1], err)) { std::printf("open: %s\n", err.c_str()); return 1; }
    if (!src.mount_toc(argv[2], err)) { std::printf("mount: %s\n", err.c_str()); return 1; }
    std::vector<uint8_t> d = src.get_res(argv[3], err);
    if (d.empty()) { std::printf("get_res: %s\n", err.c_str()); return 1; }
    bf6::MeshSet ms = bf6::meshset_parse(d.data(), d.size(), err);
    if (!ms.ok || ms.lods.empty()) { std::printf("parse: %s\n", err.c_str()); return 1; }

    const bf6::MeshLod& L = ms.lods[0];
    // Both spellings of the chunk id (plain and reversed).
    static const char* H = "0123456789abcdef";
    std::string fwd, rev;
    for (int i = 0; i < 16; i++) { fwd += H[L.chunk_id[i] >> 4]; fwd += H[L.chunk_id[i] & 0xF]; }
    for (int i = 15; i >= 0; i--) { rev += H[L.chunk_id[i] >> 4]; rev += H[L.chunk_id[i] & 0xF]; }

    std::vector<uint8_t> chunk = src.get_chunk(fwd, err);
    if (chunk.empty()) chunk = src.get_chunk(rev, err);
    if (chunk.empty()) { std::printf("get_chunk failed for %s / %s\n", fwd.c_str(), rev.c_str()); return 1; }
    std::printf("CHUNK bytes=%zu\n", chunk.size());

    auto secs = bf6::meshset_read_lod(ms, 0, chunk.data(), chunk.size(), err);
    std::printf("SECTIONS=%zu\n", secs.size());
    for (size_t i = 0; i < secs.size(); i++) {
        const auto& g = secs[i];
        std::printf("S%zu mat=%s verts=%zu tris=%zu pos_fnv=%016llx idx_fnv=%016llx\n",
            i, g.material.c_str(), g.positions.size() / 3, g.indices.size() / 3,
            (unsigned long long)fnv(g.positions.data(), g.positions.size() * 4),
            (unsigned long long)fnv(g.indices.data(), g.indices.size() * 4));
    }
    return 0;
}
