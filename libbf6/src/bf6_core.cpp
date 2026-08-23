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
#include <map>
#include <memory>
#include <string>
#include <vector>

#include "source.h"
#include "meshset.h"
#include "terrain.h"
#include "walk.h"
#include "placeables.h"

namespace fs = std::filesystem;

struct bf6_ctx {
    bf6::Source      src;
    bf6::PlaceableDB pdb;
    int lifted = 0;

    // The level currently mounted and walked, with the type schema it needed.
    // Held on the context because mounting and indexing cost seconds: a caller
    // that asked for placements twice should pay once.
    std::unique_ptr<bf6::TypeDb> types;
    std::unique_ptr<bf6::Walk>   walk;
    std::string                  walked_level;

    // WHAT EACH HANDED-OUT POINTER ACTUALLY IS.
    //
    // bf6_free takes a void* and used to cast it to MeshHandle* unconditionally,
    // which was fine while a mesh was the only thing this API handed out. The
    // moment a second handle type existed, freeing one ran the WRONG
    // destructor over it and released whatever the other type happened to have
    // at those offsets - an access violation inside the free, nowhere near the
    // call that was actually wrong.
    //
    // The ABI hands out bare pointers by design, so the type has to be
    // remembered here. Registered on the way out, looked up on the way back.
    enum HandleKind { HK_MESH = 1, HK_TERRAIN = 2 };
    std::map<void*, int> handles;

    bf6_progress_fn progress = nullptr;
    void*           progress_user = nullptr;

    // Fanned out to the pieces that take time. Returns false when the caller
    // asked to stop.
    bool report(const char* stage, int done, int total) {
        if (!progress) return true;
        return progress(progress_user, stage, done, total) != 0;
    }
};

// Backing store for a returned bf6_mesh. `mesh` is the first member so a
// bf6_mesh* handed out can be cast back for bf6_free.
// Backing store for a returned bf6_terrain.
struct TerrainHandle {
    bf6_terrain           t{};
    std::vector<uint16_t> heights;
};

struct MeshHandle {
    bf6_mesh                            mesh{};
    std::vector<bf6_section>            sections;
    std::vector<std::vector<float>>     pos, nrm, uv;
    std::vector<std::vector<uint32_t>>  idx;
};

extern "C" {

bf6_ctx* bf6_open(const char* game_dir, char* err, int err_len) {
    // Empty game_dir is the explicit no-install mode: a context with nothing
    // mounted. Mesh reads will fail, but the placeable catalogue (which only
    // needs bf6_load_placeables' SDK data) works fully.
    if (!game_dir || !*game_dir) {
        return new bf6_ctx();
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

int bf6_load_placeables(bf6_ctx* c, const char* fbexport_dir, char* err, int err_len) {
    if (!c || !fbexport_dir) return 0;
    std::string e;
    if (!c->pdb.load(fbexport_dir, e)) {
        if (err && err_len > 0) std::snprintf(err, (size_t)err_len, "%s", e.c_str());
        return 0;
    }
    return (int)c->pdb.items().size();
}

int bf6_level_count(bf6_ctx* c) { return c ? (int)c->pdb.levels().size() : 0; }

const char* bf6_level_name(bf6_ctx* c, int index) {
    if (!c) return "";
    const auto& lv = c->pdb.levels();
    if (index < 0 || index >= (int)lv.size()) return "";
    return lv[index].c_str();
}

// Case-insensitive substring test (search is expected lowercase-friendly enough;
// we lower both sides so "dumbo" matches "Dumbo").
static bool ci_contains(const std::string& hay, const std::string& needle) {
    if (needle.empty()) return true;
    if (needle.size() > hay.size()) return false;
    auto lower = [](char c){ return (c >= 'A' && c <= 'Z') ? char(c + 32) : c; };
    for (size_t i = 0; i + needle.size() <= hay.size(); i++) {
        size_t j = 0;
        for (; j < needle.size(); j++)
            if (lower(hay[i + j]) != lower(needle[j])) break;
        if (j == needle.size()) return true;
    }
    return false;
}

int bf6_list_placeables(bf6_ctx* c, const char* level, const char* search,
                        bf6_placeable* out, int out_max) {
    if (!c) return 0;
    std::string lvl = level ? level : "";
    std::string q   = search ? search : "";
    int total = 0, written = 0;
    for (const auto& p : c->pdb.items()) {
        if (!bf6::PlaceableDB::allowed_on(p, lvl)) continue;
        if (!q.empty() && !ci_contains(p.type, q)) continue;
        if (out && written < out_max) {
            out[written].type         = p.type.c_str();
            out[written].directory    = p.directory.c_str();
            out[written].mesh         = p.mesh.c_str();
            out[written].physics_cost = p.physics_cost;
            out[written].universal    = p.universal ? 1 : 0;
            written++;
        }
        total++;
    }
    return total;
}

int bf6_placeable_props(bf6_ctx* c, const char* type, bf6_prop* out, int out_max) {
    if (!c || !type) return 0;
    const std::string t = type;
    for (const auto& p : c->pdb.items()) {
        if (p.type != t) continue;
        const int total = (int)p.props.size();
        for (int i = 0; i < total && out && i < out_max; i++) {
            out[i].name = p.props[i].name.c_str();
            out[i].type = p.props[i].type.c_str();
            out[i].def  = p.props[i].def.c_str();
            out[i].selections = p.props[i].selections.c_str();
        }
        return total;
    }
    return 0;
}

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
    c->handles[&mh->mesh] = bf6_ctx::HK_MESH;
    return &mh->mesh;
}
const bf6_texture* bf6_texture_at(bf6_ctx*, int) { return nullptr; }
void bf6_set_progress(bf6_ctx* c, bf6_progress_fn fn, void* user) {
    if (!c) return;
    c->progress = fn;
    c->progress_user = user;
}

int bf6_open_level(bf6_ctx* c, const char* level, const char* exe_path,
                   int all_levels, char* err, int err_len) {
    auto fail = [&](const std::string& m) {
        if (err && err_len > 0) {
            std::snprintf(err, (size_t)err_len, "%s", m.c_str());
        }
        return 1;
    };
    if (!c || !level || !*level) return fail("no level");
    if (c->walked_level == level && c->walk) return 0;   // already open

    std::string e;
    auto tick = [c](const char* stage, int done, int total) {
        return c->report(stage, done, total);
    };
    c->src.set_progress(tick);

    if (!c->src.mount_level(level, all_levels != 0, e)) return fail(e);

    c->types.reset(new bf6::TypeDb());
    if (exe_path && *exe_path) {
        if (!c->types->open(exe_path, e)) return fail("type schema: " + e);
    } else {
        // No exe given: try the install's own, MP first because that is the
        // build a Portal level comes from.
        bool ok = false;
        for (const std::string& cand : bf6::TypeDb::exe_candidates(c->src.game_dir())) {
            if (c->types->open(cand, e)) { ok = true; break; }
        }
        if (!ok) return fail("no readable executable for the type schema");
    }
    if (c->types->looks_encrypted())
        return fail("this install's type table is encrypted (EA App build); "
                    "placements cannot be read from it yet");

    c->report("reading the object graph", 0, 0);
    c->walk.reset(new bf6::Walk(c->src, *c->types));
    c->walk->set_progress(tick);
    c->walk->build_catalog();
    if (!c->walk->run(level, e)) { c->walk.reset(); return fail(e); }
    c->walked_level = level;
    return 0;
}

int bf6_level_instances(bf6_ctx* c, const char* level,
                        bf6_instance* out, int out_max) {
    if (!c || !c->walk || !level || c->walked_level != level) return 0;
    const std::vector<bf6::WalkRow>& rows = c->walk->rows();
    const int n = (int)rows.size();
    for (int i = 0; i < n && i < out_max; i++) {
        const bf6::WalkRow& r = rows[(size_t)i];
        out[i].res_name = r.mesh.c_str();     // owned by the walk, alive until reopen
        // 3x4 row-major: the three basis rows then the origin, in the GAME's
        // space. The binding converts handedness and units, not this.
        for (int k = 0; k < 4; k++) {
            out[i].xform[k * 3 + 0] = r.xf.m[k].x;
            out[i].xform[k * 3 + 1] = r.xf.m[k].y;
            out[i].xform[k * 3 + 2] = r.xf.m[k].z;
        }
        out[i].material_scope = 0;
    }
    return n;
}
int bf6_level_lights(bf6_ctx*, const char*, bf6_light*, int) { return 0; }
bf6_terrain* bf6_read_terrain(bf6_ctx* c, const char* level) {
    if (!c || !level || !*level) return nullptr;

    // The level's heightfield lives in its streaming-tree resource, which is
    // the one whose name carries both "streamingtree" and the level id. Found
    // by name because that is what the mount gives us: there is no table that
    // says "this level's terrain is here".
    std::string want;
    {
        std::string lvl = level;
        for (char& ch : lvl) ch = (char)std::tolower((unsigned char)ch);
        for (const auto& kv : c->src.res()) {
            std::string n = kv.first;
            for (char& ch : n) ch = (char)std::tolower((unsigned char)ch);
            if (n.find("streamingtree") != std::string::npos &&
                n.find(lvl) != std::string::npos) { want = kv.first; break; }
        }
    }
    if (want.empty()) return nullptr;

    std::string err;
    std::vector<uint8_t> res = c->src.get_res(want, err);
    if (res.empty()) return nullptr;

    bf6::Terrain t;
    if (!t.parse(res, err)) return nullptr;
    t.resolve_external([&](const std::string& guid) {
        std::string e;
        return c->src.get_chunk(guid, e);
    });

    bf6::TerrainGrid g;
    if (!t.composite(g, 0, err)) return nullptr;

    TerrainHandle* th = new TerrainHandle();
    th->heights = std::move(g.heights);
    th->t.width = th->t.height = g.size;
    th->t.heights = th->heights.data();
    for (int i = 0; i < 3; i++) {
        th->t.world_min[i] = g.lo[i];
        th->t.world_max[i] = g.hi[i];
    }
    th->t.height_scale  = g.world_size_y;
    th->t.splat_texture = -1;
    th->t.color_texture = -1;
    c->handles[&th->t] = bf6_ctx::HK_TERRAIN;
    return &th->t;
}

void bf6_free(bf6_ctx* c, void* handle) {
    if (!handle || !c) return;
    auto it = c->handles.find(handle);
    // A pointer this context never handed out is not ours to delete. Better to
    // leak than to run a destructor over memory of unknown type, which is the
    // exact mistake this table exists to stop.
    if (it == c->handles.end()) return;
    const int kind = it->second;
    c->handles.erase(it);
    switch (kind) {
    case bf6_ctx::HK_MESH:    delete reinterpret_cast<MeshHandle*>(handle);    break;
    case bf6_ctx::HK_TERRAIN: delete reinterpret_cast<TerrainHandle*>(handle); break;
    default: break;
    }
}

}  // extern "C"
