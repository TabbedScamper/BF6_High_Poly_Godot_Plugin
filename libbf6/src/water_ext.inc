/* water_ext.inc - the full water render description, over the C ABI.
 *
 * NEW FILE. It is a translation-unit fragment, not a standalone .cpp: it uses
 * bf6_ctx, which only exists inside bf6_core.cpp. Wire it with ONE line in
 * src/bf6_core.cpp, immediately BEFORE that file's last line - the include has
 * to be INSIDE the extern "C" block so the new entry point gets C linkage:
 *
 *     #include "water_ext.inc"
 *     }  // extern "C"          <- the existing last line, unchanged
 *
 * and add the declarations in the comment block at the bottom of this file to
 * include/bf6_core.h, after the bf6_level_water_sim prototype. Nothing else in
 * either file changes.
 *
 * WHY A SECOND WATER CALL. bf6_level_water answers "where is the plane and
 * roughly what colour is it". A renderer needs more than that and, worse, some
 * of what it needs is a TRAP if read naively:
 *
 *   - the authored colour is a PER-METRE TRANSMISSION, not a surface colour.
 *     Painting it on a plane gives a flat pastel pane. This call returns both
 *     the raw authored value and the converted surface colour and extinction,
 *     so a consumer cannot get that wrong by accident.
 *   - ShoreDepth is meaningless unless OceanWavesAttenuationType == ShoreDepth.
 *     mp_atoll ships -18.3775 and mp_isolated 14.0251 while both run CoarseMask
 *     and their shaders do not even declare the parameter. attenuation_type is
 *     returned FIRST for that reason.
 *   - there are THREE shader families and they share no parameter. variant says
 *     which, and the fields belonging to the others are left at the "absent"
 *     sentinel rather than at zero, because zero is a legal authored value here.
 *
 * Sources: systems/WATER.md and the findings it lists, in the research repo.
 */

/* ---- material slot ids (Name32) -------------------------------------------
 * These are content-graph generated and are NOT recoverable names; they are
 * stable opaque slot ids, verified identical across every level that ships the
 * family. The ENGINE-side ids in cb0 are recoverable and are not needed here.
 */
static const uint32_t kW2_OceanColour   = 0xEACA953A;  /* ocean base colour     */
static const uint32_t kW2_AbsorbDist    = 0x2D8E51DC;  /* ocean, metres         */
static const uint32_t kW2_Overlay0      = 0xD45F0908;  /* applied in this order */
static const uint32_t kW2_Overlay1      = 0x68F68C0F;
static const uint32_t kW2_Overlay2      = 0xD5C71AFD;
static const uint32_t kW2_Overlay3      = 0xEC10E3B5;
static const uint32_t kW2_Shallow       = 0x50B54E74;  /* foam family           */
static const uint32_t kW2_Deep          = 0xDFCB439C;
static const uint32_t kW2_DepthRamp     = 0x5AD4BBEE;  /* foam family, metres   */
static const uint32_t kW2_DetailFade    = 0x0795990F;  /* Vec2, metres          */
static const uint32_t kW2_FoamThreshold = 0xFA9AA135;
static const uint32_t kW2_ShoreFoamSupp = 0x1AA264BA;
static const uint32_t kW2_FoamContrast  = 0x4B6CAED4;
static const uint32_t kW2_FoamW0        = 0x1E626FB8;
static const uint32_t kW2_FoamW1        = 0x83903BBB;
static const uint32_t kW2_FoamW2        = 0xF6A14FA0;
static const uint32_t kW2_FoamW3        = 0x5BCF1BA3;
static const uint32_t kW2_SmoothZero    = 0x35870FDC;
static const uint32_t kW2_SmoothFull    = 0xBD9F2E32;
static const uint32_t kW2_SmoothBias    = 0xC57449FF;
static const uint32_t kW2_SmoothNear    = 0x9A44CFD5;
static const uint32_t kW2_FoamSheetN    = 0xC4119C14;
static const uint32_t kW2_MicroSheetN   = 0xAB684B74;
static const uint32_t kW2_NoiseUvScale  = 0xAD0F5BEF;
static const uint32_t kW2_ReflLow       = 0x5629D818;
static const uint32_t kW2_ReflHigh      = 0xAE1243A2;
static const uint32_t kW2_ReflBias      = 0x02F07FDA;
static const uint32_t kW2_ContactFoam   = 0x6AC9C660;
static const uint32_t kW2_FoamRgb2      = 0xB4B73136;

/* ---- WaterSurfaceEntityData field hashes ---------------------------------
 * Offsets and types from the MP executable's reflection records; see
 * data/exe_water_reflection_layouts.tsv. DO NOT read these through the SP
 * executable's schema - it lays the water classes out differently and every
 * field parses to a wrong value without erroring.
 */
static const uint32_t kW2_FShoreDepth   = 0x41737016;  /* Float32, metres  */
static const uint32_t kW2_FShoreBlend   = 0x3D672CE5;  /* Vec4 cubic       */
static const uint32_t kW2_FShoreEnable  = 0xF2EBF488;  /* Boolean          */
static const uint32_t kW2_FAttenType    = 0x4F78B966;  /* OceanWavesAttenuationType */
static const uint32_t kW2_FAddDepth     = 0xB62E36DE;  /* Float32, metres  */
static const uint32_t kW2_FQueryHalf    = 0xE6CF3A3F;  /* Vec3 half extent */
static const uint32_t kW2_FVisible      = 0x2A7B2AF9;  /* Boolean          */
static const uint32_t kW2_FTerrainVt    = 0xD25F75D1;  /* Boolean          */
static const uint32_t kW2_FWaveAmp      = 0xCF58D73D;  /* Float32          */
/* THE RIVER FLAG. Unnamed in the reflection table; named by behaviour. True on
 * exactly the 8 of 14 surfaces whose shader permutation declares
 * Serac:WaterRiverFlowSampler, false on the other 6, and the byte the CPU gates
 * all three river parameters on. This is the only readable water TYPE. */
static const uint32_t kW2_FIsRiver      = 0x8325B2E3;  /* Boolean, +0x027B */
/* Vec3/Vec4 members are read BY OFFSET, never by hash order. */
static const uint32_t kW2_Vec4Members[4] =
    { 0x3901DB14, 0x42FC0F5E, 0x32A99B9C, 0x7C8062F2 };

static float W2_F(const bf6::EbxValue& d, uint32_t h, float dflt)
{
    const bf6::EbxValue* f = d.field(h);
    if (!f) return dflt;
    if (f->kind == bf6::EbxValue::Kind::Real) return (float)f->f;
    if (f->kind == bf6::EbxValue::Kind::Int)  return (float)f->i;
    if (f->kind == bf6::EbxValue::Kind::Uint) return (float)f->u;
    return dflt;
}
static int W2_I(const bf6::EbxValue& d, uint32_t h, int dflt)
{
    const bf6::EbxValue* f = d.field(h);
    if (!f) return dflt;
    if (f->kind == bf6::EbxValue::Kind::Bool) return f->b ? 1 : 0;
    if (f->kind == bf6::EbxValue::Kind::Int)  return (int)f->i;
    if (f->kind == bf6::EbxValue::Kind::Uint) return (int)f->u;
    if (f->kind == bf6::EbxValue::Kind::Real) return (int)f->f;
    return dflt;
}
static void W2_Vec(const bf6::EbxValue& d, uint32_t h, int n, float* out)
{
    const bf6::EbxValue* f = d.field(h);
    if (!f || f->kind != bf6::EbxValue::Kind::Struct) return;
    for (int i = 0; i < n; i++) out[i] = W2_F(*f, kW2_Vec4Members[i], out[i]);
}

/* One inline constant out of a resolved depot record, by slot. Returns false
 * when the record does not carry the slot, which is NOT the same as zero. */
static bool W2_Const(const bf6::MaterialBinding& mb, uint32_t slot, int n, float* out)
{
    auto it = mb.constants.find(slot);
    if (it == mb.constants.end()) return false;
    if (it->second.size() < (size_t)n * 4) return false;
    std::memcpy(out, it->second.data(), (size_t)n * 4);
    return true;
}

int bf6_level_water_render(bf6_ctx* c, const char* level,
                           bf6_water_render* out, int out_max)
{
    if (!c || !level || !*level || !c->types || !c->walk) return 0;
    if (c->walked_level != level) return 0;

    std::string lvl = c->walk->root;
    if (lvl.size() > 4 && lvl.compare(lvl.size() - 4, 4, ".ebx") == 0) lvl.resize(lvl.size() - 4);
    const size_t slash = lvl.find_last_of('/');
    lvl = slash == std::string::npos ? std::string() : lvl.substr(0, slash);

    std::string part;
    {
        const std::string cands[] = { lvl + "/default", lvl + "/_layers_content/water",
                                      std::string(level) + "/default" };
        for (const std::string& cand : cands)
            if (c->src.ebx().count(cand) && BF6_CountsWater(c, cand)) { part = cand; break; }
        if (part.empty() && !lvl.empty()) {
            std::vector<std::string> rest;
            for (const auto& kv : c->src.ebx()) {
                const std::string& n = kv.first;
                if (n.compare(0, lvl.size(), lvl) != 0) continue;
                std::string low = n;
                for (char& ch : low) ch = (char)tolower((unsigned char)ch);
                if (low.find("water") != std::string::npos) {
                    if (BF6_CountsWater(c, n)) { part = n; break; }
                } else rest.push_back(n);
            }
            if (part.empty())
                for (const std::string& n : rest)
                    if (BF6_CountsWater(c, n)) { part = n; break; }
        }
    }
    if (part.empty()) return 0;

    std::string err;
    std::vector<uint8_t> raw = c->src.get_ebx(part, err);
    if (raw.empty()) return 0;
    bf6::Ebx e(*c->types);
    e.set_guid_index(&c->src.partition_index());
    if (!e.parse(std::move(raw), err)) return 0;

    int total = 0;
    for (size_t i = 0; i < e.instance_count(); i++) {
        if (bf6::TypeDb::guid_str(e.instance_type(i)) != kWaterTypeGuid) continue;

        const int64_t base = e.payload() + (int64_t)e.instance_offset(i);
        const std::vector<uint8_t>& d = e.raw();
        if (base < 0 || (size_t)base + 0x60 > d.size()) continue;
        float sx, sz, tx, ty, tz;
        std::memcpy(&sx, d.data() + base + 0x20, 4);
        std::memcpy(&sz, d.data() + base + 0x48, 4);
        std::memcpy(&tx, d.data() + base + 0x50, 4);
        std::memcpy(&ty, d.data() + base + 0x54, 4);
        std::memcpy(&tz, d.data() + base + 0x58, 4);
        if (std::fabs(sx) < 1.f || std::fabs(sz) < 1.f) continue;

        bf6_water_render w;
        std::memset(&w, 0, sizeof(w));
        /* Absent is NOT zero anywhere in this struct: zero is authored. */
        w.base_colour[0] = w.deep_colour[0] = -1.f;
        w.surface_colour[0] = -1.f;
        w.absorption_distance_m = -1.f;
        w.depth_ramp_m = -1.f;
        w.detail_normal = w.foam_normal = w.foam_rgb = w.noise = w.perlin =
            w.contact_foam = w.foam_rgb2 = -1;
        /* Every scalar below is a non-negative quantity when authored, and zero
         * is a legal authored value for all of them, so "absent" has to be a
         * NEGATIVE sentinel. This matters: MP_Isolated and MP_Atoll run a
         * different material graph and carry NONE of the named foam or
         * reflectance slots, so a consumer that read zero here would silently
         * turn their foam off instead of falling back. */
        w.detail_fade_start_m = w.detail_fade_end_m = -1.f;
        w.foam_threshold = w.shore_foam_suppression = w.foam_contrast_divisor = -1.f;
        w.smoothness_zero_foam = w.smoothness_full_foam = -1.f;
        w.smoothness_bias = w.smoothness_near_multiplier = -1.f;
        w.foam_sheet_normal_strength = w.micro_sheet_normal_strength = -1.f;
        w.noise_uv_scale = -1.f;
        w.reflectance_low = w.reflectance_high = w.reflectance_bias = -1.f;
        for (int k = 0; k < 4; k++) w.cascade_foam_weight[k] = -1.f;

        w.center[0] = tx; w.center[1] = tz;
        w.size[0]   = std::fabs(sx); w.size[1] = std::fabs(sz);
        w.height    = ty;

        bf6::EbxValue inst = e.read_instance(i);
        w.state_key = 0;
        if (const bf6::EbxValue* f = inst.field(kWaterStateKeyField)) {
            if (f->kind == bf6::EbxValue::Kind::Uint) w.state_key = f->u;
            else if (f->kind == bf6::EbxValue::Kind::Int) w.state_key = (uint64_t)f->i;
        }
        w.attenuation_type        = W2_I(inst, kW2_FAttenType, 0);
        w.shore_enable            = W2_I(inst, kW2_FShoreEnable, 0);
        w.shore_depth_m           = W2_F(inst, kW2_FShoreDepth, 0.f);
        w.additional_water_depth_m= W2_F(inst, kW2_FAddDepth, 0.f);
        w.wave_amplitude_scale    = W2_F(inst, kW2_FWaveAmp, 1.f);
        w.visible                 = W2_I(inst, kW2_FVisible, 1);
        w.is_river                = W2_I(inst, kW2_FIsRiver, 0);
        w.terrain_vt_access       = W2_I(inst, kW2_FTerrainVt, 0);
        w.shore_blend[0] = w.shore_blend[1] = w.shore_blend[3] = 0.f;
        w.shore_blend[2] = 1.f;                       /* engine default f(t)=t */
        W2_Vec(inst, kW2_FShoreBlend, 4, w.shore_blend);
        {
            float qb[3] = { 0.f, 0.f, 0.f };
            W2_Vec(inst, kW2_FQueryHalf, 3, qb);
            w.query_box_half_extent[0] = qb[0];
            w.query_box_half_extent[1] = qb[2];
        }
        /* The shore fade only exists under attenuation type 1. Under 2 and 3
         * the shipped depth and cubic are dead fields, so say so rather than
         * handing a consumer a negative distance to divide by. */
        w.shore_fade_valid = (w.attenuation_type == 1) ? 1 : 0;

        if (w.state_key) {
            for (const auto& kv : c->src.res()) {
                const std::string& rn = kv.first;
                if (rn.find("shaderblockdepot") == std::string::npos) continue;
                if (!lvl.empty() && rn.find(lvl) == std::string::npos) continue;
                const std::vector<uint8_t>* dbytes = nullptr;
                bf6::Depot* dep = c->depot_named(rn, &dbytes);
                if (!dep || !dbytes || !dep->has_key(w.state_key)) continue;
                bf6::MaterialBinding mb = dep->textures_for(w.state_key, *dbytes);
                if (!mb.valid) continue;

                /* THREE families, not two. The Granite Portal sub-levels bind a
                 * third material that shares no slot with either of the others:
                 * seven float3 colours, each paired with a float, and the floats
                 * are world coordinates (-1024, 1024, -2048, 512) rather than
                 * distances - a region-banded water. Returning 0 for it would
                 * hand a consumer the foam family's semantics and the wrong
                 * colour, so it gets its own value and its colour fields stay
                 * absent until the family is decoded. */
                w.variant = mb.constants.count(kW2_OceanColour) ? 1
                          : (mb.constants.count(kW2_Shallow) ||
                             mb.constants.count(kW2_Deep))     ? 0
                          : 2;

                const auto& gi = c->src.partition_index();
                auto grab = [&](uint32_t slot) -> int32_t {
                    auto sit = mb.textures.find(slot);
                    if (sit == mb.textures.end()) return -1;
                    auto ait = gi.find(sit->second);
                    if (ait == gi.end()) return -1;
                    std::string t = ait->second;
                    if (t.size() > 4 && t.compare(t.size() - 4, 4, ".ebx") == 0) t.resize(t.size() - 4);
                    return c->texture_id(t);
                };
                w.detail_normal = grab(kWSlotDetailNsh);
                w.foam_normal   = grab(kWSlotFoamNsh);
                w.foam_rgb      = grab(kWSlotFoamRgb);
                w.noise         = grab(kWSlotNoise);
                w.perlin        = grab(kWSlotPerlin);
                w.contact_foam  = grab(kW2_ContactFoam);
                w.foam_rgb2     = grab(kW2_FoamRgb2);

                if (w.variant == 1) {
                    W2_Const(mb, kW2_OceanColour, 3, w.base_colour);
                    float dist = -1.f;
                    W2_Const(mb, kW2_AbsorbDist, 1, &dist);
                    w.absorption_distance_m = dist;
                    static const uint32_t ov[4] = { kW2_Overlay0, kW2_Overlay1,
                                                    kW2_Overlay2, kW2_Overlay3 };
                    for (int k = 0; k < 4; k++) {
                        float t3[3];
                        if (!W2_Const(mb, ov[k], 3, t3)) continue;
                        std::memcpy(w.overlay_colour[w.overlay_count], t3, 12);
                        w.overlay_count++;
                    }
                } else if (w.variant == 0) {
                    W2_Const(mb, kW2_Shallow, 3, w.base_colour);
                    W2_Const(mb, kW2_Deep, 3, w.deep_colour);
                    float ramp = -1.f;
                    W2_Const(mb, kW2_DepthRamp, 1, &ramp);
                    w.depth_ramp_m = ramp;
                }

                float fade[2] = { 0.f, 0.f };
                if (W2_Const(mb, kW2_DetailFade, 2, fade))
                    { w.detail_fade_start_m = fade[0]; w.detail_fade_end_m = fade[1]; }
                W2_Const(mb, kW2_FoamThreshold, 1, &w.foam_threshold);
                W2_Const(mb, kW2_ShoreFoamSupp, 1, &w.shore_foam_suppression);
                W2_Const(mb, kW2_FoamContrast,  1, &w.foam_contrast_divisor);
                W2_Const(mb, kW2_FoamW0, 1, &w.cascade_foam_weight[0]);
                W2_Const(mb, kW2_FoamW1, 1, &w.cascade_foam_weight[1]);
                W2_Const(mb, kW2_FoamW2, 1, &w.cascade_foam_weight[2]);
                W2_Const(mb, kW2_FoamW3, 1, &w.cascade_foam_weight[3]);
                W2_Const(mb, kW2_SmoothZero,   1, &w.smoothness_zero_foam);
                W2_Const(mb, kW2_SmoothFull,   1, &w.smoothness_full_foam);
                W2_Const(mb, kW2_SmoothBias,   1, &w.smoothness_bias);
                W2_Const(mb, kW2_SmoothNear,   1, &w.smoothness_near_multiplier);
                W2_Const(mb, kW2_FoamSheetN,   1, &w.foam_sheet_normal_strength);
                W2_Const(mb, kW2_MicroSheetN,  1, &w.micro_sheet_normal_strength);
                W2_Const(mb, kW2_NoiseUvScale, 1, &w.noise_uv_scale);
                W2_Const(mb, kW2_ReflLow,  1, &w.reflectance_low);
                W2_Const(mb, kW2_ReflHigh, 1, &w.reflectance_high);
                W2_Const(mb, kW2_ReflBias, 1, &w.reflectance_bias);
                break;
            }
        }

        /* THE CONVERSION, done here so no consumer has to know it exists.
         *
         *   the ocean family's authored colour is what the water REACHES after
         *   `absorption_distance_m` metres. The draw shader turns it into a
         *   per-unit transmission with saturate(1 + ln(c)/d) and hands that to
         *   the deferred pass as an albedo. extinction is the same quantity in
         *   the form a Beer-Lambert renderer wants: transmission over L metres
         *   is exp(-extinction * L).
         *
         *   d <= 0.01 is the shader's own bypass: the colour is used raw.
         */
        if (w.variant == 1 && w.base_colour[0] >= 0.f) {
            const float dst = w.absorption_distance_m;
            for (int k = 0; k < 3; k++) {
                const float col = w.base_colour[k] > 1e-6f ? w.base_colour[k] : 1e-6f;
                if (dst > 0.01f) {
                    float s = 1.f + std::log(col) / dst;
                    w.surface_colour[k] = s < 0.f ? 0.f : (s > 1.f ? 1.f : s);
                    w.extinction[k] = -std::log(col) / dst;
                } else {
                    const float s = w.base_colour[k];
                    w.surface_colour[k] = s < 0.f ? 0.f : (s > 1.f ? 1.f : s);
                    w.extinction[k] = 0.f;
                }
            }
        } else if (w.variant == 0 && w.base_colour[0] >= 0.f) {
            /* the foam family has no logarithm: the shallow colour IS the
             * surface colour at zero depth. */
            std::memcpy(w.surface_colour, w.base_colour, 12);
        }

        if (out && total < out_max) out[total] = w;
        total++;
    }
    return total;
}

/* =====================================================================
 * PASTE INTO include/bf6_core.h, immediately after the bf6_water_sim
 * declarations (anchor: the line
 *     BF6_API int bf6_level_water_sim(bf6_ctx*, const char* level, bf6_water_sim* out);
 * ), keeping the existing bf6_water and bf6_level_water untouched:
 *
 * ------------------------------------------------------------------- water 2
 * / THE FULL RENDER DESCRIPTION of a level's water, enough to drive a
 *   conventional forward or deferred renderer without reading the game again.
 *
 *   ABSENT IS NOT ZERO. Zero is a legal authored value for nearly everything
 *   here, so EVERY float in this struct that is not a coordinate is left at a
 *   NEGATIVE sentinel when the level does not carry it, and every texture id at
 *   -1. That is not defensive style: MP_Isolated and MP_Atoll run a different
 *   material graph and carry NONE of the named foam or reflectance slots, so a
 *   consumer reading zero would turn their foam off rather than fall back.
 *
 *   THREE FAMILIES. variant is 1 for the ocean shader (mp_tungsten, mp_eastwood,
 *   mp_isolated, mp_atoll), 0 for the reduced foam shader (mp_dumbo,
 *   mp_aftermath, mp_aftermath_portal), and 2 for the region-banded material the
 *   Granite Portal sub-levels bind, which is UNDECODED: its colour fields are
 *   left absent rather than guessed. The three share no material parameter, so
 *   the fields of the family you are not on are absent by design, not missing.
 *
 *   READ attenuation_type BEFORE shore_depth_m. Only type 1 (ShoreDepth) uses
 *   the shore depth and cubic; under 2 and 3 the shipped values are dead
 *   fields and one of them is negative in retail. shore_fade_valid carries
 *   that decision so a consumer does not have to know the enum. /
 * typedef struct {
 *     uint64_t state_key;
 *     int32_t  variant;                  / 1 ocean, 0 foam, 2 region-banded
 *                                          (undecoded; colours absent)        /
 *
 *     float center[2];                   / world X, Z of the plane centre   /
 *     float size[2];                     / metres, FULL width               /
 *     float height;                      / world Y                          /
 *     float query_box_half_extent[2];    / metres, half width; redundant    /
 *
 *     int32_t attenuation_type;          / 0 None 1 ShoreDepth 2 CoarseMask
 *                                          3 CoarseAndDetailMask            /
 *     int32_t shore_fade_valid;          / 1 only when attenuation_type==1   /
 *     int32_t shore_enable;
 *     float   shore_depth_m;             / metres; t = saturate(depth/this)  /
 *     float   shore_blend[4];            / cubic (a,b,c,d): dot4(t^3,t^2,t,1)/
 *     float   additional_water_depth_m;  / metres, added to the depth sample /
 *     float   wave_amplitude_scale;      / dimensionless                     /
 *     int32_t visible;
 *     int32_t terrain_vt_access;
 *     / THE ONLY READABLE WATER TYPE. There is no ocean/river/pool enum; this
 *       bool is the river flag, and it agrees 14 of 14 with whether the level's
 *       shader permutation declares Serac:WaterRiverFlowSampler. /
 *     int32_t is_river;
 *
 *     / COLOUR. base_colour is the AUTHORED value and on the ocean family it is
 *       a per-metre transmission, NOT a surface colour: it is what the water
 *       reaches after absorption_distance_m metres. surface_colour and
 *       extinction are that value converted, so a renderer never needs the
 *       formula. transmission over L metres is exp(-extinction * L). /
 *     float base_colour[3];              / linear RGB, authored              /
 *     float deep_colour[3];              / linear RGB, foam family only      /
 *     float surface_colour[3];           / linear RGB, DERIVED               /
 *     float extinction[3];               / per metre, DERIVED                /
 *     float absorption_distance_m;       / metres, ocean family              /
 *     float depth_ramp_m;                / metres, foam family               /
 *     int32_t overlay_count;             / 0..4 extra lerp-stack colours     /
 *     float overlay_colour[4][3];        / linear RGB, in application order;
 *                                          their weights are RUNTIME terms and
 *                                          cannot be evaluated offline       /
 *
 *     float detail_fade_start_m, detail_fade_end_m;
 *     float foam_threshold;              / 0..1                              /
 *     float shore_foam_suppression;      / 0..1                              /
 *     float foam_contrast_divisor;
 *     float cascade_foam_weight[4];      / cascade 0..3                      /
 *     float smoothness_zero_foam, smoothness_full_foam;
 *     float smoothness_bias, smoothness_near_multiplier;
 *     float foam_sheet_normal_strength, micro_sheet_normal_strength;
 *     float noise_uv_scale;              / 1/metres                          /
 *     float reflectance_low, reflectance_high, reflectance_bias;
 *
 *     / for bf6_texture_at, or -1 /
 *     int32_t detail_normal, foam_normal, foam_rgb, noise, perlin;
 *     int32_t contact_foam, foam_rgb2;
 * } bf6_water_render;
 *
 * / Requires bf6_open_level for this level first. Same convention as
 *   bf6_level_instances: returns the count, fills out[] to out_max. /
 * BF6_API int bf6_level_water_render(bf6_ctx*, const char* level,
 *                                    bf6_water_render* out, int out_max);
 * =====================================================================
 */
