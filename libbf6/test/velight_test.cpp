/* velight_test - decode a level's VisualEnvironment through the C ABI.
 *
 * Prints the whole record, and where a level is one of the four with a
 * hand-built reference row it also prints the comparison. The reference rows
 * are the ORACLE, not data: they were entered by hand into the Godot plugin's
 * lighting table long before any of this decoded, so reproducing them is the
 * evidence that the live decode reads the same environment the game does.
 * Nothing here feeds a value back into the decode.
 *
 *   velight_test <game_dir> <level> [level...]
 */
#include <cstdio>
#include <cstring>
#include <cmath>
#include <string>
#include <vector>

#include "bf6_core.h"

struct Row {
    const char* level;
    float az, el, lux;
    float sun[3];
    /* Two rows in that table are NOT reproducible, and the reason is recorded
     * so nobody re-opens the question by finding the same disagreement again.
     * A row marked `known_bad` prints its difference and does not fail the
     * run; every other row must match. */
    const char* known_bad;
};

// The plugin's hand-built lighting table, verbatim. Sun colour is written to
// four decimals there, so the comparison is to four decimals; lux is written as
// a round integer, so it is compared relatively.
static const Row kOracle[] = {
    { "MP_Abbasid",     225.00f, 44.00f, 120000.f, { 1.f, 0.8780f, 0.7590f }, nullptr },
    { "MP_Aftermath",   237.90f, 12.90f,  24000.f, { 1.f, 0.5033f, 0.2633f }, nullptr },
    { "MP_Aftermath_Portal",
                        237.90f, 12.90f,  24000.f, { 1.f, 0.5033f, 0.2633f }, nullptr },
    // az and SunColor here were never derived from the game. The mined sidecar
    // that carries this row says so in its own note_active_preset: "az/el/lux/
    // sun/gradient carried forward as-is" from a hand-built table that predates
    // any decode, and no artifact of a derivation survives. el 10 and lux 45860
    // ARE the game's numbers (45860.16); the level's only outdoor preset,
    // ve_mp_badlands_base, authors az 300 and SunColor (1, 0.3145, 0.0331), and
    // 354 appears nowhere in any of the four VE presets the level ships. The
    // plugin's own header separately RETRACTS the claim that this map's sun was
    // photo-verified.
    { "MP_Badlands",    354.00f, 10.00f,  45860.f, { 1.f, 0.2100f, 0.0000f },
      "az/SunColor in that row were never mined; el and lux match" },
    { "MP_Battery",     315.00f, 47.00f,  46000.f, { 1.f, 0.9665f, 0.9238f }, nullptr },
    { "MP_Contaminated", 14.17f, 45.00f, 125000.f, { 1.f, 0.8336f, 0.7054f }, nullptr },
    { "MP_Dumbo",       124.80f, 28.50f, 120000.f, { 1.f, 0.7759f, 0.6167f }, nullptr },
    { "MP_Eastwood",    199.00f, 38.00f, 125000.f, { 1.f, 0.7759f, 0.6167f }, nullptr },
    { "MP_FireStorm",   302.55f, 35.00f, 100000.f, { 1.f, 0.8796f, 0.8228f }, nullptr },
    { "MP_GolmudRailway", 145.00f, 35.00f, 100000.f, { 1.f, 0.9710f, 0.9140f }, nullptr },
    { "MP_Granite_ClubHouse_Portal",
                        280.00f, 27.50f, 135000.f, { 1.f, 0.8848f, 0.7375f }, nullptr },
    { "MP_Granite_MainStreet_Portal",
                        280.00f, 27.50f, 135000.f, { 1.f, 0.8848f, 0.7375f }, nullptr },
    { "MP_Granite_Marina_Portal",
                        280.00f, 27.50f, 135000.f, { 1.f, 0.8848f, 0.7375f }, nullptr },
    { "MP_Granite_MilitaryRnD_Portal",
                        280.00f, 27.50f, 135000.f, { 1.f, 0.8848f, 0.7375f }, nullptr },
    { "MP_Granite_MilitaryStorage_Portal",
                        280.00f, 27.50f, 135000.f, { 1.f, 0.8848f, 0.7375f }, nullptr },
    { "MP_Granite_TechCampus_Portal",
                        280.00f, 27.50f, 135000.f, { 1.f, 0.8848f, 0.7375f }, nullptr },
    { "MP_Granite_Underground_Portal",
                        280.00f, 27.50f, 135000.f, { 1.f, 0.8848f, 0.7375f }, nullptr },
    { "MP_Limestone",   245.00f, 66.00f, 125000.f, { 1.f, 0.9527f, 0.8930f }, nullptr },
    { "MP_Outskirts",   143.00f, 30.00f, 100000.f, { 1.f, 0.9871f, 0.9114f }, nullptr },
    // Everything but the red channel matches. The level authors SunColor red at
    // 1.06066, above 1, and the table carries 1 - a clamp somebody applied on
    // the way in. The tint is NOT normalised in the data, so the authored value
    // is the one to use.
    { "MP_Plaza",       300.00f, 26.00f, 145000.f, { 1.f, 0.5249f, 0.1534f },
      "SunColor red is authored at 1.06066; the table clamped it to 1" },
    { "MP_Portal_Sand", 280.00f, 27.50f, 135000.f, { 1.f, 0.8848f, 0.7375f }, nullptr },
    { "MP_Subsurface",  200.36f, 43.96f,   0.001f, { 1.f, 0.8796f, 0.8228f }, nullptr },
    { "MP_Tungsten",    350.00f, 20.00f,  50000.f, { 1.f, 0.8796f, 0.8228f }, nullptr },
};

static void v3(const char* name, const float* v)
{
    std::printf("  %-30s %.6g, %.6g, %.6g\n", name, v[0], v[1], v[2]);
}
static void f1(const char* name, float v)   { std::printf("  %-30s %.6g\n", name, v); }
static void i1(const char* name, int v)     { std::printf("  %-30s %d\n", name, v); }
static void s1(const char* name, const char* v)
{
    if (v && *v) std::printf("  %-30s %s\n", name, v);
}

// Four decimals, the precision the reference row is written to. Anything past
// 1 is compared relatively, because the table writes lux as a round integer
// (45860) where the game authors 45860.16 - the same number, written shorter.
static bool near4(float a, float b)
{
    // Half a unit in the table's fourth decimal place, plus slack for the float
    // round trip of a 4-decimal literal. Outskirts sits exactly on the boundary
    // - the game authors 0.98705 and the table writes 0.9871 - so a strict
    // 5e-5 rejects a value that is the same number written shorter.
    if (std::fabs(b) <= 1.f) return std::fabs(a - b) <= 6e-5f;
    return std::fabs(a - b) <= 1e-5f * std::fabs(b);
}

int main(int argc, char** argv)
{
    if (argc < 3) {
        std::fprintf(stderr, "usage: velight_test <game_dir> <level> [level...]\n");
        return 2;
    }
    char err[512] = {0};
    bf6_ctx* c = bf6_open(argv[1], err, (int)sizeof(err));
    if (!c) { std::fprintf(stderr, "open: %s\n", err); return 1; }

    // Explicit front-end VisualEnvironments live in flow_mainmenu rather than
    // a playable level.  Mount the non-level archives so this harness tests
    // those presets through the same runtime path as the native armory viewer.
    // A made-up partition below remains the negative control; mounting more
    // archives must not turn a nonexistent name into a match.
    if (!bf6_mount_all(c, 0, err, (int)sizeof(err))) {
        std::fprintf(stderr, "mount: %s\n", err);
        bf6_close(c);
        return 1;
    }

    int bad = 0;
    for (int i = 2; i < argc; i++) {
        const char* level = argv[i];
        bf6_ve_lighting v;
        err[0] = 0;
        if (!bf6_level_lighting(c, level, &v, err, (int)sizeof(err))) {
            std::printf("FAIL %s: %s\n", level, err);
            bad++;
            continue;
        }
        std::printf("=== %s\n", level);
        std::printf("  preset                         %s\n", v.preset);
        std::printf("  preset_path                    %s\n", v.preset_path);
        std::printf("  candidates                     %d\n", v.preset_candidates);
        std::printf("  components                     0x%03x (%d declared)\n",
                    v.components, v.component_count);
        std::printf("  visibility                     %.6g\n", v.visibility);
        std::printf("  fields                         %d/%d\n",
                    v.fields_found, v.fields_expected);

        std::printf("-- sun\n");
        f1("SunRotationX (bearing deg)", v.sun_rotation_x);
        f1("SunRotationY (elev deg)", v.sun_rotation_y);
        f1("SunIntensity (lux)", v.sun_intensity);
        v3("SunColor (linear)", v.sun_color);
        f1("SunAngularRadius (deg)", v.sun_angular_radius);
        f1("SunShadowViewDistance (m)", v.sun_shadow_view_distance);
        f1("CloudShadowSize (m)", v.cloud_shadow_size);
        f1("CloudShadowCoverage", v.cloud_shadow_coverage);
        f1("CloudShadowExponent", v.cloud_shadow_exponent);
        std::printf("  %-30s %.6g, %.6g\n", "CloudShadowSpeed",
                    v.cloud_shadow_speed[0], v.cloud_shadow_speed[1]);
        f1("SecondaryCloudShadowSize", v.secondary_cloud_shadow_size);
        f1("SecondaryCloudShadowCoverage", v.secondary_cloud_shadow_coverage);
        f1("SecondaryCloudShadowExponent", v.secondary_cloud_shadow_exponent);
        std::printf("  %-30s %.6g, %.6g\n", "SecondaryCloudShadowSpeed",
                    v.secondary_cloud_shadow_speed[0], v.secondary_cloud_shadow_speed[1]);
        std::printf("  %-30s %.6g, %.6g\n", "SecondaryCloudShadowTranslation",
                    v.secondary_cloud_shadow_translation[0], v.secondary_cloud_shadow_translation[1]);
        i1("CloudShadowAddressingMode", v.cloud_shadow_addressing_mode);
        i1("SecondaryCloudAddressingMode", v.secondary_cloud_shadow_addressing_mode);
        i1("CloudShadowIsTopDown", v.cloud_shadow_is_top_down);
        i1("SecondaryCloudIsTopDown", v.secondary_cloud_shadow_is_top_down);
        f1("CloudShadowStartFade", v.cloud_shadow_start_fade);
        f1("CloudShadowsFadeDistance", v.cloud_shadows_fade_distance);
        i1("CloudShadowHeightFadeEnable", v.cloud_shadow_height_fade_enable);
        f1("CloudShadowStartHeightFade", v.cloud_shadow_start_height_fade);
        f1("CloudShadowsHeightFadeDist", v.cloud_shadows_height_fade_distance);

        std::printf("-- sky\n");
        i1("SkyType", v.sky_type);
        f1("LuminanceScale", v.sky_luminance_scale);
        f1("PanoramicRotation (turns)", v.sky_panoramic_rotation);
        std::printf("  %-30s %.6g, %.6g\n", "PanoramicUvMin",
                    v.sky_panoramic_uv_min[0], v.sky_panoramic_uv_min[1]);
        std::printf("  %-30s %.6g, %.6g\n", "PanoramicUvMax",
                    v.sky_panoramic_uv_max[0], v.sky_panoramic_uv_max[1]);
        f1("FlowDistance", v.sky_flow_distance);
        f1("FlowDirection (degrees)", v.sky_flow_direction);
        f1("FlowPeriod (seconds)", v.sky_flow_period);
        f1("FlowHeightMaskScale", v.sky_flow_height_mask_scale);
        f1("FlowHeightMaskBias", v.sky_flow_height_mask_bias);
        i1("DrawSunDisc", v.sky_draw_sun_disc);
        f1("SunSize", v.sun_disc_size);
        f1("SunScale (sky)", v.sun_disc_scale);
        v3("Rayleigh (per channel)", v.rayleigh);
        f1("MieScatteringCoefficient", v.mie_coefficient);
        f1("MieG", v.mie_g);
        i1("UseAerialPerspective", v.use_aerial_perspective);
        f1("AerialPerspectiveIntensity", v.aerial_perspective_intensity);
        v3("HeightFogColorAdd (HDR)", v.height_fog_color_add);
        f1("CloudLayer1Altitude (m)", v.cloud1_altitude);
        f1("CloudLayer1Speed", v.cloud1_speed);

        std::printf("-- fog\n");
        i1("HeightFogEnable", v.fog_height_enable);
        i1("FogColorEnable", v.fog_color_enable);
        i1("FogGradientEnable", v.fog_gradient_enable);
        v3("FogColor (HDR radiance)", v.fog_color);
        f1("fog Start (m)", v.fog_dist_start);
        f1("fog End (m)", v.fog_dist_end);
        f1("HeightFogStart (m)", v.fog_height_start);
        f1("HeightFogEnd (m)", v.fog_height_end);
        f1("HeightFogAltitude (m)", v.fog_altitude);
        f1("HeightFogDepth (m)", v.fog_depth);
        f1("HeightFogVisibilityRange", v.fog_visibility_range);
        i1("ParticipatingMediaEnable", v.volumetrics_enable);
        f1("SunLightScatteringIntensity", v.sun_scatter_intensity);

        std::printf("-- exposure\n");
        i1("AutomaticExposure", v.auto_exposure);
        f1("EV", v.ev);
        f1("MaxEV", v.ev_max);
        f1("ExposureCompensation", v.exposure_compensation);
        v3("BloomScale", v.bloom_scale);
        i1("BloomMethod", v.bloom_method);

        std::printf("-- grading / white balance\n");
        i1("ColorGradingEnable", v.grading_enable);
        v3("Brightness", v.grade_brightness);
        v3("Contrast", v.grade_contrast);
        v3("Saturation", v.grade_saturation);
        f1("Hue", v.grade_hue);
        f1("Temperature (K)", v.white_temperature);
        f1("Tint", v.white_tint);

        std::printf("-- ambient occlusion\n");
        i1("AffectOutdoorLight", v.ao_affects_outdoor_light);
        i1("AffectLocalLight", v.ao_affects_local_light);
        f1("SsaoMaxDistanceInner", v.ssao_max_distance_inner);
        f1("SsaoMaxDistanceOuter", v.ssao_max_distance_outer);
        f1("HbaoRadius", v.hbao_radius);
        f1("HbaoContrast", v.hbao_contrast);

        std::printf("-- global illumination\n");
        v3("TerrainColor", v.gi_terrain_color);
        v3("SkyBoxSkyColor", v.gi_sky_color);
        v3("SkyBoxGroundColor", v.gi_ground_color);
        v3("SkyBoxSunLightColor", v.gi_sun_color);
        f1("BackLightRotationX", v.gi_backlight_rotation_x);
        f1("BackLightRotationY", v.gi_backlight_rotation_y);
        f1("BounceScale", v.gi_bounce_scale);
        f1("SunScale (GI)", v.gi_sun_scale);

        std::printf("-- textures\n");
        i1("has_panorama", v.has_panorama);
        s1("PanoramicTexture", v.panorama_res);
        i1("  panorama_texture id", v.panorama_texture);
        s1("PanoramicAlphaTexture", v.panorama_alpha_res);
        s1("SkyGradientTexture", v.sky_gradient_res);
        i1("  sky_gradient_texture id", v.sky_gradient_texture);
        s1("FlowMaskTexture", v.flow_mask_res);
        s1("CloudLayer1Texture", v.cloud_layer1_res);
        s1("CloudShadowTexture", v.cloud_shadow_res);
        s1("SecondaryCloudShadowTexture", v.secondary_cloud_shadow_res);
        s1("HdrColorGradingLut", v.grading_lut_res);
        s1("LensDirtTexture", v.lens_dirt_res);

        // The ids are only worth having if they decode, and the assumption they
        // rest on - that a VE names an EBX partition whose texture RESOURCE
        // shares the name - is exactly the kind of thing that is true until it
        // is not. So it is exercised rather than asserted.
        const int ids[] = { v.panorama_texture, v.sky_gradient_texture,
                            v.flow_mask_texture, v.cloud_shadow_texture,
                            v.secondary_cloud_shadow_texture,
                            v.grading_lut_texture };
        const char* what[] = { "panorama", "sky gradient", "flow mask",
                               "cloud shadow", "secondary cloud shadow",
                               "grading LUT" };
        for (int k = 0; k < (int)(sizeof(ids) / sizeof(ids[0])); k++) {
            if (ids[k] < 0) continue;
            const bf6_texture* t = bf6_texture_at(c, ids[k]);
            if (!t || t->width <= 0)
                std::printf("  %-30s id %d DOES NOT DECODE\n", what[k], ids[k]);
            else
                std::printf("  %-30s %dx%d fmt %d mips %d bytes %d\n", what[k],
                            t->width, t->height, (int)t->format, t->mip_count,
                            t->data_len);
        }

        const int nimp = bf6_level_lighting_imports(c, level, nullptr, 0);
        std::printf("-- imports (%d)\n", nimp);
        if (nimp > 0) {
            std::vector<const char*> imps((size_t)nimp, nullptr);
            bf6_level_lighting_imports(c, level, imps.data(), nimp);
            for (const char* s : imps) if (s) std::printf("  %s\n", s);
        }

        for (const Row& r : kOracle) {
            if (std::strcmp(r.level, level) != 0) continue;
            std::printf("-- ORACLE (the hand-built plugin table)\n");
            if (r.known_bad) std::printf("   known bad row: %s\n", r.known_bad);
            struct { const char* n; float got, want; } cmp[] = {
                { "az",    v.sun_rotation_x, r.az },
                { "el",    v.sun_rotation_y, r.el },
                { "lux",   v.sun_intensity,  r.lux },
                { "sun.r", v.sun_color[0],   r.sun[0] },
                { "sun.g", v.sun_color[1],   r.sun[1] },
                { "sun.b", v.sun_color[2],   r.sun[2] },
            };
            for (const auto& x : cmp) {
                const bool ok = near4(x.got, x.want);
                if (!ok && !r.known_bad) bad++;
                std::printf("  %-6s decoded %-12.6g table %-12.6g %s\n",
                            x.n, x.got, x.want,
                            ok ? "MATCH" : (r.known_bad ? "DIFFER (known)" : "DIFFER"));
            }
        }
        std::fflush(stdout);
    }
    bf6_close(c);
    std::printf("%s\n", bad ? "SOME CHECKS FAILED" : "ok");
    return bad ? 1 : 0;
}
