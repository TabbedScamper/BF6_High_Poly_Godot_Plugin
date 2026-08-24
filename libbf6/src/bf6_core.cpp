/* libbf6 - public C ABI.
 *
 * Module 2 is done, so bf6_open now opens a real install: it builds a Source,
 * mounts the shared SuperBundle TOCs, and hands back a context whose catalogue
 * can be listed. Geometry (bf6_read_mesh) waits on the EBX + meshset modules and
 * is still stubbed.
 */
#include "bf6_core.h"

#include <cstdio>
#include <algorithm>
#include <cmath>
#include <set>
#include <cstring>
#include <filesystem>
#include <map>
#include <memory>
#include <string>
#include <vector>

#include "source.h"
#include "meshset.h"
#include "depot.h"
#include "decals.h"
#include "destruction.h"
#include "terrain.h"
#include "texture.h"
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

    // ---- terraindecals ---------------------------------------------------
    // Parsed once per level and kept, for the same reason the walk is: the
    // container is megabytes and a caller commonly asks for a count before it
    // asks for the rows.
    std::unique_ptr<bf6::Decals>     decals;
    std::string                      decal_level;
    std::vector<std::vector<float> > decal_verts;
    std::vector<bf6_decal>           decal_rows;

    bf6_progress_fn progress = nullptr;
    void*           progress_user = nullptr;

    // ---- materials -------------------------------------------------------
    // Depots are parsed lazily and kept: a level touches a few hundred of the
    // thousands in a mount, and each is independent, which is what makes the
    // bundle a natural unit here.
    struct DepotHold { bf6::Depot depot; std::vector<uint8_t> bytes; };
    std::map<std::string, DepotHold> depots;

    // One entry per distinct texture RESOURCE, decoded on demand. Deduplicated
    // by name because the same texture is bound by many materials, and decoding
    // a 4K BC7 sheet once per binding would be minutes of nothing.
    struct TexHold {
        std::string      res;
        bf6::TextureImage img;
        bf6_texture      abi{};
        bool             tried = false, ok = false;
    };
    std::vector<TexHold>          textures;
    std::map<std::string, int32_t> tex_by_res;

    bf6::Depot* depot_named(const std::string& name, const std::vector<uint8_t>** out_bytes) {
        if (name.empty()) return nullptr;
        auto it = depots.find(name);
        if (it == depots.end()) {
            std::string e;
            DepotHold h;
            h.bytes = src.get_res(name, e);
            if (h.bytes.empty() || !h.depot.parse(h.bytes, e)) {
                depots.emplace(name, DepotHold{});   // remember the failure too
                return nullptr;
            }
            it = depots.emplace(name, std::move(h)).first;
        }
        if (it->second.bytes.empty()) return nullptr;
        *out_bytes = &it->second.bytes;
        return &it->second.depot;
    }

    int32_t texture_id(const std::string& res) {
        auto it = tex_by_res.find(res);
        if (it != tex_by_res.end()) return it->second;
        const int32_t id = (int32_t)textures.size();
        TexHold h;
        h.res = res;
        textures.push_back(std::move(h));
        tex_by_res.emplace(res, id);
        return id;
    }

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

// WHICH ENGINE SLOT A DEPOT SLOT FEEDS.
//
// From the research hub's SHADERS.md table plus the slots named here from the
// bindings themselves. Two things in it are easy to get wrong and expensive:
//
//  - a "_cs" base colour's ALPHA IS SMOOTHNESS, not opacity. The real opacity
//    twin is a separate slot (0xD405B0E1) that shares its high half, which is
//    why the full 32 bits always have to be compared.
//  - the NAMED emissive slot (0xD405B0E5) is bound by almost nothing and binds
//    black when it is; the glow that actually lights things is 0x407055FD.
// WHICH TEXCOORD IS THE PRIMARY UV, per material family.
//
// It is NOT a property of the geometry, and it must not be guessed. A previous
// attempt picked whichever channel "fits inside 0..1" and shipped; it was wrong
// and had to be retracted, because fitting 0..1 is how you RECOGNISE AN UNWRAP,
// and on architecture that channel is the lightmap/AO unwrap - buildings drew
// one brick the size of a facade.
//
//   *Unique*   sections : always TC0 (the prop's own atlas is authored there)
//   *CarPaint* sections : the DEPOT names it. Bool const 0x4F5F0664 on the
//                         section's record: 1 = TC1, 0 or absent = TC3.
//                         Every geometric fit provably fails here - one car's
//                         TC3 v spans -2.12..0.99 because unliveried pieces are
//                         parked outside the sheet.
//   everything else     : TC0
static int primary_uv_channel(const std::string& material, const bf6::MaterialBinding& mb)
{
    // DATA-DRIVEN, NEVER BY NAME, and never on one signal.
    //
    // The material names in this content do not contain "carpaint" at all, so a
    // name test quietly matches nothing and reports a clean zero - which reads
    // as agreement rather than as a detector that never fired.
    //
    // And the flakes slot ALONE is not enough either: a portable fuel canister
    // and a machine gun bind it, and forcing those onto TC3 would break props
    // that are correct on TC0. The full rule is flakes bound AND no base colour
    // texture AND no tile-paint palettes.
    (void)material;
    const bool carpaint =
        mb.textures.count(0xA11011B8) &&
        !mb.textures.count(0x54BBCD30) &&
        !mb.constants.count(0xF1CEE56D) && !mb.constants.count(0xF1CEE56E);

    if (carpaint) {
        auto it = mb.constants.find(0x4F5F0664);
        const bool tc1 = it != mb.constants.end() && !it->second.empty() && it->second[0] != 0;
        return tc1 ? 1 : 3;
    }
    return 0;   // Unique and everything else
}

static bf6_fmt fmt_of(int dxgi)
{
    switch (dxgi) {
    case 71: case 72: return BF6_FMT_BC1;
    case 74: case 75: case 77: case 78: return BF6_FMT_BC3;
    case 80: return BF6_FMT_BC4;
    case 83: return BF6_FMT_BC5;
    case 98: case 99: return BF6_FMT_BC7;
    case 95: return BF6_FMT_BC6H_U;
    case 96: return BF6_FMT_BC6H_S;
    case 28: return BF6_FMT_RGBA8;
    case 61: return BF6_FMT_R8;
    case 10: return BF6_FMT_RGBA16F;
    default: return BF6_FMT_UNKNOWN;
    }
}

// FAR-LOD IMPOSTORS PUT THEIR ALBEDO SOMEWHERE ELSE.
//
// An M_Vista / M_LastLod / M_Projection record binds NOTHING at the nominal
// base colour 0x54BBCD30 and puts its baked atlas at 0x54BBCD22 - the slot that
// carries a vehicle LIVERY on an ordinary material. The three share a
// 0x54BBCD** prefix and look like variants of one authored parameter under
// different shader families.
//
// So this cannot be a blanket mapping: making 0x54BBCD22 an albedo everywhere
// would paint a car with its livery sheet as the base colour. It is a
// FALLBACK, taken only when neither real base-colour slot is bound - which is
// exactly the condition the impostor records satisfy and ordinary ones do not.
//
// Measured on MP_Battery: 96 drawn sections across 768 placed instances bind
// 0x54BBCD22 with no base colour, and they are the out-of-bounds skyline.
// ---------------------------------------------------------------- colour
//
// A DEPOT RECORD CAN CARRY THE COLOUR ITSELF, and for whole families of prop
// that is the ONLY place the colour exists. Car paint is the clearest case: a
// carpaint record binds a flakes normal and NO base-colour texture at all, so
// a reader that only ever looks for a texture finds nothing, falls through to
// white, and every car on the map is white.
//
// Three sources, in priority order. They are exclusive in the data, but the
// order is stated rather than assumed because a record that carried two would
// otherwise resolve differently depending on map iteration order.
//
//   1. car paint      the body colour, and its smoothness
//   2. tile paint     the per-zone palette these architectural kits use
//   3. an albedo tint a MULTIPLIER over the sheet, which is where the
//                     "everything looks washed out / too dark" class of
//                     mismatch lives
//
// All of these end up in base_color, which a consumer multiplies its albedo
// sheet by. That works for both kinds at once: where there IS no sheet the
// consumer multiplies white and gets the colour, and where there is one it
// gets the tint. One field, no branch on the consumer's side.

// A float3 out of a constant blob at a byte offset, or false if it is short.
static bool const_c3(const bf6::MaterialBinding& mb, uint32_t hash, size_t off, float out[3])
{
    auto it = mb.constants.find(hash);
    if (it == mb.constants.end()) return false;
    const std::vector<uint8_t>& b = it->second;
    if (b.size() < off + 12) return false;
    std::memcpy(&out[0], b.data() + off + 0, 4);
    std::memcpy(&out[1], b.data() + off + 4, 4);
    std::memcpy(&out[2], b.data() + off + 8, 4);
    return true;
}

static bool const_f1(const bf6::MaterialBinding& mb, uint32_t hash, float& out)
{
    auto it = mb.constants.find(hash);
    if (it == mb.constants.end() || it->second.size() < 4) return false;
    std::memcpy(&out, it->second.data(), 4);
    return true;
}

// The tints are authored around a neutral, and the neutral means "no tint".
// 0.004 is the tolerance the reference uses; the doubling below is because the
// per-family tints are stored at half scale so that 0.5 is identity.
static const float kTintEps = 0.004f;

static bool near3(const float c[3], float v)
{
    return std::fabs(c[0] - v) < kTintEps &&
           std::fabs(c[1] - v) < kTintEps &&
           std::fabs(c[2] - v) < kTintEps;
}

static void resolve_colour(const bf6::MaterialBinding& mb, bf6_material_desc& md)
{
    const bool tilepaint = mb.constants.count(0xF1CEE56D) != 0;

    // 1. CAR PAINT. The full conjunction, for the same reason the UV rule uses
    //    it: the flakes slot alone is also bound by a fuel canister and a
    //    machine gun, and painting those in body colour would be worse than
    //    leaving them alone.
    if (mb.textures.count(0xA11011B8) &&
        !mb.textures.count(0x54BBCD30) && !mb.textures.count(0x54BBCD36) &&
        !tilepaint)
    {
        float body[3];
        if (const_c3(mb, 0xDD0512FA, 0, body))
        {
            md.base_color[0] = body[0];
            md.base_color[1] = body[1];
            md.base_color[2] = body[2];
            float smooth = 0.5f;
            const_f1(mb, 0xFE9EDB18, smooth);
            if (smooth < 0.f) smooth = 0.f;
            if (smooth > 1.f) smooth = 1.f;
            md.roughness = 1.f - smooth;
            return;
        }
    }

    // 2. TILE PAINT, at zone 0.
    //
    // Which of the eight zones a vertex takes is a PER-VERTEX selector, so the
    // honest answer needs the mesh, and a section can legitimately span two
    // zones. Entry 0 is the body colour on every record measured, which makes
    // it right by construction here rather than right by luck - but it is
    // still a floor, not the full rule, and a section that spans zones takes
    // one colour where the game takes two.
    if (tilepaint)
    {
        float a[3];
        if (const_c3(mb, 0xF1CEE56D, 0, a))
        {
            md.base_color[0] = a[0];
            md.base_color[1] = a[1];
            md.base_color[2] = a[2];
            return;
        }
    }

    // 3. AN ALBEDO TINT, which multiplies whatever sheet is bound.
    float t[3];
    if (const_c3(mb, 0x8A369BB2, 0, t) && !near3(t, 1.f))
    {
        md.base_color[0] = t[0]; md.base_color[1] = t[1]; md.base_color[2] = t[2];
        return;
    }
    // The two exclusive per-family tints. Stored at half scale: 0.5 is
    // identity, so anything else doubles into a real multiplier.
    if (const_c3(mb, 0x686A1072, 0, t) || const_c3(mb, 0x888A432A, 0, t))
    {
        if (!near3(t, 0.5f) && !near3(t, 0.4995f))
        {
            md.base_color[0] = t[0] * 2.f;
            md.base_color[1] = t[1] * 2.f;
            md.base_color[2] = t[2] * 2.f;
            if (!near3(md.base_color, 1.f)) return;
            md.base_color[0] = md.base_color[1] = md.base_color[2] = 1.f;
        }
    }
    // The eight-entry colour table, used ONLY where every entry agrees.
    //
    // Which entry a vertex takes is again per-vertex, so with no selector in
    // hand the only safe reading is a table that says the same thing whichever
    // entry is chosen. Taking entry 0 regardless would be a guess, and on a
    // table authored with eight different props in it, a badly wrong one.
    auto tab = mb.constants.find(0xC2BB295A);
    if (tab != mb.constants.end() && tab->second.size() >= 124)
    {
        float e0[3];
        if (const_c3(mb, 0xC2BB295A, 0, e0))
        {
            bool uniform = true;
            for (int k = 1; k < 8 && uniform; k++)
            {
                float ek[3];
                if (!const_c3(mb, 0xC2BB295A, (size_t)(16 * k), ek)) { uniform = false; break; }
                for (int j = 0; j < 3; j++)
                    if (std::fabs(ek[j] - e0[j]) > 1e-5f) { uniform = false; break; }
            }
            if (uniform && !near3(e0, 0.5f) && !near3(e0, 0.4995f))
            {
                float c[3] = { e0[0] * 2.f, e0[1] * 2.f, e0[2] * 2.f };
                if (!near3(c, 1.f))
                {
                    md.base_color[0] = c[0];
                    md.base_color[1] = c[1];
                    md.base_color[2] = c[2];
                }
            }
        }
    }
}

// AND CAR PAINT IS THE COUNTER-EXAMPLE THAT ALMOST BROKE THIS.
//
// "Binds the wrap slot and no base colour" is NOT enough. A carpaint record
// satisfies it exactly: it has no base-colour texture (its colour is a
// constant) and it does bind 0x54BBCD22 - with a DEFAULT sheet,
// common/shaders/textures/default/t_base_ca, standing in for a livery it does
// not have. Measured on MP_Battery, 87 carpaint sections match the naive rule,
// and taking it would have textured every car with a blank default and thrown
// away the body colour that was sitting in the record all along.
//
// So the flakes slot excludes it, the same way it identifies car paint
// everywhere else in this file.
static bool wrap_is_the_albedo(const bf6::MaterialBinding& mb)
{
    return mb.textures.count(0x54BBCD22) &&
           !mb.textures.count(0x54BBCD30) &&
           !mb.textures.count(0x54BBCD36) &&
           !mb.textures.count(0xA11011B8);
}

// WHICH SLOT ON THIS RECORD IS THE BASE COLOUR - as a chain, not a set.
//
// There is no single base-colour hash. The one everybody knows, 0x54BBCD30,
// covers most props, and 0x54BBCD36 covers vegetation, but whole families bind
// their colour somewhere else entirely and bind NOTHING at either: facades put
// it at 0x21F3F4E1, trim sheets at 0xEA026FC7, tile-breaker kits at 0xA4415059,
// far-LOD impostors at 0x54BBCD22.
//
// Read off the game rather than guessed. Censusing every slot on the depots
// that MP_Battery's placed props actually resolve to, and counting what asset
// suffix each is bound to, these come back 91-100% "_cs" on per-asset paths -
// which is what a base colour looks like and what a shared weathering sheet
// does not.
//
// STRICTLY A FALLBACK CHAIN, in this order, and only the first one present is
// taken. That matters: several of these are OVERLAY layers on a record that
// also has a real base colour, and promoting an overlay over the sheet beneath
// it would repaint a correct prop. Taken only where the alternative is drawing
// untextured, it can only be an improvement on nothing.
static uint32_t albedo_slot_of(const bf6::MaterialBinding& mb)
{
    static const uint32_t chain[] = {
        0x54BBCD30,   // the ordinary base colour
        0x54BBCD36,   // vegetation
        0x21F3F4E1,   // facade            4,697 instances, 91.2% "_cs"
        0xEA026FC7,   // trim              5,129 instances, 96.8% "_cs"
        0xA4415059,   // tile-breaker      3,679 instances, 100%  "_cs"
        // ASPHALT, which is why the roads read as empty space. The broken
        // asphalt kit is what dresses a road surface and its edges, and it
        // binds its colour at its own two hashes and nothing at 0x54BBCD30 -
        // so every piece of it drew untextured. 1,965 placed instances on
        // MP_Battery between them.
        0x691A5E17,   // asphalt ridge     1,079 instances, 100%  "_cs"
        0x691BEAB4,   // asphalt cracked     886 instances, 100%  "_cs"
        0x39DA140E,   // plaster           1,048 instances, 68.7% "_cs"
        0xA17E658F,   // cable / wire steel  159 instances, 100%  "_cs"
        0x365B13EF,   // backdrop terrain     29 instances, 100%  "_cs"
        0x1C5FA3EE,   // backdrop hulls       10 instances, 100%  "_cs"
    };
    // DELIBERATELY NOT IN THE CHAIN, though they census as 97-100% "_cs" on
    // per-asset paths and look exactly like the entries above:
    //
    //   0x002E8ADD  moss detail        41,279 instances
    //   0x05FFAEDA  moss detail normal
    //   0x5D2D90F3  rock detail         2,172 instances
    //   0x2776F9F6  rock detail
    //
    // These are DETAIL layers - a tiling sheet blended over whatever is
    // underneath, present on nearly every record in the level. Promoting one
    // to a base colour is the single worst thing this chain could do: it is on
    // more sections than any real albedo, so it would win almost everywhere
    // and paint the whole map in moss. That has happened before here, which is
    // why is_detail_layer exists.
    for (size_t i = 0; i < sizeof(chain) / sizeof(chain[0]); i++)
        if (mb.textures.count(chain[i])) return chain[i];
    // The impostor sheet last, and only under its own guard - see below.
    if (wrap_is_the_albedo(mb)) return 0x54BBCD22;
    return 0;
}

static bf6_tex_slot slot_for(uint32_t n32, bool& out_known, uint32_t albedo_slot = 0)
{
    out_known = true;
    if (albedo_slot && n32 == albedo_slot) return BF6_TEX_ALBEDO;
    switch (n32) {
    case 0x54BBCD30: case 0x54BBCD36:                 return BF6_TEX_ALBEDO;
    // The impostor's paired "_nsm": RG is the tangent normal, B is wetness
    // response and A is smoothness. Listed by its own hash rather than by a
    // "0xEC35 is a normal" rule, which would also catch a subsurface map.
    case 0xEC35AA10:                                  return BF6_TEX_NORMAL;
    // More normals, from the same census: each is 77-97% bound to an "_nv" /
    // "_nvt" / "_nts" / "_nma" asset sheet on a per-asset path. Listed one by
    // one for the reason the table has always given - one member of this
    // family is a subsurface map, so "0xEC35 is a normal" is not a rule.
    case 0xEC35AA69:                                  return BF6_TEX_NORMAL;
    case 0xEC35A742:                                  return BF6_TEX_NORMAL;
    case 0x2A507435: case 0x2C6B47EB:                 return BF6_TEX_NORMAL;
    // Normals: one hash per SHADER FAMILY, not one globally.
    case 0xEC35A74C: case 0xEC35A9E2: case 0xEC35A757:
    case 0xEC35A68C: case 0xEC35A697:                 return BF6_TEX_NORMAL;
    case 0xB1A29A3C:                                  return BF6_TEX_MRO;
    case 0x407055FD: case 0xD405B0E5:                 return BF6_TEX_EMISSIVE;
    case 0xD405B0E1:                                  return BF6_TEX_MASK;
    default: break;
    }
    out_known = false;
    return BF6_TEX_ALBEDO;
}

// THE DETAIL-LAYER TRAP. This slot sits on nearly every record and its texture
// is named "..._cs", so any fallback that picks "something albedo-looking"
// takes it - and it painted every glass pane and a whole skyline moss-green
// before it was excluded upstream. Never treat it as a base colour.
static bool is_detail_layer(uint32_t n32)
{
    return n32 == 0x002E8ADD || n32 == 0x05FFAEDA;
}

// djb2 over the lowercased path, for the variation key.
static uint64_t djb2_lower(const std::string& s)
{
    uint64_t h = 5381;
    for (unsigned char c : s) {
        if (c >= 'A' && c <= 'Z') c = (unsigned char)(c + 32);
        h = ((h << 5) + h) + c;
    }
    return h;
}

// A variation reuses a DERIVED key: sectionStateKey + djb2(variation path), as
// a genuine 64-bit add. The low dword's sum CARRIES into the high dword, so
// adding the halves independently is wrong on exactly the cases that matter.
static uint64_t variation_key(uint64_t state_key, const std::string& variation)
{
    if (variation.empty()) return state_key;
    return state_key + djb2_lower(variation);
}

struct MeshHandle {
    bf6_mesh                            mesh{};
    std::vector<bf6_section>            sections;
    std::vector<bf6_material_desc>      materials;
    std::vector<std::vector<bf6_tex_binding>> bindings;   // one array per material
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

bf6_mesh* bf6_read_mesh_scoped(bf6_ctx* c, const char* res_name, int lod,
                               const char* placing_bundle, const char* variation) {
    if (!c || !res_name) return nullptr;
    const std::string placing = placing_bundle ? placing_bundle : "";
    const std::string variant = variation ? variation : "";
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

    // ---- DROP THE PARTS THE GAME HIDES AT SPAWN ---------------------------
    //
    // A destructible prop carries its own damaged state inside its intact
    // mesh - the cracked windscreen, the crushed panel, the deflated tyre -
    // tagged per vertex and hidden until the piece breaks. Left in, every
    // parked car is drawn with its own wreck interpenetrating it, which is not
    // subtle: it reads as bodywork that is stretched, doubled and corrupt, and
    // it looks like a geometry bug rather than a missing filter.
    //
    // Skinned meshes are exempt: there the same per-vertex element is a
    // SKELETON BONE, a different and differently sized index space, and
    // indexing the part table with a bone id would cull arbitrary pieces of
    // every aircraft.
    // The part table lives in the prop EBX, so this needs the type schema.
    // A context opened without one can still read geometry, and silently
    // skipping the filter is better than refusing the mesh.
    //
    // THE PART INDEX IS CHECKED FIRST, and that ordering is the whole cost of
    // this feature. Asking the question needs the prop's EBX partition read and
    // parsed, and a map places about 1,450 distinct assets - so doing it for
    // every one of them would put seconds onto a load that is already the thing
    // people complain about. A mesh with no per-vertex part index cannot be
    // filtered whatever its table says, and that test is free: the index was
    // already decoded with the geometry.
    bool has_parts = false;
    for (const auto& g : secs)
        if (!g.parts.empty() && g.parts.size() == g.positions.size() / 3) { has_parts = true; break; }

    if (has_parts && ms.mesh_type != 1 && c->types) {
        const std::set<uint16_t> hidden =
            bf6::destruction_hidden_parts(c->src, *c->types, res_name);
        if (!hidden.empty()) {
            for (auto& g : secs) {
                if (g.parts.size() != g.positions.size() / 3) continue;
                std::vector<uint32_t> keep;
                keep.reserve(g.indices.size());
                // PER TRIANGLE, ON ITS FIRST VERTEX. A triangle spans one part
                // in practice, and requiring all three to be visible would also
                // drop the seam triangles between a hidden part and a visible
                // one - which punches a hole in the intact body instead of
                // removing an overlay.
                for (size_t k = 0; k + 2 < g.indices.size(); k += 3) {
                    const uint32_t v0 = g.indices[k];
                    if (v0 < g.parts.size() && hidden.count(g.parts[v0])) continue;
                    keep.push_back(g.indices[k]);
                    keep.push_back(g.indices[k + 1]);
                    keep.push_back(g.indices[k + 2]);
                }
                // The VERTICES are left alone. Only the triangles referencing
                // them are gone, so nothing has to be renumbered - a hidden
                // part's vertices simply become unreferenced.
                g.indices.swap(keep);
            }
            // A section can lose every triangle it had; an empty one would
            // become a zero-index draw downstream.
            secs.erase(std::remove_if(secs.begin(), secs.end(),
                       [](const bf6::MeshGeomSection& g) { return g.indices.empty(); }),
                       secs.end());
            if (secs.empty()) return nullptr;
        }
    }

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

    // ---- materials, one per section --------------------------------------
    //
    // The join: the section's state key, looked up in the depot co-located with
    // the bundle that PLACED this mesh. The placing bundle is the exact rule,
    // and a caller who knows it passes it in; reading a mesh on its own - a
    // browser, a preview - has no placement above it, so the bundle the
    // resource lives in is the fallback. Widening on a miss goes to ancestors
    // only, never to a sibling: a key is unique within a scope, so a sibling
    // holding it binds a material that merely COLLIDES, which looks fine and is
    // wrong.
    const std::string place = placing.empty()
        ? c->src.depot_for_res(res_name)
        : c->src.depot_for_bundle(placing);

    const std::vector<uint8_t>* dbytes = nullptr;
    bf6::Depot* dep = c->depot_named(place, &dbytes);

    mh->materials.resize((size_t)n);
    mh->bindings.resize((size_t)n);
    for (size_t i = 0; i < (size_t)n; i++) {
        bf6_material_desc& md = mh->materials[i];
        md.base_color[0] = md.base_color[1] = md.base_color[2] = md.base_color[3] = 1.f;
        md.emissive[0] = md.emissive[1] = md.emissive[2] = 0.f;
        md.roughness = 0.5f;
        md.metallic  = 0.f;
        md.two_sided = 0;
        md.alpha_test = 0;
        md.translucent = 0;
        md.alpha_from_albedo = 0;
        md.normal_is_nsm = 0;
        md.textures = nullptr;
        md.texture_count = 0;
        if (!dep) continue;

        const uint64_t key = variation_key(secs[i].state_key, variant);
        bf6::MaterialBinding mb = dep->textures_for(key, *dbytes);
        // A variation whose derived key is absent is not an error: not every
        // section has a variant. Fall back to the base key rather than binding
        // nothing.
        if (!mb.valid && key != secs[i].state_key)
            mb = dep->textures_for(secs[i].state_key, *dbytes);
        if (!mb.valid) continue;

        // ---- what KIND of surface this is, from the record ----------------
        //
        // THE SHADER'S OWN SWITCH, checked before anything about the mask's
        // content. Measured over every record carrying it on one level: 182 of
        // 193 with a real cutout sheet set it, and all 11 that did not were
        // foreign-filler pairings - a prop with no cutout of its own handed
        // another prop's sheet, which the game never samples. Cutting by such a
        // filler shreds the surface: a van's silhouette punched through a
        // wheel's UVs and read as "the tyres look damaged".
        {
            auto g = mb.constants.find(0x77D10576);
            if (g != mb.constants.end() && !g->second.empty() && g->second[0] != 0)
                md.alpha_test = 1;
        }
        // VEGETATION CUTS OUT FROM THE PAIRED "_a" SHEET, NOT FROM "_cu" ALPHA.
        //
        // The spec tables annotate the veg base colour as carrying coverage in
        // its alpha. It does not, and this was implemented that way here first:
        // measured over 708 vegetation shader states on one level, the "_cu"
        // alpha is near-CONSTANT per sheet and the constant differs between
        // sheets - 128 on one, 254..255 on another, 0..1 on an agave. A channel
        // uniformly ~0 on one plant and uniformly ~1 on another is not carrying
        // coverage for either, and masking by it gives blobs.
        //
        // The mask is the R channel of the "_a" texture in 0xD405B0E1, which is
        // the same slot everything else cuts out with. The reason the wrong
        // reading is easy to hold: a one-channel BC4 decompresses to R with
        // A = 1, so a consumer that reads the MASK's alpha sees a constant 1,
        // concludes there is no coverage there, and goes looking in the base
        // colour. That constant is the decoder's invention, not the asset's.
        if (mb.textures.count(0xD405B0E1)) {
            // The shader's own gate still wins when it is present; absent, a
            // real mask being bound is what decides.
            auto g = mb.constants.find(0x77D10576);
            const bool gated = g != mb.constants.end() && !g->second.empty();
            if (!gated) md.alpha_test = 1;
        }

        // Glass, data-driven: the destruction glass volume slot bound, or the
        // glass tint palette present. Never by name.
        if (mb.textures.count(0xBB245590) || mb.constants.count(0xA0106346))
            md.translucent = 1;

        // THE PRIMARY UV, now that the record is in hand. Car paint is the only
        // family that moves, and only the depot can say where to.
        {
            const int ch = primary_uv_channel(secs[i].material, mb);
            if (ch != 0 && !secs[i].uv[ch].empty()) {
                secs[i].uv0 = secs[i].uv[ch];
                // The section's uv0 pointer was taken before this, so it has to
                // be repointed or the change never reaches the caller.
                mh->uv[i] = secs[i].uv0;
                mh->sections[i].uv0 = mh->uv[i].data();
            }
        }

        resolve_colour(mb, md);
        const uint32_t albedo_slot = albedo_slot_of(mb);
        const bool wrap_albedo = albedo_slot == 0x54BBCD22;

        // AND AN IMPOSTOR IS NOT ALPHA TESTED, however binary its sheet looks.
        //
        // These atlases are ~100% binary-shaped in alpha, which invites a
        // cutout rule. The recovered pixel shader for Aftermath M_Vista reads
        // RGB only and contains no discard: the alpha is packing metadata, not
        // coverage. Inventing a test from the shape removed most of a valid
        // 3,636-triangle shell and read as "the LOD is corrupt".
        if (wrap_albedo) md.alpha_test = 0;

        for (const auto& kv : mb.textures) {
            const uint32_t n32 = kv.first;
            if (is_detail_layer(n32)) continue;
            bool known = false;
            const bf6_tex_slot slot = slot_for(n32, known, albedo_slot);
            if (!known) continue;

            // The FILE guid resolves through the partition index to the texture
            // asset's name; the resource is that name without the .ebx.
            const auto& gi = c->src.partition_index();
            auto ait = gi.find(kv.second);
            if (ait == gi.end()) continue;
            std::string tres = ait->second;
            if (tres.size() > 4 && tres.compare(tres.size() - 4, 4, ".ebx") == 0)
                tres.resize(tres.size() - 4);

            // A PLACEHOLDER IS NOT AN ALBEDO. Plenty of records fill a slot
            // they do not use with common/shaders/textures/default or /debug,
            // and binding one as a base colour paints the prop a flat
            // stand-in - which looks like a texture that loaded, so nobody
            // goes looking for a lookup bug. Only the albedo is guarded:
            // elsewhere a default IS the intended neutral.
            if (slot == BF6_TEX_ALBEDO &&
                (tres.find("/textures/default/") != std::string::npos ||
                 tres.find("/textures/debug/") != std::string::npos))
                continue;

            bf6_tex_binding b;
            b.slot = slot;
            b.texture = c->texture_id(tres);
            mh->bindings[i].push_back(b);

            // The vista "_nsm" is not an ordinary normal map: RG normal,
            // B wetness, A smoothness. The consumer has to unpack it
            // differently, so the record says so - keyed on the slot hash,
            // which is exact, not on the asset's name.
            if (n32 == 0xEC35AA10 && slot == BF6_TEX_NORMAL)
                md.normal_is_nsm = 1;
        }
        md.textures = mh->bindings[i].empty() ? nullptr : mh->bindings[i].data();
        md.texture_count = (int32_t)mh->bindings[i].size();
    }
    mh->mesh.materials      = mh->materials.data();
    mh->mesh.material_count = (int32_t)n;
    for (int k = 0; k < 3; k++) { mh->mesh.aabb_min[k] = lo[k]; mh->mesh.aabb_max[k] = hi[k]; }
    c->handles[&mh->mesh] = bf6_ctx::HK_MESH;
    return &mh->mesh;
}
bf6_mesh* bf6_read_mesh(bf6_ctx* c, const char* res_name, int lod) {
    return bf6_read_mesh_scoped(c, res_name, lod, nullptr, nullptr);
}

// Decoded on demand and kept: the same texture is bound by many materials, and
// a 4K BC7 sheet decoded once per binding would be minutes of nothing.
const bf6_texture* bf6_texture_at(bf6_ctx* c, int texture_id) {
    if (!c || texture_id < 0 || (size_t)texture_id >= c->textures.size()) return nullptr;
    bf6_ctx::TexHold& h = c->textures[(size_t)texture_id];
    if (!h.tried) {
        h.tried = true;
        std::string e;
        std::vector<uint8_t> res = c->src.get_res(h.res, e);
        if (!res.empty()) {
            auto fetch = [c](const std::string& g) {
                std::string e2;
                return c->src.get_chunk(g, e2);
            };
            h.ok = bf6::Texture::decode(res, fetch, h.img, 0, e);
        }
        if (h.ok) {
            h.abi.width     = h.img.width;
            h.abi.height    = h.img.height;
            h.abi.mip_count = h.img.mip_count;   // the chain from the chosen level down
            h.abi.format    = fmt_of(h.img.dxgi);
            h.abi.data      = h.img.blocks.data();
            h.abi.data_len  = (int32_t)h.img.blocks.size();
            h.abi.srgb      = h.img.srgb ? 1 : 0;
        }
    }
    return h.ok ? &h.abi : nullptr;
}
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
        // Owned by the walk, alive until the level is reopened, same as the name.
        out[i].placing_bundle = r.bundle.empty() ? nullptr : r.bundle.c_str();
        out[i].variation      = r.var.empty()    ? nullptr : r.var.c_str();
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

// ------------------------------------------------------------ terraindecals
//
// The property-name hashes the decal material binds its sheets under. These are
// u64 property names in the record's own stream, not depot slot hashes - a
// decal record carries its textures directly rather than through a shader
// state key.
//
// SLOT_OP IS THE ONE THAT MATTERS MOST. A lane stripe, a crosswalk, a stop
// line: they are all COVERAGE, not colour, and a consumer that binds only the
// base colour draws the asphalt and none of the paint - which is a road that
// still reads as empty.
static const uint64_t DECAL_SLOT_CV  = 0x399AC0336ACFE03Cull;   // base colour
static const uint64_t DECAL_SLOT_NHS = 0x567A9BC35CCBB1B2ull;   // normal/height/smooth
static const uint64_t DECAL_SLOT_AO  = 0x3A411B3E209FC9E2ull;   // ambient occlusion
static const uint64_t DECAL_SLOT_OP  = 0x3810287D4CE70B49ull;   // coverage / markings

static const char* decal_res_for(bf6_ctx* c, const std::string& level)
{
    // BY RES TYPE, NOT BY NAME. The name is
    // "<level path>/<level>_terraindecals" on every map sampled, but the TYPE
    // is what the format guarantees, and a map that spelled its name
    // differently would otherwise silently ship no roads at all.
    static std::string want;
    want.clear();
    std::string lvl = level, fallback;
    for (char& ch : lvl) ch = (char)std::tolower((unsigned char)ch);
    for (const auto& kv : c->src.res()) {
        if (kv.second.type != (uint32_t)bf6::Decals::kResType) continue;
        std::string n = kv.first;
        for (char& ch : n) ch = (char)std::tolower((unsigned char)ch);
        if (n.find(lvl) != std::string::npos) { want = kv.first; return want.c_str(); }
        if (fallback.empty()) fallback = kv.first;
    }
    want = fallback;
    return want.empty() ? nullptr : want.c_str();
}

int bf6_level_decals(bf6_ctx* c, const char* level, bf6_decal* out, int out_max)
{
    if (!c || !level || !*level) return 0;

    // Parsed once per level and kept, like the walk: the container is a few
    // megabytes and the caller may well ask for a count before asking for the
    // rows.
    if (c->decal_level != level) {
        c->decals.reset();
        c->decal_verts.clear();
        c->decal_rows.clear();
        c->decal_level = level;

        const char* rn = decal_res_for(c, level);
        if (!rn) return 0;
        std::string err;
        std::vector<uint8_t> res = c->src.get_res(rn, err);
        if (res.empty()) return 0;

        std::unique_ptr<bf6::Decals> dc(new bf6::Decals());
        if (!dc->parse(std::move(res), err)) return 0;

        const auto& gi = c->src.partition_index();
        auto tex_of = [&](const bf6::DecalRecord& r, uint64_t name) -> int32_t {
            for (const bf6::DecalProp& p : r.props) {
                if (p.name != name || p.kind != bf6::DecalProp::Kind::Texture) continue;
                auto it = gi.find(p.guid);
                if (it == gi.end()) return -1;
                std::string t = it->second;
                if (t.size() > 4 && t.compare(t.size() - 4, 4, ".ebx") == 0) t.resize(t.size() - 4);
                return c->texture_id(t);
            }
            return -1;
        };

        c->decal_verts.reserve(dc->records().size());
        for (const bf6::DecalRecord& r : dc->records()) {
            std::vector<bf6::DecalVertex> vs = dc->vertices(r);
            // NON-INDEXED, so this is an equality and not a bound. A record
            // whose vertex count disagrees with its triangle count is being
            // read at the wrong offset, and a wrong offset still yields
            // plausible floats - it would render as confetti rather than as
            // nothing. Dropped.
            if (vs.empty() || vs.size() != (size_t)r.tri_count * 3) continue;

            std::vector<float> flat;
            flat.reserve(vs.size() * 8);
            for (const bf6::DecalVertex& v : vs) {
                flat.push_back(v.x); flat.push_back(v.z);
                flat.push_back(v.u); flat.push_back(v.v);
                flat.push_back(v.r); flat.push_back(v.g);
                flat.push_back(v.b); flat.push_back(v.a);
            }

            bf6_decal d{};
            d.vertex_count = (int32_t)vs.size();
            for (int k = 0; k < 3; k++) { d.aabb_min[k] = r.aabb_min[k]; d.aabb_max[k] = r.aabb_max[k]; }
            d.tiling0 = r.tiling0;
            d.tiling1 = r.tiling1;
            d.planar  = bf6::Decals::is_planar(vs) ? 1 : 0;
            d.albedo  = tex_of(r, DECAL_SLOT_CV);
            d.opacity = tex_of(r, DECAL_SLOT_OP);
            d.normal  = tex_of(r, DECAL_SLOT_NHS);

            c->decal_verts.push_back(std::move(flat));
            c->decal_rows.push_back(d);
        }
        // The vectors are only now stable, so the pointers go in last. Taking
        // them inside the loop would leave every one but the final row dangling
        // after a reallocation, which reads as a decoder that produces garbage
        // for all but the last record.
        for (size_t i = 0; i < c->decal_rows.size(); i++)
            c->decal_rows[i].verts = c->decal_verts[i].data();

        c->decals = std::move(dc);
    }

    const int n = (int)c->decal_rows.size();
    if (out && out_max > 0)
        for (int i = 0; i < n && i < out_max; i++) out[i] = c->decal_rows[i];
    return n;
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
