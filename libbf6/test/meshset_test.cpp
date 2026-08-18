/* meshset_test - validate the MeshSet header parse against the plugin.
 *   meshset_test <game_dir> <toc_path> <res_name>
 */
#include <cstdio>
#include "source.h"
#include "meshset.h"
int main(int argc, char** argv) {
    if (argc < 4) { std::printf("usage: meshset_test <game> <toc> <res>\n"); return 2; }
    bf6::Source src; std::string err;
    if (!src.open(argv[1], err)) { std::printf("open: %s\n", err.c_str()); return 1; }
    if (!src.mount_toc(argv[2], err)) { std::printf("mount: %s\n", err.c_str()); return 1; }
    std::vector<uint8_t> d = src.get_res(argv[3], err);
    if (d.empty()) { std::printf("get_res: %s\n", err.c_str()); return 1; }
    bf6::MeshSet ms = bf6::meshset_parse(d.data(), d.size(), err);
    if (!ms.ok) { std::printf("parse: %s\n", err.c_str()); return 1; }
    std::printf("NAME=%s TYPE=%u LODS=%d SECTIONS=%d STRIDE=%d\n",
        ms.name.c_str(), ms.mesh_type, ms.lod_count, ms.section_count, ms.lod_stride);
    if (!ms.lods.empty()) {
        const bf6::MeshLod& L = ms.lods[0];
        std::printf("LOD0 secs=%d idx32=%d isize=%d vsize=%d nsec=%zu\n",
            L.section_count, L.idx32?1:0, L.index_size, L.vertex_size, L.sections.size());
        char h[33]={0}; for(int i=0;i<16;i++) std::snprintf(h+i*2,3,"%02x",L.chunk_id[i]);
        std::printf("LOD0 chunk=%s\n", h);
        if (!L.sections.empty()) {
            const bf6::MeshSection& s = L.sections[0];
            std::printf("SEC0 mat=%s vcount=%u voff=%u prim=%u start=%u statekey=%llu\n",
                s.material.c_str(), s.vertex_count, s.vertex_offset, s.prim_count,
                s.start_index, (unsigned long long)s.state_key);
        }
    }
    return 0;
}
