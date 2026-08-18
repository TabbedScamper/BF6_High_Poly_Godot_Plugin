/* libbf6 - stub implementation.
 *
 * This compiles the contract in bf6_core.h and nothing more: every entry point
 * is a well-formed no-op that returns "nothing yet". The point is to lock the
 * ABI and prove the build path (MSVC + CMake -> bf6_core.dll/.lib) before any
 * decode logic is ported in from the GDScript reference.
 *
 * Ported modules replace these one at a time, each validated by byte-comparing
 * its output against the working Godot plugin (see PORT_PLAN.md).
 */
#include "bf6_core.h"
#include <cstring>
#include <cstdio>

struct bf6_ctx {
    int lifted = 0;
    /* the mount, catalogue, type schema and caches will live here as modules
     * are ported: BF6Container, BF6Cas, BF6Types (+ OOA lift), BF6MeshSet, ... */
};

extern "C" {

bf6_ctx* bf6_open(const char* game_dir, char* err, int err_len) {
    (void)game_dir;
    if (err && err_len > 0)
        std::snprintf(err, (size_t)err_len, "libbf6 stub: decode not ported yet");
    return nullptr;   /* nothing to open until the mount module lands */
}

void bf6_close(bf6_ctx* c) { delete c; }

int  bf6_was_lifted(bf6_ctx* c) { return c ? c->lifted : 0; }

int  bf6_level_count(bf6_ctx*) { return 0; }
const char* bf6_level_name(bf6_ctx*, int) { return ""; }

int  bf6_catalogue(bf6_ctx*, const char*, bf6_cat_entry*, int) { return 0; }

bf6_mesh* bf6_read_mesh(bf6_ctx*, const char*, int) { return nullptr; }

const bf6_texture* bf6_texture_at(bf6_ctx*, int) { return nullptr; }

int  bf6_level_instances(bf6_ctx*, const char*, bf6_instance*, int) { return 0; }
int  bf6_level_lights(bf6_ctx*, const char*, bf6_light*, int) { return 0; }

bf6_terrain* bf6_read_terrain(bf6_ctx*, const char*) { return nullptr; }

void bf6_free(bf6_ctx*, void*) { /* no allocations handed out yet */ }

} /* extern "C" */
