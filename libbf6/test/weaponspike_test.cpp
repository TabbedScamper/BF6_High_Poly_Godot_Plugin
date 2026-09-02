// Can a native tool read a WEAPON straight out of the install, with no
// extract, no Python and no staging drive?
//
// The previewer today stages 38 GB to a drive and converts every mesh to GLB
// and every texture to webp so a browser can read them. That whole stage
// exists to feed the browser, not because the data needs it. libbf6 already
// mounts an install and decodes meshes and textures, and bf6_read_mesh
// resolves materials against the bundle the mesh RESOURCE lives in, which the
// header notes is the right answer precisely for "a browser, a preview" with
// no placement above it to ask.
//
// So this asks the one question that decides whether a C++ previewer is worth
// building: point it at an install, name a weapon, and see whether geometry
// and pixels come back. It renders nothing. Vertices and texels on stdout are
// the entire deliverable.
//
//   weaponspike_test <game_dir> [weapon] [--list]
//
// Exit 0 means the data layer holds and only UI work remains.
#include "bf6_core.h"
#include <cstdio>
#include <cstring>
#include <cstdlib>
#include <string>
#include <vector>
#include <algorithm>
#include <cmath>

static const char* slot_name(bf6_tex_slot s)
{
    switch (s)
    {
    case BF6_TEX_ALBEDO:    return "albedo";
    case BF6_TEX_NORMAL:    return "normal";
    case BF6_TEX_WO:        return "wo";
    case BF6_TEX_EMISSIVE:  return "emissive";
    case BF6_TEX_MASK:      return "mask";
    default:                return "other";
    }
}

// Prefer a first-person base mesh: it is what a previewer shows, and picking
// deterministically keeps the run comparable between invocations.
static bool better(const std::string& a, const std::string& b)
{
    auto score = [](const std::string& s)
    {
        int v = 0;
        if (s.find("_1p_mesh") != std::string::npos) v += 4;
        if (s.find("base")     != std::string::npos) v += 2;
        if (s.find("shadow")   != std::string::npos) v -= 8;
        if (s.find("_zonly")   != std::string::npos) v -= 8;
        return v;
    };
    const int sa = score(a), sb = score(b);
    if (sa != sb) return sa > sb;
    return a < b;                       // stable tie-break
}

int main(int argc, char** argv)
{
    if (argc < 2)
    {
        std::printf("usage: weaponspike_test <game_dir> [weapon] [--list]\n");
        return 2;
    }
    const char* game = argv[1];
    const char* want = (argc > 2 && argv[2][0] != '-') ? argv[2] : "m4a1";
    bool list_only = false;
    for (int i = 2; i < argc; i++)
        if (!std::strcmp(argv[i], "--list")) list_only = true;

    // 1) The storefront gate first. An EA App install reads archives fine and
    //    returns nothing for every type lookup WITHOUT erroring, so a tool
    //    that skips this check produces a complete-looking empty result.
    std::string exe = std::string(game) + "\\bf6.exe";
    double bits = 0.0;
    const int readable = bf6_typeinfo_readable(exe.c_str(), &bits);
    std::printf("typeinfo entropy   %.3f bits/byte -> %s\n", bits,
                readable == 1 ? "readable" :
                readable == 0 ? "ENCRYPTED (EA App)" : "exe unreadable");

    char err[512] = { 0 };
    bf6_ctx* c = bf6_open(game, err, (int)sizeof(err));
    if (!c) { std::printf("open failed: %s\n", err); return 1; }
    std::printf("opened             %s%s\n", game,
                bf6_was_lifted(c) ? "  (schema was OOA-lifted)" : "");

    // 2) Mount everything EXCEPT levels. Weapons live in common bundles, and
    //    level content is the big slow half we do not need here.
    if (!bf6_mount_all(c, 0, err, (int)sizeof(err)))
    { std::printf("mount failed: %s\n", err); bf6_close(c); return 1; }

    const int n_ebx = bf6_list_ebx(c, nullptr, nullptr, 0);
    const int n_res = bf6_list_res(c, nullptr, nullptr, 0);
    std::printf("mounted            %d ebx, %d res\n", n_ebx, n_res);

    // 3) Find the weapon's meshes by name. This is the step that replaces the
    //    entire extract: a substring query against the mount's name table.
    std::string q = std::string("weapons/") + want;
    int hits = bf6_list_res(c, q.c_str(), nullptr, 0);
    if (hits <= 0)                       // fall back to a bare name match
    { q = want; hits = bf6_list_res(c, q.c_str(), nullptr, 0); }
    if (hits <= 0)
    { std::printf("no resources match '%s'\n", want); bf6_close(c); return 1; }

    std::vector<bf6_asset> rows((size_t)hits);
    hits = bf6_list_res(c, q.c_str(), rows.data(), hits);

    std::vector<std::string> meshes;
    for (int i = 0; i < hits; i++)
    {
        const std::string nm = rows[(size_t)i].name ? rows[(size_t)i].name : "";
        if (nm.find("_mesh") != std::string::npos) meshes.push_back(nm);
    }
    std::sort(meshes.begin(), meshes.end());
    std::printf("matched '%s'       %d resources, %d meshes\n",
                q.c_str(), hits, (int)meshes.size());

    if (list_only)
    {
        for (size_t i = 0; i < meshes.size() && i < 60; i++)
            std::printf("   %s\n", meshes[i].c_str());
        bf6_close(c);
        return 0;
    }
    if (meshes.empty()) { std::printf("no *_mesh resources\n"); bf6_close(c); return 1; }

    std::string pick = meshes[0];
    for (const std::string& m : meshes) if (better(m, pick)) pick = m;
    std::printf("reading            %s\n", pick.c_str());

    // 4) Geometry.
    bf6_mesh* m = bf6_read_mesh(c, pick.c_str(), 0);
    if (!m) { std::printf("bf6_read_mesh returned NULL\n"); bf6_close(c); return 1; }

    long long verts = 0, tris = 0;
    int with_uv1 = 0;
    for (int i = 0; i < m->section_count; i++)
    {
        const bf6_section& s = m->sections[i];
        verts += s.vertex_count;
        tris  += s.index_count / 3;
        if (s.uv1) with_uv1++;
    }
    std::printf("\nGEOMETRY\n");
    std::printf("  sections         %d\n", m->section_count);
    std::printf("  vertices         %lld\n", verts);
    std::printf("  triangles        %lld\n", tris);
    std::printf("  sections w/ uv1  %d of %d\n", with_uv1, m->section_count);
    std::printf("  aabb             %.3f %.3f %.3f  ..  %.3f %.3f %.3f  (m)\n",
                m->aabb_min[0], m->aabb_min[1], m->aabb_min[2],
                m->aabb_max[0], m->aabb_max[1], m->aabb_max[2]);
    std::printf("  materials        %d\n", m->material_count);

    // How much of this mesh is BONE-DRIVEN? The moving pieces of a receiver -
    // bolt, ejection cover, charging handle, trigger - are bones rather than
    // separate meshes, so a viewer that ignores the stream draws them at their
    // bone-local origin and they look detached.
    {
        int withBones = 0;
        long long boneVerts = 0;
        int lo = 1 << 20, hi = -1;
        for (int i = 0; i < m->section_count; i++)
        {
            const bf6_section& s2 = m->sections[i];
            if (!s2.bones) continue;
            withBones++;
            for (int v = 0; v < s2.vertex_count; v++)
            {
                const int b = (int)s2.bones[v];
                if (b < lo) lo = b;
                if (b > hi) hi = b;
                if (b != 0) boneVerts++;
            }
        }
        std::printf("  bone stream      %d of %d sections\n", withBones, m->section_count);
        if (withBones)
            std::printf("  bone indices     %d..%d, %lld verts on a non-zero bone\n",
                        lo, hi, boneVerts);
        std::printf("  bone palette     %s\n",
                    m->section_count && m->sections[0].bone_list ? "present" : "NOT DECODED YET");
    }

    // Falsifiable check on the channel we just plumbed through. The UV census
    // measured TexCoord1 at a FIXED world density of 1.97 +/- 0.09 UV per
    // metre (one repeat per 50.9 cm) regardless of part size, while TexCoord0
    // is a per-object 0..1 unwrap whose density falls as parts grow. So if
    // uv1 really is the paint channel and not garbage, its UV-per-metre lands
    // near 1.97 and uv0's does not.
    {
        const float dx = m->aabb_max[0] - m->aabb_min[0];
        const float dy = m->aabb_max[1] - m->aabb_min[1];
        const float dz = m->aabb_max[2] - m->aabb_min[2];
        const float world = std::sqrt(dx*dx + dy*dy + dz*dz);
        const bf6_section& s = m->sections[0];
        for (int ch = 0; ch < 2; ch++)
        {
            const float* uv = ch ? s.uv1 : s.uv0;
            if (!uv) { std::printf("  uv%d              ABSENT\n", ch); continue; }
            float lo[2] = { 1e30f, 1e30f }, hi[2] = { -1e30f, -1e30f };
            int finite = 0;
            for (int v = 0; v < s.vertex_count; v++)
                for (int k = 0; k < 2; k++)
                {
                    const float t = uv[v*2+k];
                    if (!(t > -1e30f && t < 1e30f)) continue;   // shipped inf
                    finite++;
                    if (t < lo[k]) lo[k] = t;
                    if (t > hi[k]) hi[k] = t;
                }
            if (!finite) { std::printf("  uv%d              no finite values\n", ch); continue; }
            const float span = (hi[0]-lo[0]) > (hi[1]-lo[1]) ? (hi[0]-lo[0]) : (hi[1]-lo[1]);
            std::printf("  uv%d              u %.3f..%.3f  v %.3f..%.3f   span %.3f -> %.2f UV/m\n",
                        ch, lo[0], hi[0], lo[1], hi[1], span,
                        world > 1e-6f ? span / world : 0.f);
        }
    }

    // 5) Pixels. One decoded texture is the whole claim: if a real BCn payload
    //    comes back, the browser's webp round-trip is unnecessary.
    std::printf("\nTEXTURES\n");
    int bound = 0, decoded = 0;
    long long bytes = 0;
    for (int mi = 0; mi < m->material_count && decoded < 6; mi++)
    {
        const bf6_material_desc& md = m->materials[mi];
        for (int b = 0; b < md.texture_count; b++)
        {
            const bf6_tex_binding& tb = md.textures[b];
            if (tb.texture < 0) continue;
            bound++;
            const bf6_texture* t = bf6_texture_at(c, tb.texture);
            if (!t || t->data_len <= 0) continue;
            decoded++;
            bytes += t->data_len;
            if (decoded <= 6)
                std::printf("  %-7s %5d x %-5d fmt %-3d srgb %d  %8d bytes  %s\n",
                            slot_name(tb.slot), t->width, t->height,
                            (int)t->format, t->srgb, t->data_len,
                            bf6_texture_name_at(c, tb.texture));
        }
    }
    std::printf("  bound %d, decoded %d, %.2f MB of compressed texels\n",
                bound, decoded, bytes / 1e6);

    // WHOLE-WEAPON material coverage. One mesh proving out says nothing about
    // the assembled gun: the question that matters is whether EVERY part a
    // consumer draws gets its albedo, normal and MRO.
    {
        std::printf("\nassembled coverage\n");
        int parts = 0, sects = 0, withAlb = 0, withNrm = 0, withMro = 0, bare = 0;
        int triedScope = 0;
        // The receiver's albedo, as the reference every part should share.
        int baseAlbedo = -1;
        for (int mi = 0; mi < m->material_count && baseAlbedo < 0; mi++)
            for (int b = 0; b < m->materials[mi].texture_count; b++)
                if (m->materials[mi].textures[b].slot == BF6_TEX_ALBEDO)
                { baseAlbedo = m->materials[mi].textures[b].texture; break; }
        for (const std::string& r : meshes)
        {
            if (r.find("_1p_mesh") == std::string::npos) continue;
            const size_t leaf = r.find_last_of('/');
            const std::string ln = leaf == std::string::npos ? r : r.substr(leaf + 1);
            if (ln.find("_ws") != std::string::npos) continue;
            bf6_mesh* pm = bf6_read_mesh(c, r.c_str(), 0);
            if (!pm) continue;
            parts++;
            for (int i = 0; i < pm->section_count; i++)
            {
                const bf6_section& s2 = pm->sections[i];
                sects++;
                bool a2 = false, n2 = false, m2 = false;
                if (s2.material >= 0 && s2.material < pm->material_count)
                {
                    const bf6_material_desc& md = pm->materials[s2.material];
                    for (int b = 0; b < md.texture_count; b++)
                    {
                        if (md.textures[b].texture < 0) continue;
                        if (md.textures[b].slot == BF6_TEX_ALBEDO) a2 = true;
                        if (md.textures[b].slot == BF6_TEX_NORMAL) n2 = true;
                        if (md.textures[b].slot == BF6_TEX_MRO)    m2 = true;
                    }
                }
                withAlb += a2; withNrm += n2; withMro += m2;
                if (!a2)
                {
                    bare++;
                    // RETRY SCOPED. A shader state key is unique only within a
                    // bundle, and the mesh RESOURCE lives in an art bundle
                    // while its material lives in a per-part dpf bundle
                    // (dpf_<weapon>_<part>_<code>_bundle_1p). Resolving
                    // against the resource's own bundle finds nothing for
                    // these parts - the record is there, in a bundle nobody
                    // asked. This is the test of that.
                    if (triedScope < 12)
                    {
                        // Derive the part token from the mesh name and look for
                        // a bundle whose name carries it.
                        std::string part = ln;
                        const size_t up = part.find("_1p_mesh");
                        if (up != std::string::npos) part = part.substr(0, up);
                        const size_t lastu = part.find_last_of('_');
                        if (lastu != std::string::npos) part = part.substr(lastu + 1);
                        // Exact bundle names, as they ship. A prefix does not
                        // match: the shipped name carries a per-variant hash
                        // suffix (dpf_m4a1_panelleft_1ebaj57_bundle_1p).
                        std::string guess;
                        if (ln.find("panelleft")  != std::string::npos)
                            guess = "dpf_m4a1_panelleft_1ebaj57_bundle_1p";
                        else if (ln.find("panelright") != std::string::npos)
                            guess = "dpf_m4a1_panelright_13qy040_bundle_1p";
                        else if (ln.find("magazine") != std::string::npos)
                            guess = "dpf_m4a1_magazine_18klqic_bundle_1p";
                        else
                            guess = "dpf_" + std::string(want) + "_" + part;
                        bf6_mesh* sm = bf6_read_mesh_scoped(c, r.c_str(), 0,
                                                            guess.c_str(), nullptr);
                        int sb = 0;
                        if (sm && s2.material < sm->material_count)
                            for (int b = 0; b < sm->materials[s2.material].texture_count; b++)
                                if (sm->materials[s2.material].textures[b].texture >= 0) sb++;
                        // IS IT THE RIGHT MATERIAL, OR A COLLISION? The
                        // library refuses to widen to a sibling bundle on
                        // purpose: a key is unique only within a scope, and a
                        // sibling that happens to carry it binds a confidently
                        // wrong texture. A weapon shares ONE sheet set across
                        // its parts, so the honest check is whether the scoped
                        // albedo id equals the receiver's.
                        int sAlb = -1;
                        if (sm && s2.material < sm->material_count)
                            for (int b = 0; b < sm->materials[s2.material].texture_count; b++)
                                if (sm->materials[s2.material].textures[b].slot == BF6_TEX_ALBEDO)
                                    sAlb = sm->materials[s2.material].textures[b].texture;
                        std::printf("    scoped %-44s bound %d  albedo id %d  base id %d  %s\n",
                                    guess.c_str(), sb, sAlb, baseAlbedo,
                                    sAlb < 0 ? "" :
                                    (sAlb == baseAlbedo ? "MATCHES the receiver"
                                                        : "DIFFERENT sheet"));
                        if (false) std::printf("    scoped retry on \"%s\": %s, bound %d\n",
                                    guess.c_str(), sm ? "read" : "NULL", sb);
                        if (sm) bf6_free(c, sm);
                        triedScope++;
                    }
                    // Name the part and say whether the material resolved at
                    // all: "no record" and "record with no albedo slot" are
                    // different failures needing different fixes.
                    const bool hasMat = (s2.material >= 0 && s2.material < pm->material_count);
                    int bound = 0;
                    if (hasMat)
                        for (int b = 0; b < pm->materials[s2.material].texture_count; b++)
                            if (pm->materials[s2.material].textures[b].texture >= 0) bound++;
                    if (bare <= 8)
                        std::printf("    bare: %-52s sec %d  mat %s  bound %d\n",
                                    ln.c_str(), i, hasMat ? "yes" : "NONE", bound);
                }
            }
            bf6_free(c, pm);
        }
        std::printf("  parts %d, sections %d\n", parts, sects);
        std::printf("  albedo %d/%d   normal %d/%d   mro %d/%d\n",
                    withAlb, sects, withNrm, sects, withMro, sects);
        std::printf("  sections with NO albedo: %d%s\n", bare,
                    bare ? "   <- these draw black" : "");
    }

    // ---- skinning ------------------------------------------------------
    // The question: does applying the palette PULL THE MESH TOGETHER? If the
    // authored vertices are already in place, skinning changes nothing and the
    // bounding box is unmoved. If the parts are at their bone-local origins,
    // the authored box is too big and skinning shrinks it onto the receiver.
    {
        std::string md = std::string("common/hardware/weapons/") + "" ;
        // md_<weapon> sits beside the weapon folder, not under art/.
        std::string mdp;
        {
            const int q2 = bf6_list_ebx(c, (std::string("md_") + want).c_str(), nullptr, 0);
            if (q2 > 0)
            {
                std::vector<bf6_asset> rr((size_t)q2);
                const int g2 = bf6_list_ebx(c, (std::string("md_") + want).c_str(), rr.data(), q2);
                for (int i = 0; i < g2; i++)
                {
                    const std::string nm2 = rr[(size_t)i].name ? rr[(size_t)i].name : "";
                    if (nm2.find("/md_") == std::string::npos) continue;
                    if (nm2.find("_bundle") != std::string::npos) continue;
                    if (mdp.empty() || nm2.size() < mdp.size()) mdp = nm2;
                }
            }
        }
        std::printf("\nskinning\n  model definition  %s\n",
                    mdp.empty() ? "NOT FOUND" : mdp.c_str());

        const int nb = bf6_weapon_skin(c, mdp.empty() ? nullptr : mdp.c_str(), nullptr, 0);
        std::printf("  bones             %d\n", nb);
        if (nb > 0)
        {
            std::vector<bf6_bone_xform> sk((size_t)nb);
            bf6_weapon_skin(c, mdp.empty() ? nullptr : mdp.c_str(), sk.data(), nb);

            float alo[3] = { 1e30f, 1e30f, 1e30f }, ahi[3] = { -1e30f, -1e30f, -1e30f };
            float slo[3] = { 1e30f, 1e30f, 1e30f }, shi[3] = { -1e30f, -1e30f, -1e30f };
            long long moved = 0, total = 0;
            for (int i = 0; i < m->section_count; i++)
            {
                const bf6_section& s2 = m->sections[i];
                for (int v = 0; v < s2.vertex_count; v++)
                {
                    const float* P = s2.positions + v * 3;
                    for (int k = 0; k < 3; k++)
                    { if (P[k] < alo[k]) alo[k] = P[k]; if (P[k] > ahi[k]) ahi[k] = P[k]; }
                    int b = s2.bones ? (int)s2.bones[v] : 0;
                    if (b < 0 || b >= nb) b = 0;
                    const float* M = sk[(size_t)b].m;
                    float o[3];
                    for (int col = 0; col < 3; col++)
                        o[col] = P[0]*M[0*3+col] + P[1]*M[1*3+col] + P[2]*M[2*3+col] + M[9+col];
                    for (int k = 0; k < 3; k++)
                    { if (o[k] < slo[k]) slo[k] = o[k]; if (o[k] > shi[k]) shi[k] = o[k]; }
                    const float d = fabsf(o[0]-P[0]) + fabsf(o[1]-P[1]) + fabsf(o[2]-P[2]);
                    if (d > 0.001f) moved++;
                    total++;
                }
            }
            std::printf("  authored extent   %.3f x %.3f x %.3f m\n",
                        ahi[0]-alo[0], ahi[1]-alo[1], ahi[2]-alo[2]);
            std::printf("  skinned  extent   %.3f x %.3f x %.3f m\n",
                        shi[0]-slo[0], shi[1]-slo[1], shi[2]-slo[2]);
            std::printf("  vertices moved    %lld of %lld\n", moved, total);
        }
    }

    // ---- the part list, through the blueprint bundles -------------------
    {
        std::string mdp;
        const std::string q3 = std::string("md_") + want;
        const int c3 = bf6_list_ebx(c, q3.c_str(), nullptr, 0);
        if (c3 > 0)
        {
            std::vector<bf6_asset> rr((size_t)c3);
            const int g3 = bf6_list_ebx(c, q3.c_str(), rr.data(), c3);
            for (int i = 0; i < g3; i++)
            {
                const std::string nm3 = rr[(size_t)i].name ? rr[(size_t)i].name : "";
                if (nm3.find("/md_") == std::string::npos) continue;
                if (nm3.find("_bundle") != std::string::npos) continue;
                if (mdp.empty() || nm3.size() < mdp.size()) mdp = nm3;
            }
        }
        const int np = mdp.empty() ? 0 : bf6_weapon_parts(c, mdp.c_str(), nullptr, 0);
        std::printf("\npart graph\n  parts named by bundles: %d\n", np);
        if (np > 0)
        {
            std::vector<bf6_weapon_part> pv((size_t)np);
            const int gp = bf6_weapon_parts(c, mdp.c_str(), pv.data(), np);
            int resolved = 0, textured = 0;
            for (int i = 0; i < gp; i++)
            {
                bf6_mesh* pm = bf6_read_mesh_scoped(c, pv[(size_t)i].mesh, 0,
                                                    pv[(size_t)i].bundle, nullptr);
                bool alb = false;
                if (pm)
                {
                    resolved++;
                    for (int mi = 0; mi < pm->material_count && !alb; mi++)
                        for (int b = 0; b < pm->materials[mi].texture_count; b++)
                            if (pm->materials[mi].textures[b].slot == BF6_TEX_ALBEDO &&
                                pm->materials[mi].textures[b].texture >= 0) { alb = true; break; }
                    if (alb) textured++;
                    bf6_free(c, pm);
                }
                const bool iron = std::strstr(pv[(size_t)i].mesh, "ironsight") != nullptr;
                if (i < 14 || iron)
                {
                    const char* leaf = strrchr(pv[(size_t)i].mesh, '/');
                    std::printf("   %-52s %s%s%s%s\n", leaf ? leaf + 1 : pv[(size_t)i].mesh,
                                pm ? "ok" : "UNRESOLVED", alb ? " +albedo" : " (no albedo)",
                                iron ? "  bundle=" : "", iron ? pv[(size_t)i].bundle : "");
                }
            }
            std::printf("  resolved %d/%d, with albedo %d\n", resolved, gp, textured);
        }

        const int nd = mdp.empty() ? 0 : bf6_weapon_default_parts(c, mdp.c_str(), nullptr, 0);
        std::printf("\nmodel-definition defaults\n  authored meshes: %d\n", nd);
        if (nd > 0)
        {
            std::vector<bf6_weapon_part> dv((size_t)nd);
            const int gd = bf6_weapon_default_parts(c, mdp.c_str(), dv.data(), nd);
            int resolved = 0, sections = 0, albedo = 0;
            for (int i = 0; i < gd; i++)
            {
                bf6_mesh* pm = bf6_read_mesh_scoped(c, dv[(size_t)i].mesh, 0,
                                                    dv[(size_t)i].bundle, nullptr);
                if (!pm) continue;
                resolved++;
                for (int s = 0; s < pm->section_count; s++)
                {
                    sections++;
                    bool has = false;
                    const int mi = pm->sections[s].material;
                    if (mi >= 0 && mi < pm->material_count)
                        for (int b = 0; b < pm->materials[mi].texture_count; b++)
                            if (pm->materials[mi].textures[b].slot == BF6_TEX_ALBEDO &&
                                pm->materials[mi].textures[b].texture >= 0) { has = true; break; }
                    if (has) albedo++;
                    else
                    {
                        const char* leaf = strrchr(dv[(size_t)i].mesh, '/');
                        std::printf("    NO ALBEDO section %d: %s [%s]\n", s,
                                    leaf ? leaf + 1 : dv[(size_t)i].mesh,
                                    dv[(size_t)i].bundle);
                    }
                }
                std::printf("  default %-52s [%s]\n", dv[(size_t)i].mesh,
                            dv[(size_t)i].bundle);
                bf6_free(c, pm);
            }
            std::printf("  resolved %d/%d, albedo sections %d/%d\n",
                        resolved, gd, albedo, sections);
        }
    }

    bf6_weapon_base_stats baseStats{};
    const int haveStats = bf6_base_weapon_stats(c, "carbine", want, &baseStats);
    std::printf("\nbase stats\n  resolved %d  DMG %d  ROF %d  MAG %d\n",
                haveStats, baseStats.damage, baseStats.rate_of_fire, baseStats.magazine);

    const bool ok = (verts > 0 && tris > 0 && decoded > 0);
    std::printf("\n%s\n", ok
        ? "SPIKE PASSED: geometry and pixels came straight out of the install.\n"
          "No extract, no GLB, no webp, no Python. The data layer holds; what\n"
          "remains for a native previewer is the armory decode and the UI."
        : "SPIKE FAILED: see which of geometry or textures came back empty.");

    bf6_free(c, m);
    bf6_close(c);
    return ok ? 0 : 1;
}
