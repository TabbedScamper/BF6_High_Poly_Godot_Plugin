/* levellights_test - a level's local light placements through the C ABI.
 *
 * Prints the counts, the placement split, the distributions that say whether
 * the read is real, and a sample of individual lights with their units.
 *
 * WHAT IS BEING CHECKED, because a light decode fails in ways that look like
 * success:
 *
 *  - COUNT. Zero is a failure on any map that has fixtures, and so is a number
 *    in the tens of thousands. mp_dumbo's reference is 7,878 collected lights.
 *  - PLACEMENT SPLIT. `placed_at_holder` is the classic bug made visible: read
 *    the light entity's own Transform and 86.9% of a map's lights come out in
 *    the right number, in roughly the right part of the map, and sitting on
 *    their holders' origins. It is not a failure on its own - a light authored
 *    straight into a subworld legitimately sits on the holder placed for it,
 *    and maps run 1% (dumbo) to 16% (subsurface) - so it is read together with
 *    the Y range: most of the map on its holder AND a pile of lights at the
 *    world origin is the component join having broken.
 *  - HEIGHT RANGE against the terrain. Lights piled at y = 0 on a map whose
 *    ground starts at 24.8 m are unresolved placements, not basements.
 *  - COLOUR. 96% of mp_dumbo's lights carry an authored non-white colour. All
 *    white is what a reader gets when it resolves field names against
 *    sdk_field_names.tsv alone, and it produces a full, plausible light set.
 *  - INTENSITY against the engine's own photometric constants. LightUnit 0 is
 *    LuminousPower, so the number is LUMENS: a median in the thousands is a
 *    real fixture, a median of 1 or of 1e8 is not.
 *
 *   levellights_test <game_dir> [--asset] <level-or-asset> [...] [@fixture]
 */
#include <algorithm>
#include <cstdio>
#include <cstring>
#include <cmath>
#include <string>
#include <vector>

#include "bf6_core.h"

static const char* kind_name(int t)
{
    switch (t) {
    case BF6_LIGHT_SPHERE: return "sphere";
    case BF6_LIGHT_SPOT:   return "spot";
    case BF6_LIGHT_TUBE:   return "tube";
    case BF6_LIGHT_RECT:   return "rect";
    default:               return "other";
    }
}

static const char* unit_name(int u)
{
    return u == BF6_LIGHT_UNIT_LUMINANCE ? "cd/m2" : "lm";
}

static const char* qse_name(int q)
{
    switch (q) {
    case BF6_QSE_LOW:      return "Low+";
    case BF6_QSE_MEDIUM:   return "Medium+";
    case BF6_QSE_HIGH:     return "High+";
    case BF6_QSE_ULTRA:    return "Ultra";
    case BF6_QSE_DISABLED: return "off";
    default:               return "?";
    }
}

static float median(std::vector<float> v)
{
    if (v.empty()) return 0.f;
    std::sort(v.begin(), v.end());
    return v[v.size() / 2];
}

static const char* leaf(const char* s)
{
    if (!s) return "";
    const char* p = std::strrchr(s, '/');
    return p ? p + 1 : s;
}

int main(int argc, char** argv)
{
    if (argc < 3) {
        std::fprintf(stderr, "usage: levellights_test <game_dir> [--asset] <level-or-asset> [...]\n");
        return 2;
    }
    char err[512] = {0};
    bf6_ctx* c = bf6_open(argv[1], err, (int)sizeof(err));
    if (!c) { std::fprintf(stderr, "open: %s\n", err); return 1; }
    const bool asset_mode = argc >= 4 && std::strcmp(argv[2], "--asset") == 0;
    const int first_input = asset_mode ? 3 : 2;
    if (asset_mode && !bf6_mount_all(c, 1, err, (int)sizeof(err))) {
        std::fprintf(stderr, "mount all: %s\n", err);
        bf6_close(c);
        return 1;
    }

    // An argument beginning with '@' names a fixture to dump in full, e.g.
    // "@ceilinglamp_rect_01". That is how a decode is checked against a known
    // fixture rather than against its own averages: the corpus records
    // CeilingLamp_Rect_01's four emitters by hand, so its numbers are an
    // oracle this reader never saw.
    std::string fixture;
    bool have_near = false;
    float near_x = 0.f, near_z = 0.f, near_radius = 0.f;
    for (int a = first_input; a < argc; a++) {
        if (std::strncmp(argv[a], "@near=", 6) == 0) {
            have_near = std::sscanf(argv[a] + 6, "%f,%f,%f",
                                    &near_x, &near_z, &near_radius) == 3;
        } else if (argv[a][0] == '@') {
            fixture = argv[a] + 1;
        }
    }

    int bad = 0;
    for (int a = first_input; a < argc; a++) {
        if (argv[a][0] == '@') continue;
        const char* level = argv[a];
        bf6_light_stats st;
        err[0] = 0;
        const int n = asset_mode
            ? bf6_asset_lights(c, level, nullptr, 0, &st, err, (int)sizeof(err))
            : bf6_level_lights(c, level, nullptr, 0, &st, err, (int)sizeof(err));
        if (n <= 0) {
            std::printf("FAIL %s: %s\n", level, err[0] ? err : "no lights");
            bad++;
            continue;
        }
        std::vector<bf6_light> L((size_t)n);
        if (asset_mode)
            bf6_asset_lights(c, level, L.data(), n, nullptr, err, (int)sizeof(err));
        else
            bf6_level_lights(c, level, L.data(), n, nullptr, err, (int)sizeof(err));

        std::printf("=== %s\n", level);
        std::printf("  lights                 %d   (%d sphere, %d spot, %d tube, %d rect, %d other)\n",
                    st.total, st.sphere, st.spot, st.tube, st.rect, st.other);
        std::printf("  partitions walked      %d   unresolved types %d\n",
                    st.partitions, st.unresolved_types);
        std::printf("  placement components   %d   unlinked %d   excluded %d\n",
                    st.components, st.comp_unlinked, st.comp_excluded);
        std::printf("  placed by component    %d\n", st.placed_by_component);
        std::printf("  placed by own xform    %d\n", st.placed_by_own_transform);
        // Not a failure on its own: a light authored directly in a subworld
        // legitimately sits on the holder that was placed for it. It is a
        // failure when it is most of the map AND the Y range below piles at
        // the world origin, which is the component join having broken.
        std::printf("  on its holder's origin %d   (%.1f%% - read it with the Y range)\n",
                    st.placed_at_holder,
                    st.total ? 100.0 * st.placed_at_holder / st.total : 0.0);
        std::printf("  old 0x11F57ECA join    resolved %d, agreed with the real pointer %d\n",
                    st.comp_legacy_resolved, st.comp_legacy_agree);

        // ---- the distributions that separate a real read from a plausible one
        float ymin = 1e30f, ymax = -1e30f;
        int   nonwhite = 0, shadowed = 0, with_ies = 0, unit1 = 0, dimmed = 0;
        std::vector<float> inten, radius, cone;
        for (const bf6_light& l : L) {
            ymin = std::min(ymin, l.xform[10]);
            ymax = std::max(ymax, l.xform[10]);
            if (l.color[0] != 1.f || l.color[1] != 1.f || l.color[2] != 1.f) nonwhite++;
            if (l.cast_shadows_enable && l.cast_shadows != BF6_QSE_DISABLED) shadowed++;
            if (l.ies_profile) with_ies++;
            if (l.unit == BF6_LIGHT_UNIT_LUMINANCE) unit1++;
            if (l.dimmer != 1.f) dimmed++;
            if (l.intensity > 0.f) inten.push_back(l.intensity);
            if (l.attenuation_radius > 0.f) radius.push_back(l.attenuation_radius);
            if (l.type == BF6_LIGHT_SPOT && l.outer_angle > 0.f) cone.push_back(l.outer_angle);
        }
        std::sort(inten.begin(), inten.end());
        std::sort(radius.begin(), radius.end());
        std::sort(cone.begin(), cone.end());
        std::printf("  world Y                %.1f .. %.1f m\n", ymin, ymax);
        std::printf("  authored non-white     %d of %d (%.1f%%)\n",
                    nonwhite, st.total, st.total ? 100.0 * nonwhite / st.total : 0.0);
        std::printf("  casting shadows        %d      IES profile %d      dimmed %d\n",
                    shadowed, with_ies, dimmed);
        std::printf("  LightUnit              %d LuminousPower (lm), %d Luminance (cd/m2)\n",
                    st.total - unit1, unit1);
        if (!inten.empty())
            std::printf("  Intensity              min %.4g  median %.4g  max %.4g   (%zu authored)\n",
                        inten.front(), median(inten), inten.back(), inten.size());
        if (!radius.empty())
            std::printf("  AttenuationRadius      min %.4g  median %.4g  max %.4g m\n",
                        radius.front(), median(radius), radius.back());
        if (!cone.empty())
            std::printf("  OuterAngle (full cone) min %.4g  median %.4g  max %.4g deg\n",
                        cone.front(), median(cone), cone.back());
        // The emitter-size fields, per kind. A field read at a WRONG offset
        // comes back zero on every record, which looks exactly like "the artist
        // left it at the default" - so how many are non-zero is the check.
        for (int k = 0; k <= BF6_LIGHT_RECT; k++) {
            std::vector<float> sz;
            int have = 0, tot = 0;
            for (const bf6_light& l : L) {
                if (l.type != k) continue;
                tot++;
                const float v = (k == BF6_LIGHT_RECT) ? l.rect_height : l.shape_radius;
                if (v > 0.f) { have++; sz.push_back(v); }
            }
            if (!tot) continue;
            std::printf("  %-6s emitter size    %d of %d non-zero", kind_name(k), have, tot);
            if (!sz.empty()) {
                std::sort(sz.begin(), sz.end());
                std::printf("   min %.4g median %.4g max %.4g m", sz.front(), median(sz), sz.back());
            }
            std::printf("\n");
        }

        // ---- a sample, one of each kind, with everything in real units
        std::printf("-- sample\n");
        for (int want = 0; want <= BF6_LIGHT_RECT; want++) {
            const bf6_light* pick = nullptr;
            for (const bf6_light& l : L)
                if (l.type == want && l.from_component && l.intensity > 0.f) { pick = &l; break; }
            if (!pick)
                for (const bf6_light& l : L) if (l.type == want) { pick = &l; break; }
            if (!pick) continue;
            const bf6_light& l = *pick;
            std::printf("  [%s] %s\n", kind_name(l.type), leaf(l.source));
            std::printf("      pos      (%.3f, %.3f, %.3f)   %s\n",
                        l.xform[9], l.xform[10], l.xform[11],
                        l.from_component ? "placed by its component" : "own transform");
            // The beam is MINUS forward. Printed that way rather than as the
            // raw row, because the raw row is the thing that gets used by
            // mistake.
            {
                // The basis rows carry the holder's SCALE, so the forward row
                // is not a unit vector and an area light's world size is its
                // authored height and width times these. Printed rather than
                // hidden, because a consumer that uses row 2 raw as a
                // direction gets a beam whose length is a scale factor.
                const float sr = std::sqrt(l.xform[0]*l.xform[0] + l.xform[1]*l.xform[1] + l.xform[2]*l.xform[2]);
                const float su = std::sqrt(l.xform[3]*l.xform[3] + l.xform[4]*l.xform[4] + l.xform[5]*l.xform[5]);
                const float sf = std::sqrt(l.xform[6]*l.xform[6] + l.xform[7]*l.xform[7] + l.xform[8]*l.xform[8]);
                std::printf("      beam     (%.3f, %.3f, %.3f)   [-forward, normalised]\n",
                            sf > 0.f ? -l.xform[6] / sf : 0.f,
                            sf > 0.f ? -l.xform[7] / sf : 0.f,
                            sf > 0.f ? -l.xform[8] / sf : 0.f);
                std::printf("      scale    right %.4g  up %.4g  forward %.4g\n", sr, su, sf);
            }
            std::printf("      colour   (%.4f, %.4f, %.4f)   linear\n",
                        l.color[0], l.color[1], l.color[2]);
            std::printf("      energy   %.6g %s   dimmer %.3g   reach %.3g m (offset %.3g)\n",
                        l.intensity, unit_name(l.unit), l.dimmer,
                        l.attenuation_radius, l.attenuation_offset);
            if (l.type == BF6_LIGHT_SPOT)
                std::printf("      cone     inner %.3g deg, outer %.3g deg (FULL)   disc %.3g m\n",
                            l.inner_angle, l.outer_angle, l.shape_radius);
            if (l.type == BF6_LIGHT_SPHERE)
                std::printf("      emitter  sphere radius %.3g m\n", l.shape_radius);
            if (l.type == BF6_LIGHT_TUBE)
                std::printf("      emitter  tube radius %.3g m, width %.3g m, capsule %d\n",
                            l.shape_radius, l.tube_width, l.is_capsule);
            if (l.type == BF6_LIGHT_RECT)
                std::printf("      emitter  height %.3g m, aspect %.3g (width %.3g m), shape %d, outer %.3g deg\n",
                            l.rect_height, l.rect_aspect, l.rect_height * l.rect_aspect,
                            l.rect_shape, l.outer_angle);
            std::printf("      shadows  enable %d, %s   volumetric %s x%.3g\n",
                        l.cast_shadows_enable, qse_name(l.cast_shadows),
                        qse_name(l.cast_volumetric), l.volumetric_scattering);
            std::printf("      affects  diffuse %d specular %d radiosity %d   emissive shape %d\n",
                        l.affect_diffuse, l.affect_specular, l.affect_radiosity,
                        l.emissive_shape_enable);
            std::printf("      cull     %.4g m   fade %.4g m   flags 0x%08x\n",
                        l.cull_distance, l.fade_distance, l.flags);
            if (l.ies_profile)
                std::printf("      ies      %s   x%.3g   as-mask %d\n",
                            leaf(l.ies_profile), l.ies_multiplier, l.ies_as_mask);
            if (l.texture)
                std::printf("      texture  %s\n", leaf(l.texture));
        }

        // ---- the fixtures that place the most light, which is the readable
        // check that these are lamps rather than noise.
        std::printf("-- busiest source partitions\n");
        std::vector<std::pair<std::string, int> > by_src;
        for (const bf6_light& l : L) {
            const std::string s = leaf(l.source);
            bool found = false;
            for (auto& kv : by_src) if (kv.first == s) { kv.second++; found = true; break; }
            if (!found) by_src.push_back(std::make_pair(s, 1));
        }
        std::sort(by_src.begin(), by_src.end(),
                  [](const std::pair<std::string, int>& x,
                     const std::pair<std::string, int>& y) { return x.second > y.second; });
        for (size_t i = 0; i < by_src.size() && i < 8; i++)
            std::printf("  %-46s %d\n", by_src[i].first.c_str(), by_src[i].second);

        if (have_near) {
            struct Near { float d; const bf6_light* l; };
            std::vector<Near> near;
            for (const bf6_light& l : L) {
                const float dx = l.xform[9] - near_x;
                const float dz = l.xform[11] - near_z;
                const float d = std::sqrt(dx*dx + dz*dz);
                if (d <= near_radius) near.push_back({d, &l});
            }
            std::sort(near.begin(), near.end(),
                      [](const Near& a, const Near& b) { return a.d < b.d; });
            std::printf("-- %zu lights within %.1f m of game XZ (%.1f, %.1f)\n",
                        near.size(), near_radius, near_x, near_z);
            for (size_t i = 0; i < near.size() && i < 250; i++) {
                const bf6_light& l = *near[i].l;
                std::printf("  d%6.2f  (%8.2f,%7.2f,%8.2f) %-6s %10.6g lm  "
                            "reach %5.1f  rgb(%5.2f,%5.2f,%5.2f)  emissive-shape %d  flags %08x  %s",
                            near[i].d, l.xform[9], l.xform[10], l.xform[11],
                            kind_name(l.type), l.intensity * l.dimmer,
                            l.attenuation_radius, l.color[0], l.color[1], l.color[2],
                            l.emissive_shape_enable, l.flags, leaf(l.source));
                if (l.ies_profile) std::printf("  IES=%s x%.3g", leaf(l.ies_profile), l.ies_multiplier);
                std::printf("\n");
            }
        }

        if (!fixture.empty()) {
            std::printf("-- fixture matching \"%s\"\n", fixture.c_str());
            std::string seen;
            int shown = 0;
            for (const bf6_light& l : L) {
                if (!l.source || std::string(l.source).find(fixture) == std::string::npos) continue;
                if (seen.find("|" + std::string(leaf(l.source)) + "|") != std::string::npos) continue;
                // One PLACEMENT of each matching partition is enough: the same
                // prefab is placed hundreds of times with identical fields.
                seen += "|" + std::string(leaf(l.source)) + "|";
                for (const bf6_light& m : L) {
                    if (!m.source || std::string(leaf(m.source)) != std::string(leaf(l.source))) continue;
                    std::printf("  %-40s %-6s  %8.6g %s  range %6.3g m  cone %5.4g/%-5.4g  emitter %.4g\n",
                                leaf(m.source), kind_name(m.type), m.intensity,
                                unit_name(m.unit), m.attenuation_radius,
                                m.inner_angle, m.outer_angle,
                                m.type == BF6_LIGHT_RECT ? m.rect_height : m.shape_radius);
                    if (++shown > 40) break;
                }
                if (shown > 40) break;
            }
        }

        if (st.total <= 0 || st.total > 200000) {
            std::printf("IMPLAUSIBLE light count for %s\n", level);
            bad++;
        }
    }
    bf6_close(c);
    return bad ? 1 : 0;
}
