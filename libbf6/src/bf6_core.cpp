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

namespace fs = std::filesystem;

struct bf6_ctx {
    bf6::Source src;
    int lifted = 0;
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

bf6_mesh* bf6_read_mesh(bf6_ctx*, const char*, int) { return nullptr; }   // module 6
const bf6_texture* bf6_texture_at(bf6_ctx*, int) { return nullptr; }
int bf6_level_instances(bf6_ctx*, const char*, bf6_instance*, int) { return 0; }
int bf6_level_lights(bf6_ctx*, const char*, bf6_light*, int) { return 0; }
bf6_terrain* bf6_read_terrain(bf6_ctx*, const char*) { return nullptr; }

void bf6_free(bf6_ctx*, void*) { /* nothing handed out yet */ }

}  // extern "C"
