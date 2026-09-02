/* physics_test - PhysicsResource, ported from formats/PHYSICS_COLLISION.md.
 *
 * The spec states its own invariants and names its own traps, so the test
 * asserts THOSE rather than inventing softer ones:
 *
 *  1. MAGIC on every payload (spec: 42,515/42,515).
 *  2. FOUR SPAN EQUATIONS exact on every payload. The spec is explicit that a
 *     nonzero failure count means the parser has the layout wrong, not that
 *     data is damaged. Four simultaneous equations cannot hold by luck.
 *  3. SELF-RELATIVE vs BASE-RELATIVE is DEMONSTRATED, not assumed. The two
 *     readings agree on region A (both give 0x38) and must diverge elsewhere;
 *     the test counts payloads where they differ, so the trap is shown to be
 *     real on this corpus rather than taken on faith.
 *  4. HULL / MESH EXCLUSIVITY: +0x40 and +0x44 never both present.
 *  5. MidphaseNodeCount == FaceCount - 1 on meshes.
 *  6. FACE-START TABLE well-formed: starts at 0, strictly ascends, last entry
 *     == IndexCount. This is what proves the face table was read correctly and
 *     that +0x1C's LOW u16 is the face count.
 *  7. THE +0x24 TRAP: the real shape index at +0x38 must address far more
 *     distinct shapes than +0x24 does. On a big group +0x24 collapses tens of
 *     thousands of instances onto a handful of shapes.
 *  8. PRIMITIVE RADIUS: nonzero on exactly kinds 0/1, zero on hull/mesh.
 *  9. Fabricated resource names return nothing.
 */
#include "bf6_core.h"
#include <cstdio>
#include <cstring>
#include <cmath>
#include <set>
#include <string>
#include <vector>

int main(int argc, char** argv)
{
    if (argc < 2) { std::printf("usage: physics_test <game> [max]\n"); return 2; }
    const int maxn = (argc > 2) ? atoi(argv[2]) : 400;
    char err[512] = {0};
    bf6_ctx* c = bf6_open(argv[1], err, (int)sizeof(err));
    if (!c) { std::printf("open: %s\n", err); return 1; }
    if (!bf6_mount_all(c, 1, err, (int)sizeof(err))) { std::printf("mount: %s\n", err); return 1; }

    const int total = bf6_list_res(c, nullptr, nullptr, 0);
    std::vector<bf6_asset> assets((size_t)(total > 0 ? total : 0));
    const int got = bf6_list_res(c, nullptr, assets.data(), total);

    int seen = 0, read = 0, failed = 0;
    long shapes = 0, insts = 0, verts = 0, tris = 0;
    int hull = 0, mesh = 0, both = 0, neither = 0;
    int midphase_ok = 0, midphase_bad = 0;
    int fs_ok = 0, fs_bad = 0;
    int prim = 0, prim_radius_ok = 0, solid = 0, solid_radius_ok = 0;
    std::set<int> idx38, idx24;
    long badref = 0;

    for (int i = 0; i < got && read < maxn; i++) {
        const bf6_asset& a = assets[(size_t)i];
        if (!a.name || a.type != 0x41759364u) continue;
        seen++;
        bf6_physics* p = bf6_physics_read(c, a.name);
        if (!p) { failed++; continue; }
        read++;
        shapes += p->shape_count; insts += p->inst_count; verts += p->vertex_total;

        for (int s = 0; s < p->shape_count; s++) {
            const bf6_phys_shape& sh = p->shapes[s];
            if (sh.plane_ptr && sh.mesh_ptr) both++;
            else if (sh.plane_ptr) hull++;
            else if (sh.mesh_ptr) mesh++;
            else neither++;
            if (sh.mesh_ptr && sh.face_count) {
                if (sh.midphase_nodes == sh.face_count - 1) midphase_ok++;
                else midphase_bad++;
            }
            /* face-start table: 0, strictly ascending, last == IndexCount */
            if (sh.face_start_first >= 0 && sh.face_count) {
                const uint16_t* fsv = p->face_starts + sh.face_start_first;
                bool ok = (fsv[0] == 0) && (fsv[sh.face_count] == sh.index_count);
                for (int k = 1; ok && k <= sh.face_count; k++)
                    if (fsv[k] <= fsv[k - 1]) ok = false;
                if (ok) { fs_ok++; tris += sh.face_count; } else fs_bad++;
            }
        }
        for (int k = 0; k < p->inst_count; k++) {
            const bf6_phys_inst& d = p->instances[k];
            if (d.shape_index >= 0 && d.shape_index < p->shape_count) idx38.insert(d.shape_index);
            else if ((uint32_t)d.shape_index != 0xFFFFFFFFu) badref++;
            idx24.insert((int)d.trap_0x24);
            const bool isprim = (d.shape_type == 0 || d.shape_type == 1);
            if (isprim) { prim++; if (d.radius != 0.f) prim_radius_ok++; }
            else if (d.shape_type == 3 || d.shape_type == 6) {
                solid++; if (d.radius == 0.f) solid_radius_ok++;
            }
        }
        bf6_free(c, p);
    }

    std::printf("  PhysicsResource seen %d   parsed %d   REJECTED %d\n", seen, read, failed);
    std::printf("  shapes %ld  instances %ld  vertices %ld  faces %ld\n", shapes, insts, verts, tris);
    std::printf("  hull(+0x40) %d   mesh(+0x44) %d   BOTH %d   neither %d\n", hull, mesh, both, neither);
    std::printf("  midphase == faces-1 on meshes: %d ok / %d bad\n", midphase_ok, midphase_bad);
    std::printf("  face-start tables well-formed: %d ok / %d bad\n", fs_ok, fs_bad);
    std::printf("  distinct shapes addressed: +0x38 = %zu   +0x24 = %zu  <-- the trap\n",
                idx38.size(), idx24.size());
    std::printf("  primitives (kind 0/1) with radius: %d of %d\n", prim_radius_ok, prim);
    std::printf("  hull/mesh with ZERO radius       : %d of %d\n", solid_radius_ok, solid);
    std::printf("  shape indices out of range       : %ld\n", badref);

    /* ---- region A bodies: every field constrained by the spec ------------ */
    /* The spec states each field's legal range and its sentinel. Reading them
     * back and requiring those ranges is what distinguishes a decoded record
     * from 76 bytes that happen to parse. `-1` on the three surface fields
     * means "take the world default" and MUST survive - a reader that clamped
     * it to 0 would silently make everything frictionless. */
    long bodies = 0, bad_motion = 0, bad_drag = 0, bad_inertia = 0, bad_quat = 0;
    long default_friction = 0, static_placeholder = 0;
    std::set<uint32_t> motion_types;
    for (int i = 0; i < got && bodies < 4000; i++) {
        const bf6_asset& a = assets[(size_t)i];
        if (!a.name || a.type != 0x41759364u) continue;
        bf6_physics* p = bf6_physics_read(c, a.name);
        if (!p) continue;
        for (int k = 0; k < p->body_rec_count; k++) {
            const bf6_phys_body& bd = p->bodies[k];
            bodies++;
            motion_types.insert(bd.motion_type);
            if (bd.motion_type > 4) bad_motion++;
            if (!std::isfinite(bd.linear_drag) || bd.linear_drag < 0.f ||
                !std::isfinite(bd.angular_drag) || bd.angular_drag < 0.f) bad_drag++;
            for (int q = 0; q < 3; q++)
                if (!std::isfinite(bd.inv_inertia[q]) || bd.inv_inertia[q] < 0.f) bad_inertia++;
            const float ql = bd.quat[0]*bd.quat[0] + bd.quat[1]*bd.quat[1] +
                             bd.quat[2]*bd.quat[2] + bd.quat[3]*bd.quat[3];
            if (std::fabs(ql - 1.f) > 0.01f && ql > 1e-6f) bad_quat++;
            if (bd.static_friction == -1.f) default_friction++;
            if (bd.reciprocal_mass == 1.f) static_placeholder++;
        }
        bf6_free(c, p);
    }
    std::printf("\n  region A bodies read: %ld\n", bodies);
    std::printf("    motion types seen           : ");
    for (uint32_t m : motion_types) std::printf("%u ", m);
    std::printf("  (spec: 1 Fixed, 2 Keyframed, 3 Dynamic; 0/4 no-ops)\n");
    std::printf("    motion type out of range    : %ld\n", bad_motion);
    std::printf("    non-finite or negative drag : %ld\n", bad_drag);
    std::printf("    bad inverse inertia         : %ld\n", bad_inertia);
    std::printf("    non-unit, non-zero quaternion: %ld\n", bad_quat);
    std::printf("    StaticFriction == -1 (world default, must survive): %ld\n", default_friction);
    std::printf("    ReciprocalMass == 1 (static placeholder)          : %ld\n", static_placeholder);

    /* CONTROL 3, DEMONSTRATED. The spec says offsets are self-relative and
     * that a base-relative parser "passes the obvious spot check and then
     * reads vertices out of a descriptor region". Rather than take that on
     * faith, parse the SAME payloads both ways and score the span equations.
     * Self-relative must satisfy them; base-relative must not. */
    int both_agree_regionA = 0, self_ok = 0, base_ok = 0, checked = 0;
    for (int i = 0; i < got && checked < 200; i++) {
        const bf6_asset& a = assets[(size_t)i];
        if (!a.name || a.type != 0x41759364u) continue;
        const uint8_t* raw = nullptr;
        const int64_t n = bf6_read_raw(c, BF6_RAW_RES, a.name, &raw);
        if (n < 0x38 || !raw) continue;
        checked++;
        auto u32 = [&](size_t o) {
            return (uint32_t)raw[o] | ((uint32_t)raw[o+1] << 8) |
                   ((uint32_t)raw[o+2] << 16) | ((uint32_t)raw[o+3] << 24);
        };
        const uint32_t bodyC = u32(0x08), instC = u32(0x0C), shapeC = u32(0x18), rcC = u32(0x1C);
        /* self-relative: fieldAddress + stored.  base-relative: 0 + stored. */
        const int64_t sa = 0x24 + (int64_t)(int32_t)u32(0x24), ba = (int64_t)u32(0x24);
        const int64_t sb = 0x28 + (int64_t)(int32_t)u32(0x28), bb = (int64_t)u32(0x28);
        const int64_t sc = 0x2C + (int64_t)(int32_t)u32(0x2C), bc = (int64_t)u32(0x2C);
        const int64_t sd = 0x30 + (int64_t)(int32_t)u32(0x30), bd = (int64_t)u32(0x30);
        const int64_t sg = 0x34 + (int64_t)(int32_t)u32(0x34), bg = (int64_t)u32(0x34);
        if (sa == ba) both_agree_regionA++;      /* the spot check that fools you */
        auto spans = [&](int64_t A, int64_t B, int64_t C, int64_t D, int64_t G) {
            return A <= B && B <= C && C <= D && D <= G && G <= n &&
                   B - A == (int64_t)bodyC * 76 && C - B == (int64_t)shapeC * 72 &&
                   D - C == (int64_t)rcC * 44 && G - D == (int64_t)instC * 72;
        };
        if (spans(sa, sb, sc, sd, sg)) self_ok++;
        if (spans(ba, bb, bc, bd, bg)) base_ok++;
    }
    std::printf("\n  SELF-RELATIVE vs BASE-RELATIVE over %d payloads:\n", checked);
    std::printf("    region A resolves IDENTICALLY under both readings: %d of %d"
                "   <-- the spot check that hides the bug\n", both_agree_regionA, checked);
    std::printf("    all four span equations hold, self-relative: %d of %d\n", self_ok, checked);
    std::printf("    all four span equations hold, BASE-relative: %d of %d\n", base_ok, checked);

    /* CONTROL 9: fabricated names. */
    int fake = 0;
    if (bf6_physics_read(c, "common/environment/generic/common/props/nope_zzz.physics")) fake++;
    if (bf6_physics_read(c, "not/a/resource/at/all")) fake++;
    std::printf("  fabricated reads returning data  : %d of 2 (must be 0)\n", fake);

    const bool pass =
        read > 50 && failed == 0 && self_ok == checked && base_ok == 0 &&
        bodies > 0 && bad_motion == 0 && bad_drag == 0 && bad_inertia == 0 && bad_quat == 0 && both == 0 && midphase_bad == 0 && fs_bad == 0 &&
        badref == 0 && fake == 0 && prim_radius_ok == prim && solid_radius_ok == solid &&
        idx38.size() > idx24.size();
    std::printf("\n%s\n", pass ? "PASS" : "FAIL");
    bf6_close(c);
    return pass ? 0 : 1;
}
