/* libbf6 - engine-neutral Battlefield 6 decode core.
 *
 * The contract between the decode (which reads and understands the game's own
 * files) and an engine binding (Godot, Unreal) that turns the result into scene
 * objects. Nothing engine-specific crosses this line: vectors are plain floats,
 * buffers are pointer+length, strings are UTF-8. The core resolves EVERYTHING -
 * the mount, Oodle, the DRM lift, material and variation resolution, the
 * placement walk - and hands back baked data. The binding only uploads it,
 * converts coordinates, and parents nodes.
 *
 * A C ABI on purpose: a Godot GDExtension and an Unreal module can both call it
 * without either knowing the other exists, and it stays stable while the C++
 * inside churns.
 *
 * Memory: every pointer this API returns is owned by the core and freed with
 * bf6_free() on the handle the returning call gave you. Do not free members
 * individually. Handles are valid until freed or until bf6_close().
 */
#ifndef BF6_CORE_H
#define BF6_CORE_H

#include <stdint.h>

/* Windows only exports DLL symbols that are explicitly marked. The shared build
 * defines BF6_BUILDING_DLL and every public function is tagged for export; a
 * static build (Unreal linking bf6_core_static) leaves it empty. Consumers that
 * load the DLL at runtime (GetProcAddress) don't need the import side, so this
 * stays a plain export tag rather than the usual export/import dance. */
#if defined(_WIN32) && defined(BF6_BUILDING_DLL)
#  define BF6_API __declspec(dllexport)
#else
#  define BF6_API
#endif

#ifdef __cplusplus
extern "C" {
#endif

#define BF6_ABI_VERSION 3

/* ------------------------------------------------------------------ session */
typedef struct bf6_ctx bf6_ctx;

/* Runtime contract check for dynamically loaded consumers. A binding must
 * compare this result with BF6_ABI_VERSION before resolving or calling any
 * struct-bearing API; this catches a current DLL paired with a stale copied
 * header, which otherwise compiles and can corrupt memory without an error. */
BF6_API int bf6_abi_version(void);

/* Open an install: mount, read the type schema, and OOA-lift the executable in
 * memory if it is DRM-wrapped (EA App). All storefront divergence lives behind
 * this one call. Returns NULL on failure and writes a reason into err.
 * An empty game_dir is the explicit no-install mode: it always succeeds and
 * returns a context with nothing mounted. Mesh reads fail on it, but the
 * placeable catalogue (bf6_load_placeables and friends) works fully. */
BF6_API bf6_ctx* bf6_open(const char* game_dir, char* err, int err_len);
BF6_API void     bf6_close(bf6_ctx*);

/* True if the type schema had to be decrypted (EA install). For diagnostics. */
BF6_API int      bf6_was_lifted(bf6_ctx*);

/* --------------------------------------------------------------- enumerate */
/* The SDK ships its placeable-object catalogue as JSON (level_info.json +
 * asset_types.json under FbExportData/). Point this at that directory once after
 * bf6_open; it populates the level list and the placeable catalogue below.
 * Returns the number of placeables loaded, 0 on failure (reason in err). Until
 * called, bf6_level_count and bf6_list_placeables report empty. */
BF6_API int bf6_load_placeables(bf6_ctx*, const char* fbexport_dir,
                                char* err, int err_len);

BF6_API int         bf6_level_count(bf6_ctx*);
BF6_API const char* bf6_level_name(bf6_ctx*, int index);      /* e.g. "MP_Badlands" */

/* One SDK-placeable object. Strings point into the ctx and live until close. */
typedef struct {
    const char* type;          /* the placeable's name, e.g. "AAGun_01"     */
    const char* directory;     /* UI category, e.g. "Generic/Common/Props"  */
    const char* mesh;          /* the 'mesh' constant - a resource stem      */
    int32_t     physics_cost;
    int32_t     universal;     /* 1 if allowed on every level (no restriction) */
} bf6_placeable;

/* List the SDK placeables available on `level` - the objects allowed on that
 * level PLUS the universal ones - exactly the Portal object library's per-level
 * set. level NULL/"" lists every placeable. `search` filters by type substring
 * (NULL/"" = all). Returns the TOTAL match count; writes up to out_max. */
BF6_API int bf6_list_placeables(bf6_ctx*, const char* level, const char* search,
                                bf6_placeable* out, int out_max);

/* One editable field the SDK exposes on a placeable (from its properties[]). */
typedef struct {
    const char* name;       /* "CameraFOV", "Team", "ObjId"                   */
    const char* type;       /* "float","int","bool","string","vector",       */
                            /* "selection", or an object-link type like       */
                            /* "PolygonVolume" / "Array[SpawnPoint]"          */
    const char* def;        /* default value as a string, may be ""           */
    const char* selections; /* "selection" enum options, newline-joined; ""   */
                            /* when the field is not an enum                  */
} bf6_prop;

/* List the editable properties of placeable `type` (e.g. a CapturePoint has ~34;
 * a plain prop has just "ObjId"). Returns the TOTAL count; writes up to out_max.
 * Strings point into the ctx and live until close. */
BF6_API int bf6_placeable_props(bf6_ctx*, const char* type,
                                bf6_prop* out, int out_max);

typedef struct {
    const char* res_name;      /* the asset id, e.g. common/.../foo_mesh   */
    const char* category;      /* grouping for a browser, may be ""        */
} bf6_cat_entry;

/* Fill out[] with up to out_max catalogue entries matching `search` (NULL or ""
 * = everything). Returns the number written. */
BF6_API int bf6_catalogue(bf6_ctx*, const char* search,
                  bf6_cat_entry* out, int out_max);

/* ---------------------------------------------------------------- geometry */
typedef struct {
    const float*    positions;   /* xyz * vertex_count                      */
    const float*    normals;     /* xyz * vertex_count, or NULL             */
    const float*    tangents;    /* xyzw * vertex_count, or NULL            */
    const float*    uv0;         /* uv * vertex_count, primary channel      */
    const float*    uv1;         /* uv * vertex_count, secondary, or NULL   */
    const uint32_t* colors;      /* rgba8 * vertex_count, or NULL           */
    const uint32_t* indices;
    int32_t         vertex_count;
    int32_t         index_count;
    int32_t         material;    /* index into bf6_mesh.materials           */
    /* PER-VERTEX BONE / PART INDEX, or NULL.
     *
     * The BoneIndices element (vertex usage 2). What it MEANS depends on the
     * mesh kind, and reading it without knowing which is a real error:
     *   Skinned (weapons)  - a slot in this section's bone palette, which
     *                        resolves through `bone_list` to a skeleton bone.
     *                        The bolt, ejection cover, charging handle and
     *                        trigger are bones, not separate meshes, so a
     *                        consumer that ignores this draws them wherever
     *                        their bone-local origin happens to fall.
     *   Rigid/Composite    - a destruction part index, a different and
     *                        differently sized index space entirely.
     * Decoded all along; it simply never crossed this ABI, the same way uv1
     * did not. */
    const uint16_t* bones;
    /* The mesh's bone/part list from the MeshSet header (one per mesh, handed
     * to every section). These are skeleton bone ids, but this is NOT a
     * skinning palette - it is the set of bones that own mesh parts and
     * bounding boxes, and it is far too short to index with `skin_bones`.
     * NULL on a Rigid mesh, which carries no block at all. */
    const uint16_t* bone_list;
    int32_t         bone_list_count;
    /* PER-VERTEX SKIN BINDING. NULL on an unskinned section.
     *
     * `skin_influences` is 4 or 8. Both arrays are
     * skin_influences * vertex_count and are lane-aligned:
     * skin_weights[v * skin_influences + k] weights skin_bones[v * skin_influences + k].
     *
     * `bones` above is ONE index per vertex and is not the same thing - on a
     * destructible it is a destruction part, and even on a skinned mesh it is
     * only the last lane. Skinning a character with it collapses every vertex
     * onto a single joint.
     *
     * The weights sum to 1 ACROSS ALL `skin_influences` LANES. On an
     * 8-influence section the first four alone sum to less than 1; the rest is
     * in the second element, and both are already concatenated here.
     *
     * THE INDICES ARE SKELETON BONE IDS DIRECTLY - do not remap them through
     * `bone_list`. That was the natural assumption and it is wrong: on a
     * character the palette holds 1 to 7 entries (it is the part-ownership and
     * bounding-box list) while skin indices reach 210, so routing through it
     * would index past the end of a 7-element array on nearly every vertex.
     * Measured on ske_soldier_3p: 0 of 339,568 body influences and 0 of 69,096
     * face influences fall outside the rig's 291 bones, and the bones they
     * weight are the right ones - the face mesh's heaviest are Head, Neck and
     * HeadRoll, the body's are Spine, Hips and the knees.
     *
     * A bone index carrying 0x8000 has already been decoded on the way out. */
    const uint16_t* skin_bones;
    const float*    skin_weights;
    int32_t         skin_influences;
    /* Authored MeshSubsetCategory_TransparentDecal membership. Per section,
     * never inferred from an asset or material name. */
    int32_t         is_decal;
    /* THIS SECTION'S SHADER STATE KEY, from the MeshSection record.
     *
     * It is the handle into the ShaderBlockDepot, and therefore the way to
     * reach everything the section-texture list does NOT carry - the character
     * eye shader, skin subsurface and wrinkle slots among them. Without it a
     * consumer can only see the two or three textures the section resolves
     * directly.
     *
     * A STATE KEY IS NOT GLOBALLY UNIQUE - it is scoped to the depot it came
     * from, so the same key resolves differently against a different bundle.
     * Resolve it against the depot of the bundle the mesh was read with. */
    uint64_t        state_key;
} bf6_section;

typedef struct bf6_material_desc bf6_material_desc;   /* below */

typedef struct {
    const bf6_section*       sections;
    int32_t                  section_count;
    const bf6_material_desc*  materials;
    int32_t                  material_count;
    /* MeshType: 0 Rigid, 1 Skinned, 2 Composite.
     *
     * NOT cosmetic. It decides what the per-vertex usage-2 element MEANS, and
     * the two readings are different index spaces entirely: on a Skinned mesh
     * it is a skeleton bone id, on a Rigid or Composite destructible it is a
     * DESTRUCTION PART index. A consumer that assumes one gets plausible small
     * integers either way and binds vertices to the wrong thing with no error.
     * The renderbone 0x8000 convention is likewise MeshType 1 only.
     *
     * `bone_count` is the MeshSet's declared bone count; `lod_count` is how
     * many LODs the set carries, of which this handle decoded one. */
    int32_t                  mesh_type;
    int32_t                  bone_count;
    int32_t                  lod_count;
    float                    aabb_min[3];
    float                    aabb_max[3];
} bf6_mesh;

/* Build one asset's geometry. lod 0 = full detail. NULL if unreadable.
 *
 * Materials resolve against the bundle the mesh RESOURCE lives in, which is the
 * right answer for reading a mesh on its own - a browser, a preview - because
 * there is no placement above it to ask. */
BF6_API bf6_mesh* bf6_read_mesh(bf6_ctx*, const char* res_name, int lod);

/* The same, for a mesh that is being PLACED.
 *
 * placing_bundle is the bundle whose placement pulled this mesh in (a walk row
 * carries it). That is the exact scope for a material: a shader state key is
 * unique only within a bundle, so resolving against any other one can bind a
 * material that merely collides - which looks correct and is not.
 *
 * variation is the ObjectVariation asset path from the placement, or NULL. It
 * derives a second key (state key + djb2 of the path, a genuine 64-bit add),
 * and the base key is used when that derived key is absent.
 *
 * Passed rather than held on the context on purpose: the scope belongs to the
 * INSTANCE, and hidden state would make two placements of one mesh race. */
BF6_API bf6_mesh* bf6_read_mesh_scoped(bf6_ctx*, const char* res_name, int lod,
                              const char* placing_bundle, const char* variation);

/* Armory-specialized form of the same read. It resolves material FILE guids
 * through the bounded runtime armory index, avoiding a scan of unrelated level
 * partitions. Geometry and bundle scoping are otherwise identical. */
BF6_API bf6_mesh* bf6_read_armory_mesh_scoped(bf6_ctx*, const char* res_name, int lod,
                              const char* placing_bundle, const char* variation);

/* DOES THIS VARIATION CHANGE ANYTHING FOR THIS MESH? 1 when any of the mesh's
 * section keys derives a resolving record in the placing bundle's depot, else
 * 0. The question exists because splitting instance groups by variation is
 * not free - every extra group is another component and another mesh build -
 * so a renderer splits only where the split is EARNED, which is the rule the
 * reference plugin measured its way to. Cached on the context. */
BF6_API int bf6_variation_live(bf6_ctx*, const char* res_name,
                               const char* placing_bundle, const char* variation);

/* ---------------------------------------------------------------- material */
typedef enum {
    BF6_TEX_ALBEDO = 0,
    BF6_TEX_NORMAL,
    /* Hardware/weapon `_wo` sheet.  This is NOT a generic M/R/O texture:
     * R is an edge/wear field and A is the paint mask; G/B are not yet
     * identified.  Smoothness comes from the ALBEDO `_cs` alpha channel. */
    BF6_TEX_WO,
    BF6_TEX_EMISSIVE,
    BF6_TEX_MASK,
    BF6_TEX_SLOT_COUNT
} bf6_tex_slot;

/* Source-compatibility only.  Older consumers called `_wo` an MRO map.  The
 * numeric slot remains stable, but new code must not apply M/R/O semantics. */
#define BF6_TEX_MRO BF6_TEX_WO

typedef struct {
    bf6_tex_slot slot;
    int32_t      texture;      /* index for bf6_texture_at(), or -1          */
} bf6_tex_binding;

struct bf6_material_desc {
    const bf6_tex_binding* textures;
    int32_t                texture_count;
    float                  base_color[4];
    float                  emissive[3];
    float                  roughness;
    float                  metallic;
    int32_t                two_sided;   /* 0/1 */
    /* The shader's OWN alpha-test switch, not a guess from the textures. A
     * depot record carries a bool that says whether it cuts out; a prop with no
     * cutout of its own is sometimes handed another prop's mask in the alpha
     * slot, and cutting by that shreds the surface. Checked before any test of
     * the mask's content. */
    int32_t                alpha_test;  /* 0/1 */
    /* Classified from the bindings, not from names: glass is the
     * destruction-glass-volume slot or the glass-tint palette. */
    int32_t                translucent; /* 0/1 */
    /* Vegetation carries its cutout in its OWN base colour's alpha (the "_cu"
     * sheet), not in a separate mask. Everything else that cuts out ships a
     * single-channel "_a" sheet, because a normal "_cs" base colour's alpha is
     * SMOOTHNESS. A consumer has to mask from a different place for the two,
     * so the record says which. */
    int32_t                alpha_from_albedo; /* 0/1 */
    /* The far-LOD impostor's "_nsm" packing on the NORMAL binding, from the
     * recovered Aftermath M_Vista pixel shader: RG is the tangent normal
     * (reconstruct Z), B is WETNESS response and A is SMOOTHNESS. It is not a
     * metallic map, and roughness comes from 1 - A. When this is set, light
     * the surface with specular INDEPENDENT of albedo, the way the game's
     * separate G-buffer outputs do - a baseColor * (diffuse + specular)
     * composition makes the sheet's authentic dark texels impossible to
     * light and reads as corruption. */
    int32_t                normal_is_nsm; /* 0/1 */
    /* The depot record binds the terrain virtual-texture colour slot
     * 0x89D3AD5E and has no usable albedo of its own. These are the authored
     * M_TerrainBlend surfaces that receive terrain decals. */
    int32_t                terrain_decal_receiver; /* 0/1 */
};

/* ---------------------------------------------------------------- textures */
typedef enum {
    BF6_FMT_RGBA8 = 0,
    BF6_FMT_BC1,   BF6_FMT_BC3,   BF6_FMT_BC4,
    BF6_FMT_BC5,   BF6_FMT_BC7,
    /* Added rather than reusing a slot: skies and light probes are BC6H, and a
     * binding that quietly reported them as BC7 would upload garbage. */
    BF6_FMT_BC6H_U, BF6_FMT_BC6H_S,
    BF6_FMT_R8,     BF6_FMT_RGBA16F,
    /* The 33-cubed VisualEnvironment grading LUT. Appended so the values of
     * every previously published format remain ABI-stable. */
    BF6_FMT_RGB10A2,
    BF6_FMT_UNKNOWN = 255
} bf6_fmt;

typedef struct {
    int32_t        width;
    int32_t        height;
    int32_t        mip_count;
    bf6_fmt        format;
    const uint8_t* data;       /* all mips, tightly packed, GPU-ready        */
    int32_t        data_len;
    int32_t        srgb;       /* 0/1 */
} bf6_texture;

/* Textures are handed across COMPRESSED (BCn) so the engine uploads them as-is.
 * texture_id comes from a material's bf6_tex_binding. Owned by the ctx. */
BF6_API const bf6_texture* bf6_texture_at(bf6_ctx*, int texture_id);

/* Same exact texture resource and authored mip chain, capped for an on-screen
 * preview. For streamed textures this deliberately reads the embedded mip tail
 * rather than isolated mip0, which makes the cap effective. Context-owned. */
BF6_API const bf6_texture* bf6_texture_at_max_dim(bf6_ctx*, int texture_id,
                                                  int max_dimension);

/* The live resource name behind a texture id returned by any read path.
 * Context-owned, stable until bf6_close. This is metadata, not an exported
 * intermediate: consumers use it to select material behaviour from the
 * current install (for example road paint versus track wear) without shipping
 * a per-patch id table. */
BF6_API const char* bf6_texture_name_at(bf6_ctx*, int texture_id);

/* --------------------------------------------------------------- placements */
typedef struct {
    const char* res_name;      /* the mesh to instance                       */
    float       xform[12];     /* 3x4 row-major: basis columns then origin,  */
                               /* in the GAME's space - the binding converts */
    int32_t     material_scope;/* pre-resolved variation key, for caching    */
    /* The bundle whose placement pulled this mesh in, and the ObjectVariation
     * path if it has one. Pass BOTH to bf6_read_mesh_scoped: they are what
     * makes a material resolve in the right scope, and they belong to the
     * INSTANCE rather than to the mesh. Owned by the ctx, valid until the next
     * bf6_open_level. */
    const char* placing_bundle;
    const char* variation;
    /* Authoring partition that emitted this placement.  This is deliberately
     * appended so existing consumers keep the offsets of every older field.
     * Owned by the context, with the same lifetime as res_name. */
    const char* source;
} bf6_instance;

/* ---------------------------------------------------------------- progress */
/* Called from inside the long calls so a caller can show something moving.
 * `stage` is a short label ("mounting", "indexing partitions", "walking");
 * done/total are that stage's own counts, and total may be 0 when it is not
 * known yet.
 *
 * CALLED FROM WHATEVER THREAD IS DOING THE WORK, including several at once
 * during indexing, so an implementation must be safe to call concurrently and
 * must NOT touch a UI directly. Store the numbers and let the UI thread read
 * them. Return 0 to ask the operation to stop.
 */
typedef int (*bf6_progress_fn)(void* user, const char* stage, int done, int total);

BF6_API void bf6_set_progress(bf6_ctx*, bf6_progress_fn, void* user);

/* Mount a level's archives and read the type schema, which every placement
 * call needs. all_levels also mounts every OTHER level, which is what makes the
 * whole placeable catalogue resolvable and is not free. Returns 0 on success,
 * with a message in err.
 *
 * Expensive and cached on the context: mounting is a few seconds and indexing
 * every partition's guid is a few more. Call it once per level. */
BF6_API int bf6_open_level(bf6_ctx*, const char* level, const char* exe_path,
                   int all_levels, char* err, int err_len);

/* Every placement in a level. Returns the count; if it exceeds out_max, out[]
 * is filled to out_max and the return value tells you to call again bigger.
 * bf6_open_level must have been called for this level first.
 *
 * res_name points into storage owned by the context and stays valid until the
 * next bf6_open_level. */
BF6_API int bf6_level_instances(bf6_ctx*, const char* level,
                        bf6_instance* out, int out_max);

/* Walk one mounted prefab/asset directly and return its placements.  This is
 * the runtime read path for front-end scenes that are instantiated by flow
 * code instead of appearing as a conventional level root.  The asset is read
 * from the mounted game archives; no exported placement table is involved. */
BF6_API int bf6_asset_instances(bf6_ctx*, const char* asset,
                        bf6_instance* out, int out_max,
                        char* err, int err_len);

/* ------------------------------------------------------- local light placements
 *
 * THE MAP'S ARTIFICIAL LIGHT: every lamp, spotlight, ceiling fixture and
 * emissive panel it places. bf6_level_lighting is the sun and the sky; this is
 * everything else, and on an urban map it is thousands of fixtures. A level
 * imported with a sun and none of these is lit at midday whatever its preset
 * says, because ALL of its artificial light is here.
 *
 * These are found by walking the level graph, not by reading its lighting
 * partitions: sampling lay_art_*_lighting.ebx and _layers_content/lighting.ebx
 * directly returns zero light entities, because almost every light sits inside
 * a placed fixture prefab. The call therefore does its own traversal and takes
 * tens of seconds on a big map, cached per level like the placement walk.
 *
 * Only bf6_open plus a mount is needed - bf6_open_level's placement walk does
 * NOT have to have run. */
typedef enum {
    BF6_LIGHT_SPHERE = 0,   /* PbrSphereLight: a point light with a real radius */
    BF6_LIGHT_SPOT   = 1,   /* PbrSpotLight                                     */
    BF6_LIGHT_TUBE   = 2,   /* PbrTubeLight: a line or capsule emitter          */
    BF6_LIGHT_RECT   = 3,   /* PbrRectangularLight: an area emitter             */
    BF6_LIGHT_OTHER  = 4    /* a declared light class carrying no light fields   */
} bf6_light_type;

/* LightUnitType, the engine's own two-member enum. The two are DIFFERENT
 * PHYSICAL QUANTITIES and cannot share a conversion constant: a consumer must
 * branch on `unit` before scaling anything. Measured on mp_dumbo, 11,634 of
 * 11,640 lights are LuminousPower, so lumens is the case that matters. */
typedef enum {
    BF6_LIGHT_UNIT_LUMINOUS_POWER = 0,  /* lumens (lm), total emitted flux      */
    BF6_LIGHT_UNIT_LUMINANCE      = 1   /* candela per square metre (nits)      */
} bf6_light_unit;

/* QualityScalableEnabled: the LOWEST graphics preset at which the feature is
 * on. NOT a boolean - reading it as one turns "Ultra only" into "always". */
typedef enum {
    BF6_QSE_LOW = 0, BF6_QSE_MEDIUM = 1, BF6_QSE_HIGH = 2,
    BF6_QSE_ULTRA = 3, BF6_QSE_DISABLED = 4
} bf6_quality_scalable;

typedef struct {
    int32_t type;           /* bf6_light_type                                  */

    /* World transform in the GAME's space, 3x4 ROW-MAJOR: rows 0..2 are the
     * basis right/up/forward and row 3 is the translation in metres. Identical
     * in shape and order to bf6_instance.xform, so a consumer that already
     * places props places these the same way.
     *
     * A SPOT SHINES ALONG MINUS ROW 2 (minus forward). Measured off fixtures
     * whose real aim is not in question - recessed ceiling downlights and
     * street lamps 7 to 10 m up their poles all carry forward = (0, +1, 0) -
     * and across mp_dumbo's 4,470 spots, minus-forward points 3,688 of them
     * downwards while plus-forward points 36. Get the sign wrong and every
     * cone in the map aims at the ceiling it is set into.
     *
     * THE BASIS ROWS CARRY THE HOLDER'S SCALE and are not unit vectors -
     * measured scales of 1.2 and 1.5 are ordinary. Two consequences: normalise
     * row 2 before using it as a direction, and an AREA light's world size is
     * its authored rect_height / tube_width TIMES that scale. A rect light
     * authored 1 m square inside a prefab scaled 1.5 is 1.5 m square in the
     * world. */
    float   xform[12];

    float   color[3];       /* LINEAR, as authored. 96% are non-white          */
    float   intensity;      /* in `unit`; RAW, spanning eight orders of magnitude */
    int32_t unit;           /* bf6_light_unit                                  */
    float   dimmer;         /* authored multiplier on intensity, usually 1     */

    float   attenuation_radius;  /* metres, the light's reach                  */
    float   attenuation_offset;  /* metres, an inner offset on the falloff     */

    /* Shape. Which of these is authored depends on `type`; the rest are 0.
     * BOTH ANGLES ARE THE FULL CONE IN DEGREES, not half-angles and not
     * radians: mp_dumbo's spots run 40 to 179 degrees, and halving is the
     * consumer's job if its renderer wants a half-angle. */
    float   inner_angle;    /* spot                                            */
    float   outer_angle;    /* spot, and rect when its shape is a frustum      */
    float   shape_radius;   /* metres: sphere SphereRadius / spot DiscRadius /
                             * tube TubeRadius. The size of the EMITTER, which
                             * is what softens a shadow - not the reach.       */
    float   tube_width;     /* tube, metres end to end                         */
    int32_t is_capsule;     /* tube                                            */
    float   rect_height;    /* rect, metres                                    */
    float   rect_aspect;    /* rect. THERE IS NO Width FIELD on the class:
                             * the width is height * aspect.                   */
    int32_t rect_shape;     /* RectangularLightShape: 0 Rect, 1 Frustum,
                             * 2 OrthoFrustum                                  */

    int32_t cast_shadows_enable;  /* bool                                      */
    int32_t cast_shadows;         /* bf6_quality_scalable                      */
    int32_t cast_volumetric;      /* bf6_quality_scalable                      */
    float   volumetric_scattering;
    int32_t affect_diffuse;       /* bool                                      */
    int32_t affect_specular;      /* bool                                      */
    int32_t affect_radiosity;     /* bool                                      */
    int32_t emissive_shape_enable;/* bool: the emitter draws its own shape     */

    /* Goniometry. ies_profile is the partition name of an IesProfileAsset, or
     * NULL; its resource is a 128x128 equal-solid-angle candela grid carrying
     * absolute peak-candela and lumen scalars. */
    const char* ies_profile;
    float       ies_multiplier;
    int32_t     ies_as_mask;
    const char* texture;    /* rect only: the atlas texture it projects, or NULL */

    float   cull_distance;  /* metres                                          */
    float   fade_distance;  /* metres                                          */

    const char* source;     /* the partition the light was found in            */
    uint32_t    flags;      /* the entity's Flags word. MEANING UNDECODED      */
    int32_t     from_component; /* 1 = placed by its own spatial component     */

    /* All const char* above point into storage owned by the context and stay
     * valid until the next bf6_level_lights for a DIFFERENT level. */
} bf6_light;

/* Counters, so a bad read is visible rather than plausible. A light count of 0
 * or of tens of thousands is a failure, not a result; `placed_at_holder` is the
 * one that catches the classic bug, where lights come out in the right number
 * and all sit on their holders' origins. */
typedef struct {
    int32_t total;
    int32_t sphere, spot, tube, rect, other;
    int32_t placed_by_component;    /* transform came from the spatial component */
    int32_t placed_by_own_transform;/* the entity's own Transform, non-identity   */
    /* Neither: the entity's Transform is identity and no component claimed it,
     * so it sits exactly on its holder. NOT a failure on its own - a light
     * authored straight into a subworld legitimately sits on the holder placed
     * for it, and shipped maps run 1% (dumbo) to 16% (subsurface). It IS the
     * failure when it is most of the map and those lights pile at the world
     * origin, which is the component join having broken. */
    int32_t placed_at_holder;
    int32_t components;             /* placement components seen                  */
    int32_t comp_unlinked;          /* component whose Light pointer went nowhere */
    int32_t comp_excluded;          /* authored Excluded, dropped                 */
    int32_t partitions;             /* partitions the traversal opened            */
    int32_t unresolved_types;       /* types the schema could not describe        */
    /* The OLD join, measured beside the real one. Earlier readers follow field
     * 0x11F57ECA as "an int that holds a pointer"; under the multiplayer schema
     * it is a genuine four-byte Enum(PBRAnalyticLightShape) at a different
     * offset, and it only ever resolved because those readers load the
     * SINGLE-PLAYER executable, whose table puts 0x11F57ECA at the offset where
     * the MP data keeps the real pointer. Expect resolved to be small and agree
     * to be 0 on a correct MP-schema read. */
    int32_t comp_legacy_resolved, comp_legacy_agree;
} bf6_light_stats;

/* Every light on the level. Same convention as bf6_level_instances: returns the
 * count, fills out[] to out_max, so a caller sizes its buffer by calling once
 * with out=NULL. `stats` may be NULL. Returns 0 with a message in err on
 * failure - and 0 lights on a map that has fixtures IS a failure. */
BF6_API int bf6_level_lights(bf6_ctx*, const char* level,
                             bf6_light* out, int out_max,
                             bf6_light_stats* stats, char* err, int err_len);

/* Every light reachable from one named EBX asset. This is the same graph and
 * field decoder as bf6_level_lights, but it deliberately does not remount a
 * level: front-end scenes and studio rigs live in the global install mount and
 * are not playable levels. Call bf6_mount_all first. Count/fill and ownership
 * match bf6_level_lights. */
BF6_API int bf6_asset_lights(bf6_ctx*, const char* asset,
                             bf6_light* out, int out_max,
                             bf6_light_stats* stats, char* err, int err_len);

/* -------------------------------------- local VisualEnvironment trigger zones
 * A VisualEnvironment preset does not carry its own bounds. These are the
 * exact shapes connected from AreaProximityEntityData.Geometry in the owning
 * blueprint, transformed through the placed level graph. Only zones whose
 * property/event graph reaches a concrete VisualEnvironmentReferenceObjectData
 * preset are returned. Channel-routed zones are counted in `omitted_no_preset`
 * and deliberately omitted until their channel-to-preset join is decoded. */
enum bf6_lighting_zone_kind {
    BF6_LIGHTING_ZONE_OBB = 0,
    BF6_LIGHTING_ZONE_POLYGON = 1
};

typedef struct {
    int32_t kind;              /* bf6_lighting_zone_kind */
    float   xform[12];         /* world transform, same row layout as instances */
    float   half_extents[3];   /* OBB local half extents; zero for polygon */
    /* Polygon vertices as point_count triples, local to xform. Context-owned,
     * valid until this function is called for another level or bf6_close. */
    const float* points;
    int32_t point_count;
    float   height;            /* polygon extrusion along local +Y */
    float   fade_distance;     /* authored AreaProximity ProximityDistance */
    const char* preset;        /* exact imported VE partition */
    const char* source;        /* owning blueprint partition */
    int32_t proximity_instance;
    int32_t shape_instance;
} bf6_lighting_zone;

typedef struct {
    int32_t total, obb, polygon;
    int32_t partitions, instances, proximity;
    int32_t shape_links;
    int32_t non_geometry_links;
    int32_t non_shape_geometry_links;
    int32_t target_obb, target_polygon, target_other;
    int32_t joined_preset, omitted_no_preset;
    int32_t parse_fail, missing, cycles, malformed_shape, unresolved_types;
    /* Negative control: source instance rotated by one while target is held
     * fixed. A real join should dominate this fabricated pairing. */
    int32_t rotated_control_hits;
} bf6_lighting_zone_stats;

/* Count/fill convention. Mounts the level and reflection schema on demand.
 * Returns 0 with err set on failure; stats may be NULL. */
BF6_API int bf6_level_lighting_zones(bf6_ctx*, const char* level,
                                     bf6_lighting_zone* out, int out_max,
                                     bf6_lighting_zone_stats* stats,
                                     char* err, int err_len);

/* ------------------------------------------------------------------ effects */
/* One GPU-exposed parameter. `type` is 0 Float, 1 Vec2, 2 Vec3, 3 Vec4, 4 Bool,
 * 5 Int, and IT IS THE READ RULE: only the first width(type) components of v[]
 * are meaningful, and a Bool or Int carries its value in `ivalue`, never in the
 * floats. Reading all four back gives a Float parameter as (180, 1, 1, 1) where
 * only 180 was written.
 *
 * `cb_offset` is the parameter's float offset in the emitter constant buffer,
 * and it tiles exactly: cb[k+1] == cb[k] + width(type[k]) held for 31,039 of
 * 31,039 consecutive pairs across every shipped emitter template. That is what
 * lets a consumer lay the buffer out for all 2,524 observed PropertyIds without
 * knowing what any of them are called. A LAYER'S OVERRIDE TABLE CARRIES
 * cb_offset == 0 THROUGHOUT - it patches a value and leaves the layout to the
 * template - so the merged table here keeps the template's offset. */
typedef struct {
    uint32_t pid;          /* djb2-xor of the parameter name                   */
    int32_t  type;
    int32_t  cb_offset;
    float    v[4];
    int32_t  ivalue;       /* the value when type is Bool or Int               */
} bf6_fx_param;

/* One placed EMITTER LAYER. Not one effect: a layer is the unit that renders -
 * its own sheet, its own spawn rate, its own parameters, its own offset - and
 * 1,368 distinct effects on 14 retail levels expand to 3,983 layers. Merging
 * them per effect throws away exactly the variation that makes an explosion
 * read as an explosion (BaseSize 100/200/35 and Drag 0.5/0.0/0.7/0.01 on ONE
 * effect) and leaves a generic puff. */
typedef struct {
    const char* effect;         /* fx_* leaf name                              */
    const char* effect_path;    /* its partition path, no .ebx                 */
    int32_t     placements;     /* how many times the level places it          */
    float       effect_cull_distance;
    int32_t     effect_max_instances;

    int32_t     layer;          /* EBX instance index inside the effect        */
    const char* graph;          /* eg_* emitter template path                  */
    /* billboard_globalsorting | volumedecal | sparks | debris_mesh | distortion
     * | creature | lensflare | ribbon | other. From the graph path alone, so it
     * is independent of lighting_model and the two can be cross-tabulated. */
    const char* family;
    float       local[12];      /* the layer's offset inside the effect        */

    /* THE SHEET. NULL for the families that draw no flipbook, which is 1,406 of
     * 3,983 shipped layers and is a classification, not a miss. */
    const char* atlas;          /* AtlasTextureAsset partition, or NULL        */
    const char* atlas_res;      /* the RES the rid resolved to, or NULL        */
    const char* atlas_chunk;    /* its pixel chunk guid, raw hex, or NULL      */
    /* 1 when the sheet came from the LAYER'S own binding and 0 when it came
     * from the template's GlobalSorting. Measured over 3,983 layers: 2,322
     * override, 255 template - a reader that implements only the template path
     * resolves 255 of 2,577 and calls the rest textureless. */
    int32_t     atlas_from_override;
    int32_t     atlas_cols;     /* AUTHORED, never from the filename           */
    int32_t     atlas_frames;   /* total frames; t_..._7x144_d authors 49       */
    int32_t     atlas_left_right;
    uint64_t    atlas_rid;      /* the ResourceId the RES is found BY, not name */
    int32_t     atlas_width, atlas_height, atlas_mips;

    /* Authored per layer, in the layer's own parameter table. NOT in the draw
     * config: 267 distinct draw-config signatures over 565 templates and not
     * one of their 21 booleans separates Emissive from GnomonLit. -1 means the
     * layer authors none. */
    int32_t lighting_model;     /* 0 Emissive 1 VertexLit 2 GnomonLit          */
    int32_t alignment;          /* 0 Screen 1 Directional 2 ScreenStretch
                                 * 3 FullRotation 4 Emitter 5 Up               */

    const char* spawn_mode;     /* "SpawnModeContinuous" | "SpawnModeBurst"    */
    int32_t has_spawn_rate;     /* burst has no such field AT ALL              */
    float   spawn_rate;         /* particles per second                        */
    int32_t particle_max;
    float   particle_life, emitter_life;
    float   gpu_cull_distance;  /* the REAL cull distance                      */
    /* Every float above whose engine type is QualityScalableFloat is its LOW
     * member. Four of the five are identical across all four quality tiers on
     * all 374 shipped templates; max_spawn_distance is not - 39 of 374 author
     * Low 40 / Medium 60 / High 80 / Ultra 100. */
    float   min_spawn_distance, max_spawn_distance;
    float   preroll_time;
    int32_t draw_layer, draw_pass, sort_mode;
    int32_t particle_type;      /* 0 Quad, 1 Ribbon, -1 no global sorting      */

    /* The template's defaults with this layer's overrides applied on top.
     * Points into storage owned by the context. */
    int32_t             param_count;
    const bf6_fx_param* params;

    /* Every const char* above points into storage owned by the context and
     * stays valid until the next bf6_level_fx for a DIFFERENT level. */
} bf6_fx_layer;

/* Counters, so a bad read is visible rather than plausible. atlas_resolved
 * BELOW layers is normal and expected; atlas_resolved == atlas_template is the
 * signature of a reader that skipped the override slot. */
typedef struct {
    int32_t placements, distinct_effects, effect_failed;
    int32_t layers, graph_resolved;
    int32_t atlas_resolved, atlas_override, atlas_template;
    int32_t grid_resolved, rid_present, res_resolved, chunk_named;
    int32_t lighting_model, alignment;
} bf6_fx_stats;

/* Every emitter layer the level places, one row each. Requires bf6_open_level
 * for this level first: the effect placements come from that walk, and they
 * have to, because it is what stops at the destruction branch and at
 * StaticModelGroup members. A hand-rolled descent that skips those returned
 * 14,576 placements on mp_dumbo against the correct 1,010.
 *
 * Same convention as bf6_level_instances: returns the count and fills out[] to
 * out_max, so a caller sizes its buffer by calling once with out=NULL. `stats`
 * may be NULL. Returns 0 with a message in err on failure. */
BF6_API int bf6_level_fx(bf6_ctx*, const char* level,
                         bf6_fx_layer* out, int out_max,
                         bf6_fx_stats* stats, char* err, int err_len);

/* Where one effect is placed. Fills out_xf with count*12 floats (rows right,
 * up, forward, translation) and returns the count. */
BF6_API int bf6_fx_placements(bf6_ctx*, const char* level, const char* effect,
                              float* out_xf, int out_max);

/* The sheet's mip 0 for one row of bf6_level_fx, as BCn blocks ready for
 * upload - nothing is decompressed. The bytes are owned by the core and stay
 * valid until the next call. Returns 1 on success, 0 with a reason in err. */
BF6_API int bf6_fx_atlas_mip0(bf6_ctx*, const char* level, int layer_index,
                              const uint8_t** out_data, int32_t* out_size,
                              char* err, int err_len);

/* One flipbook frame's UV rect (u0, v0, u1, v1). USE THIS rather than computing
 * a pixel rect: six- and seven-column sheets do not divide a power-of-two
 * texture, so the cell is fractional (341.333, 170.667, 146.286 px on four of
 * one level's fourteen sheets) and flooring to pixels accumulates drift and
 * shears the last column. On a LeftRightTiles sheet the LEFT half is the
 * sprite; the right half is the alternate tile UseRightTile selects, and the
 * six-way basis GnomonLit reads. */
BF6_API void bf6_fx_frame_uv(const bf6_fx_layer*, int frame, float* out_uv);


/* ------------------------------------------------------------------ terrain */
typedef struct {
    int32_t         width;         /* samples per side, from the tree itself */
    int32_t         height;
    const uint16_t* heights;       /* row-major, width*height samples */
    float           world_min[3];  /* the AABB the grid spans, GAME space */
    float           world_max[3];
    float           height_scale;  /* the header's height scale             */
    int32_t         splat_texture; /* index for bf6_texture_at(), or -1     */
    int32_t         color_texture;
} bf6_terrain;

BF6_API bf6_terrain* bf6_read_terrain(bf6_ctx*, const char* level);
/* Absolute-Y water surface heightfield from streaming-tree block 2.  This is
 * the large spatial offset sampled by the water vertex shader; it is distinct
 * from the small ocean FFT displacement.  Reads the mounted game at runtime. */
BF6_API bf6_terrain* bf6_read_water_heightfield(bf6_ctx*, const char* level);

/* ------------------------------------------------------------ terraindecals */
/* Roads and street markings.
 *
 * The street SURFACE is the terrain heightfield - block 7 paints it asphalt -
 * so a reader without this still draws ground where a road is. What it does not
 * draw is any of what makes a road read as one: lane markings, mud, wear, tyre
 * tracks, kerb blending. That is what "the roads are giant empty spaces"
 * describes.
 *
 * A decal vertex carries world X and Z and NO Y: decals are draped on the
 * heightfield by the consumer, which must sample the terrain at (x, z).
 *
 * THE AABB IS A BAND, NOT A SURFACE. Its Y range is where the authored
 * geometry sat, and it is worth exactly one thing: telling an ELEVATED record
 * (a rooftop court, a loading deck) from a street-level one. Clamping every
 * record into its band is a trap - where the rebuilt ground sits lower than
 * the ground the decal was compiled against, a clamp cannot follow the terrain
 * down and the marking hangs in the air. Clamp only where the authored floor
 * stands well above the ground you actually built under that record. */
typedef struct {
    /* x, z, u, v, r, g, b, a per vertex - stride 8 floats. The list is NON
     * INDEXED: vertex_count is exactly tri_count * 3, in triangle order. */
    const float* verts;
    int32_t      vertex_count;
    float        aabb_min[3];
    float        aabb_max[3];
    /* World metres per tile. A planar fill stores u = world X and v = world Z
     * verbatim and tiles by these; everything else authors u across the ribbon
     * (0..1 over tiling1) and v as arc length along it, already divided by
     * tiling0. */
    float        tiling0, tiling1;
    int32_t      planar;        /* 0/1 */
    /* Texture ids for bf6_texture_at, or -1. THE MARKINGS LIVE IN opacity -
     * a lane stripe is coverage, not colour, and a consumer that binds only
     * the base colour draws the asphalt and none of the paint. */
    int32_t      albedo, opacity, normal;
    /* APPENDED, NEVER REORDERED. bf6_level_decals writes at the DLL's own
     * sizeof(bf6_decal), so a header and a DLL that disagree write every row
     * at the wrong stride and produce plausible garbage rather than an error.
     * Deploy the two together. */

    /* AMBIENT OCCLUSION. Its slot was declared and never read. */
    int32_t      ao;

    /* THE AUTHORED COLOUR, and it means two DIFFERENT things.
     *
     * With a colour sheet bound it is a MULTIPLIER over that sheet: 40.6% of
     * 12,941 such values exceed 1.0 and the largest is 61.1. With no sheet it
     * is the colour ITSELF, absolute: only 1.2% of 4,568 exceed 1.0, the
     * median is 0.691, and the commonest triples are road yellow
     * (0.911, 0.542, 0.042), park green and concretes. Switch on whether
     * `albedo` is bound, never on the value. */
    float        tint[3];
    int32_t      has_tint;
    /* A second authored colour, only ever present when there is no sheet. */
    float        tint2[3];
    int32_t      has_tint2;

    /* WHICH CHANNEL OF A PACKED MASK is this record's coverage, 0..3, or -1.
     *
     * The sheets are atlases: one texture holds three or four painted road
     * words or arrows and each record picks one. Evidence that this is the
     * selector rather than a coincidence: it is present on 6,334 colourless
     * records and 0 coloured ones; its cardinality per sheet is capped at 4
     * while the sheets carry 5 to 851 records each, where competing scalars on
     * the same records reach 8, 11, 19 and 28; it varies WITHIN one material
     * class and sheet pair on 34 of 49 pairs, which kills "the material
     * selects it"; and every one of the 13 sheets using 3 or 4 values is named
     * `_rgb`, while no single-mask `_op` sheet reaches 3. A reader that always
     * takes red gets roughly one record in three right. */
    int32_t      mask_channel;

    /* The record's decal-asset slot: a BLEND PRESET, not art. On MP_Badlands
     * the colour / no-colour split is uniform per slot with zero mixing.
     * NOTE it is not a terrain layer index where the slot is non-empty, which
     * on MP_Badlands is all 628 of them. */
    int32_t      asset_slot;
} bf6_decal;

/* Every decal record in a level. Same convention as bf6_level_instances:
 * returns the count, fills out[] to out_max. The vert pointers are owned by the
 * context and stay valid until the next bf6_open_level. */
BF6_API int bf6_level_decals(bf6_ctx*, const char* level, bf6_decal* out, int out_max);

/* ------------------------------------------------------------------- water */
/* The level's water surfaces, from its own water entities: flat planes at an
 * absolute height, with the colours the level's depot record authors for them.
 *
 * A consumer draws each as a horizontal plane of size[0] x size[1] metres
 * centred at (center[0], height, center[1]) in the GAME's coordinates. Where
 * the record carried no colour, shallow[0] is negative and a preset is the
 * honest fallback. is_ocean says which shader family the level binds - the
 * ocean variant authors ONE colour and the darker "deep" is absent by design
 * (a consumer derives depth by darkening, and writing the same colour into
 * both would flatten the gradient while still looking like mined data). */
typedef struct {
    float   center[2];     /* world X, Z of the plane's centre               */
    float   size[2];       /* metres                                        */
    float   height;        /* world Y of the surface                        */
    float   shallow[3];    /* linear; [0] < 0 when the record had no colour */
    float   deep[3];       /* linear; [0] < 0 when absent (always on ocean) */
    int32_t is_ocean;      /* 0/1                                           */
    /* THE SHEETS THE GAME'S OWN WATER BINDS, for bf6_texture_at, or -1.
     * Colour alone gives a flat pane; these are what make it read as water:
     * detail_normal is the micro-ripple normal the surface is covered in,
     * foam_normal and foam_rgb are the foam sheets (R patches, G bubbles,
     * B crest streaks), and noise/perlin drive the break-up. They come off
     * the same depot record as the colours. */
    int32_t detail_normal;
    int32_t foam_normal;
    int32_t foam_rgb;
    int32_t noise;
    int32_t perlin;
} bf6_water;

/* Requires bf6_open_level for this level first (the scan needs the mounted
 * archives, the type schema and the walk's root). Same convention as
 * bf6_level_instances: returns the count, fills out[] to out_max. */
BF6_API int bf6_level_water(bf6_ctx*, const char* level, bf6_water* out, int out_max);

/* The ocean simulation's INPUTS - the authored sea state. The wave field
 * itself is a runtime GPU simulation and nothing on disk holds it; these are
 * the numbers that drive it, read from WaterOceanSimulationEntityData in the
 * level's schematic partitions (the flagged instance wins, else the first -
 * tungsten's only instance is NOT flagged, so "flagged only" loses the most
 * oceanic map in the game).
 *
 * Units: the executable's initial-spectrum builder divides wind_angle by 360,
 * so it is degrees. wind_speed is a normalised authoring scalar, NOT m/s.
 *
 * RETRACTED: this comment used to give that scalar's scale as "0.01 calm, 0.07
 * windy, 0.30+ the D-Day sea". Those numbers were read through the SINGLE
 * PLAYER executable's reflection schema, which lays this class out differently
 * from the multiplayer one, so they are values from neighbouring fields. Under
 * the MP schema the class default is 0.5 and MP_Isolated authors about 0.9, so
 * the real scale is roughly an order of magnitude higher and 0.5 is the
 * middle of it rather than a gale. See the exe-schema finding; anything
 * calibrated against the old numbers is wrong by that factor.
 *
 * The distribution is
 * wave ENERGY BY DIRECTION: control points over x 0..1 = a full turn around
 * wind_angle, y = relative energy. */
typedef struct {
    float   wind_angle;
    float   wind_speed;
    float   choppiness;
    float   tile_dimension;
    float   min_wavelength;
    float   large_wave_reduction;
    float   wave_thickness;
    int32_t foam_enable;
    float   foam_threshold;
    float   foam_max;
    int32_t enabled;          /* 1 = the flagged instance; 0 = first fallback */
    int32_t dist_count;       /* 0, 5, 9 or 13 control points */
    float   dist_x[13];       /* ascending, last implicitly 1.0              */
    float   dist_y[13];
} bf6_water_sim;

/* Requires bf6_open_level. Returns 1 and fills out when the level has a sim
 * entity, else 0. */
BF6_API int bf6_level_water_sim(bf6_ctx*, const char* level, bf6_water_sim* out);

/* Complete ocean-cascade input. Unlike bf6_water_sim this preserves every
 * value consumed by the game's CPU H0 builder, including the Hermite tangent
 * pairs and the selected PC resolution. source_index is the original EBX
 * instance index; returned rows are in renderer cascade order (largest tile
 * first), up to the game's four-cascade limit. */
typedef struct {
    int32_t source_index;
    int32_t enabled;
    int32_t resolution;       /* PlatformScalableInt.Default: Win64/PC route */
    float   wind_angle_degrees;
    float   wind_speed;
    float   choppiness;
    float   tile_dimension;
    float   min_wavelength;
    float   large_wave_reduction;
    float   wave_amplitude;
    float   wave_thickness;
    int32_t foam_enable;
    float   foam_threshold;
    float   foam_max;
    float   foam_half_life;
    int32_t physics_simulation_enabled;
    int32_t force_simple_plane_collision;
    int32_t visual_cpu_simulation_enabled;
    int32_t dist_count;       /* 5, 9 or 13 */
    float   dist_x[13];
    float   dist_y[13];
    float   dist_tangent_out[12];
    float   dist_tangent_in[12];
    float   dist_clamp_min;
    float   dist_clamp_max;
} bf6_water_sim_v2;

/* Requires bf6_open_level. Returns the total enabled cascade count; writes at
 * most out_max rows. A null output/count-only call is supported. */
BF6_API int bf6_level_water_sims(bf6_ctx*, const char* level,
                                  bf6_water_sim_v2* out, int out_max);

/* Water-lab route: mount only the named level archives, load the executable
 * type schema, and inspect only that level's water schematic partitions. It
 * deliberately does NOT run bf6_open_level's placement/object-graph walk.
 * The returned rows and count/fill contract are identical to
 * bf6_level_water_sims, so callers can compare the isolated and full routes
 * byte-for-byte as a control. */
BF6_API int bf6_level_water_sims_isolated(bf6_ctx*, const char* level,
                                           bf6_water_sim_v2* out, int out_max);

/* Rebuild the CPU-created complex H0 texture used by the shipped ocean FFT.
 * out_rg contains resolution*resolution float2 values. Returns the required
 * float count on success (also for a null/count-only call), or 0 on invalid
 * input. The seed and random walk are the executable's deterministic route. */
BF6_API int bf6_water_spectrum_h0(const bf6_water_sim_v2* sim,
                                  float* out_rg, int out_float_count);

/* ---------------------------------------------------------- water, part 2
 *
 * The full RENDER description of a level's water: the geometry above plus
 * the decoded material, enough to drive a conventional renderer without
 * reading the game again.
 *
 * ABSENT IS NOT ZERO. Zero is a legal authored value for nearly everything
 * here, so every float that is not a coordinate carries a NEGATIVE sentinel
 * when the level does not author it, and every texture id is -1. That is not
 * defensive style: two of the four ocean levels run a different material
 * graph and carry none of the named foam slots, so a consumer reading zero
 * would switch their foam off rather than fall back.
 */
typedef struct {
    uint64_t state_key;
    int32_t  variant;                  /* 1 ocean, 0 foam, 2 region-banded
                                         (undecoded; colours absent)        */

    float center[2];                   /* world X, Z of the plane centre   */
    float size[2];                     /* metres, FULL width               */
    float height;                      /* world Y                          */
    float query_box_half_extent[2];    /* metres, half width; redundant    */

    int32_t attenuation_type;          /* 0 None 1 ShoreDepth 2 CoarseMask
                                         3 CoarseAndDetailMask            */
    int32_t shore_fade_valid;          /* 1 only when attenuation_type==1   */
    int32_t shore_enable;
    float   shore_depth_m;             /* metres; t = saturate(depth/this)  */
    float   shore_blend[4];            /* cubic (a,b,c,d): dot4(t^3,t^2,t,1) */
    float   additional_water_depth_m;  /* metres, added to the depth sample */
    float   wave_amplitude_scale;      /* dimensionless                     */
    int32_t visible;
    int32_t terrain_vt_access;
    /* THE ONLY READABLE WATER TYPE. There is no ocean/river/pool enum; this
      bool is the river flag, and it agrees 14 of 14 with whether the level's
      shader permutation declares Serac:WaterRiverFlowSampler. */
    int32_t is_river;

    /* COLOUR. base_colour is the AUTHORED value and on the ocean family it is
      a per-metre transmission, NOT a surface colour: it is what the water
      reaches after absorption_distance_m metres. surface_colour and
      extinction are that value converted, so a renderer never needs the
      formula. transmission over L metres is exp(-extinction * L). */
    float base_colour[3];              /* linear RGB, authored              */
    float deep_colour[3];              /* linear RGB, foam family only      */
    float surface_colour[3];           /* linear RGB, DERIVED               */
    float extinction[3];               /* per metre, DERIVED                */
    float absorption_distance_m;       /* metres, ocean family              */
    float depth_ramp_m;                /* metres, foam family               */
    int32_t overlay_count;             /* 0..4 extra lerp-stack colours     */
    float overlay_colour[4][3];        /* linear RGB, in application order;
                                         their weights are RUNTIME terms and
                                         cannot be evaluated offline       */

    float detail_fade_start_m, detail_fade_end_m;
    float foam_threshold;              /* 0..1                              */
    float shore_foam_suppression;      /* 0..1                              */
    float foam_contrast_divisor;
    float cascade_foam_weight[4];      /* cascade 0..3                      */
    float smoothness_zero_foam, smoothness_full_foam;
    float smoothness_bias, smoothness_near_multiplier;
    float foam_sheet_normal_strength, micro_sheet_normal_strength;
    float noise_uv_scale;              /* 1/metres                          */
    float reflectance_low, reflectance_high, reflectance_bias;

    /* for bf6_texture_at, or -1 */
    int32_t detail_normal, foam_normal, foam_rgb, noise, perlin;
    int32_t contact_foam, foam_rgb2;

    /* Extended-water draw graph parameters. These are appended so older ABI
       consumers keep their layout. They are read from the current level's
       ShaderBlockDepot on every call; negative means this graph does not
       author the parameter. MP_Isolated uses separate scales for the micro
       and foam normal sheets -- collapsing them to one scale is visibly
       wrong -- plus an authored micro-sheet animation rate. */
    float micro_sheet_uv_scale;         /* cycles / metre                  */
    float foam_sheet_uv_scale;          /* cycles / metre                  */
    float micro_sheet_flow_speed;       /* graph time multiplier           */
    float foam_composite_low;           /* final coverage range remap low  */
    float foam_composite_high;          /* final coverage range remap high */
    float contact_world_divisor_m;      /* contact UV = world/divisor-.5   */
    float contact_remap_low;
    float contact_gain;
    /* MP_Isolated's broad moving crest sheet.  These three values are depot
       constants selected by the current pixel permutation, not fitted
       preview controls.  The three motion coefficients which combine them
       are literals in the current shipped permutation. */
    float broad_pattern_world_mul;
    float broad_pattern_world_scale;
    float broad_pattern_floor;
    /* Exact current extended-water material cbuffer, registers 0..21.  The
       values are assembled from the mounted depot by Name32, never loaded
       from a staged dump.  Version is zero unless every value used by the
       current MP_Isolated graph and all five textures are present AND the
       live ShaderStateDatabase selects the pixel program this translation was
       decoded from. */
    uint32_t extended_graph_version;
    float extended_cb1[22][4];
    /* Raw .NET-layout GUID bytes of pass 0's selected pixel program. */
    uint8_t selected_pass0_pixel_guid[16];
    /* Current selected vertex shader's cascade-0 overlap transform. Appended
       for ABI compatibility. Version is zero unless the live entity carries
       every source field and pass 0 selects the shader whose arithmetic was
       decoded. params=(sin,cos,shear_x,shear_y), params2=(1/A,1/B,A,B). */
    uint32_t cascade_overlap_version;
    int32_t cascade_overlap_enabled;
    float cascade_overlap_params[4];
    float cascade_overlap_params2[4];
    float cascade_overlap_height_scale;
    uint8_t selected_pass0_vertex_guid[16];

    /* Active VisualEnvironment OceanComponentData, joined at runtime through
       the level root's import list.  These are the inputs consumed by the
       deferred water composite; they do not come from the surface material
       above.  Version is zero unless the active preset and every required
       source field were resolved from the mounted game. */
    uint32_t ocean_component_version;
    char ocean_preset[128];
    int32_t ocean_preset_candidates;
    int32_t ocean_enable;
    int32_t simplified_distortion;
    int32_t foam_enable;
    float composite_ior;
    float opacity_ramp_m;
    float foam_depth_ramp_m;
    float scatter_phase_g;
    float transmission_colour[3];
    float scatter_shadow_influence;
    float foam_tint[3];
    float foam_smoothness;
    float foam_roughness;              /* derived as 1-FoamSmoothness */
    float authored_ocean_albedo[3];
    float authored_albedo_distance_m;
} bf6_water_render;

/* Requires bf6_open_level for this level first. Same convention as
  bf6_level_instances: returns the count, fills out[] to out_max. */
BF6_API int bf6_level_water_render(bf6_ctx*, const char* level,
                                   bf6_water_render* out, int out_max);

/* The terrain utility raster bound by the selected water vertex shader as the
 * CoarseMask source. The atlas is the game's R8 pages in persistent-record
 * order, byte-for-byte; indirection is the packed uint32 table built by the
 * game's runtime loader. Pointers are owned by the context and remain valid
 * until the next mask read or bf6_close. No exported intermediate is used. */
typedef struct bf6_water_mask {
    uint32_t version;                 /* 1 = current exact utility-raster path */
    uint32_t tile_side;               /* stored page side, including border   */
    uint32_t interior_side;           /* tile_side - 2*border - 1             */
    uint32_t border;
    uint32_t page_count;
    uint32_t indirection_side;        /* 1 << max_level                       */
    float bounds_min[2];              /* world X,Z metres                     */
    float bounds_max[2];
    float coverage_side_rcp;          /* 1 / (bounds_max.x-bounds_min.x)       */
    float border_fraction;            /* border / (tile_side-1)                */
    const uint8_t* atlas_r8;          /* page_count*tile_side*tile_side bytes  */
    const uint32_t* indirection_u32;  /* indirection_side squared packed cells */
} bf6_water_mask;

/* Requires the level to be mounted. Returns 1 and fills out on success. */
BF6_API int bf6_level_water_mask(bf6_ctx*, const char* level,
                                 bf6_water_mask* out, char* err, int err_cap);


/* --------------------------------------------------------------- lighting */
/* THE LEVEL'S OWN LIGHTING, out of its active VisualEnvironment preset.
 *
 * A VE is the map's whole authored environment: sun, sky, atmosphere, two cloud
 * layers, cloud shadows, fog, exposure, bloom, colour grading, white balance,
 * ambient occlusion, global illumination and the shadow cascades - about 800
 * fields over 27 components. This is the subset that lights a scene, plus the
 * texture references that go with it.
 *
 * WHICH PRESET. A level ships several - interior, dark alley, construction
 * site, thermal - and the level ROOT partition names the outdoor one by
 * importing it. mp_dumbo's lighting/ folder holds 19 partitions and the root
 * imports exactly two of them: the active VE and `thermal`. So:
 *
 *   active VE = the non-thermal ve_* partition, under the level's OWN
 *               directory, that the level root imports
 *
 * It is a selector, not a dependency dump. `preset` says which one answered and
 * `preset_candidates` says how many matched, so a level that ever grows a
 * second outdoor preset shows up as a number rather than as a silent choice.
 *
 * ABSENT IS NOT ZERO. Zero is a legal authored value nearly everywhere here -
 * MP_Subsurface really does ship SunIntensity 0.001, an underground map with
 * the sun off - so a component the preset does not carry cannot be recognised
 * by its values. `components` is the bitmask of the ones that were there, and
 * every field belonging to a component whose bit is clear is meaningless.
 *
 * Strings are FIXED ARRAYS inside the struct rather than pointers into the
 * context: the whole record is one value the caller owns, with no lifetime to
 * track and nothing to free.
 */
typedef enum {
    BF6_VE_SUN           = 1 << 0,
    BF6_VE_SKY           = 1 << 1,
    BF6_VE_FOG           = 1 << 2,
    BF6_VE_EXPOSURE      = 1 << 3,
    BF6_VE_GRADING       = 1 << 4,
    BF6_VE_WHITE_BALANCE = 1 << 5,
    BF6_VE_AO            = 1 << 6,
    BF6_VE_GI            = 1 << 7,
    BF6_VE_SUN_SHADOW    = 1 << 8
} bf6_ve_component;

typedef struct {
    char    preset[128];        /* the preset's leaf name                    */
    char    preset_path[256];   /* the partition it was read from            */
    int32_t preset_candidates;  /* outdoor presets the level root selected   */
    uint32_t components;        /* bf6_ve_component bits actually present    */
    /* A level blends several VEs. This is the chosen preset's own blend
     * weight, 1.0 on every outdoor preset checked, and the number that
     * separates the environment from a thin layer stacked on top of it
     * (mp_granite's `nolut` preset sits at 0.15 with 2 components). */
    float   visibility;
    int32_t component_count;    /* components the preset's entity declares   */

    /* ---- sun --------------------------------------------------------------
     * SUN ANGLES ARE A COMPASS BEARING PLUS AN ELEVATION, both in DEGREES.
     * sun_rotation_x is the bearing: 0 points along the game's +Z and turns
     * toward +X. sun_rotation_y is height above the horizon. A unit vector
     * TOWARD the sun is therefore
     *
     *     (sin(az)*cos(el), sin(el), cos(az)*cos(el))
     *
     * and NOT the maths convention (cos az, sin az), which is both mirrored
     * and 90 degrees out - two errors that cancel often enough to look nearly
     * right. Nothing shipped can settle this on its own: the sky panoramas
     * contain no sun disc (the engine draws it), and the maptiles are flat lit.
     * It was settled against the running game on two dense city maps.
     *
     * sun_intensity is REAL ILLUMINANCE IN LUX - 120000 for full midday, 45860
     * for a low golden-hour sun, 0.001 on an underground map. A renderer with
     * no physical light units has to map it, and that mapping is a calibration
     * the consumer owns; this reports the game's number.
     *
     * sun_color is a linear TINT and the magnitude lives in sun_intensity, so
     * red is 1.0 on almost every map. It is NOT normalised, though: MP_Plaza
     * ships (1.06066, 0.5249, 0.1534) and clamping that to 1 quietly changes
     * the colour. Use it as authored. */
    float   sun_rotation_x;
    float   sun_rotation_y;
    float   sun_color[3];
    float   sun_intensity;
    float   sun_angular_radius;        /* degrees, the disc's half-angle      */
    float   sun_specular_scale;
    float   sun_shadow_view_distance;  /* metres, highest quality level       */
    /* Cloud shadows. speed is (0,0) on some maps and (-4,-8) or (2,2) on
     * others: static on some, moving on others, which is exactly the kind of
     * thing generalising one map's lighting to the fleet gets wrong. */
    float   cloud_shadow_size;         /* world metres per tile               */
    float   cloud_shadow_coverage;
    float   cloud_shadow_exponent;
    float   cloud_shadow_speed[2];
    float   cloud_shadow_translation[2];
    int32_t cloud_radiosity;           /* 0/1 */

    /* ---- sky -------------------------------------------------------------
     * THERE IS NO ZENITH / HORIZON / GROUND COLOUR HERE, because the VE does
     * not author one. Those three are a SAMPLE of the sky gradient texture,
     * and a reader that invented them would be reporting its own sampling
     * choices as game data. sky_gradient_res and sky_gradient_texture hand
     * over the gradient itself (a 256x128 BC6H strip) so a consumer can sample
     * it and say how. */
    int32_t sky_type;                  /* 0 = panoramic                       */
    /* Panoramas ship NORMALISED (measured mean 0.057 to 1.345 across the
     * fleet) and this carries the magnitude. Read it; do not measure the
     * texture. */
    float   sky_luminance_scale;
    float   sky_panoramic_rotation;    /* TURNS, not degrees                  */
    float   sky_panoramic_tile_factor;
    int32_t sky_draw_sun_disc;         /* 0/1, true on every shipped map      */
    float   sun_disc_size;
    float   sun_disc_scale;            /* the SKY's SunScale, ~300000         */
    /* RayleighScatteringCoefficient is a VEC3, not the scalar its name
     * implies. The per-channel ratio (6e-06, 1.4e-05, 3.3e-05) is why the sky
     * is blue; collapsing it to one number throws the colour away. */
    float   rayleigh[3];
    float   rayleigh_scale;
    float   mie_coefficient;
    float   mie_g;
    int32_t use_aerial_perspective;    /* 0/1 */
    float   aerial_perspective_scale;
    float   aerial_perspective_intensity;
    float   earth_radius;              /* thousands of km, as authored        */
    float   atmosphere_radius;
    float   height_fog_color_add[3];   /* HDR radiance, the sky's own term    */
    float   cloud1_altitude;           /* metres                              */
    float   cloud1_tile_factor;
    float   cloud1_rotation;           /* degrees                             */
    float   cloud1_speed;
    float   cloud1_alpha_mul;
    float   cloud1_color[3];

    /* ---- fog --------------------------------------------------------------
     * fog_color is HDR RADIANCE, not a 0..1 colour: (1385, 2132, 3072) is a
     * sky blue at magnitude 3072. Normalise by the peak channel to get a hue
     * and keep the magnitude separately; clamping it turns every map's fog
     * white. Fog is the most map-varying system in the VE - fog_color alone
     * takes 14 distinct values across 22 maps, and fog_height_enable is
     * genuinely false on some. */
    int32_t fog_height_enable;         /* 0/1 */
    int32_t fog_color_enable;
    int32_t fog_gradient_enable;
    float   fog_color[3];
    float   fog_dist_start, fog_dist_end;      /* metres */
    float   fog_color_start, fog_color_end;    /* metres */
    float   fog_height_start, fog_height_end;  /* metres */
    float   fog_altitude;              /* world Y the height fog sits at      */
    float   fog_depth;
    float   fog_visibility_range;
    int32_t volumetrics_enable;        /* participating media, 0/1            */
    float   sun_scatter_intensity;
    float   local_light_scatter_intensity;

    /* ---- exposure + bloom -------------------------------------------------
     * EXPOSURE IS AUTOMATIC on the shipped maps (auto_exposure is 1), so `ev`
     * is the starting point of a runtime metering loop and not a fixed value a
     * renderer can apply. ev_max clamps it. A consumer that wants a fixed
     * exposure has to choose one; the game does not ship it. */
    int32_t auto_exposure;             /* 0/1 */
    float   ev;
    float   ev_max;
    float   exposure_compensation;
    float   bloom_scale[3];
    int32_t bloom_method;

    /* ---- colour grading + white balance ----------------------------------- */
    int32_t grading_enable;            /* 0/1 */
    float   grade_brightness[3];
    float   grade_contrast[3];
    float   grade_saturation[3];
    float   grade_hue;                 /* degrees */
    float   white_temperature;         /* kelvin */
    float   white_tint;

    /* ---- ambient occlusion ------------------------------------------------
     * ao_affects_outdoor_light is FALSE on the maps checked: ambient occlusion
     * does not darken sun-lit surfaces in this game. A renderer that lets its
     * SSAO touch direct light is not matching it. */
    int32_t ao_affects_outdoor_light;  /* 0/1 */
    int32_t ao_affects_local_light;
    float   ssao_max_distance_inner, ssao_max_distance_outer;
    float   hbao_radius, hbao_contrast;
    float   dynamic_ao_factor;

    /* ---- global illumination (the Enlighten sky box) ---------------------- */
    float   gi_terrain_color[3];
    float   gi_sky_color[3];
    float   gi_ground_color[3];
    float   gi_sun_color[3];
    float   gi_backlight_rotation_x;   /* degrees, = sun bearing + 180        */
    float   gi_backlight_rotation_y;
    float   gi_bounce_scale;
    float   gi_sun_scale;              /* the GI's own SunScale, ~1.5         */

    /* ---- the textures the preset binds ------------------------------------
     * Resource names, empty when the preset binds nothing there, plus the
     * texture ids for bf6_texture_at where the mount carries the resource
     * (-1 otherwise). Skies and light probes are BC6H.
     *
     * These come out of the payload as raw import pointers. The type tables
     * describe these particular fields with a NULL type, so an ordinary schema
     * read reports them absent - which is why an earlier reader concluded some
     * maps bound no sky at all. */
    int32_t has_panorama;              /* 0/1, panorama_res is non-empty      */
    char    panorama_res[192];
    int32_t panorama_texture;
    char    panorama_alpha_res[192];
    char    sky_gradient_res[192];
    int32_t sky_gradient_texture;
    char    flow_mask_res[192];
    char    cloud_layer1_res[192];
    char    cloud_shadow_res[192];
    int32_t cloud_shadow_texture;
    char    secondary_cloud_shadow_res[192];
    char    grading_lut_res[192];      /* directly consumable as a colour LUT */
    char    lens_dirt_res[192];

    /* Of the named fields this call looks for, how many the preset carried.
     * A number rather than a bool because a preset legitimately omits whole
     * components, and a caller wants to see that as a ratio rather than as a
     * failure. */
    int32_t fields_found;
    int32_t fields_expected;

    /* Version 1 appended sky/cloud fields. They are kept at the tail so every
     * previously published member retains its ABI offset. The values are read
     * from the active preset in the current install; no fleet table is a
     * runtime input. */
    uint32_t sky_cloud_extension_version;
    float sky_panoramic_uv_min[2];
    float sky_panoramic_uv_max[2];
    float sky_flow_distance;
    float sky_flow_direction;           /* degrees */
    float sky_flow_period;              /* seconds */
    float sky_flow_height_mask_scale;
    float sky_flow_height_mask_bias;
    float secondary_cloud_shadow_size;
    float secondary_cloud_shadow_coverage;
    float secondary_cloud_shadow_exponent;
    float secondary_cloud_shadow_speed[2];
    float secondary_cloud_shadow_translation[2];
    int32_t cloud_shadow_addressing_mode;
    int32_t secondary_cloud_shadow_addressing_mode;
    int32_t cloud_shadow_is_top_down;
    int32_t secondary_cloud_shadow_is_top_down;
    float cloud_shadow_start_fade;
    float cloud_shadows_fade_distance;
    int32_t cloud_shadow_height_fade_enable;
    float cloud_shadow_start_height_fade;
    float cloud_shadows_height_fade_distance;
    int32_t secondary_cloud_shadow_texture;
    int32_t panorama_alpha_texture;
    int32_t flow_mask_texture;
    int32_t cloud_layer1_texture;
    int32_t grading_lut_texture;
    int32_t lens_dirt_texture;
} bf6_ve_lighting;

/* Decode `level`'s active VisualEnvironment. An explicitly named
 * game/.../lighting/ve_* partition is decoded directly; front-end screens have
 * no playable level root and select these presets themselves. Returns 1 on success.
 *
 * Mounts on demand, so it works on a context where bf6_open_level failed at the
 * placement walk (or was never called). */
BF6_API int bf6_level_lighting(bf6_ctx*, const char* level,
                               bf6_ve_lighting* out, char* err, int err_len);

/* Every partition the active preset imports, resolved to a name: its level's
 * own textures, a few shared/global ones, and the enum types two of its fields
 * are declared with. This is how a map's real texture set is found without
 * guessing at a `t_<map>_panoramicsky_*` naming convention - Tungsten's set is
 * a five-element lens-flare rig and a colour-grading LUT, which no convention
 * would have surfaced.
 *
 * Returns the TOTAL count and fills out[] to out_max. Strings point into the
 * context and stay valid until the next bf6_level_lighting_imports call. */
BF6_API int bf6_level_lighting_imports(bf6_ctx*, const char* level,
                                       const char** out, int out_max);

/* ------------------------------------------------------------ ground bake */
/* The terrain's real ground materials, composited the way the game's own
 * ComputeLayer evaluator does it: per-texel layer coverage from the splat,
 * each layer's sheet sampled in world space at its authored tiling, blended
 * in ascending layer order, with the colour map applied as an Overlay.
 *
 * This is a BAKE, not a live shader. A renderer drapes the result over the
 * heightfield and gets ground that matches the game rather than flat grey.
 *
 * The window is in world XZ metres. rect_size <= 0 bakes the whole footprint,
 * which on a 4 km map means a metre per texel at 4096 - the pages are far
 * denser than that, so a window is how real detail is recovered. */
typedef struct {
    float   rect_min[2];
    float   rect_size;      /* <= 0 = the whole map */
    int32_t size;           /* output texels per side, 0 -> 1024 */
    int32_t want_normal;    /* 0/1 */
    int32_t stochastic;     /* 0/1, the shader's own repetition breakup */
    int32_t colour_map;
    /* Let a texel no textured layer reached take the aerial colour map rather
     * than the game's magenta. A renderer wants this on; a diagnostic does
     * not. */
    int32_t fallback_colour_map;     /* 0/1, the per-layer Overlay blend */
} bf6_terrain_bake_opts;

typedef struct {
    int32_t        size;
    float          lo[2];   /* world XZ of the low corner */
    float          hi[2];
    float          metres_per_texel;
    /* RGBA8, size*size*4, sRGB-ENCODED. Owned by the context, valid until
     * the next bake or bf6_close. */
    const uint8_t* albedo;
    /* RGBA8 or NULL. RGB is the tangent-space layer normal as 0.5n+0.5; A is
     * composite height over -1..+1 m. This is NOT the final world normal -
     * the game finishes by combining it with the heightfield's own normal,
     * which a renderer holding terrain.h data can do better itself. */
    const uint8_t* normal;
    int32_t        layers_used;
    int32_t        layers_textured;
    float          fallback_fraction;   /* texels no textured layer reached */
} bf6_terrain_bake;

/* Requires bf6_open_level. Returns 1 on success. */
BF6_API int bf6_bake_terrain(bf6_ctx*, const char* level,
                             const bf6_terrain_bake_opts* opts,
                             bf6_terrain_bake* out, char* err, int err_len);

/* ---------------------------------------------- ground coverage (per pixel) */
/* The ground as WEIGHTS plus a material list, for a renderer that blends per
 * pixel rather than consuming a flattened bake.
 *
 * bf6_bake_terrain flattens the ground into one albedo raster, which is the
 * right answer for a thumbnail and the wrong one for a viewport: a whole-map
 * raster lands at two to four metres a texel while the ground materials
 * themselves repeat every one to seven metres, so flattening averages every
 * material away before the renderer sees it and the result reads as a
 * low-resolution photograph of ground.
 *
 * This carries the coverage instead - which varies slowly and rasterises
 * happily at a couple of metres - and leaves the materials to be sampled per
 * pixel at their own tiling. The detail then comes from the sheets at full
 * resolution and only the mixing weights are baked. */
typedef struct {
    int32_t     layer;              /* the layer index this came from       */
    const char* albedo_res;         /* texture resource, "" when unbound    */
    const char* normal_res;
    float       metres_per_repeat;  /* world metres per texture repeat      */
    float       uv_rotation_deg;
    float       tint[3];
    /* How strongly this layer takes the aerial colour map, as a Photoshop
     * Overlay. 1 when the level does not author it - the field is optional
     * and its absence means "fully", not "not at all". */
    float       overlay;

    /* THE EVALUATOR CONSTANTS. `weight` in the coverage raster is the game's
     * raw MASK, not final coverage; the ComputeLayer kernel turns one into the
     * other per pixel using each layer's own height:
     *
     *   coverage = saturate(mask + (hiRef - loRef) * height_blend)
     *
     * with both height references pulled toward the running composite by
     * pow(maskRamp, mask_ramp_exp), evaluated in ASCENDING layer order.
     * Normalising the masks instead makes every texel a four-way average and
     * no material ever reads. The height itself is the BLUE channel of
     * `normal_res`. */
    float       base_height;
    float       displace_range;
    float       mask_ramp_exp;
    float       height_blend;
    float       coord_scale[2];
    float       uv_offset[2];
    /* Authored auxiliary `_op` sheet used by the generated evaluator to gate
     * the stored paint mask. Appended so every earlier field keeps its ABI
     * offset; NULL/empty means the multiplicative identity. */
    const char* coverage_res;
} bf6_ground_material;

typedef struct {
    int32_t        size;
    float          lo[2];           /* world XZ of the low corner, metres   */
    float          hi[2];
    /* size*size*slot_count each, owned by the context. idx indexes MATERIALS, not raw
     * layer ids, and 255 means "no layer here"; w is that slot's weight,
     * weight-sorted with the first zero ending the list. Sample idx with
     * POINT filtering - a bilinear read of an index is a different index. */
    const uint8_t* idx;
    const uint8_t* weight;
    /* THE AERIAL COLOUR MAP over the same rectangle, size*size*3 sRGB bytes,
     * or NULL when the level ships none. Every layer Overlay-blends this by
     * its own `overlay` strength. It is what carries a map's real palette:
     * the sheets on their own are stock studio colour, so a renderer that
     * skips this draws ground that is grey or plainly the wrong hue. */
    const uint8_t* colour;
    const bf6_ground_material* materials;
    int32_t        material_count;
    float          empty_fraction;
    /* Number of compact evaluator slots per texel. Appended for ABI hygiene;
     * zero from an older DLL means the historical width of four. */
    int32_t        slot_count;
} bf6_ground_coverage;

/* Requires bf6_open_level. size 0 -> 2048. Returns 1 on success. */
BF6_API int bf6_ground_coverage_get(bf6_ctx*, const char* level, int size,
                                    bf6_ground_coverage* out,
                                    char* err, int err_len);

/* One material sheet, DECODED and resampled to a square of `size`, so a
 * renderer can put every ground layer into one texture array.
 *
 * bf6_texture_at hands back COMPRESSED blocks at whatever size the asset
 * ships, which is right for binding a sheet on its own and useless for an
 * array: an array needs one size and one format for every slice. This does
 * the decode and the box-resample so a caller does not need a BCn decoder of
 * its own.
 *
 * Writes size*size*4 bytes of RGBA8 into `out`, which the CALLER owns and
 * sizes. Returns 1 on success. */
BF6_API int bf6_layer_sheet(bf6_ctx*, const char* res_name, int size,
                            uint8_t* out, char* err, int err_len);

/* ----------------------------------------------------------- raw asset access
 *
 * WHY A RAW DOOR EXISTS AT ALL. Everything above hands back DECODED things -
 * a mesh, a texture, a light row - because that is what an engine binding
 * wants. A pipeline that reproduces the game's own asset tree on disk wants
 * the opposite: the bytes exactly as the mount produces them, so a decoder
 * written elsewhere (a Python EBX reader, an existing converter) can read them
 * without this library having to grow that decoder's opinions.
 *
 * These are the mount's own three tables, unfiltered: EBX partitions,
 * resources, and chunks. Nothing here parses anything except bf6_res_chunks,
 * which exists only because the mapping resource -> chunk is not recorded in
 * the mount and has to come out of the resource's own header.
 */

/* MOUNT THE REST OF THE INSTALL.
 *
 * bf6_open mounts <game>/Data/Win32/*.toc only. That is the fast catalogue and
 * it is not the whole install: a large part of the shipped content arrives in
 * the packages under Update/, and anything that reads assets by NAME rather
 * than by placement will find those names simply absent. Measured on a retail
 * install, a weapon folder that holds 250 assets holds 4 of them in the
 * Data/Win32 mount - every per-attachment record is in the Update packages.
 *
 * include_levels additionally mounts every LEVEL's archives, which is a much
 * bigger and slower thing; pass 0 unless level content is actually wanted.
 * First mount wins on a name collision, so calling this after bf6_open leaves
 * everything bf6_open already resolved exactly as it was.
 *
 * Returns 1 on success, 0 with a reason in err. */
BF6_API int bf6_mount_all(bf6_ctx*, int include_levels, char* err, int err_len);

/* Focused native-viewer mount. It discovers installed TOCs and selects the
 * shared UI/weapons/characters/vehicles/globals/main-menu/English-text archive
 * families by their live paths. It does not consume an exported owner table.
 * Use bf6_mount_all for whole-install enumeration. */
BF6_API int bf6_mount_frontend(bf6_ctx*, char* err, int err_len);

/* Add one named level's archives to an existing mount without walking or
 * decoding the level. This is for narrowly owned shared assets (for example a
 * UI palette authored in one campaign bundle), and is deliberately distinct
 * from bf6_open_level. Existing names still win. */
BF6_API int bf6_mount_level_archives(bf6_ctx*, const char* level,
                                     char* err, int err_len);

/* Mount one EBX through an exact TOC + bundle owner read path. `toc_path` may
 * be relative to the game directory. This avoids widening a focused viewer's
 * active name/index population merely to read one authored record. */
BF6_API int bf6_mount_ebx_owner(bf6_ctx*, const char* toc_path,
                                const char* bundle_name, const char* ebx_name,
                                char* err, int err_len);

/* One row of the mount's name tables. `name` points into the ctx and is valid
 * until bf6_close. `type` is the resource type id (0 for EBX), `size` the
 * decompressed byte length the bundle recorded. */
typedef struct {
    const char* name;
    uint32_t    type;
    uint32_t    size;
} bf6_asset;

/* Every EBX partition / resource whose name CONTAINS `search` (NULL or "" =
 * all). Returns the TOTAL match count and writes up to out_max rows, so the
 * usual call is once with out NULL to size and once to fill. Order is the
 * mount's hash order and is not stable across runs; sort if you need it. */
BF6_API int bf6_list_ebx(bf6_ctx*, const char* search, bf6_asset* out, int out_max);
BF6_API int bf6_list_res(bf6_ctx*, const char* search, bf6_asset* out, int out_max);

/* Which chunks the mount carries, by 32-char lowercase guid hex. Writes
 * out_max * 33 bytes (32 hex + NUL each) into `out`. Returns the total. */
BF6_API int bf6_list_chunks(bf6_ctx*, char* out, int out_max);

/* PARTITION GUID -> ASSET NAME.
 *
 * An EBX partition refers to another one by GUID, never by name, so anything
 * that follows a reference out of a partition needs this map to know what it
 * landed on. It is not in the mount's tables: it comes from the EFIX header of
 * every partition, so building it is a read of every partition header in the
 * mount and it is cached after the first call.
 *
 * Both strings point into the ctx and live until bf6_close. Returns the TOTAL
 * count; writes up to out_max rows. */
typedef struct {
    const char* guid;   /* 8-4-4-4-12 lowercase hex with dashes */
    const char* name;   /* the asset name with a .ebx suffix    */
} bf6_partition;

BF6_API int bf6_partition_index(bf6_ctx*, bf6_partition* out, int out_max);

/* The runtime-read subset needed by the native armory. Same lifetime and
 * count/fill contract as bf6_partition_index. */
BF6_API int bf6_armory_partition_index(bf6_ctx*, bf6_partition* out, int out_max);

typedef enum {
    BF6_RAW_EBX = 0,
    BF6_RAW_RES = 1,
    BF6_RAW_CHUNK = 2        /* `name` is the guid hex, either spelling */
} bf6_raw_kind;

/* The decompressed bytes of one asset. Returns the byte length, or -1 when the
 * name is not in the mount / the read failed.
 *
 * The bytes live in a ONE-SLOT buffer on the context and are valid only until
 * the next bf6_read_raw on that context - a copy-out door, not a cache. A
 * two-call size-then-fill protocol would decompress twice, which over a
 * hundred thousand assets is the whole cost of the operation; a handle per read
 * would make the caller free a hundred thousand times. Neither is worth it for
 * a caller that is going to memcpy the bytes and write them to a file.
 *
 * NOT thread safe against itself for that reason: one reader per context. */
BF6_API int64_t bf6_read_raw(bf6_ctx*, int kind, const char* name,
                             const uint8_t** out_data);

/* Structural inspection of one raw SerializedExpressionNodeGraph RES
 * (0x7DD4CC89). The caller mounts the owning frontend/level first, then names
 * the installed resource directly. No exported corpus table is consumed.
 * `exact_record_tiling` is 1 only when every record byte is covered by a
 * measured kind length; 0 is an explicit rare-kind coverage gap, not failure.
 */
typedef struct {
    uint32_t payload_bytes;
    uint32_t content_hash;
    uint32_t instance_header_size;
    uint32_t constant_pool_size;
    uint32_t slot_file_size;
    uint32_t record_bytes;
    uint32_t pointer_table_entries;
    uint32_t external_bindings;
    uint32_t type_count;
    uint32_t instance_value_group_count;
    uint32_t slot_value_group_count;
    uint32_t relocation_count;
    uint32_t fixup_count;
    uint32_t record_count;
    uint32_t discovered_record_bytes;
    uint8_t  exact_record_tiling;
    uint8_t  instance_buffer_count;
    uint8_t  register_group_0;
    uint8_t  register_group_1;
    uint8_t  register_group_2;
    uint8_t  _reserved[3];
} bf6_expression_stats;

BF6_API int bf6_expression_inspect(bf6_ctx*, const char* res_name,
                                   bf6_expression_stats* out,
                                   char* err, int err_len);

/* Current executable's 32-byte DiceExpression descriptor registry. This is a
 * direct structural PE scan, so game updates add/remove rows automatically.
 * Returns TOTAL matches and writes up to out_max, like the asset listings. */
typedef struct {
    uint32_t key;
    uint32_t flags;
    uint64_t implementation_va;
    uint64_t record_va;
} bf6_expression_operator;

BF6_API int bf6_expression_descriptor_operators(
    const char* exe_path, bf6_expression_operator* out, int out_max,
    char* err, int err_len);

/* Query-driven compact EA::EX::MethodRegistry scan. `keys` must come from
 * graph fixups; unrelated executable tables share this 16-byte shape. */
BF6_API int bf6_expression_method_operators(
    const char* exe_path, const uint32_t* keys, int key_count,
    bf6_expression_operator* out, int out_max,
    char* err, int err_len);

typedef struct {
    uint32_t key;
    uint32_t match_count; /* 1 is usable; >1 is deliberately withheld */
    char     name[128];
} bf6_expression_operator_name;

BF6_API int bf6_expression_resolve_operator_names(
    const char* exe_path, const uint32_t* keys, int key_count,
    bf6_expression_operator_name* out, int out_max,
    char* err, int err_len);

typedef struct {
    uint32_t key;
    uint16_t parameter_count;
    uint16_t _reserved;
    uint32_t signature;
    uint64_t descriptor_va;
    uint64_t parameters_va;
} bf6_expression_reflected_operator;

BF6_API int bf6_expression_reflected_operators(
    const char* exe_path, bf6_expression_reflected_operator* out, int out_max,
    char* err, int err_len);

/* Resolve an EBX ResourceRef id to the RES name it points at. Returns 1 and
 * fills `out` on success, 0 if no resource carries that rid.
 *
 * A ResourceRef is a 64-bit id, not a name. A reader that only resolves by name
 * cannot follow one, which makes a live reference look like a dead end - so
 * "the reference does not resolve" and "this reader cannot follow references"
 * get confused. This tells them apart. */
BF6_API int bf6_res_by_rid(bf6_ctx*, uint64_t rid, char* out, int out_len);

/* What a chunk is TO the resource that named it. A caller extracting to disk
 * wants this: the streamed chunks are the high-resolution mip0 sheets and they
 * are the overwhelming majority of the bytes, so "everything except those" is
 * a real and useful choice rather than a corrupt subset. */
typedef enum {
    BF6_CHUNK_EMBEDDED = 0,  /* the texture's own chain, mip0 or the tail mips */
    BF6_CHUNK_STREAMED = 1,  /* mip0 on its own, present only when the header's
                              * stream bit is set - the high-resolution sheet  */
    BF6_CHUNK_LOD      = 2   /* a MeshSet LOD's vertex and index bytes         */
} bf6_chunk_role;

/* The chunk guids one RESOURCE references, which is the only part of the
 * mapping that is not in the mount's tables. A MeshSet names one chunk per LOD;
 * a texture names an embedded chunk and, when its header's stream bit is set, a
 * separate mip0 chunk.
 *
 * Writes out_max * 33 bytes (32 hex + NUL each) into `out`, and, when
 * out_roles is non-NULL, out_max ints of bf6_chunk_role beside them. Returns
 * the total found, or 0 when the resource references none.
 *
 * A guid the mount does not carry is NOT returned, and neither is an all-zero
 * one: both mean "no chunk here", and reporting them would make every caller
 * re-derive that. */
BF6_API int bf6_res_chunks(bf6_ctx*, const char* res_name, char* out, int out_max,
                           int* out_roles);

/* IS THIS INSTALL'S TYPE SCHEMA READABLE?
 *
 * An EA App install ships the executable DRM-wrapped: the reflection sections
 * read as ciphertext, so every type lookup returns nothing and every EBX walk
 * comes back EMPTY WITH NO ERROR. A tool that does not check this produces a
 * plausible, entirely empty result. Meshes, textures and the archive name
 * tables are unaffected - they never touch the executable.
 *
 * Measures Shannon entropy over the first mebibyte of the executable's
 * `typeinfo` section. Returns 1 when the schema reads, 0 when it does not, and
 * -1 when the executable could not be opened at all. `bits` (may be NULL)
 * receives the measurement so a caller can print it rather than assert it. */
BF6_API int bf6_typeinfo_readable(const char* exe_path, double* bits);

/* One EBX partition, read THROUGH THE REFLECTION, formatted as a readable
 * tree. Returns the byte length the text needs (including the terminator), or
 * -1 with a reason written into `out`.
 *
 * For exploring a record whose layout you do not yet know. Reading a field by
 * FIXED OFFSET is the alternative and it is a trap: attachment cost sits at
 * 0x80 in an attachment partition, while 0x80 in a slot-definition partition
 * is the middle of that partition's own name string, and both reads return a
 * plausible integer. The schema already knows the difference.
 *
 * max_depth <= 0 means 3, which is deep enough to see an array of structs. */
BF6_API int64_t bf6_ebx_dump(bf6_ctx*, const char* name, int max_depth,
                             char* out, int out_len);

/* BF6's installed reflection does not ship field names, only hashes. This ABI
 * is retained for compatibility and returns NULL in the runtime library.
 * Research tools may join hashes against the guarded field-name oracle, but a
 * runtime reader must carry its proven field hashes and read path directly. */
BF6_API const char* bf6_field_name(uint32_t name_hash);

/* ------------------------------------------------------------------ armory */
/* One weapon-customization slot, as the GAME defines it.
 *
 * There are 43 of these, not the 11 three-letter codes that appear in
 * attachment FILENAMES. `mzl` is an abbreviation in a filename; MuzzleDevice
 * is a slot. A consumer that works from the abbreviations cannot see the
 * slots that have no filename form, including camo and charm slots. */
typedef struct {
    uint32_t    id;        /* authored, NOT a hash of the name - it must be read */
    const char* name;      /* owned by the ctx, valid until bf6_close            */
    int32_t     is_player_facing; /* IsPlayerFacing, 0/1; authored field          */
    int32_t     flag2;     /* 0/1; meaning not yet established                   */
} bf6_armory_slot;

/* Every slot the install defines. Returns the TOTAL count and fills up to
 * out_max rows, so the usual call is once with out NULL to size and once to
 * fill. Sorted by partition name, so the order is stable between runs - the
 * mount's own order is a hash order and is not. -1 if the type schema cannot
 * be loaded (an EA App install, whose type table is encrypted). */
BF6_API int bf6_armory_slots(bf6_ctx*, bf6_armory_slot* out, int out_max);

/* One live armory CameraModeAsset. `mode` is the asset leaf (for example
 * "weaponbehavior" or "weaponsightbehavior"). The two offsets are returned
 * in evaluation order around LookAtTarget: pre is weapon-anchor local, post
 * is camera local. No recorded camera table is a runtime input. */
typedef struct {
    char    mode[64];
    char    anchor[64];
    char    look_at[64];
    float   pre_offset[3];
    float   pre_rotation_degrees[3];
    float   post_offset[3];
    float   post_rotation_degrees[3];
    float   focal_length_mm;
    float   aperture;
    float   shutter;
    float   focus_distance;
    int32_t lens_candidates;
} bf6_armory_camera_mode;

/* Reads game/glacierflow/flow_mainmenu/camera/<mode> from the current mount.
 * Returns 1 only when the anchor, look-at, both constant offsets and a physical
 * lens were found in the authored controller graph. */
BF6_API int bf6_armory_camera_mode_read(bf6_ctx*, const char* mode,
                                        bf6_armory_camera_mode* out);

/* Enumerates every structurally valid weapon camera under the live main-menu
 * camera directory. Returns TOTAL and fills up to out_max. This keeps the
 * shipped mode inventory out of viewer-side tables. */
BF6_API int bf6_armory_camera_modes(bf6_ctx*, bf6_armory_camera_mode* out,
                                    int out_max);

/* Physical sensor gate used by the armory rig.  This is deliberately a
 * separate ABI record: adding fields to bf6_armory_camera_mode would change
 * the size of an existing public struct.  The reader discovers the body asset
 * from the current mount and accepts it only when every distinct candidate
 * agrees on the same positive SensorWidth and SensorHeight values. */
typedef struct {
    char    asset[192];
    float   width_mm;
    float   height_mm;
    int32_t candidates;
} bf6_armory_camera_sensor;

BF6_API int bf6_armory_camera_sensor_read(bf6_ctx*,
                                          bf6_armory_camera_sensor* out);

/* Per-weapon values written into the eight runtime CameraVec3Assets consumed
 * by the slot camera modes.  The order is the graph's proven memory-slot
 * order, not the declaration order of MenuWeaponAttachmentsCamera:
 * sight position, sight look-at, top rail, right rail, left rail, muzzle,
 * underbarrel, magazine.  `has_record` is false for the two trailing weapon
 * references for which the current graph deliberately falls back to zero. */
typedef enum {
    BF6_ARMORY_CAMERA_SIGHT_POSITION = 0,
    BF6_ARMORY_CAMERA_SIGHT_LOOK_AT = 1,
    BF6_ARMORY_CAMERA_TOP_RAIL_LOOK_AT = 2,
    BF6_ARMORY_CAMERA_RIGHT_RAIL_LOOK_AT = 3,
    BF6_ARMORY_CAMERA_LEFT_RAIL_LOOK_AT = 4,
    BF6_ARMORY_CAMERA_MUZZLE_LOOK_AT = 5,
    BF6_ARMORY_CAMERA_UNDERBARREL_LOOK_AT = 6,
    BF6_ARMORY_CAMERA_MAGAZINE_LOOK_AT = 7,
    BF6_ARMORY_CAMERA_CORRECTION_COUNT = 8
} bf6_armory_camera_correction_slot;

typedef struct {
    char    weapon[64];
    float   correction[BF6_ARMORY_CAMERA_CORRECTION_COUNT][3];
    int32_t reference_index;
    int32_t record_index;
    int32_t has_record;
} bf6_armory_camera_weapon_correction;

/* Reads WeaponAttachments_CameraSetup and its SerializedExpressionNodeGraph
 * from the mounted install.  No recorded camera TSV is a runtime input.
 * Returns TOTAL and fills up to out_max. */
BF6_API int bf6_armory_camera_weapon_corrections(
    bf6_ctx*, bf6_armory_camera_weapon_correction* out, int out_max);
BF6_API int bf6_armory_camera_weapon_correction_read(
    bf6_ctx*, const char* weapon, bf6_armory_camera_weapon_correction* out);

/* One ASLO category anchor. Category ids are authored opaque ids and are
 * returned unchanged; consumers join them to the live armory category assets.
 * The position is metric weapon space. `has_position` distinguishes an
 * authored zero from a non-zero override without inventing a threshold. */
typedef struct {
    uint32_t category_id;
    float    position[3];
    float    line_offset[2];
    int32_t  has_position;
} bf6_armory_slot_anchor;

/* Reads common/hardware/.../<weapon>/aslo_<weapon>. Returns 0 when that weapon
 * ships no ASLO asset, -1 on malformed input, or TOTAL rows on success. */
BF6_API int bf6_armory_slot_anchors(bf6_ctx*, const char* weapon,
                                    bf6_armory_slot_anchor* out, int out_max);

/* The armory screen's 12 attachment categories, IN THE ORDER THE GAME SHOWS
 * THEM. Read from the screen's own config asset, not tabulated here, and not
 * the navigation order - a sibling asset carries the same labels in a
 * different permutation for input indexing. Strings are owned by the ctx. */
BF6_API int bf6_armory_categories(bf6_ctx*, const char** out, int out_max);

/* One row of the armory screen's authored category binding, joined to the
 * three-letter filename vocabulary by reading this weapon's attachment
 * records.  `label` and `category_asset` come from
 * BFUIWeaponCustomizationViewManagerConfig; `code` is accepted only when all
 * attachment records that reference that category agree on one filename code.
 * An empty code is an explicit unresolved join, never a guessed abbreviation.
 */
typedef struct {
    char     label[32];
    char     code[8];
    char     category_asset[192];
    uint32_t category_id;
    int32_t  evidence_rows;
    int32_t  conflicting_rows;
} bf6_armory_category_binding;

/* Returns the twelve rows in authored presentation order. `weapon` is the
 * bare runtime token, for example "m4a1". A fake or absent weapon may still
 * return the authored rows, but every `code` will remain empty. */
BF6_API int bf6_armory_category_bindings(
    bf6_ctx*, const char* weapon, bf6_armory_category_binding* out, int out_max);

/* The three honestly reproducible BASE numbers in the armory stat block.
 * The four bars are attribute-delegate outputs and are intentionally absent
 * until those delegate expressions are decoded. */
typedef struct {
    int32_t damage;
    int32_t rate_of_fire;
    int32_t magazine;
} bf6_weapon_base_stats;

/* Read <weapon>_wb plus its ProjectileData import at runtime. Returns 1 when
 * all three values resolve, 0 for an unsupported/non-weapon roster entry. */
BF6_API int bf6_base_weapon_stats(bf6_ctx*, const char* weapon_class,
                                  const char* weapon, bf6_weapon_base_stats* out);

/* Read the customization allowance from equipment_<weapon> in the mounted
 * install.  The value is field 0x3CE3B411 on the weapon's customization
 * registry (100 on current primaries, 60 on current sidearms).  Returns -1
 * when the exact equipment partition or field is absent; callers must not
 * substitute a plausible default. */
BF6_API int bf6_weapon_point_budget(bf6_ctx*, const char* weapon);

/* Read WeaponCustomizationAttachmentDBD.Weight from one per-weapon
 * attachment partition.  The read is keyed by the attachment-record type
 * GUID and reflected field 0x6EE865A5; it does not depend on the field's
 * current byte offset.  Returns -1 when the partition, exact record type, or
 * field is absent. */
BF6_API int bf6_attachment_weight(bf6_ctx*, const char* attachment_ebx);

typedef struct bf6_weapon_ui_info {
    const char* name;
    const char* description;
    const char* class_label;
    const char* factory_label;
    const char* traits[3];
    int32_t trait_count;
} bf6_weapon_ui_info;

/* US-English strings and weapon UI metadata, decoded from the mounted
 * FsUITextDatabase/UIWeaponAbilityMetadata at runtime. Returned strings are
 * context-owned; weapon_ui_info pointers last until the next such call. */
BF6_API const char* bf6_localized_string(bf6_ctx*, uint32_t string_id);
BF6_API int bf6_weapon_ui_info_read(bf6_ctx*, const char* weapon,
                                    bf6_weapon_ui_info* out);

/* One authored row from <weapon>/pkg_<weapon>.ebx.  This is the package list
 * consumed by the armory package screen; array order is the authored UI order.
 * The fixed buffers deliberately make the count/fill result self-contained --
 * no exported catalogue is consulted and no pointer lifetime leaks through
 * the C ABI. */
typedef struct {
    char    key[96];          /* author/debug identity, e.g. M4A1_WSEr0014 */
    char    name[128];        /* localized NameSid                        */
    char    description[512]; /* localized DescriptionSid                 */
    char    icon_asset[256];  /* authored weapon-package TextureAsset, if any */
    int32_t ordinal;          /* index in UIItemDescriptionAsset.Items    */
} bf6_weapon_package_row;

/* Read pkg_<weapon> directly from the mounted install. `weapon` is the bare
 * roster token. Returns the total row count, -1 when the exact partition or
 * schema is absent. A fake token is therefore a negative control, not an
 * empty but apparently valid package catalogue. */
BF6_API int bf6_weapon_packages(bf6_ctx*, const char* weapon,
                                bf6_weapon_package_row* out, int out_max);

/* -------------------------------------------------------------------- rime */
/* One axis of a UI element's box. Anchors are fractions of the parent, offsets
 * are authored pixels on a 1920x1080 canvas (a consumer scales by nothing).
 * offset_end is an INWARD inset: on all 14,077 point-anchored axes in the
 * front end, offset_start == -offset_end exactly, which only makes sense if
 * both edges land on one line and the box is self-sized from Width/Height and
 * placed by the pivot. */
typedef struct {
    float anchor_start, anchor_end;
    float offset_start, offset_end;
    float pivot, weight;
} bf6_rime_axis;

/* One UI element, read from the SHIPPED schema.
 *
 * Rime partitions carry an older revision of these types than the executable
 * does, so this is deliberately NOT read through the reflection - doing that
 * returns plausible garbage with no error. */
typedef struct {
    const char*   name;          /* owned by the ctx, valid until bf6_close  */
    uint32_t      name_hash;     /* djb2-xor of the lowercased name          */
    bf6_rime_axis h, v;
    float         width, height; /* used when an axis is point-anchored      */
    float         alpha;
    int32_t       visible, fit_w, fit_h;
    int32_t       is_widget_ref; /* a reference to another partition's tree  */
    int32_t       instance;      /* index within the partition               */
} bf6_rime_element;

/* Every named UI element in one partition. Returns the TOTAL count and fills
 * up to out_max, so size then fill. -1 when the partition is not in the mount
 * or the type schema cannot load. */
BF6_API int bf6_rime_elements(bf6_ctx*, const char* partition,
                              bf6_rime_element* out, int out_max);

/* A live, recursively expanded Rime screen tree.  Unlike bf6_rime_elements,
 * this follows the authored Elements arrays and widget-reference imports, so
 * depth describes the real parent/child order used by the layout pass.  All
 * text is stored inline: rows remain valid independently of later calls.
 *
 * `kind` is one of BF6_RIME_* below.  A node with kind UNKNOWN is retained as
 * an explicit gap, but no fixed offsets are read from it unless its concrete
 * (type GUID, shipped signature) pair is in the compiled gate. */
enum {
    BF6_RIME_UNKNOWN = 0,
    BF6_RIME_WIDGET_REFERENCE,
    BF6_RIME_CONTAINER,
    BF6_RIME_STACK_CONTAINER,
    BF6_RIME_LABEL,
    BF6_RIME_LAYER,
    BF6_RIME_REPEAT_SHAPE,
    BF6_RIME_VECTOR_SHAPE,
    BF6_RIME_FILL,
    BF6_RIME_SVG,
    BF6_RIME_TEXTURE,
    BF6_RIME_LINE,
    BF6_RIME_MOVIE,
    /* Appended element kinds keep every earlier numeric value ABI-stable.
     * These are concrete shipped Rime records, not presentation guesses. */
    BF6_RIME_BORDER,
    BF6_RIME_BLUR,
    BF6_RIME_PROGRESS,
    BF6_RIME_ARC_PROGRESS,
    BF6_RIME_FLIPBOOK,
    BF6_RIME_TEXTURE_BLEND,
    BF6_RIME_INPUT_BEHAVIOR,
    /* Custom front-end elements whose visible content is supplied by a live
     * property/view-model binding.  Keeping them distinct prevents a renderer
     * from mistaking "not statically populated" for an ordinary empty box. */
    BF6_RIME_LAYERED_ICON_BINDING,
    BF6_RIME_HARDWARE_ICON_BINDING,
    BF6_RIME_REMOTE_WIDGET_PRESENTER
};

typedef struct {
    char          partition[256];   /* partition that owns this instance       */
    char          reference[256];   /* widget target, empty if not a reference */
    char          type_guid[37];
    char          type_name[64];
    char          name[128];
    uint32_t      type_signature;   /* signature shipped in this partition     */
    uint32_t      name_hash;
    bf6_rime_axis h, v;
    float         width, height, alpha;
    float         pad_l, pad_t, pad_r, pad_b;
    float         item_spacing;
    int32_t       kind, depth, parent, instance;
    int32_t       visible, fit_w, fit_h;
    int32_t       stack_orientation; /* -1 except on a stack                    */

    /* PAINT.  Appended after the box fields on purpose: the struct still grew,
     * so header and dll move together as always, but the geometry offsets a
     * consumer already relies on do not shift. */
    char          color_id[40];   /* the authored ColorId, "" when unnamed     */
    char          color_name[64]; /* its palette name, e.g. "FE-Neutral"       */
    uint32_t      color_rgb;      /* 0x00RRGGBB, sRGB-ENCODED and ready to use */
    int32_t       color_source;   /* BF6_RIME_COLOR_*                          */

    /* Repeat shapes: the pip strip's own count and distribution, rather than a
     * guess.  0 / -1 on every other kind. */
    int32_t       repeat_instances;
    int32_t       repeat_distribution; /* BF6_RIME_DIST_*, -1 when not a repeat */

    /* Image elements: the asset the element draws, resolved to a partition
     * path, plus the uv window on it.
     *
     * A NULL image is the common case and is not a failure: 21 of the 30 SVG
     * elements on the weapon screen carry no asset because the icon arrives
     * from a data binding. Those must draw nothing rather than a placeholder,
     * or the screen fills with boxes the game does not have. */
    char          image_asset[192];
    float         image_uv[4];      /* u0,v0,u1,v1; 0,0,1,1 when unauthored */

    /* Fills only: the authored fill style.
     *
     * A null FillStyle is NOT an error - it is a flat fill of the element's own
     * resolved colour, which is 26 of the 32 fills on the weapon screen. The six
     * that name a style are all a single gradient layer whose start and end
     * colours are WHITE and whose only variation is alpha: the layer is an
     * ALPHA RAMP modulating the element colour, not a colour gradient. Read as a
     * colour gradient it turns white-on-white and the full-screen scrim that
     * every menu lays down simply vanishes. */
    int32_t       fill_kind;        /* BF6_RIME_FILL_*                      */
    int32_t       fill_direction;   /* BF6_RIME_GRADIENT_*                  */
    float         fill_alpha_start;
    float         fill_alpha_end;
    int32_t       blend_mode;       /* authored on the element base, -1 if absent */

    /* Labels only: the authored text style, and the point size resolved from
     * it.  PointSize on the element itself is an override and is 0 throughout
     * the shipped front end, so the style is the answer.  Canvas pixels are
     * point_size / 1.5. */
    char          font_style[160];
    float         point_size;
    float         line_height;

    /* Anchor containers only: the point ON THIS BOX that a leader line leaves
     * from, as a fraction of the box.  The customization screen's twelve
     * floating attachment tiles are laid out entirely from these plus the
     * axes above, so a consumer does not need a transcribed anchor table.
     * has_attach is 0 on every other kind - (0,0) is a real value. */
    int32_t       has_attach;
    float         attach_x, attach_y;

    /* Runtime-populated list metadata, read from the shipped DiceUI element.
     * UniformGrid owns one ItemTemplate. DataList owns an ordered
     * ItemTemplates class-reference ARRAY: weaponinfoheader, for example,
     * selects two different cell families for LabelList and three for
     * ButtonList. item_template remains the first entry for source
     * compatibility; item_templates preserves the authored selector order.
     * Empty / -1 means this is not a list. */
    char          item_template[256];
    int32_t       item_template_count;
    char          item_templates[8][256];
    int32_t       grid_static_segment_item_count;
    float         grid_column_size;
    float         grid_row_size;
    float         grid_row_spacing;
    float         grid_column_spacing;
    int32_t       grid_segment_distribution;
    int32_t       grid_segment_count_mode;
    int32_t       grid_column_flow_direction;
    int32_t       grid_row_flow_direction;
    int32_t       grid_item_fit_content;

    /* Fixed-size paint records carried directly by their gated concrete
     * element.  These remain zero/-1 on other kinds. */
    float         progress;
    float         progress_segment_gap;
    int32_t       progress_segment_count;
    int32_t       progress_orientation; /* RimeOrientation, -1 if absent */
    float         border_thickness;
    float         border_start_alpha;
    float         border_end_alpha;
    int32_t       border_alignment;      /* RimeOutlineAlignment, -1 */
    int32_t       border_gradient_direction; /* RimeGradientDirection, -1 */

    /* DiceUIDataListElementData only, gated by shipped type GUID
     * 2420ee41-1c4d-38bd-4203-777f31cf9c9a.  ItemSpacing uses the existing
     * item_spacing member above.  These are the remaining authored repetition
     * fields at +420/+436/+444/+449.  FlowDirection is the shipped
     * Default/Reverse/TextDirection enum; it is NOT an axis/orientation and a
     * consumer must not turn it into Horizontal/Vertical. */
    int32_t       data_list_size_distribution;
    int32_t       data_list_flow_direction;
    int32_t       data_list_space_distribution;
    int32_t       data_list_preserve_fit_content;

    /* RimeViewportStretchContainerElementData only.  These are authored edge
     * selectors, not inferred from the element name.  The old schema shipped
     * in UI partitions places them after its Elements/FlowDirection tail; the
     * concrete type GUID + signature gate protects the fixed read.  -1 on
     * every other element kind. */
    int32_t       viewport_flow_direction;
    int32_t       viewport_extend_top;
    int32_t       viewport_extend_bottom;
    int32_t       viewport_extend_left;
    int32_t       viewport_extend_right;

    /* Shipped stack/reference layout controls.  These are appended to keep
     * every established bf6_rime_node member ABI-stable.  -1 means the row is
     * not the corresponding concrete type. */
    float         stack_wrap_spacing;
    int32_t       stack_overflow_mode;
    int32_t       stack_size_distribution;
    int32_t       stack_space_distribution;
    int32_t       stack_preserve_fit_content;
    int32_t       widget_use_width;
    int32_t       widget_use_height;

    /* RimeContainerBaseData.FlowDirection at old-schema +328.  This is a
     * presentation-order enum (Default/Reverse/TextDirection), not a stack
     * orientation.  Appended so existing consumers keep their member offsets. */
    int32_t       container_flow_direction;
} bf6_rime_node;

enum {
    BF6_RIME_FILL_FLAT = 0,   /* no style: the element colour, flat        */
    BF6_RIME_FILL_GRADIENT,   /* an alpha ramp over the element colour     */
    BF6_RIME_FILL_SOLID,
    BF6_RIME_FILL_TEXTURE
};

/* RimeGradientDirection.
 *
 * VERTICAL IS ZERO. The obvious guess is the other way round and it reads
 * plausibly - every gradient still ramps, just along the wrong axis. Two
 * independent things pin it: the shipped elements are edge fades whose names
 * say which way they run ("[Fill] Bottom" must ramp vertically, "[Fill] Left
 * Gradient Fade" horizontally), and rime-paint-read-path states Bottom is
 * vertical. Under the reversed reading all four of the weapon screen's
 * gradients disagree with their own names; under this one all four agree. */
enum {
    BF6_RIME_GRADIENT_VERTICAL = 0,
    BF6_RIME_GRADIENT_HORIZONTAL
};

/* Where a node's colour came from.  Kept explicit because "white" is three
 * different facts: an element that named white, an element that named nothing
 * and sits under an ancestor that named nothing either, and a read that
 * failed.  A consumer that cannot tell those apart paints the third one. */
enum {
    BF6_RIME_COLOR_NONE = 0,      /* no id, no named ancestor: white x alpha  */
    BF6_RIME_COLOR_PALETTE,       /* its own ColorId resolved in the palette  */
    BF6_RIME_COLOR_RAW,           /* authored non-white RawColor, no id       */
    BF6_RIME_COLOR_INHERITED      /* nearest ancestor that named one          */
};

/* RimeRepeatShapeElementData.DistributionType.  The SDK type database names
 * these wrongly; a conservative shipped literal-name oracle scores this
 * mapping 9/9 and a rotated one 0/9. */
enum {
    BF6_RIME_DIST_RADIAL = 0,
    BF6_RIME_DIST_HORIZONTAL,
    BF6_RIME_DIST_VERTICAL,
    BF6_RIME_DIST_GRID
};

/* One entry of the front end's authored colour palette.
 *
 * 111 entries across seven assets under common/ui/assets/styles/colorpalette.
 * The stored floats are LINEAR light, and encoding them with the standard sRGB
 * transfer is not optional: skip it and FE-Neutral #BFCAD1 comes out olive.
 * `rgb` is already encoded; `linear` is kept for a consumer that wants to
 * blend before encoding. */
typedef struct {
    char     id[40];      /* ColorId, spelled as an element's SelectedColorId */
    char     name[64];    /* "FE-Neutral"                                     */
    char     palette[64]; /* "gla_frontend"                                   */
    uint32_t rgb;         /* 0x00RRGGBB, sRGB                                 */
    float    linear[3];   /* as authored                                      */
} bf6_rime_color;

/* The whole palette, read live from the mounted install.  Returns the TOTAL
 * count and fills up to out_max, so size then fill.  -1 when the palette
 * assets are not reachable.  Cached on the context after the first call. */
BF6_API int bf6_rime_palette(bf6_ctx*, bf6_rime_color* out, int out_max);

/* ------------------------------------------------------------------- fonts */
/* One authored text style.
 *
 * The front end does not carry font SIZES at its use sites; it carries a
 * reference to one of these, and the style says how big the text is and how
 * far apart the lines sit.  A consumer that picks its own pixel sizes is
 * inventing typography next to the game's own.
 *
 * POINT SIZE IS NOT PIXELS.  Canvas pixels are PointSize / 1.5 - the filename
 * of every style spells both, e.g. fe_body_14px_(21pt)_regular is 21.02 pt and
 * 14 px.  Line height is authored independently and is not derived from the
 * point size: above roughly 40 pt it is SMALLER, which is the tight display
 * leading the headings use. */
typedef struct {
    char    name[160];       /* the style asset's authored name               */
    char    font_asset[192]; /* FontAsset path for the default language       */
    char    family[64];      /* the sfnt family, e.g. "BFText"                */
    float   point_size;      /* authored; divide by 1.5 for canvas pixels     */
    float   line_height;     /* authored independently of point_size          */
    int32_t weight;          /* 400, 500, 700 ...                             */
} bf6_rime_font_style;

/* Every RimeFontStyle in the mount.  Returns the TOTAL and fills up to out_max.
 * Cached on the context. */
BF6_API int bf6_rime_font_styles(bf6_ctx*, bf6_rime_font_style* out, int out_max);

/* One weapon's in-game identity. Keyed by the bare token the roster uses, so
 * the two join exactly rather than by resemblance. */
typedef struct {
    char weapon[64];       /* bare token, from the row's hiao_<weapon> import */
    char name[96];         /* the localised display name */
    char class_label[64];  /* the localised class */
    char factory_label[64];/* shared localised Factory package label */
    char icon_asset[256];  /* same-row imported archetype TextureAsset */
    char category_icon_asset[256]; /* same-row weapon-category TextureAsset */
} bf6_weapon_name_row;

/* Every weapon the metadata names, in ONE pass. bf6_weapon_ui_info_read
 * answers for one weapon and rescans every metadata partition to do it; a
 * roster of 185 wants the table. Returns the TOTAL and fills up to out_max. */
BF6_API int bf6_weapon_names(bf6_ctx*, bf6_weapon_name_row* out, int out_max);

/* One authored entry in MainMenu_WeaponCollectionViewManagerConfig.  This is
 * the collection source consumed by UM_WeaponNavigationListGenerator; it is
 * deliberately not reduced to a copied list of English tab labels. */
typedef struct {
    int32_t ordinal;          /* row identity carried by the config           */
    int32_t sort_index;       /* authored SortIndex                           */
    char    icon_asset[256];  /* category icon import; stable class identity  */
} bf6_weapon_navigation_row;

/* Read the ordered collection directly from the mounted install. Returns the
 * TOTAL count and fills up to out_max. A missing/changed config returns -1. */
BF6_API int bf6_weapon_navigation_rows(
    bf6_ctx*, bf6_weapon_navigation_row* out, int out_max);

/* ------------------------------------------------- the attachment catalogue */
/* One row of `aam_<weapon>.ebx`, the game's own presentation list for a
 * weapon's attachments.
 *
 * TWO LISTS EXIST AND THEY ARE NOT THE SAME LIST. The roster built from
 * partition names says what can be FITTED; this says how the armory PRESENTS
 * it - display name, description, icon and sort order. They overlap but do not
 * correspond: m4a1 has 15 muzzle tokens against 11 catalogue rows, two of those
 * rows share one description asset, and the strings are independently authored
 * (`socomrc3` against "SOCOM556 RC3", `nt4qdsuppressor` against "NT4
 * Suppressor"). So a consumer decorates the roster with this where the two
 * meet and keeps the token where they do not - it must not swap one list for
 * the other.
 *
 * `name_key` is the display name folded to lowercase alphanumerics, which is
 * the only join to a roster token that exists today. It matches 74% on m4a1
 * against a 39% shuffled control: real, and not enough to rely on silently. */
typedef struct {
    char    slot[8];          /* three-letter code, from the authored row      */
    char    name[96];         /* localised display name                        */
    char    name_key[96];     /* name folded for joining; see above            */
    char    detail_title[96]; /* description asset title used on fitted tiles  */
    char    description[512]; /* localised description                         */
    int32_t order;            /* authored display order                        */
    /* The description asset's own stem, folded and with its "ad_" prefix
     * removed. A SECOND join key, and it earns its place: the display name and
     * the filename token are independently authored, but the asset stem often
     * sits closer to the token than the name does. */
    char    ad_stem[96];

    /* Art. The index selects directly into the atlas's entry array, so these
     * pair with bf6_icon_atlas on the same partition. */
    char    icon_atlas[192];      /* per-category atlas                        */
    int32_t icon_index;
    char    layered_atlas[192];   /* the weapon's own silhouette atlas         */
    int32_t layered_index;
} bf6_attachment_catalogue_row;

/* Read one weapon's catalogue. `weapon` is the bare name, e.g. "m4a1".
 * Returns the TOTAL row count and fills up to out_max; -1 when the weapon has
 * no aam_ asset in the mount. */
BF6_API int bf6_weapon_attachment_catalogue(bf6_ctx*, const char* weapon,
                                            bf6_attachment_catalogue_row* out,
                                            int out_max);

/* ------------------------------------------------------------- connections */
/* One authored property connection - the wire that carries a value from one
 * element to another.
 *
 * This is how the front end is actually assembled. The element tree gives the
 * boxes; the connections give the DATA FLOW, and without them a screen is a
 * pile of unlabelled rectangles. menuweaponattachmenticonscreen alone carries
 * 912 of them, every endpoint internal to the partition.
 *
 * Both endpoints are instance indices into the same partition, so they join
 * directly against bf6_rime_node.instance. */
typedef struct {
    int32_t  source;        /* instance index */
    int32_t  target;        /* instance index */
    uint32_t source_field;  /* semantic property hash on source */
    uint32_t target_field;  /* semantic property hash on target */
    int32_t  mode;          /* raw shipped flags; low 3 bits are realm */
} bf6_rime_connection;

/* Every property connection authored in one partition.  This reads the
 * shipped Blueprint +48 relative array and its 32-byte records directly; it
 * does not reflect the older Rime widget graph through bf6.exe. Returns the
 * TOTAL and fills up to out_max; -1 when the partition cannot be read. */
BF6_API int bf6_rime_connections(bf6_ctx*, const char* partition,
                                 bf6_rime_connection* out, int out_max);

/* One authored event connection. Event ids intentionally remain raw hashes:
 * the installed graph proves the routing, while most event names are not yet
 * independently identified. Both endpoints are local instance indices. */
typedef struct {
    int32_t  source;        /* instance index */
    int32_t  target;        /* instance index */
    uint32_t source_event;  /* raw EventSpec.Id on the source */
    uint32_t target_event;  /* raw EventSpec.Id on the target */
    int32_t  mode;          /* target realm: 2 Client, 3 Server */
} bf6_rime_event_connection;

/* Every event connection authored in one partition. This reads the shipped
 * Blueprint +64 relative array and its 32-byte records directly. Returns the
 * TOTAL and fills up to out_max; -1 when the partition cannot be read. */
BF6_API int bf6_rime_event_connections(bf6_ctx*, const char* partition,
                                       bf6_rime_event_connection* out,
                                       int out_max);

/* One authored ConditionalFloatEntityData node from a Rime property graph.
 * These logic types have matching shipped/executable signatures; unlike the
 * older Rime element family they are safe to read through current reflection.
 * The viewer joins `instance` to the raw property wires above, so the game
 * data decides both the condition source and every target property. */
typedef struct {
    int32_t instance;
    float   value_if_true;
    float   value_if_false;
    int32_t authored_condition;
} bf6_rime_conditional_float;

/* Every ConditionalFloatEntityData node in one live partition. Returns TOTAL
 * and fills up to out_max. No research table or exported intermediate is a
 * runtime input. */
BF6_API int bf6_rime_conditional_floats(bf6_ctx*, const char* partition,
                                        bf6_rime_conditional_float* out,
                                        int out_max);

/* One authored ConditionalPropertyEntityData node.  Unlike a conditional
 * float, this node does not carry two values: it carries the hashes of two
 * dynamic input properties and selects one onto a dynamic output property.
 * That distinction is what lets WeaponInfoHeader choose Category vs Title
 * without the renderer naming either destination element. */
typedef struct {
    int32_t  instance;
    uint32_t value_if_true_property_hash;
    uint32_t value_if_false_property_hash;
    uint32_t out_hash;
    int32_t  authored_condition;
} bf6_rime_conditional_property;

/* Every ConditionalPropertyEntityData node in one live partition. */
BF6_API int bf6_rime_conditional_properties(
    bf6_ctx*, const char* partition,
    bf6_rime_conditional_property* out, int out_max);

/* Authored boolean operation nodes used throughout Rime property graphs.
 * These nodes carry no route-specific constants: their inputs and outputs are
 * the exact property connections above.  Consumers must require every wired
 * input to be known before evaluating one; an absent provider value is not
 * false. */
enum {
    BF6_RIME_LOGIC_AND = 1,
    BF6_RIME_LOGIC_OR,
    BF6_RIME_LOGIC_NOT,
    BF6_RIME_LOGIC_PROPERTY_DEFAULT
};

typedef struct {
    int32_t instance;
    int32_t operation; /* BF6_RIME_LOGIC_* */
} bf6_rime_logic_operation;

/* Every gated AndOperationEntityData, OrOperationEntityData and
 * NotOperationEntityData node in one live partition. */
BF6_API int bf6_rime_logic_operations(
    bf6_ctx*, const char* partition,
    bf6_rime_logic_operation* out, int out_max);

/* Local instance indices whose concrete type is InterfaceDescriptorData.
 * The descriptor is the blueprint's public runtime-facing property surface;
 * values sourced from it are not authored constants.  Returning identity only
 * lets consumers distinguish a dynamic input from an element fallback without
 * inventing the value.  The exact type GUID is read from the live partition;
 * the corpus is verification evidence, never a runtime lookup table. */
BF6_API int bf6_rime_interface_descriptors(bf6_ctx*, const char* partition,
                                           int32_t* out, int out_max);

/* Typed default values on an InterfaceDescriptorData's public Fields array.
 * These are decoded from the partition's DataField.BoxedValue through its
 * EBXX boxed-value descriptor; `raw typeWord` is never treated as the value.
 * A Null default remains Null -- it means the runtime provider owns that
 * property, not false/zero. */
enum {
    BF6_RIME_VALUE_NULL = 0,
    BF6_RIME_VALUE_BOOL,
    BF6_RIME_VALUE_INT,
    BF6_RIME_VALUE_UINT,
    BF6_RIME_VALUE_REAL,
    BF6_RIME_VALUE_STRING,
    BF6_RIME_VALUE_STRUCT,
    BF6_RIME_VALUE_ARRAY,
    BF6_RIME_VALUE_UNRESOLVED
};

typedef struct {
    int32_t  interface_instance;
    uint32_t field_id;
    int32_t  access_type;       /* FieldAccessType: source/target/both */
    int32_t  value_kind;        /* BF6_RIME_VALUE_*                    */
    int32_t  bool_value;
    int64_t  int_value;
    uint64_t uint_value;
    double   real_value;
    char     string_value[256];
} bf6_rime_interface_field;

/* Returns TOTAL and fills up to out_max. A fabricated partition returns -1.
 * Runtime code reads the installed EBX every process; no research TSV/JSON is
 * consumed. */
BF6_API int bf6_rime_interface_fields(bf6_ctx*, const char* partition,
                                      bf6_rime_interface_field* out,
                                      int out_max);

/* Concrete type identity for boxed STRUCT interface defaults. This is a
 * separate narrow row rather than an extension of bf6_rime_interface_field so
 * existing C ABI consumers keep the same struct size. It intentionally
 * exposes no struct payload: callers may classify a proven type GUID, but
 * must not reinterpret an unknown struct by field name or byte offset. */
typedef struct {
    int32_t  interface_instance;
    uint32_t field_id;
    char     type_guid[40];
} bf6_rime_interface_struct_type;

/* Returns one row per STRUCT default; fabricated partitions return -1. */
BF6_API int bf6_rime_interface_struct_types(
    bf6_ctx*, const char* partition,
    bf6_rime_interface_struct_type* out, int out_max);

/* One field from a mounted Rime DataBindingDefinition.  This deliberately
 * exposes only the two pieces authored by the DBD: its exact property name
 * and the opaque TypeRef payload.  The latter is evidence, not a guessed
 * semantic type. */
typedef struct {
    char     name[128];
    uint64_t type_signature;
} bf6_rime_dbd_field;

/* Read one DBD directly from the current mounted install without constructing
 * the generic, full-game partition GUID index used by the diagnostic EBX
 * dumper.  Returns TOTAL and fills up to out_max; a fabricated/unreadable
 * partition returns -1.  data_name may be NULL.  Count/fill calls both read
 * the live mounted EBX and never consume an exported table. */
BF6_API int bf6_rime_dbd_fields(bf6_ctx*, const char* partition,
                                char* data_name, int data_name_len,
                                bf6_rime_dbd_field* out, int out_max);

/* A localized-string entity's key, by instance. These are the authored text
 * the screen pushes into its widgets - the customization tile captions are
 * twelve of them - and they reach a label through a connection rather than by
 * sitting on it. Returns 0 when that instance is not a string entity. */
BF6_API uint32_t bf6_rime_string_entity(bf6_ctx*, const char* partition,
                                        int instance);

/* ------------------------------------------------------------------ shapes */
/* The front end's plates, brackets, rules and chrome are vector shapes, and
 * the FILLED ones ship their triangulation - anchors, offsets, per-vertex
 * colours and a u16 index list.  A consumer that draws a rectangle where a
 * shape belongs is not approximating the screen, it is drawing something else.
 *
 * VERTEX POSITION IS `anchor * (element_w, element_h) + offset`.  The anchors
 * are fractions of the ELEMENT's solved box, not of the asset's design Size,
 * which is how one 12x12 corner bracket serves boxes of every size.  Origin
 * top-left, +Y down, matching the box-solving law.
 *
 * STROKED SHAPES SHIP NO TRIANGLES.  They carry a corner polyline instead and
 * the renderer strokes it with Thickness and Alignment.  Corner ROUNDING is
 * not baked either - it is driven at draw time by CornerType and Curvature -
 * though 5,709 of 7,402 authored corners have curvature exactly 0. */
enum {
    BF6_RIME_DRAW_NONE = 0,
    BF6_RIME_DRAW_OUTLINED,
    BF6_RIME_DRAW_FILLED
};

typedef struct {
    float anchor[2];   /* fraction of the element box */
    float offset[2];   /* authored pixels */
    float color[4];    /* per-vertex; (1,1,1,1) throughout the shipped screens */
} bf6_rime_shape_vertex;

typedef struct {
    float   anchor[2], offset[2];
    int32_t corner_type;
    float   curvature;
} bf6_rime_shape_corner;

typedef struct {
    int32_t vertex_count;   /* triangulated vertices; 0 on a stroked shape */
    int32_t index_count;    /* u16 indices                                  */
    int32_t corner_count;   /* path corners, for stroking                   */
    int32_t draw_style;     /* BF6_RIME_DRAW_*                              */
    float   thickness;
    float   alpha;
    float   size[2];        /* the asset's design box, diagnostic only      */
} bf6_rime_shape_info;

/* The geometry behind one shape element, by the partition and instance the
 * Rime tree reports.  Returns the shape count found (0 or 1 here), -1 on a
 * failed read.  Sizes are reported in `info` so a caller can size then fill. */
BF6_API int bf6_rime_shape(bf6_ctx*, const char* partition, int instance,
                           bf6_rime_shape_info* info,
                           bf6_rime_shape_vertex* verts, int vmax,
                           unsigned short* indices, int imax,
                           bf6_rime_shape_corner* corners, int cmax);

/* RimeLineElementData keeps its polyline inline as PointData records.  This is
 * deliberately separate from bf6_rime_shape: lines do not reference a vector
 * shape asset and their points may be authored either as fractions of the
 * element box or as canvas-pixel coordinates.  Returns the TOTAL point count
 * and fills up to point_max, or -1 when the concrete shipped signature/type or
 * instance does not match. */
typedef struct {
    float x, y;
} bf6_rime_line_point;

typedef struct {
    int32_t point_count;
    float   width;
    float   glow_size;
    float   start_progress;
    float   end_progress;
    int32_t cap_type;
    int32_t relative_coordinates;
    int32_t close_line_shape;
    int32_t single_pixel;
} bf6_rime_line_info;

BF6_API int bf6_rime_line(bf6_ctx*, const char* partition, int instance,
                          bf6_rime_line_info* info,
                          bf6_rime_line_point* points, int point_max);

/* The raw sfnt bytes behind a FontAsset path, read out of the install.
 *
 * These are ordinary TrueType files with no wrapper, so the result can be
 * handed straight to a rasteriser.  Returns the TOTAL byte count and fills up
 * to out_max, or -1 if the asset is not in the mount.  A previewer therefore
 * does not need - and must not keep - extracted .ttf files beside it. */
BF6_API int bf6_rime_font_data(bf6_ctx*, const char* font_asset,
                               unsigned char* out, int out_max);

/* The native resource named by an authored Rime image partition.  This is the
 * ResourceId join used by both vector and texture assets; it does not assume
 * that the resource shares the EBX name. Returns the required string length,
 * excluding NUL, or -1. */
BF6_API int bf6_rime_image_resource(bf6_ctx*, const char* image_asset,
                                    char* out, int out_len);

/* Resolve a RimeTextureElementData image partition to the standalone texture
 * resource it names and register that resource in the ordinary texture cache.
 * Returns an id for bf6_texture_at, or -1 when the partition is not a texture
 * asset / its ResourceId is absent from the live mount.  The partition is read
 * from the installed game on this call; no exported lookup table participates. */
BF6_API int bf6_rime_texture_id(bf6_ctx*, const char* image_asset);

/* Compiled SvgImageData (RES 0x89983F10) is retained cubic-Bezier geometry,
 * not XML and not a pre-rasterized bitmap.  One contour is a start point plus
 * groups of three control/end points: (point_count - 1) % 3 == 0. */
typedef struct {
    float x, y;
} bf6_rime_svg_point;

typedef struct {
    int32_t shape;
    int32_t point_first;
    int32_t point_count;
    int32_t flag;             /* shipped 0/1; semantics remain unidentified */
    float   bounds[4];
} bf6_rime_svg_contour;

typedef struct {
    float   canvas[2];
    int32_t shape_count;
    int32_t contour_count;
    int32_t point_count;
} bf6_rime_svg_info;

/* Decode one RimeSvg image partition by its live ResourceId join.  Returns the
 * TOTAL contour count and reports total point capacity through info.  A count
 * call may pass NULL arrays; a fill call supplies the capacities from info.
 * SvgImageData paint blocks have measured 50/54/58-byte forms which may mix
 * within one resource.  Until their selector is decoded the reader constrains
 * the walk by the cubic grammar and exact resource-end closure.  -2 means no
 * unique structural walk exists; ambiguous/unknown forms are never guessed. */
BF6_API int bf6_rime_svg(bf6_ctx*, const char* image_asset,
                         bf6_rime_svg_info* info,
                         bf6_rime_svg_contour* contours, int contour_max,
                         bf6_rime_svg_point* points, int point_max);

/* A ScreenHub is a logic blueprint whose Objects array selects other hub or
 * screen blueprints at runtime.  These imports are the real main-menu
 * composition; `/screens/` name enumeration alone cannot reconstruct it. */
typedef struct {
    int32_t instance;
    char    blueprint[256];
} bf6_ui_hub_entry;

/* Direct children of one live ScreenHub partition, in authored Objects order.
 * Returns TOTAL and fills up to out_max.  Only exact Blueprint ImportRefs are
 * returned; null/dynamic entries remain absent rather than guessed by name. */
BF6_API int bf6_ui_hub_entries(bf6_ctx*, const char* hub_asset,
                               bf6_ui_hub_entry* out, int out_max);

/* Photon/Twinkle's OFFLINE visual bundle.  This is distinct from the
 * CurrentBundle-selected production JavaScript: the mounted PhotonBundle EBX
 * names one chunk plus an authored, contiguous list of PNG/SVG/font slices.
 * A consumer reads these rows and then calls bf6_read_raw(BF6_RAW_CHUNK,
 * info.chunk_guid, ...) once, slicing those exact bytes in memory.  No files
 * are exported and no research table participates at runtime. */
typedef enum {
    BF6_PHOTON_ASSET_UNKNOWN = 0,
    BF6_PHOTON_ASSET_PNG = 1,
    BF6_PHOTON_ASSET_SVG = 2,
    BF6_PHOTON_ASSET_FONT = 3
} bf6_photon_asset_kind;

typedef struct {
    char    name[256];
    uint32_t offset;
    uint32_t size;
    int32_t kind;              /* bf6_photon_asset_kind */
} bf6_photon_asset;

typedef struct {
    char    chunk_guid[33];    /* mounted spelling accepted by BF6_RAW_CHUNK */
    int64_t chunk_size;
    int32_t asset_count;
    int32_t ranges_in_bounds;
    int32_t ranges_contiguous;
    int32_t signatures_valid;
} bf6_photon_bundle_info;

/* Returns TOTAL authored asset rows, or -1 when the live bundle cannot be
 * decoded. Count/fill is cached on the context so the 29.5 MB chunk is read
 * only once. `info` reports internal controls; a renderer must reject the
 * bundle unless every count equals asset_count. */
BF6_API int bf6_photon_offline_assets(bf6_ctx*, bf6_photon_bundle_info* info,
                                      bf6_photon_asset* out, int out_max);

typedef struct {
    int32_t nodes;
    int32_t gated_nodes;       /* concrete types accepted by signature gate */
    int32_t unknown_types;     /* retained without speculative field reads   */
    int32_t unresolved_refs;
    int32_t cycles;
    int32_t depth_limited;
    int32_t duplicate_guid_refs;    /* refs whose GUID names >1 partition    */
    int32_t instance_disambiguated_refs; /* import InstanceGuid selected one */
    int32_t name_disambiguated_refs;/* duplicate resolved by authored Name  */
    int32_t identity_collision_refs;/* same full identity; mount-first wins */
    int32_t equivalent_alias_refs;  /* byte-identical aliases; mount first  */
    int32_t ambiguous_refs;         /* duplicate still ambiguous; not read  */
} bf6_rime_tree_stats;

/* Read one screen directly from the mounted install.  max_ref_depth <= 0 uses
 * six, matching the verified menuweaponscreen oracle.  Returns the total row
 * count, -1 when the root partition cannot be read.  The function caches the
 * last root on the context, so the count/fill pair performs one traversal. */
BF6_API int bf6_rime_tree(bf6_ctx*, const char* root_partition,
                          int max_ref_depth, bf6_rime_node* out, int out_max,
                          bf6_rime_tree_stats* stats);

/* --------------------------------------------------------- animation ----- */
/* AnimationAssetRelocResource - RES type 0x4088BF7E.
 *
 * 486,942 resources fleet-wide, 99.9% of BF6's animation, and the ONLY thing a
 * clip-player node ever reaches. The raw and ACL clip containers documented
 * elsewhere hold a few hundred payloads between them; a consumer that reads
 * only those reaches essentially none of the game's animation.
 *
 * Region 0's offset is the header size and decides the framing: 32 means the
 * DCT clip, 48 'VBR ', 64 'RAW '. A parser that assumes two descriptors reads
 * a RAW payload as a truncated structure WITHOUT failing, which is why the
 * framing is reported explicitly rather than inferred by the caller.
 *
 * Region meanings differ per framing. For RAW they are, in order: KeyTimes
 * (u16, empty across the whole shipped population), MappingIndices (u16),
 * ChannelIndices (u16, the inverse permutation of the previous), Data (float4)
 * and ConstData (float4). Data and ConstData are HETEROGENEOUS float4 storage -
 * channel metadata decides whether a record is a quaternion, a vector or packed
 * scalars, so neither has a unit-length invariant to check against. */
typedef enum {
    BF6_ANIM_UNKNOWN = 0,
    BF6_ANIM_DCT,          /* header 32 - the serialized DCT clip   */
    BF6_ANIM_VBR,          /* header 48                             */
    BF6_ANIM_RAW           /* header 64                             */
} bf6_anim_framing;

typedef struct { uint32_t count, offset, flags; } bf6_anim_region;

typedef struct {
    bf6_anim_framing       framing;
    int32_t                header_size;   /* == regions[0].offset          */
    const bf6_anim_region* regions;
    int32_t                region_count;  /* terminator excluded           */
    const uint8_t*         data;          /* the whole payload             */
    int64_t                size;
} bf6_anim_reloc;

BF6_API bf6_anim_reloc* bf6_anim_reloc_read(bf6_ctx*, const char* res_name);

/* A DECODED VARIANT-A (DCT) CLIP.
 *
 * Channels are ordered quaternions, then vector3s, then vector-float groups.
 * Each group packs up to four scalar DOFs into one float4, lane by position, so
 * scalar ordinal s is group s/4 lane s%4 and the last group may be short.
 *
 * `predicted_stream_bytes` against `actual_stream_bytes` is the reader's own
 * self-check: the prediction is a function of every lane width in every
 * descriptor, so a single misresolved width nibble moves it. They should be
 * equal; if they are not, do not trust the samples.
 *
 * Sampling takes a SAMPLE ORDINAL, not a time. When `sparse_times` is NULL the
 * key times are implicit and dense - every integer from 0 to the owning EBX
 * frame count INCLUSIVE, which is a last-frame index rather than a count. */
typedef struct {
    int32_t key_time_count;
    int32_t quat_count, vec3_count, group_count;
    int32_t channel_count;          /* quat + vec3 + group                    */
    int32_t block_count;            /* ceil(key_time_count / 8)               */
    const uint16_t* sparse_times;   /* NULL when times are implicit and dense */
    int32_t sparse_time_count;
    int32_t full_block_bits;
    int32_t first_coefficient_bits;
    int64_t predicted_stream_bytes;
    int64_t actual_stream_bytes;
} bf6_anim_clip;

BF6_API bf6_anim_clip* bf6_anim_clip_open(bf6_ctx*, const char* res_name);

/* Fill `out` with channel_count float4s for one sample ordinal. Returns 0 if
 * the ordinal is outside the clip. Quaternion channels come back normalised;
 * vector channels do not, because the engine does not normalise them. */
/* `out_quat_magnitude` may be NULL. When given, it receives quat_count entries:
 * each quaternion's magnitude BEFORE normalisation. That is the decode-health
 * signal - a correct unpack arrives near 1.0 because the encoder quantised a
 * unit quaternion. Checking the returned quaternions are unit proves nothing,
 * since they are normalised on the way out. */
BF6_API int bf6_anim_clip_sample(bf6_ctx*, bf6_anim_clip*, int sample_ordinal,
                                 float* out, float* out_quat_magnitude);

/* Sample at a playback TIME rather than an exact ordinal, bracketing the two
 * surrounding samples and interpolating between them. `loop` wraps.
 *
 * Time is in FRAMES. On a dense clip the ordinal is the time; on a sparse clip
 * region 0's key-time table converts, and two adjacent ordinals may be several
 * frames apart - which is why a large change between adjacent ordinals on a
 * sparse clip is correct rather than a decode fault.
 *
 * CAVEAT, stated because it is not measured: the format spec records THAT the
 * engine interpolates, not WHICH interpolation it uses for quaternions. This is
 * shortest-arc nlerp followed by renormalisation - correct to within the usual
 * nlerp/slerp difference, and not a reproduction of the engine's arithmetic. */
BF6_API int bf6_anim_clip_sample_time(bf6_ctx*, bf6_anim_clip*, float time,
                                      int loop, float* out);

/* ------------------------------------------------------- renderbones ----- */
/* THE PROCEDURAL BONES ABOVE THE RIG.
 *
 * A skin index with 0x8000 set does not name a rig bone. It names slot
 * ((raw & 0x7FFF) >> 1) of this array, and the composed skeleton the mesh
 * actually addresses is the SkeletonAsset's bones followed by these, in order:
 * entry k IS bone rigCount + k.
 *
 * `parent` is a bone of the COMPOSED skeleton - either a base-rig bone
 * (< rigCount) or an earlier entry (rigCount + j with j < k) - so one forward
 * pass composes them, exactly like the rig. Model pose for entry k is
 * local composed onto the parent's model pose.
 *
 * `source_pose` is the bind pose expressed in the SOURCE bone's frame, which is
 * what a bind-pose driver re-anchors when the source bone moves. It is not the
 * local pose and the two are not interchangeable.
 *
 * The mesh's own EBX names its Renderbones asset through SkinnedMeshAsset field
 * 0xA38BC860; the `<stem>_renderbonesdata` filename is a convention, not the
 * source, and meshes do import another outfit's asset outright. */
typedef struct {
    float   source_pose[12];  /* bind pose in the source bone's frame     */
    float   local[12];        /* local pose, relative to `parent`         */
    int32_t parent;           /* index into the COMPOSED skeleton         */
} bf6_renderbone;

typedef struct {
    const bf6_renderbone* bones;
    int32_t               bone_count;
} bf6_renderbones;

BF6_API bf6_renderbones* bf6_renderbones_read(bf6_ctx*, const char* ebx_name);

/* ------------------------------------------------- character deformation */
/* GPU DEFORM ADJACENCY: for each vertex, the FACES touching it.
 *
 * Not the neighbouring VERTICES. Reading the ids as vertices is the mistake
 * this decode was stuck on for two attempts: against a vertex count the ids
 * look out of range (they run to ~2x it, because a closed mesh has about twice
 * as many triangles as vertices) and vertex-vertex edge symmetry scores near
 * zero, so correct data looks broken.
 *
 * Faces for vertex v are faces[first[v] .. first[v+1]).  `first` has
 * vertex_count+1 entries.  Mean fan size is ~6, the textbook valence of a
 * closed triangulated 2-manifold, and a triangle is referenced by exactly three
 * vertices about 96% of the time (the rest are mesh boundary and UV seams). */
typedef struct {
    int32_t         vertex_count;
    const uint32_t* first;       /* vertex_count + 1 offsets into `faces`     */
    const uint16_t* faces;       /* incident face ids, grouped by vertex      */
    int32_t         face_count;  /* total ids, == first[vertex_count]         */
    const uint32_t* aux;         /* one per vertex, MEANING NOT DECODED       */
} bf6_deform_adjacency;

BF6_API bf6_deform_adjacency* bf6_deform_adjacency_read(bf6_ctx*, const char* res_name);

/* STRAND HAIR SCALP BINDING: each strand root rides a triangle of the head.
 *
 * Per LOD, per strand: the three corner indices of a scalp triangle and TWO
 * barycentric weights. The third weight is IMPLIED - w2 = 1 - w0 - w1. Reading
 * three from the buffer walks into the next strand.
 *
 * For lod L and strand s:
 *     tri [ lod_first_tri[L]  + s*3 .. +3 )
 *     bary[ lod_first_bary[L] + s*2 .. +2 )
 *
 * lod_count is 0 on a HIGHDEF bind asset, and that is an answer, not a failure:
 * the highdef tier fills a different slot and binds every hair vertex directly
 * instead of binding strand roots per LOD. */
typedef struct {
    int32_t        lod_count;
    const int32_t* lod_strands;     /* strands at each LOD                    */
    const int32_t* lod_first_tri;   /* start index into `tri`  for each LOD   */
    const int32_t* lod_first_bary;  /* start index into `bary` for each LOD   */
    const uint16_t* tri;            /* 3 scalp vertex ids per strand          */
    const float*   bary;            /* 2 weights per strand; w2 = 1 - w0 - w1 */
} bf6_hair_bind;

BF6_API bf6_hair_bind* bf6_hair_bind_read(bf6_ctx*, const char* res_name);

/* SWARM CROWDS: crowd spawn points and region transforms from an SP campaign
 * `*_area_swarm` partition. Field SHAPES are confirmed against the executable
 * typeinfo section (Vec3 size 16, LinearTransform size 64); the field NAMES are
 * hashed in retail and are not recoverable, so a consumer gets trustworthy
 * geometry and no labels. A multiplayer level yields zero of both - swarm
 * content is SP-only - which is an answer, not a parse failure. */
typedef struct {
    int32_t      point_count;
    const float* points;   /* 3 floats per spawn point, world space       */
    int32_t      xform_count;
    const float* xforms;   /* 12 floats per transform, 3x4 row-major      */
} bf6_swarm;

BF6_API bf6_swarm* bf6_swarm_read(bf6_ctx*, const char* ebx_name);

/* ALTERNATE SPAWN POINTS: authored spawn placements on a per-game-mode gameplay
 * layer (`_layers_gameplay/<mode>/...`). Field names come from the executable's
 * reflection table, so these are LABELLED, unlike the swarm reader's geometry.
 *
 * `team` IS ALWAYS 0 in shipped data - 529 instances over three levels, none
 * selecting a side. Do NOT sort spawns by it; that reading was tested and
 * failed. It is returned so a consumer can verify rather than trust.
 *
 * `transform` is 12 floats, 3x4 row-major, and is yaw-only: row1 == (0,1,0)
 * and row0.y == row2.y == 0 on 247/247 measured. Position and facing. */
typedef struct {
    float    transform[12];      /* 3x4 row-major; valid if has_transform     */
    uint32_t flags;              /* 0x5645E663; 0x06000000 on 242 of 247      */
    int32_t  team;               /* 0x2ADBF2A3 TeamId; 0 in ALL shipped data  */
    float    initial_spawn_delay;/* 0x3F680D24; 1, 8, 10 or 100 observed      */
    float    unnamed_060;        /* 0x54F22136; 0.1 on all 247                */
    float    unnamed_070;        /* 0x60D18AE7; 0.01 on all 247               */
    uint8_t  enabled;            /* 0xF97D7309; genuinely per-instance        */
    uint8_t  use_as_fallback;    /* 0x3A6F09AD; true on all 247               */
    uint8_t  draw_debug_pool;    /* 0x666021F3 DrawDebugTexturePool           */
    uint8_t  unnamed_077;        /* 0xCF690BA2; varies, meaning unknown       */
    uint8_t  has_transform;      /* 1 if transform[] was populated            */
} bf6_spawn_point;

typedef struct {
    int32_t                count;
    const bf6_spawn_point* points;
} bf6_spawns;

BF6_API bf6_spawns* bf6_spawns_read(bf6_ctx*, const char* ebx_name);

/* VECTOR SHAPES AND SPLINES: authored control-point geometry.
 * `VolumeVectorShapeData` and `CustomSplineData` share a 6-field head but are
 * used for disjoint things: a volume is a CLOSED, exactly PLANAR polygon
 * extruded by `height` (52 of 52 measured have a Y span of 0.000), while a
 * custom spline is an OPEN 3D path (8 of 9 non-planar) and is where non-zero
 * `tension` actually appears.
 *
 * TWO TRAPS. Closure is IMPLICIT - the first point is never repeated as the
 * last (0 of 61) - and winding is NOT normalised (32 CW vs 20 CCW in XZ), so
 * anything needing an orientation must compute the signed area. */
typedef struct {
    int32_t      point_count;
    const float* points;      /* 3 floats per control point, world space   */
    float        tension;     /* 0 on every volume; 0 or 0.5 on splines    */
    float        height;      /* extrusion, volumes only; 0 on splines     */
    uint32_t     flags;       /* 0x5645E663; 0x06000000 on all measured    */
    int32_t      realm;       /* 0xDFD68748; 0 on all measured             */
    uint8_t      is_closed;   /* true on all volumes, false on all splines */
    uint8_t      allow_roll;  /* false on all 61 measured                  */
    uint8_t      is_volume;   /* 1 = VolumeVectorShapeData, 0 = CustomSpline */
} bf6_vector_shape;

typedef struct {
    int32_t                 count;
    const bf6_vector_shape* shapes;
} bf6_vector_shapes;

BF6_API bf6_vector_shapes* bf6_vector_shapes_read(bf6_ctx*, const char* ebx_name);

/* FOOTPRINTS: battle-royale procedural PLACEMENT, not snow/sand deformation
 * (a separate system shares the word). A footprint is a reserved slot with a
 * category that the runtime fills from a weighted prefab database.
 *
 * One call serves both halves of the system: point a level partition at it for
 * PLACEMENTS, or a `*_footprint_size` asset for the CATEGORY vocabulary
 * (LootLocation_Chest_Rare, Vehicle_Heli_UH60, MissionObject_CTFDeposit, ...).
 *
 * Unlike spawn points these are NOT yaw-only - 18 of 26 measured are, the rest
 * carry pitch and roll and spread over 52 m of height, sitting on whatever
 * surface they are placed against. */
typedef struct {
    float    transform[12];      /* 3x4 row-major; valid if has_transform     */
    uint32_t flags;              /* 0x5645E663; per-instance, unlike spawns   */
    int32_t  suppression_type;   /* 0x032A545B; 0 in every sample             */
    uint8_t  is_next_to_wall;    /* 0x24ADFFBC                                */
    uint8_t  is_interior;        /* 0x6B4CCC16                                */
    uint8_t  draw_debug_pool;    /* 0x666021F3                                */
    uint8_t  has_prefab_override;/* 0x8D7A921F non-null; null in all samples  */
    uint8_t  has_category;       /* 0x18D8777E non-null                       */
    uint8_t  has_transform;
} bf6_footprint;

typedef struct {
    int32_t              count;
    const bf6_footprint* points;
    int32_t              category_count;  /* 79 in granite_footprint_size     */
    const char* const*   categories;      /* category DebugNames              */
} bf6_footprints;

BF6_API bf6_footprints* bf6_footprints_read(bf6_ctx*, const char* ebx_name);

/* The engine's name hash: djb2-XOR, basis 5381, CASE-SENSITIVE.
 *     h = 5381; for each byte: h = (h * 33) ^ byte;
 * Identified on 62 FootprintBiomeTheme DebugName/NameHash pairs (62 of 62),
 * held out on a second biome list (4 of 4) and on the telemetry member ids
 * (3 of 3). FNV-1, FNV-1a, additive djb2, sdbm and CRC32 each score 0.
 * A stored NameHash of 0 means "not baked" - hash the name instead. */
BF6_API uint32_t bf6_name_hash(const char* s);

/* AUTOPAINT: per-level authored paint content. Authored as ordinary
 * SpatialPrefabBlueprints under <level>/autopaint/{nature,pois,presets,shapes},
 * so anything that reads a spatial prefab reads autopaint.
 *
 * IDENTITY IS POSITIONAL. Leaves ship an EMPTY name - 27 of 27 capture presets
 * and 2 of 2 outputs across the granite tree - while the containers in the same
 * partitions ARE named. The *_named counters are returned so a caller can see
 * that for itself rather than take it on trust: expect outputs_named == 0 and
 * presets_named == 0 with groups_named and blueprints_named non-zero. Address a
 * slot BY INDEX within its named container; there is no name to match on. */
typedef struct {
    int32_t capture_presets;      /* AutopaintCapturePreset instances        */
    int32_t presets_named;        /* expected 0 - leaves are anonymous       */
    int32_t outputs;              /* AutopaintOutput instances               */
    int32_t outputs_named;        /* expected 0                              */
    int32_t outputs_groups;       /* AutopaintOutputs containers             */
    int32_t groups_named;         /* expected == outputs_groups              */
    int32_t outputs_in_last_group;/* array size; NOT fixed (2 and 3 seen)    */
    int32_t blueprints;           /* SpatialPrefabBlueprint roots            */
    int32_t blueprints_named;
    int32_t named_count;
    const char* const* named;     /* the names that DO ship                  */
} bf6_autopaint;

BF6_API bf6_autopaint* bf6_autopaint_read(bf6_ctx*, const char* ebx_name);

/* ECS SYSTEM ASSET: how a runtime-only system ships when nothing authored
 * backs it - `systems/ecssystems/<name>/ecssystemasset`. EcsWorldAnchorSystem
 * is the worked example: onArchetypeMatched, onArchetypeUnmatched and
 * onComponentDataChangeWorldAnchorTags, i.e. anchors are acquired through ECS
 * composition at runtime and are never placed by a level designer.
 *
 * `system_hash` and `schedule_hashes` are NOT djb2-XOR of any name tried
 * (11 candidates, 0 matches), so bf6_name_hash does NOT decode them. */
typedef struct {
    const char*     name;
    uint32_t        system_hash;      /* 0x258E57C4                          */
    int32_t         schedulables;
    const uint32_t* schedule_hashes;  /* 0x8A0D8E03, in step with imports    */
    int32_t         import_count;
    const char* const* imports;       /* 0xCC9ADA59 execution descriptors    */
} bf6_ecs_system;

BF6_API bf6_ecs_system* bf6_ecs_system_read(bf6_ctx*, const char* ebx_name);

/* DEBRIS. Overwhelmingly a MATERIAL PROPERTY, not placed content: 2 clusters
 * exist across all 28 shipped levels and StaticDebrisArea* has none, while
 * MaterialRelationDebrisData ships 11 per level on 27 of 28 inside
 * materialgrid_win32.
 *
 * `direction` IS NOT A VELOCITY despite the field being named LinearVelocity:
 * it is unit length on 5 of 5 parts measured, so it carries a direction only
 * and the speed comes from elsewhere. Multiply it by your own impulse.
 *
 * `material_relation_markers` is a COUNT and nothing more. Every
 * MaterialRelation*Data in the grid decodes to zero fields - 7,737 of 7,833
 * instances over 52 types - with the reflection table placing their fields at
 * offset 0xFFFF. The payload is not absent; this view does not decode it, and
 * MaterialGridData's InteractionGrid is where to look. */
typedef struct {
    int32_t part_index;
    float   direction[3];   /* UNIT length - a direction, not a speed */
    float   angular[3];     /* zero on every part measured            */
    float   delay;
    int32_t delay_mode;
} bf6_debris_part;

typedef struct {
    int32_t clusters;
    int32_t max_active_parts;          /* 50 on both shipped clusters   */
    float   height_limit;              /* 50 on both                    */
    int32_t part_count;
    const bf6_debris_part* parts;
    int32_t material_relation_markers; /* a COUNT; values are not decoded */
} bf6_debris;

BF6_API bf6_debris* bf6_debris_read(bf6_ctx*, const char* ebx_name);

/* WIND: authored MeshWind components and vector-field volumes.
 *
 * WHERE THESE LIVE is not obvious from the type names. MeshWindComponentData
 * ships 1,561 instances over 12 levels, ONE PER PARTITION, and those partitions
 * are `_layers_world/cables/cableset_<guid>` - the component belongs to a CABLE
 * SET, and its BonePositions array is EMPTY there, consistent with the separate
 * result that BonePositions is not a cable chain. VectorFieldEntityData ships
 * 20 instances over 7 levels and lives in BUILDING PREFABS, i.e. authored wind
 * volumes around architecture rather than level-wide weather.
 *
 * This is the authored INPUT side: the primary (mass, area) and secondary
 * spring constants the two-spring integrator consumes, and the mask selecting
 * which vector fields a component responds to. */
typedef struct {
    float    transform[12];      /* 3x4 row-major; valid if has_transform */
    float    mass;               /* 0x6E58E5B7 */
    float    area;               /* 0x31EBB6C2 */
    float    secondary_mass;     /* 0x0E9552FA */
    float    secondary_damping;  /* 0xDBF5C20E */
    float    secondary_area;     /* 0x21D9AF44 */
    uint32_t vector_field_mask;  /* 0x1021C09C - which fields this responds to */
    int32_t  client_index;
    int32_t  bone_count;         /* BonePositions length; 0 on cable sets */
    uint8_t  excluded;
    uint8_t  has_transform;
} bf6_wind_component;

typedef struct {
    float    transform[12];
    float    magnitude;          /* 0x79600A6A on VectorFieldData   */
    float    magnitude_scale;    /* 0x754DEF54 on the entity        */
    float    bottom_radius_pct;  /* 0xC5BFC01C                      */
    uint32_t tags;               /* 0x605F79AF                      */
    int32_t  name_index;         /* into bf6_wind.names, or -1      */
    uint8_t  is_entity;          /* 1 = VectorFieldEntityData, 0 = VectorFieldData */
    uint8_t  has_transform;
} bf6_vector_field;

typedef struct {
    int32_t                   component_count;
    const bf6_wind_component* components;
    int32_t                   field_count;
    const bf6_vector_field*   fields;
} bf6_wind;

BF6_API bf6_wind* bf6_wind_read(bf6_ctx*, const char* ebx_name);

/* WEATHER: the global weather-state variable database.
 *
 * There is NO authored storm type in this engine, and the WeatherSequencer
 * state machine ships ONE instance across 28 levels. What ships is
 * `globals/weather/weatherstatevariabledatabase`: 21 named variables that every
 * other system reads - Global_Rain, Global_Snow, Global_Fog, Global_Sand_amount,
 * Global_Storm_Active, Cont_HasLightningstrikes, Temperature, Vfx_*, Audio_Rain,
 * AI_Visibility_*, GlobalWindTransition. A storm is a VARIABLE, not an entity.
 *
 * Each carries a default and a fade window. `name_hash` is djb2-exact of the
 * name (bf6_name_hash), verified 21 of 21. */
typedef struct {
    int32_t  name_index;     /* into bf6_weather.names, or -1 */
    uint32_t name_hash;      /* djb2-exact of the name        */
    float    default_value;
    float    fade_low;       /* FadeLowThreshold  */
    float    fade_high;      /* FadeHighThreshold */
    uint8_t  kind;           /* 0 = float, 1 = bool, 2 = int */
} bf6_weather_var;

typedef struct {
    int32_t                count;
    const bf6_weather_var* vars;
    int32_t                name_count;
    const char* const*     names;
} bf6_weather;

BF6_API bf6_weather* bf6_weather_read(bf6_ctx*, const char* ebx_name);

/* WAVE SELECTION: how a sound picks its next variation.
 * The authored values split by ROLE, 9 of 9 measured: impact FX markers are
 * Random with history 3 and randomise TRUE; area ambiences are Rank with
 * history 100 and randomise FALSE. Only mp_contaminated ships this family
 * (12 instances on 1 of 28 levels), so the rule is observed, not universal. */
typedef struct {
    int32_t  behavior;              /* 0 = Random, 1 = Rank, -1 = none found */
    uint32_t history_entry_count;   /* 3 on FX, 100 on ambiences            */
    int32_t  scoring_mode;          /* 0 on every instance measured         */
    uint8_t  randomize_candidates;
} bf6_wave_selector;

typedef struct {
    int32_t                  count;
    const bf6_wave_selector* selectors;
} bf6_wave_selection;

BF6_API bf6_wave_selection* bf6_wave_selection_read(bf6_ctx*, const char* ebx_name);

/* GAMEPLAY LOGIC: behaviour trees, the network registry, unlock manifests.
 *
 * BEHAVIOUR TREES are authored data and they LABEL THEMSELVES. Every node in
 * `behaviortree_soldier` carries an authored `Title` ("BEHAVIOR SELECTOR",
 * "CheckTacticalObjective - Attack"), so a tree stays readable even though 10
 * of its 25 instance types are unnamed in the SDK table. Composition is by
 * BTTreeLink, whose `Tree` field imports another partition - 36 on the soldier
 * root, which is that bot's entire behaviour repertoire. */
typedef enum {
    BF6_BT_OTHER = 0, BF6_BT_ROOT, BF6_BT_SELECTOR, BF6_BT_SEQUENCE,
    BF6_BT_RUNNING, BF6_BT_FAIL, BF6_BT_SUCCEEDED, BF6_BT_TREELINK
} bf6_bt_kind;

typedef struct {
    int32_t index;            /* instance index inside the partition       */
    int32_t kind;             /* bf6_bt_kind                               */
    int32_t node_type;        /* BTTreeLink.NodeType, 0 otherwise          */
    uint8_t visual_enabled;
    char    title[128];       /* authored label; may be empty              */
    char    subtree[256];     /* BTTreeLink.Tree import, else empty        */
} bf6_bt_node;

typedef struct {
    int32_t            count;          /* nodes returned (excludes the asset) */
    int32_t            declared_nodes; /* BehaviorTreeData.Nodes array length */
    int32_t            root_index;     /* BehaviorTreeData.Root, -1 if absent */
    const bf6_bt_node* nodes;
} bf6_behavior_tree;

BF6_API bf6_behavior_tree* bf6_behavior_tree_read(bf6_ctx*, const char* ebx_name);

/* NETWORK REGISTRY: one per LAYER partition, 1,092 over 27 levels.
 * ORDER IS IDENTITY - the Objects array carries repeated imports, so the slot
 * index is the network id. A consumer must not deduplicate or sort it. */
typedef struct {
    int32_t slot;
    char    object[256];
} bf6_net_object;

typedef struct {
    char                  name[256];  /* the asset's own path, self-describing */
    uint32_t              checksum;   /* 0x258E57C4, shared with unlocks       */
    int32_t               count;
    const bf6_net_object* objects;
} bf6_net_registry;

BF6_API bf6_net_registry* bf6_net_registry_read(bf6_ctx*, const char* ebx_name);

/* UNLOCK MANIFEST: UnlockLevelData sits in the LEVEL ROOT partition, exactly
 * one per level on 27, and points at a <level>_unlocks_win32 partition holding
 * about 20,800 imports. Sizes DIFFER per level, so these are per-level
 * manifests and not one global list replicated 27 times. */
typedef struct { char asset[256]; } bf6_unlock;

typedef struct {
    char              manifest[256];  /* the resolved manifest partition */
    uint32_t          root_checksum;  /* UnlockLevelData.Checksum        */
    int32_t           count;
    const bf6_unlock* items;
} bf6_unlock_manifest;

/* Takes the LEVEL ROOT partition, e.g.
 * "game/glaciermp/levels/mp_dumbo/mp_dumbo", and follows the reference. */
BF6_API bf6_unlock_manifest* bf6_unlocks_read(bf6_ctx*, const char* level_root_ebx);

/* GEM MODULES. A gem is a parameterised gameplay MODULE - capture point, MCOM,
 * payload, HQ - that a game mode is assembled from, not an entity. It carries
 * a typed interface (mi_*) and its _view twin, plus FieldHashes: the binding
 * between SCHEMATIC GRAPH PINS and that interface. On gem_capturepoint 42 of
 * 44 pin_hash values are in the engine pin universe and 0 of 44
 * field_info_hash values are, so the two are distinct hash namespaces. */
typedef struct {
    uint32_t pin_hash;         /* a schematic graph pin  */
    uint32_t field_info_hash;  /* an interface field     */
} bf6_gem_bind;

typedef struct {
    char                interface_ebx[256];  /* the mi_* module interface  */
    char                view_ebx[256];       /* its mi_*_view twin         */
    uint32_t            number;              /* u32 field, identity unknown */
    int32_t             count;
    const bf6_gem_bind* binds;
} bf6_gem;

BF6_API bf6_gem* bf6_gem_read(bf6_ctx*, const char* ebx_name);

/* SCHEMATICS - the entity graph. A blueprint root carries Objects[] plus three
 * connection arrays, and the three edge kinds are NOT interchangeable:
 *   PROPERTY - data flow, names a pin on BOTH ends
 *   EVENT    - control flow, carries NO field ids
 *   LINK     - object reference, node level, no pins
 * Pin hash 0 means "no pin"; do not mint a slot for it. 0xFFFFFFFF is a
 * second no-pin sentinel. */
typedef enum { BF6_SCHEM_PROPERTY = 0, BF6_SCHEM_EVENT, BF6_SCHEM_LINK } bf6_schem_kind;

typedef struct {
    int32_t  kind;         /* bf6_schem_kind                    */
    int32_t  source;       /* source instance index, -1 if none */
    int32_t  target;       /* target instance index, -1 if none */
    uint32_t source_pin;   /* SourceFieldId, 0 = no pin         */
    uint32_t target_pin;   /* TargetFieldId, 0 = no pin         */
} bf6_schem_edge;

typedef struct {
    int32_t root_index;
    int32_t instances;      /* instances in the partition      */
    int32_t objects;        /* Objects[] length on the root    */
    int32_t property_edges;
    int32_t event_edges;
    int32_t link_edges;
    int32_t count;          /* edges returned = the three sums */
    const bf6_schem_edge* edges;
} bf6_schematic;

BF6_API bf6_schematic* bf6_schematic_read(bf6_ctx*, const char* ebx_name);

/* PHYSICS / COLLISION - PhysicsResource (RES type 0x41759364), 669,966 in the
 * game, the second largest resource type. Spec: formats/PHYSICS_COLLISION.md.
 *
 * Offsets inside the payload are SELF-RELATIVE (fieldAddress + storedValue).
 * The container is self-checking: five monotonic bounds and four exact
 * span == count * stride equations, all enforced by the reader. */
typedef struct {
    float    quat[4];            /* WORLD orientation of the inertia PRINCIPAL AXES */
    float    inv_inertia[3];     /* INVERSE principal inertia, unit mass            */
    float    center_of_mass[3];  /* WORLD space, not a local offset                 */
    float    reciprocal_mass;    /* 1.0 = static placeholder, 0 = infinite mass     */
    uint32_t motion_type;        /* 1 Fixed, 2 Keyframed, 3 Dynamic (0/4 no-ops)    */
    uint32_t group_index;        /* body group/layer - u32, NOT a float             */
    float    static_friction;    /* -1 = take the world default                     */
    float    dynamic_friction;   /* -1 = world default                              */
    float    restitution;        /* -1 = world default                              */
    float    linear_drag;        /* f32, NOT a u32                                  */
    float    angular_drag;       /* f32, NOT a u32                                  */
    uint8_t  keyframed_contacts, autosleep, start_asleep;
} bf6_phys_body;

typedef struct {
    uint16_t vertex_count;
    uint16_t index_count;      /* total face-vertex indices, NOT triangles */
    uint16_t face_count;       /* LOW u16 of +0x1C; the high half is below  */
    uint16_t midphase_nodes;   /* nonzero on meshes, zero on hulls          */
    uint8_t  plane_ptr;        /* +0x40 present: this shape is a HULL       */
    uint8_t  mesh_ptr;         /* +0x44 present: this shape is a MESH       */
    int32_t  vertex_first;     /* index into bf6_physics.vertices (xyz), -1 */
    int32_t  index_first;      /* index into bf6_physics.indices, -1        */
    int32_t  face_start_first; /* index into bf6_physics.face_starts, -1    */
} bf6_phys_shape;

typedef struct {
    float    quat[4];             /* x, y, z, w                             */
    float    pos[3];
    float    scale_or_halfheight; /* UNION: uniform scale, or capsule half-H */
    float    radius;              /* primitive radius; 0 on hull/mesh        */
    uint32_t shape_type;          /* 0 Sphere 1 Capsule 2 Box 3 ConvexHull
                                     4 Cylinder 5 Heightfield 6 Mesh 7 Aggregate */
    uint32_t preset_a, preset_b, preset_c;  /* djb2 PhysicsShapePreset_* hashes */
    uint32_t object_id;           /* owning-object handle; shared by siblings */
    int32_t  shape_index;         /* +0x38 into region B, -1 (0xFFFFFFFF) none */
    uint32_t body_index;          /* 0x7FFFFFFF = the world static body       */
    uint32_t material_packed;     /* surface material, NOT a collision mask   */
    uint32_t trap_0x24;           /* exposed ONLY so a test can prove it is
                                     not the shape index - see the .inc       */
} bf6_phys_inst;

typedef struct {
    uint32_t flags;
    int32_t  body_count;      /* region A, from the header       */
    int32_t  body_rec_count;  /* region A records actually read  */
    const bf6_phys_body* bodies;
    int32_t  region_c;        /* region C */
    int32_t  shape_count;
    int32_t  inst_count;
    int64_t  geometry_at;
    int64_t  payload_size;
    const bf6_phys_shape* shapes;
    const bf6_phys_inst*  instances;
    int32_t  vertex_total;    const float*    vertices;    /* xyz triples */
    int32_t  index_total;     const uint16_t* indices;
    int32_t  face_start_total; const uint16_t* face_starts;
} bf6_physics;

BF6_API bf6_physics* bf6_physics_read(bf6_ctx*, const char* res_name);

/* OCCLUDER MESH - hand-authored low-poly occlusion geometry (RES 0x30B4A553,
 * 4,002 resources). Spec: findings/occluder-entities-decoded.md. Draw calls are
 * the measured root of the rebuild frame cost and this is what the artists used
 * to cut them.
 *
 * The header stores vertexOffset/indexOffset AND they are derivable from the
 * two u16 counts, so the reader PREDICTS both and reports whether the
 * prediction held - a layout error breaks it on every file instead of yielding
 * plausible geometry. */
typedef struct {
    float    aabb_a[3];
    float    aabb_b[3];
    uint32_t vertex_count;
    uint32_t index_count;          /* always a multiple of 3 */
    uint32_t scratch_at;           /* always 64 on shipped files */
    uint32_t flag;
    uint32_t stored_vertex_offset,  predicted_vertex_offset;
    uint32_t stored_index_offset,   predicted_index_offset;
    uint8_t  offsets_predicted;    /* 1 when both predictions matched */
    const float*    vertices;      /* xyz triples; the stored w (1.0) is dropped */
    const uint16_t* indices;
} bf6_occluder_mesh;

BF6_API bf6_occluder_mesh* bf6_occluder_mesh_read(bf6_ctx*, const char* res_name);

/* TYPE CENSUS - count instances of a reflected type across a level, read from
 * the installed game. Exists so that "this system authors nothing" is a
 * MEASUREMENT the caller can re-run, not a note in a document.
 *
 * Counts through each partition's own type table, never by searching raw bytes
 * for the GUID: a raw search hits the type TABLE of any partition that merely
 * references the type, which is a candidate finder rather than a census.
 *
 * A zero is only meaningful beside a non-zero. Run a control type known to
 * ship, and check `partitions_parsed` - zero instances over zero partitions
 * means the mount failed, not that the data is absent. */
typedef struct {
    int32_t partitions_matched;   /* names containing the level substring   */
    int32_t partitions_parsed;    /* of those, successfully parsed          */
    int32_t partitions_with;      /* partitions carrying >= 1 instance      */
    int32_t instances;            /* total instances of the type            */
    char    last_partition[256];  /* first partition seen carrying it       */
} bf6_type_census_result;

/* `type_guid_hex` may be dashed or bare; BOTH byte orders are matched. */
BF6_API bf6_type_census_result bf6_type_census(bf6_ctx*, const char* level,
                                               const char* type_guid_hex);

/* PARTICIPATING MEDIA - the authored half of volumetric fog. 2,886 volumes over
 * 25 levels plus 40 graphs. Parameters use the EXPOSED-PARAMETER record shape
 * shared with FX emitters (PropertyId / Vec4 value / IntValue / ExposableType /
 * Normalize); the id VOCABULARY is not shown to be shared. */
typedef struct {
    int32_t  volume_index;
    uint32_t property_id;      /* a hash - never read through a float */
    uint32_t int_value;
    uint32_t exposable_type;
    uint8_t  normalize;
    int32_t  value_components; /* how many of value[] were present    */
    float    value[4];
} bf6_pm_param;

typedef struct {
    int32_t volume_count;
    int32_t graph_count;
    int32_t graph_param_count;
    uint32_t object_layers;
    int32_t param_count;
    const bf6_pm_param* params;
} bf6_pm_volumes;

BF6_API bf6_pm_volumes* bf6_pm_volumes_read(bf6_ctx*, const char* ebx_name);

/* LIGHT PROBE VOLUMES - authored diffuse-GI blend regions. 12,983 over 25
 * levels. A volume is a falloff box: one BlendDistance with a per-axis min/max
 * override on each of X/Y/Z, a Weight, and a DistanceOffsetAlongNormal. The
 * reflection volume types alongside these are COUNTED but not decoded - their
 * 35 fields resolve to no names. */
typedef struct {
    int32_t  instance;
    float    blend_distance;
    float    blend_min[3];   /* BlendDistanceOverrideMin X, Y, Z */
    float    blend_max[3];   /* BlendDistanceOverrideMax X, Y, Z */
    float    distance_offset_along_normal;
    float    weight;
    uint32_t unnamed_int;    /* 0x3F680D24, unnamed; 20 where sampled */
} bf6_light_probe;

typedef struct {
    int32_t count;
    const bf6_light_probe* volumes;
} bf6_light_probes;

BF6_API bf6_light_probes* bf6_light_probes_read(bf6_ctx*, const char* ebx_name);

/* TELEMETRY SCORING ENUMS: the metrics a game mode reports.
 * `<mode>_scoringtelemetryenum` members name them - Conquest ships
 * current_tickets, kill_tickets, majority_bleed.
 *
 * `id` is the file's own 32-bit value and is NOT an FNV hash of the name:
 * FNV-1 and FNV-1a with the engine's 0x811c9dc5 seed both scored 0 of 3, so it
 * is passed through raw rather than reinterpreted.
 *
 * Members arrive in FILE order, which is not enum order - Conquest's are 1,0,2.
 * Sort by `value` if you need the declared sequence. */
typedef struct {
    int32_t     value;     /* enum value                                     */
    int32_t     ordinal;   /* the separate ordinal field; equals value so far */
    uint32_t    id;        /* 32-bit id, provenance unknown                  */
    const char* name;      /* e.g. "current_tickets"                         */
} bf6_telemetry_member;

typedef struct {
    int32_t                     count;
    const bf6_telemetry_member* members;
    const char*                 name;   /* the enum asset's own path         */
} bf6_telemetry_enum;

BF6_API bf6_telemetry_enum* bf6_telemetry_enum_read(bf6_ctx*, const char* ebx_name);

/* POSE-SPACE DEFORMATION: which facial poses displace which vertices, and by
 * how much. This is what makes an expression, on top of the skinned pose.
 *
 * The storage is SPARSE - only vertices a pose actually moves are stored - so
 * this is a flat list of (vertex, pose, delta) rather than an N x V array. A
 * dense array would be larger than the whole file.
 *
 * `scale` is the payload's own quantisation scale (0.01 on every sampled file):
 * one 10-bit signed lane spans +/- that, so a delta magnitude cannot exceed
 * scale*sqrt(3), about 17.3 mm. Measured mean is around 10 mm on a face mesh
 * roughly 0.2 m across - millimetre-scale correctives, as a face rig should be.
 *
 * `pose_index` indexes the pose-descriptor table, whose names come from the
 * paired EBX (for example NN_Squash_100, NN_Taco_050). */
typedef struct {
    int32_t vertex_index;   /* into the LOD's vertex array, < vertex_count */
    int32_t pose_index;     /* < pose_count                                */
    float   delta[3];       /* metres, already dequantised                 */
} bf6_psd_delta;

typedef struct {
    int32_t vertex_count;            /* V for this LOD                     */
    int32_t pose_count;              /* N                                  */
    float   scale;                   /* per-axis quantisation range        */
    int32_t affected_vertex_count;   /* vertices any pose displaces        */
    /* the header's own deformedVertexCount at +0x10. Should equal the
     * above; if it does not, the index table was mis-walked. */
    int32_t declared_deformed_count;
    const bf6_psd_delta* deltas;
    int32_t delta_count;
} bf6_psd;

BF6_API bf6_psd* bf6_psd_read(bf6_ctx*, const char* res_name);

/* THE PSD VERTEX MAP - source render vertex to welded PSD vertex.
 *
 * This is what connects a mesh to its facial deformation: `bf6_psd` is keyed by
 * PSD vertex and a renderer has RENDER vertices, so applying an expression means
 *
 *     pv = psd_vertex_id[renderVertex];
 *     if (pv != 0xFFFFFFFF) apply every bf6_psd_delta whose vertex_index == pv
 *
 * The map is MANY-TO-ONE by design - render vertices split at UV and normal
 * seams and several copies collapse onto one deformation vertex - so duplicate
 * ids are correct, not a bad read. 0xFFFFFFFF means this render vertex is not
 * deformed by any pose and MUST be skipped; it is roughly 7% of elements across
 * the shipped population, so treating it as an index is not a rare edge case. */
typedef struct {
    int32_t         element_count;      /* source render vertices in this LOD  */
    int32_t         mesh_vertex_offset; /* cumulative source offset of the LOD */
    const uint32_t* psd_vertex_id;      /* 0xFFFFFFFF = not deformed           */
    int32_t         mapped_count;       /* entries that are not 0xFFFFFFFF     */
    int32_t         max_psd_vertex;     /* highest mapped id; must be < the
                                         * paired bf6_psd's vertex_count       */
} bf6_psd_map;

BF6_API bf6_psd_map* bf6_psd_map_read(bf6_ctx*, const char* res_name);

/* --------------------------------------------------------------- skeleton */
/* THE CHARACTER RIG.
 *
 * A skinned mesh hands back bone indices and weights; they mean nothing without
 * this. Read the rig the mesh binds to - for every shipped soldier part that is
 * `common/characters/_soldier/ske_soldier_3p` (291 bones), or `_1p` (203).
 *
 * The three transforms are each 3x4 ROW-MAJOR: rows 0..2 are the right, up and
 * forward columns, row 3 is the translation. Applying one is
 * v' = right*v.x + up*v.y + forward*v.z + trans.
 *
 * They are related, and the relations are what tell you which is which:
 *     model[i]   == local[i] composed onto model[parent[i]]
 *     inverse[i] composed onto model[i] == identity
 * Both hold on 291 of 291 bones of the 3P rig and 203 of 203 of the 1P rig.
 *
 * `inverse` is NOT the transpose of `model` - these transforms carry scale, so
 * transposing gives a rig that looks almost right and drifts on scaled bones.
 *
 * TO SKIN A VERTEX: for each of the section's `skin_influences` lanes, take
 * bone b = skin_bones[...] (resolve through the section's palette first), and
 * accumulate skin_weights[...] * (pose[b] * inverse[b] * v), where `pose` is
 * your animated model-space transform for that bone. At bind time pose == model
 * and the inverse cancels it, which is the cheapest way to check a rig is
 * wired correctly: the mesh must come back unchanged.
 *
 * Bones are TOPOLOGICALLY ORDERED - a parent's index is always lower than its
 * child's - so one forward pass composes the whole rig with no recursion. */
typedef struct {
    const char* name;        /* bone name, e.g. "LeftForeArm"                  */
    uint32_t    name_hash;   /* FNV-1 32-bit of the name, CASE SENSITIVE       */
    int32_t     parent;      /* parent bone index, -1 on the single root       */
    float       local[12];   /* bind pose relative to the parent               */
    float       model[12];   /* bind pose in model space                       */
    float       inverse[12]; /* inverse of model: model space -> bone space    */
} bf6_bone;

typedef struct {
    const bf6_bone* bones;
    int32_t         bone_count;
    const char*     name;    /* the rig's own authored path, or NULL           */
    /* Bones [0, rig_bone_count) come from the SkeletonAsset; anything at or
     * above it is an appended renderbone. Equals bone_count on a plain rig. */
    int32_t         rig_bone_count;
} bf6_skeleton;

/* Read a rig by EBX name. NULL if the name is not in the mount or the instance
 * is not a skeleton. Free with bf6_free().
 *
 * NOT EVERY ASSET NAMED *skeleton IS THIS TYPE. The animation side ships a
 * second, topology-only skeleton (parent / first-child / next-sibling, names,
 * NO transforms) and the two are not distinguishable by filename -
 * propcommonskeleton is this type while weaponskeleton is the other. This
 * returns NULL on the other type rather than a rig with an empty pose. */
BF6_API bf6_skeleton* bf6_skeleton_read(bf6_ctx*, const char* ebx_name);

/* THE SKELETON A SKINNED CHARACTER MESH ACTUALLY INDEXES: a rig with the mesh's
 * renderbones appended, so entry k of the renderbones array is bone
 * rigCount + k, with model and inverse bind poses already composed.
 *
 * Use this rather than composing by hand. Three things fail quietly otherwise:
 * a flagged skin index resolves to rigCount + slot and not to the shifted slot
 * alone; a renderbone's model pose is its local pose composed onto its parent's
 * MODEL pose, and that parent may be another renderbone; and the inverse must
 * be a general affine inverse, because these transforms carry scale and the
 * transpose shortcut drifts on exactly the bones where it is hardest to see.
 *
 * `renderbones_ebx` may be NULL, which just returns the plain rig. Free with
 * bf6_free(). Verified: skinning at bind pose against a composed skeleton
 * reproduces the mesh exactly on 360,619 vertices over four characters and nine
 * meshes, with zero vertices left unplaceable. */
BF6_API bf6_skeleton* bf6_skeleton_compose(bf6_ctx*, const char* skeleton_ebx,
                                           const char* renderbones_ebx);

/* Resolve a per-vertex skin index (bf6_section.skin_bones) against a composed
 * skeleton, handling the 0x8000 renderbone flag. Returns -1 if out of range. */
BF6_API int32_t bf6_skin_index_to_bone(const bf6_skeleton*, uint16_t raw);

/* ------------------------------------------------------------------- bones */
/* One bone's skinning matrix, 3x4 row-major: right, up, forward, trans -
 * the same convention a placement transform uses. */
typedef struct { float m[12]; } bf6_bone_xform;

/* The weapon's skinning palette.
 *
 * A WEAPON MESH IS SKINNED, AND IGNORING THAT IS VISIBLE. The bolt, the
 * ejection cover, the charging handle and a mounted optic are all placed by
 * this palette - there is no separate mount path. A Wep_Bolt1 part reproduces
 * the game's own bounding box 96.4% of the time when skinned and 0.0% as
 * authored, median error 89.8 mm, which is what "the part is floating off the
 * receiver" looks like.
 *
 * Apply it per vertex:
 *     v_render = skin[ section.bones[v] ] * v_authored
 * The bone palette is the 66-entry identity list on 1,944 of 1,948 weapon
 * meshes, so the vertex index IS the bone id in practice; the four exceptions
 * are cloth sims.
 *
 * md_partition is the weapon's model definition (its parent-local bone
 * overrides). Pass NULL for the bare shared bind pose. Returns the bone count
 * and fills up to out_max, or -1 if the skeleton cannot be read. */
BF6_API int bf6_weapon_skin(bf6_ctx*, const char* md_partition,
                            bf6_bone_xform* out, int out_max);

/* Model-space transform of one named weapon bone after the model-definition's
 * parent-local pose overrides have been applied and composed. This is a pose
 * transform, not a skinning matrix. Returns 1 for an exact case-sensitive
 * bone-name match and 0 for a fabricated/absent name. */
BF6_API int bf6_weapon_bone_transform(bf6_ctx*, const char* md_partition,
                                      const char* bone_name,
                                      bf6_bone_xform* out);

/* The shader bundle that owns a weapon part's material, or 0 if none matches.
 *
 * Pass the result to bf6_read_mesh_scoped. A part's material lives in
 * dpf_<weapon>_<part>_<hash>_bundle_1p, NOT in the bundle its mesh shipped in,
 * and resolving against the latter binds nothing - which renders black. */
BF6_API int bf6_part_bundle(bf6_ctx*, const char* weapon, const char* part,
                            char* out, int out_len);

/* A texture id for a standalone texture RESOURCE, or -1 if not in the mount.
 *
 * bf6_texture_at only takes ids from material bindings, which cannot reach UI
 * art: an icon atlas page is bound by nothing. Register it here, then read it
 * with bf6_texture_at as usual - same cache, same decode-once rule. */
BF6_API int bf6_texture_id_by_name(bf6_ctx*, const char* res_name);

/* One sprite in a layered icon atlas - a weapon card layer, or an attachment's
 * outline icon. Card and icon are the same data. */
typedef struct {
    const char* name;        /* the sprite's source path; owned by the ctx    */
    uint32_t    name_hash;   /* joins to a card layer's sprite_hash          */
    int32_t     page;        /* -> <atlas>_atlas<page>                        */
    float       uv[4];       /* u0, v0, u1, v1 within the page                */
    float       size[2];     /* pixel size                                    */
    float       offset[2];   /* slot in the packed sheet (not card placement) */
    float       placement[2];/* authored base placement on the 512x256 canvas */
    float       canvas[2];   /* the canvas it is placed on, {512, 256}        */
} bf6_icon_sprite;

/* Every sprite in one layered icon atlas partition, e.g.
 * common/ui/assets/images/hardware/generated/layerediconsatlases/<w>_layerediconatlas
 * Returns the total and fills up to out_max. Sprites are 2-channel: line art
 * in R, fill in G - alpha is NOT coverage and sampling it gives a solid box. */
BF6_API int bf6_icon_atlas(bf6_ctx*, const char* partition,
                           bf6_icon_sprite* out, int out_max);

/* Where one sprite goes ON THE CARD.
 *
 * NOT the same as the sprite's Offset in the atlas - that is its slot in the
 * packed sheet, and composing with it stacks every layer in a column. Card
 * placement is authored in hiao_<weapon>.ebx and can be fractional/negative. */
typedef struct {
    uint32_t sprite_hash;   /* joins to bf6_icon_sprite.name_hash */
    float    offset[2];
} bf6_card_layer;

BF6_API int bf6_card_layers(bf6_ctx*, const char* hiao_partition,
                            bf6_card_layer* out, int out_max);

/* One drawable part of a weapon: its mesh, and the bundle that owns it.
 *
 * The bundle is not a convenience - it is the MATERIAL SCOPE. Pass it to
 * bf6_read_mesh_scoped, or the part resolves against the bundle its mesh
 * shipped in, binds nothing, and renders black. */
typedef struct {
    const char* mesh;     /* resource name for bf6_read_mesh                */
    const char* bundle;   /* placing bundle for bf6_read_mesh_scoped        */
    /* Runtime-authored record Binding[0] translation plus the slot-group
     * socket translation. Add after skinning. Zero when the part has no
     * gameplay-bone binding (receiver, most magazines, charms). */
    float       attach_offset[3];
    int32_t     has_attach_offset;
} bf6_weapon_part;

typedef struct {
    const char* slot;       /* shipped UI slot code: scp, rgt, btm...        */
    const char* attachment; /* token from attachment_<weapon>_<slot>_<token> */
} bf6_weapon_fit;

/* The game's stock/factory configuration, read from equipment_<weapon>.ebx.
 *
 * MeshSlot.Default is a UI preselection and is NOT the stock weapon.  The
 * actual presentation is the set of equipment grants whose grantor import is
 * u_<weapon>_pkg_factory.  Strings are context-owned and remain valid until
 * the next call to this function on the same context. */
BF6_API int bf6_weapon_factory_fits(bf6_ctx*, const char* equipment_partition,
                                    bf6_weapon_fit* out, int out_max);

/* Every part mesh a weapon's model definition can draw, with its bundle.
 *
 * A DefinitionMesh does not name its mesh; it names a blueprint BUNDLE, and
 * the bundle names the mesh. One bundle can list 1-3 meshes, which is where an
 * optic's lens and a receiver's charm holder come from - draw them all. */
BF6_API int bf6_weapon_parts(bf6_ctx*, const char* md_partition,
                             bf6_weapon_part* out, int out_max);

/* The model-definition default presentation, one authored MeshSlot.Default member per
 * slot.  Unlike bf6_weapon_parts (the complete mutually-exclusive graph), this
 * is directly drawable as one weapon.  Mesh and bundle strings are context
 * owned and valid until the next weapon-parts call on that context. */
BF6_API int bf6_weapon_default_parts(bf6_ctx*, const char* md_partition,
                                     bf6_weapon_part* out, int out_max);

/* A zero-optional-attachment presentation with fitted slots selected from the
 * live model-definition graph. Structural defaults (base, barrel, magazine,
 * iron sights and rail covers) remain. The token join is bounded to the selected slot's
 * own groups and requires an exact normalized substring; an unknown/fake
 * token therefore leaves the authored default unchanged instead of choosing
 * a plausible wrong part. */
BF6_API int bf6_weapon_configured_parts(bf6_ctx*, const char* md_partition,
                                        const bf6_weapon_fit* fits, int fit_count,
                                        bf6_weapon_part* out, int out_max);

/* ---------------------------------------------------------- ground scatter */
/* One record from the level's MeshScatteringDatabase RES (0x2AB067B5).
 * This is the exact shipped CATALOGUE: which mesh, its visibility horizon and
 * dissolve ratio. The retail resource does not contain per-instance world
 * positions; consumers must label any generated placement as reconstruction. */
typedef struct {
    const char* name;              /* authored blueprint path                  */
    const char* mesh_res;          /* resolved MeshSet RES, context-owned      */
    float       view_distance;     /* metres                                   */
    float       dissolve_ratio;    /* fade fraction of the view distance       */
    int32_t     point_count;       /* opaque authored points; not placements   */
} bf6_scatter_entry;

/* Returns the exact record count, 0 when the level carries no database, or -1
 * on a malformed resource. A variable-length parse is accepted only when it
 * consumes the payload exactly. Strings remain valid until the next call. */
BF6_API int bf6_level_scatter(bf6_ctx*, const char* level,
                              bf6_scatter_entry* out, int out_max,
                              char* err, int err_len);

/* -------------------------------------------------------------------- memory */
/* Free anything this API returned (bf6_mesh*, bf6_terrain*, ...). The bf6_ctx*
 * itself is freed by bf6_close(), not this. */
BF6_API void bf6_free(bf6_ctx*, void* handle);

#ifdef __cplusplus
}
#endif
#endif /* BF6_CORE_H */
