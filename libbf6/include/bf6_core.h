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

#ifdef __cplusplus
extern "C" {
#endif

#define BF6_ABI_VERSION 1

/* ------------------------------------------------------------------ session */
typedef struct bf6_ctx bf6_ctx;

/* Open an install: mount, read the type schema, and OOA-lift the executable in
 * memory if it is DRM-wrapped (EA App). All storefront divergence lives behind
 * this one call. Returns NULL on failure and writes a reason into err. */
bf6_ctx* bf6_open(const char* game_dir, char* err, int err_len);
void     bf6_close(bf6_ctx*);

/* True if the type schema had to be decrypted (EA install). For diagnostics. */
int      bf6_was_lifted(bf6_ctx*);

/* --------------------------------------------------------------- enumerate */
int         bf6_level_count(bf6_ctx*);
const char* bf6_level_name(bf6_ctx*, int index);      /* e.g. "MP_Badlands" */

typedef struct {
    const char* res_name;      /* the asset id, e.g. common/.../foo_mesh   */
    const char* category;      /* grouping for a browser, may be ""        */
} bf6_cat_entry;

/* Fill out[] with up to out_max catalogue entries matching `search` (NULL or ""
 * = everything). Returns the number written. */
int bf6_catalogue(bf6_ctx*, const char* search,
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
} bf6_section;

typedef struct bf6_material_desc bf6_material_desc;   /* below */

typedef struct {
    const bf6_section*       sections;
    int32_t                  section_count;
    const bf6_material_desc*  materials;
    int32_t                  material_count;
    float                    aabb_min[3];
    float                    aabb_max[3];
} bf6_mesh;

/* Build one asset's geometry. lod 0 = full detail. NULL if unreadable. */
bf6_mesh* bf6_read_mesh(bf6_ctx*, const char* res_name, int lod);

/* ---------------------------------------------------------------- material */
typedef enum {
    BF6_TEX_ALBEDO = 0,
    BF6_TEX_NORMAL,
    BF6_TEX_MRO,          /* metallic / roughness / occlusion, packed       */
    BF6_TEX_EMISSIVE,
    BF6_TEX_MASK,
    BF6_TEX_SLOT_COUNT
} bf6_tex_slot;

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
    int32_t                alpha_test;  /* 0/1 */
};

/* ---------------------------------------------------------------- textures */
typedef enum {
    BF6_FMT_RGBA8 = 0,
    BF6_FMT_BC1,   BF6_FMT_BC3,   BF6_FMT_BC4,
    BF6_FMT_BC5,   BF6_FMT_BC7
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
const bf6_texture* bf6_texture_at(bf6_ctx*, int texture_id);

/* --------------------------------------------------------------- placements */
typedef struct {
    const char* res_name;      /* the mesh to instance                       */
    float       xform[12];     /* 3x4 row-major: basis columns then origin,  */
                               /* in the GAME's space - the binding converts */
    int32_t     material_scope;/* pre-resolved variation key, for caching    */
} bf6_instance;

/* Every placement in a level. Returns the count; if it exceeds out_max, out[]
 * is filled to out_max and the return value tells you to call again bigger. */
int bf6_level_instances(bf6_ctx*, const char* level,
                        bf6_instance* out, int out_max);

/* ------------------------------------------------------------------- lights */
typedef enum { BF6_LIGHT_POINT = 0, BF6_LIGHT_SPOT, BF6_LIGHT_LINE } bf6_light_type;

typedef struct {
    bf6_light_type type;
    float          xform[12];
    float          color[3];
    float          intensity;
    float          range;
    float          spot_inner;   /* radians, 0 for non-spot */
    float          spot_outer;
    const char*    ies_profile;  /* goniometric ref, or NULL */
} bf6_light;

int bf6_level_lights(bf6_ctx*, const char* level,
                     bf6_light* out, int out_max);

/* ------------------------------------------------------------------ terrain */
typedef struct {
    int32_t         width;         /* samples, e.g. 8193 */
    int32_t         height;
    const uint16_t* heights;       /* row-major, width*height samples */
    float           world_size;    /* metres across */
    float           height_scale;  /* sample -> metres */
    int32_t         splat_texture; /* index for bf6_texture_at(), or -1 */
    int32_t         color_texture;
} bf6_terrain;

bf6_terrain* bf6_read_terrain(bf6_ctx*, const char* level);

/* -------------------------------------------------------------------- memory */
/* Free anything this API returned (bf6_mesh*, bf6_terrain*, ...). The bf6_ctx*
 * itself is freed by bf6_close(), not this. */
void bf6_free(bf6_ctx*, void* handle);

#ifdef __cplusplus
}
#endif
#endif /* BF6_CORE_H */
