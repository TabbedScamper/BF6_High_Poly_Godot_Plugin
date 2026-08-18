/* libbf6 - public C ABI.
 *
 * Module 2 is done, so bf6_open now opens a real install: it builds a Source,
 * mounts the shared SuperBundle TOCs, and hands back a context whose catalogue
 * can be listed. Geometry (bf6_read_mesh) waits on the EBX + meshset modules and
 * is still stubbed.
 */
#include "bf6_core.h"

#include <cstdio>
#include <cstring>
#include <filesystem>
#include <string>
#include <vector>

#include "source.h"
#include "meshset.h"

namespace fs = std::filesystem;

struct bf6_ctx {
    bf6::Source src;
    int lifted = 0;
};

// Backing store for a returned bf6_mesh. `mesh` is the first member so a
// bf6_mesh* handed out can be cast back for bf6_free.
struct MeshHandle {
    bf6_mesh                            mesh{};
    std::vector<bf6_section>            sections;
    std::vector<std::vector<float>>     pos, nrm, uv;
    std::vector<std::vector<uint32_t>>  idx;
};

extern "C" {

bf6_ctx* bf6_open(const char* game_dir, char* err, int err_len) {
    if (!game_dir || !*game_dir) {
        if (err && err_len > 0) std::snprintf(err, (size_t)err_len, "no game_dir given");
        return nullptr;
    }
    bf6_ctx* c = new bf6_ctx();
    std::string e;
    if (!c->src.open(game_dir, e)) {
        if (err && err_len > 0) std::snprintf(err, (size_t)err_len, "%s", e.c_str());
        delete c;
        return nullptr;
    }
    // Mount the shared SuperBundle TOCs at Data/Win32/*.toc. This is the fast,
    // level-independent catalogue; per-level mounting lands with find_tocs later.
    std::string dir = std::string(game_dir) + "/Data/Win32";
    std::error_code ec;
    if (fs::is_directory(dir, ec)) {
        for (const auto& f : fs::directory_iterator(dir, ec)) {
            if (f.path().extension() == ".toc") {
                std::string me;
                c->src.mount_toc(f.path().string(), me);
            }
        }
    }
    if (c->src.res_count() == 0) {
        if (err && err_len > 0)
            std::snprintf(err, (size_t)err_len, "opened the install but mounted no resources");
        delete c;
        return nullptr;
    }
    return c;
}

void bf6_close(bf6_ctx* c) { delete c; }

int bf6_was_lifted(bf6_ctx* c) { return c ? c->lifted : 0; }

int bf6_level_count(bf6_ctx*) { return 0; }              // per-level mount: later
const char* bf6_level_name(bf6_ctx*, int) { return ""; }

// Count matches; write up to out_max. Returns the TOTAL match count, so a caller
// passing out_max=0 learns the catalogue size. res_name points into the ctx.
int bf6_catalogue(bf6_ctx* c, const char* search, bf6_cat_entry* out, int out_max) {
    if (!c) return 0;
    std::string q = search ? search : "";
    int total = 0, written = 0;
    for (const auto& kv : c->src.res()) {
        if (!q.empty() && kv.first.find(q) == std::string::npos) continue;
        if (written < out_max && out) {
            out[written].res_name = kv.first.c_str();
            out[written].category = "";
            written++;
        }
        total++;
    }
    return total;
}

bf6_mesh* bf6_read_mesh(bf6_ctx* c, const char* res_name, int lod) {
    if (!c || !res_name) return nullptr;
    std::string err;
    std::vector<uint8_t> d = c->src.get_res(res_name, err);
    if (d.empty()) return nullptr;
    bf6::MeshSet ms = bf6::meshset_parse(d.data(), d.size(), err);
    if (!ms.ok || ms.lods.empty()) return nullptr;
    if (lod < 0 || lod >= (int)ms.lods.size()) lod = 0;

    // The vertex/index bytes live in the LOD's chunk (try both guid spellings).
    static const char* H = "0123456789abcdef";
    const auto& cid = ms.lods[lod].chunk_id;
    std::string fwd, rev;
    for (int i = 0; i < 16; i++) { fwd += H[cid[i] >> 4]; fwd += H[cid[i] & 0xF]; }
    for (int i = 15; i >= 0; i--) { rev += H[cid[i] >> 4]; rev += H[cid[i] & 0xF]; }
    std::vector<uint8_t> chunk = c->src.get_chunk(fwd, err);
    if (chunk.empty()) chunk = c->src.get_chunk(rev, err);
    if (chunk.empty()) return nullptr;

    auto secs = bf6::meshset_read_lod(ms, lod, chunk.data(), chunk.size(), err);
    if (secs.empty()) return nullptr;

    MeshHandle* mh = new MeshHandle();
    const size_t n = secs.size();
    mh->pos.reserve(n); mh->nrm.reserve(n); mh->uv.reserve(n); mh->idx.reserve(n);
    for (auto& s : secs) {
        mh->pos.push_back(std::move(s.positions));
        mh->nrm.push_back(std::move(s.normals));
        mh->uv.push_back(std::move(s.uv0));
        mh->idx.push_back(std::move(s.indices));
    }
    mh->sections.resize(n);
    float lo[3] = { 1e30f, 1e30f, 1e30f }, hi[3] = { -1e30f, -1e30f, -1e30f };
    for (size_t i = 0; i < n; i++) {
        bf6_section& sec = mh->sections[i];
        sec = bf6_section{};
        sec.positions    = mh->pos[i].data();
        sec.vertex_count = (int32_t)(mh->pos[i].size() / 3);
        sec.normals      = mh->nrm[i].empty() ? nullptr : mh->nrm[i].data();
        sec.uv0          = mh->uv[i].empty()  ? nullptr : mh->uv[i].data();
        sec.indices      = mh->idx[i].data();
        sec.index_count  = (int32_t)mh->idx[i].size();
        sec.material     = (int32_t)i;
        for (size_t v = 0; v + 2 < mh->pos[i].size(); v += 3)
            for (int k = 0; k < 3; k++) {
                float x = mh->pos[i][v + k];
                if (x < lo[k]) lo[k] = x;
                if (x > hi[k]) hi[k] = x;
            }
    }
    mh->mesh.sections       = mh->sections.data();
    mh->mesh.section_count  = (int32_t)n;
    mh->mesh.materials      = nullptr;   // depot materials: later
    mh->mesh.material_count = 0;
    for (int k = 0; k < 3; k++) { mh->mesh.aabb_min[k] = lo[k]; mh->mesh.aabb_max[k] = hi[k]; }
    return &mh->mesh;
}
const bf6_texture* bf6_texture_at(bf6_ctx*, int) { return nullptr; }
int bf6_level_instances(bf6_ctx*, const char*, bf6_instance*, int) { return 0; }
int bf6_level_lights(bf6_ctx*, const char*, bf6_light*, int) { return 0; }
bf6_terrain* bf6_read_terrain(bf6_ctx*, const char*) { return nullptr; }

void bf6_free(bf6_ctx*, void* handle) {
    if (handle) delete reinterpret_cast<MeshHandle*>(handle);
}

}  // extern "C"
