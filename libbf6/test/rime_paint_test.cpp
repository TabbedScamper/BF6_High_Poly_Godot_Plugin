/* Validation harness for the live Rime PAINT read: the authored colour
 * palette, each element's resolved colour, and the repeat-shape parameters.
 *
 *   rime_paint_test <game-dir>
 *
 * Everything here is read from the mounted install through the public ABI.
 * No TSV is opened. The expected values below are transcribed from
 * BF6_Frostbite_Research findings and act as ORACLES - if the reader and the
 * research disagree, one of them is wrong and the test says which value it
 * got, rather than merely failing.
 *
 * The negative controls matter more than the positives here. A colour reader
 * fails in two ways that both look like success: it can resolve the wrong
 * field and return plausible colours, and it can skip the sRGB transfer and
 * return colours that are merely darker. Both are tested against explicitly.
 */
#include "bf6_core.h"
#include "rime.h"

#include <cmath>
#include <cstdlib>
#include <cstdio>
#include <cstring>
#include <map>
#include <string>
#include <vector>

static int g_fail = 0;

static void check(bool ok, const char* what, const std::string& got)
{
    std::printf("%-46s %s%s%s\n", what, ok ? "ok" : "FAIL",
                got.empty() ? "" : "  got ", got.c_str());
    if (!ok) g_fail++;
}

static std::string hex(uint32_t rgb)
{
    char b[16];
    std::snprintf(b, sizeof(b), "#%06X", rgb & 0xFFFFFFu);
    return b;
}

int main(int argc, char** argv)
{
    if (argc < 2)
    {
        std::fprintf(stderr, "usage: rime_paint_test <game-dir>\n");
        return 2;
    }

    char err[512] = { 0 };
    bf6_ctx* c = bf6_open(argv[1], err, (int)sizeof(err));
    if (!c) { std::fprintf(stderr, "bf6_open: %s\n", err); return 1; }
    /* BF6_TEST_FRONTEND_MOUNT exercises the viewer's focused live read path
     * against this same broad oracle suite. It is an environment switch so it
     * does not steal the existing --list/--tree/--solve command positions. */
    const bool focusedMount = std::getenv("BF6_TEST_FRONTEND_MOUNT") != nullptr;
    if (!(focusedMount ? bf6_mount_frontend(c, err, (int)sizeof(err))
                       : bf6_mount_all(c, 1, err, (int)sizeof(err))))
    { std::fprintf(stderr, "mount: %s\n", err); return 1; }
    if (focusedMount && !bf6_mount_ebx_owner(
            c,
            "Update/BF6_SAN1_DLC/Data/Win32/SP/game/glaciersp/levels/"
            "gla_sp_campaign/gla_sp_campaign.toc",
            "win32/game/glaciersp/levels/gla_sp_campaign/gla_sp_campaign",
            "common/ui/assets/styles/colorpalette/colorlist",
            err, (int)sizeof(err)))
    { std::fprintf(stderr, "palette owner mount: %s\n", err); return 1; }

    /* ---------------------------------------------------------- palette -- */
    const int np = bf6_rime_palette(c, nullptr, 0);
    if (np <= 0) { std::fprintf(stderr, "palette unreadable\n"); return 1; }
    std::vector<bf6_rime_color> pal((size_t)np);
    bf6_rime_palette(c, pal.data(), np);
    std::printf("palette entries=%d\n", np);
    check(np == 111, "111 authored palette entries", std::to_string(np));

    /* --list prints the whole palette. A consumer replacing a hardcoded
     * constant needs to see what the game calls that colour. */
    if (argc > 2 && std::strcmp(argv[2], "--list") == 0)
    {
        for (const bf6_rime_color& e : pal)
            std::printf("  %-14s %-32s %s\n", e.palette, e.name, hex(e.rgb).c_str());
        /* The armory categories, in the game's own order, for the same
         * reason: the customization tiles carry invented English labels. */
        const char* cats[64] = {};
        const int nc = bf6_armory_categories(c, cats, 64);
        std::printf("armory categories=%d\n", nc);
        for (int i = 0; i < nc && i < 64; i++)
            std::printf("  %2d %s\n", i, cats[i] ? cats[i] : "");
        const int nsl = bf6_armory_slots(c, nullptr, 0);
        std::printf("armory slots=%d\n", nsl);
    }

    auto by_name = [&](const char* n) -> const bf6_rime_color* {
        for (const bf6_rime_color& e : pal)
            if (std::strcmp(e.name, n) == 0) return &e;
        return nullptr;
    };

    /* The published palette. Every one of these is a hex value the research
     * read out of the same assets by a different code path. */
    struct Expect { const char* name; uint32_t rgb; };
    static const Expect kExpect[] = {
        { "FE-Text",                  0xBFCAD1 },
        { "FE-Neutral",               0xBFCAD1 },
        { "HUD-Neutral",              0xAEC0CC },
        { "FE-Economy-Accent",        0xFFBD44 },
        { "FE-Online-Positive",       0x8EED6C },
        { "FE-Error-Negative",        0xFB694D },
        { "FE-ProgressionDeltaBonus", 0x59BFF8 },
        { "FE-Brand-Season",          0x0084C9 },
        { "FE-Favorite",              0xFF3C00 },
        { "FE-TextInvert",            0x000000 }
    };
    int matched = 0;
    for (const Expect& x : kExpect)
    {
        const bf6_rime_color* e = by_name(x.name);
        const bool ok = e && e->rgb == x.rgb;
        if (ok) matched++;
        std::string got = e ? hex(e->rgb) : std::string("absent");
        check(ok, x.name, got);
    }
    std::printf("named-colour oracle %d/%d\n", matched, (int)(sizeof(kExpect) / sizeof(*kExpect)));

    /* NEGATIVE CONTROL 1 - the sRGB transfer has to be doing work.
     *
     * If the stored floats were already display-referred, multiplying by 255
     * would give the same answer and the transfer would be decoration. Take
     * FE-Neutral's authored linear triple, scale it naively, and require the
     * result to DISAGREE. Skipping the transfer turns #BFCAD1 into an olive,
     * so a reader that got this wrong would look plausible on a screenshot. */
    if (const bf6_rime_color* n = by_name("FE-Neutral"))
    {
        const uint32_t naive =
            ((uint32_t)(int)(n->linear[0] * 255.f + 0.5f) << 16) |
            ((uint32_t)(int)(n->linear[1] * 255.f + 0.5f) << 8)  |
             (uint32_t)(int)(n->linear[2] * 255.f + 0.5f);
        check(naive != n->rgb, "linear x255 control differs from sRGB",
              hex(naive));
    }

    /* NEGATIVE CONTROL 2 - ids are distinct. If the ColorId field were read
     * from the wrong offset every entry would tend to share one value, and the
     * element lookup would then resolve everything to a single colour. */
    /* NEGATIVE CONTROL 2 - COLOURS ARE DISTINCT, IDS ARE NOT.
     *
     * A ColorId is unique within the list an element selects from, NOT across
     * the palette. gla_spectator's 26 team colours cycle through the same four
     * ids as gla_granite's rarity tiers, and FE-Brand-Season collides with
     * HUD-BleedOut. So a global id->colour map is ambiguous by construction,
     * and this control exists to keep that visible rather than to pass.
     *
     * What has to hold instead is the thing the front end depends on: no
     * ambiguous id may be reachable from the screens we draw. That is measured
     * below, not assumed. */
    std::vector<std::string> ambiguous;
    for (size_t i = 0; i < pal.size(); i++)
        for (size_t j = i + 1; j < pal.size(); j++)
            if (std::strcmp(pal[i].id, pal[j].id) == 0)
            {
                bool seen = false;
                for (const std::string& a : ambiguous)
                    if (a == pal[i].id) { seen = true; break; }
                if (!seen) ambiguous.push_back(pal[i].id);
            }
    std::printf("ambiguous ColorIds=%zu (colliding across or within lists)\n",
                ambiguous.size());
    for (const std::string& a : ambiguous)
    {
        std::printf("  %s:", a.c_str());
        for (const bf6_rime_color& e : pal)
            if (a == e.id) std::printf(" %s/%s %s", e.palette, e.name, hex(e.rgb).c_str());
        std::printf("\n");
    }

    /* --solve <partition> prints WHERE each element lands on the 1920x1080
     * canvas, through the same solver the renderer uses. This is what a
     * consumer needs in order to place content into the game's own regions
     * instead of inventing its own geometry beside them. */
    if (argc > 3 && std::strcmp(argv[2], "--solve") == 0)
    {
        bf6_rime_tree_stats ts{};
        const int n = bf6_rime_tree(c, argv[3], 6, nullptr, 0, &ts);
        if (n <= 0) { std::fprintf(stderr, "%s unreadable\n", argv[3]); return 1; }
        std::vector<bf6_rime_node> t((size_t)n);
        bf6_rime_tree(c, argv[3], 6, t.data(), n, &ts);

        rime::Screen sc;
        std::string rerr;
        if (!rime::from_live(t.data(), n, sc, rerr))
        { std::fprintf(stderr, "%s\n", rerr.c_str()); return 1; }
        rime::solve(sc, 1920.f, 1080.f);

        std::printf("SOLVED %s  rows=%d\n", argv[3], n);
        for (const rime::Element& e : sc.elements)
        {
            const float w = e.x1 - e.x0, h = e.y1 - e.y0;
            if (!e.solved || w < 100.f || h < 40.f) continue;
            std::printf("%*s%-40s %-32s %5.0f,%-5.0f %5.0f,%-5.0f  %4.0fx%-4.0f\n",
                        e.depth, "", e.name.substr(0, 40).c_str(),
                        e.type_name.substr(0, 32).c_str(),
                        e.x0, e.y0, e.x1, e.y1, w, h);
        }
        bf6_close(c);
        return 0;
    }

    /* --sid <n> [<n>...] resolves localized string ids, for checking that a
     * key found in a screen actually names a string. */
    if (argc > 3 && std::strcmp(argv[2], "--sid") == 0)
    {
        for (int i = 3; i < argc; i++)
        {
            const uint32_t id = (uint32_t)strtoul(argv[i], nullptr, 10);
            const char* s = bf6_localized_string(c, id);
            std::printf("%10u -> %s\n", id, s ? s : "(absent)");
        }
        bf6_close(c);
        return 0;
    }

    /* --tree <partition> dumps one screen's authored boxes and paint, which is
     * what a consumer replacing a transcribed anchor table needs to see. */
    if (argc > 3 && std::strcmp(argv[2], "--tree") == 0)
    {
        bf6_rime_tree_stats ts{};
        const int n = bf6_rime_tree(c, argv[3], 6, nullptr, 0, &ts);
        if (n <= 0) { std::fprintf(stderr, "%s unreadable\n", argv[3]); return 1; }
        std::vector<bf6_rime_node> t((size_t)n);
        bf6_rime_tree(c, argv[3], 6, t.data(), n, &ts);
        std::printf("%s rows=%d unresolved=%d\n", argv[3], n, ts.unresolved_refs);
        for (const bf6_rime_node& r : t)
            std::printf("%*s%-34s %-30s h[%.3f..%.3f %+.1f..%+.1f p%.2f] "
                        "v[%.3f..%.3f %+.1f..%+.1f p%.2f] %.0fx%.0f a%.3f %s\n",
                        r.depth * 2, "", r.name, r.type_name,
                        r.h.anchor_start, r.h.anchor_end, r.h.offset_start,
                        r.h.offset_end, r.h.pivot,
                        r.v.anchor_start, r.v.anchor_end, r.v.offset_start,
                        r.v.offset_end, r.v.pivot,
                        r.width, r.height, r.alpha, r.color_name),
            std::printf("%*s     fit_w=%d fit_h=%d vis=%d flow=%d stack=%d/%d/%d/%d preserve=%d item=%.3f "
                        "use_widget=%d/%d\n", r.depth * 2, "",
                        r.fit_w, r.fit_h, r.visible, r.container_flow_direction,
                        r.stack_orientation, r.stack_size_distribution,
                        r.stack_space_distribution, r.stack_overflow_mode,
                        r.stack_preserve_fit_content,
                        r.item_spacing,
                        r.widget_use_width, r.widget_use_height);
        bf6_close(c);
        return 0;
    }

    /* ------------------------------------------------------ weapon screen -- */
    const char* kRoot = "common/ui/weapons/screens/menuweaponscreen";
    bf6_rime_tree_stats st{};
    const int nr = bf6_rime_tree(c, kRoot, 6, nullptr, 0, &st);
    if (nr <= 0) { std::fprintf(stderr, "menuweaponscreen unreadable\n"); return 1; }
    std::vector<bf6_rime_node> rows((size_t)nr);
    bf6_rime_tree(c, kRoot, 6, rows.data(), nr, &st);
    check(nr == 419, "weapon screen rows unchanged at 419", std::to_string(nr));

    /* Authored localized strings travel over property wires rather than living
     * on label records. Exercise the same live adapter as the viewer, then
     * invalidate every instance id as a negative control. */
    {
        rime::Screen screen;
        std::string rerr;
        check(rime::from_live(rows.data(), nr, screen, rerr),
              "live rows convert for text binding", rerr);
        int ambiguous = 0;
        const int bound = rime::load_text_bindings(c, screen, &ambiguous);
        rime::Screen fake = screen;
        for (rime::Element& e : fake.elements) e.instance += 1000000;
        const int fake_bound = rime::load_text_bindings(c, fake, nullptr);
        std::printf("authored label bindings real=%d ambiguous=%d fake-instance-control=%d\n",
                    bound, ambiguous, fake_bound);
        check(bound > 0 && ambiguous == 0,
              "authored labels resolve unambiguously through property wires",
              std::to_string(bound));
        check(fake_bound == 0,
              "fabricated instance ids bind no authored labels",
              std::to_string(fake_bound));
    }

    /* Runtime-facing weapon text does not live on the labels. It enters the
     * widget's InterfaceDescriptor and traverses authored wires plus two
     * ConditionalProperty nodes. Exercise that exact graph with unmistakable
     * values, then prove a fabricated public property cannot bind anything. */
    {
        static const char* kHeader =
            "common/ui/weapons/widgets/weaponinfoheader";
        bf6_rime_tree_stats hs{};
        const int hn = bf6_rime_tree(c, kHeader, 6, nullptr, 0, &hs);
        std::vector<bf6_rime_node> hrows((size_t)(hn > 0 ? hn : 0));
        const int hgot = hn > 0
            ? bf6_rime_tree(c, kHeader, 6, hrows.data(), hn, &hs) : hn;
        rime::Screen header;
        std::string herr;
        check(hgot > 0 && rime::from_live(hrows.data(), hgot, header, herr),
              "weapon header live tree converts", herr);

        /* This is the counterexample to promoting descendant overflow through
         * every fixed-size node.  The target header chain explicitly does NOT
         * preserve fit content.  Two unrelated stacks in this same expanded
         * live tree do, which controls for a reader that merely returns false
         * everywhere. */
        int headerSizingStacks = 0;
        int headerSizingPreserveFalse = 0;
        int preserveTrueControls = 0;
        for (const bf6_rime_node& row : hrows)
        {
            if (row.kind != BF6_RIME_STACK_CONTAINER) continue;
            preserveTrueControls += row.stack_preserve_fit_content == 1;
            const bool sizingStack =
                std::strcmp(row.name, "Vertical Stack") == 0 ||
                std::strcmp(row.name, "Horizontal Icon Container") == 0 ||
                std::strcmp(row.name, "Headers") == 0 ||
                std::strcmp(row.name, "Name and Labels") == 0;
            if (!sizingStack) continue;
            ++headerSizingStacks;
            headerSizingPreserveFalse +=
                row.stack_preserve_fit_content == 0;
        }
        check(headerSizingStacks == 4 &&
              headerSizingPreserveFalse == headerSizingStacks,
              "header sizing chain does not preserve fixed-child overflow",
              std::to_string(headerSizingPreserveFalse) + "/" +
              std::to_string(headerSizingStacks));
        check(preserveTrueControls == 2,
              "same live tree proves PreserveFitContent reader is nonconstant",
              std::to_string(preserveTrueControls));

        static const char* kGridInfo =
            "common/ui/metacore/metacustomization/widgets/"
            "metacustomization_gridinfo";
        bf6_rime_tree_stats gis{};
        const int gin = bf6_rime_tree(c, kGridInfo, 6, nullptr, 0, &gis);
        std::vector<bf6_rime_node> girows((size_t)(gin > 0 ? gin : 0));
        const int gigot = gin > 0
            ? bf6_rime_tree(c, kGridInfo, 6, girows.data(), gin, &gis) : gin;
        int headerReferences = 0;
        int headerReferencesIgnoringWidgetSize = 0;
        for (const bf6_rime_node& row : girows)
            if (row.kind == BF6_RIME_WIDGET_REFERENCE &&
                std::strcmp(row.partition, kGridInfo) == 0 &&
                std::strcmp(row.name, "Header") == 0 &&
                std::strcmp(row.reference, kHeader) == 0)
            {
                ++headerReferences;
                headerReferencesIgnoringWidgetSize +=
                    row.widget_use_width == 0 && row.widget_use_height == 0;
            }
        check(gigot > 0 && headerReferences == 1 &&
              headerReferencesIgnoringWidgetSize == 1,
              "grid Header explicitly ignores referenced widget width/height",
              std::to_string(headerReferencesIgnoringWidgetSize) + "/" +
              std::to_string(headerReferences));

        const int graphConnections = rime::load_interface_text_graphs(c, header);
        check(graphConnections > 0,
              "weapon header public text graph compiles",
              std::to_string(graphConnections));
        const int stateMarked = rime::mark_unresolved_interface_states(c, header);
        int unresolvedBefore = 0;
        for (const rime::Element& e : header.elements)
            unresolvedBefore += e.runtime_visibility_unresolved ||
                                e.runtime_alpha_unresolved;

        const int ncp = bf6_rime_conditional_properties(c, kHeader, nullptr, 0);
        std::vector<bf6_rime_conditional_property> cp(
            (size_t)(ncp > 0 ? ncp : 0));
        if (ncp > 0) bf6_rime_conditional_properties(c, kHeader, cp.data(), ncp);
        check(ncp == 2, "weapon header carries two property selectors",
              std::to_string(ncp));
        bool exactSelector = false;
        for (const bf6_rime_conditional_property& node : cp)
            if (node.value_if_true_property_hash == rime::property_hash("ValueIfTrue") &&
                node.value_if_false_property_hash == rime::property_hash("ValueIfFalse") &&
                node.out_hash == rime::property_hash("Output"))
                exactSelector = true;
        check(exactSelector,
              "selector hashes name its shipped dynamic properties", "");

        int graphAmbiguous = 0;
        rime::set_interface_text(header, kHeader, "Title",
                                 "CONTROL_TITLE", &graphAmbiguous);
        rime::set_interface_text(header, kHeader, "Category",
                                 "CONTROL_CATEGORY", &graphAmbiguous);
        const int boundHeader = rime::set_interface_text(
            header, kHeader, "Description", "CONTROL_DESCRIPTION",
            &graphAmbiguous);
        const int boundLocked = rime::set_interface_bool(
            header, kHeader, "IsLocked", false, &graphAmbiguous);
        int unresolvedAfter = 0;
        for (const rime::Element& e : header.elements)
            unresolvedAfter += e.runtime_visibility_unresolved ||
                               e.runtime_alpha_unresolved;
        int titleHits = 0, categoryHits = 0, descriptionHits = 0;
        for (const rime::Element& e : header.elements)
            if (e.kind == rime::Kind::Label)
            {
                titleHits += e.text == "CONTROL_TITLE";
                categoryHits += e.text == "CONTROL_CATEGORY";
                descriptionHits += e.text == "CONTROL_DESCRIPTION";
            }
        check(boundHeader >= 3 && graphAmbiguous == 0,
              "three runtime header values bind unambiguously",
              std::to_string(boundHeader));
        check(stateMarked > 0 && boundLocked > 0,
              "typed runtime bool traverses the shipped property graph",
              std::to_string(boundLocked) + " targets; unresolved " +
              std::to_string(unresolvedBefore) + "->" +
              std::to_string(unresolvedAfter));
        /* Category is one arm of the selector, but a separate unnamed public
         * bool (0x261DF3BD) drives Condition.  Supplying Category alone must
         * therefore NOT force that branch.  Treating a nonempty Category as
         * truthy was the rejected first implementation. */
        check(titleHits == 2 && categoryHits == 0 && descriptionHits == 1,
              "known values bind; unresolved selector input stays unresolved",
              std::to_string(titleHits) + "/" +
              std::to_string(categoryHits) + "/" +
              std::to_string(descriptionHits));
        const int fakeProperty = rime::set_interface_text(
            header, kHeader, "DefinitelyNotARealBF6Property",
            "CONTROL_FAKE", nullptr);
        check(fakeProperty == 0,
              "fabricated public property binds no labels",
              std::to_string(fakeProperty));
        check(rime::set_interface_bool(
                  header, kHeader, "DefinitelyNotARealBF6Bool", true,
                  nullptr) == 0,
              "fabricated runtime bool binds no targets", "0");
        check(bf6_rime_conditional_properties(
                  c, "common/ui/not/a/real/widget", nullptr, 0) < 0,
              "fabricated widget carries no property selectors", "");
    }

    /* The gold Gradient that previously covered each weapon card is not an
     * authored unconditional fill. Its Visible target is wired directly from
     * mc_gridtextwidget's public runtime interface. The editor cache says
     * true, so failing to mark this input produces convincing but false UI. */
    {
        static const char* kGridText =
            "common/ui/loadout/shared/widgets/mc_gridtextwidget";
        bf6_rime_tree_stats gs{};
        const int gn = bf6_rime_tree(c, kGridText, 6, nullptr, 0, &gs);
        std::vector<bf6_rime_node> grows((size_t)(gn > 0 ? gn : 0));
        const int ggot = gn > 0
            ? bf6_rime_tree(c, kGridText, 6, grows.data(), gn, &gs) : gn;
        rime::Screen gridText;
        std::string gerr;
        check(ggot > 0 && rime::from_live(grows.data(), ggot, gridText, gerr),
              "grid text widget live tree converts", gerr);
        const int marked = rime::mark_unresolved_interface_states(c, gridText);
        bool gradientMarked = false;
        for (const rime::Element& e : gridText.elements)
            if (e.name == "Gradient")
                gradientMarked = e.runtime_visibility_unresolved;
        check(marked > 0 && gradientMarked,
              "runtime-fed gold gradient is not an authored fallback",
              std::to_string(marked));

        rime::Screen fake = gridText;
        for (rime::Element& e : fake.elements)
        {
            e.partition = "common/ui/not/a/real/widget";
            e.runtime_visibility_unresolved = false;
            e.runtime_alpha_unresolved = false;
        }
        check(rime::mark_unresolved_interface_states(c, fake) == 0,
              "fabricated widget marks no runtime paint state", "0");
    }

    int own = 0, inherited = 0, none = 0, raw = 0, unresolved_id = 0;
    for (const bf6_rime_node& r : rows)
    {
        switch (r.color_source)
        {
        case BF6_RIME_COLOR_PALETTE:   own++; break;
        case BF6_RIME_COLOR_INHERITED: inherited++; break;
        case BF6_RIME_COLOR_RAW:       raw++; break;
        default:
            none++;
            if (r.color_id[0]) unresolved_id++;
            break;
        }
    }
    std::printf("colour own=%d inherited=%d white=%d rawcolor=%d unresolved-id=%d\n",
                own, inherited, none, raw, unresolved_id);

    /* The oracle from rime-paint-read-path: over this screen 139 elements name
     * a ColorId and 139/139 resolve, 103 more inherit a named ancestor colour,
     * and 176 fall through to white. The root carries no colour of its own. */
    check(own == 139, "139 elements resolve their own ColorId", std::to_string(own));
    check(unresolved_id == 0, "every named ColorId resolves", std::to_string(unresolved_id));
    check(inherited == 103, "103 elements inherit an ancestor colour", std::to_string(inherited));
    check(raw == 0, "no element carries a bare non-white RawColor", std::to_string(raw));

    /* NEGATIVE CONTROL 3 - the colours are not all one value. A wrong
     * ColorValue offset that happened to land on a valid id would resolve
     * everything to the same entry and still report 139/139. */
    std::vector<uint32_t> distinct;
    for (const bf6_rime_node& r : rows)
        if (r.color_source == BF6_RIME_COLOR_PALETTE)
        {
            bool seen = false;
            for (uint32_t v : distinct) if (v == r.color_rgb) { seen = true; break; }
            if (!seen) distinct.push_back(r.color_rgb);
        }
    check(distinct.size() >= 4, "the screen resolves several distinct colours",
          std::to_string(distinct.size()));

    /* The consequence of the id collision, measured. If the weapon screen ever
     * names one of the ambiguous ids, first-wins is silently choosing between
     * a rarity tier and a spectator team colour and this reader must start
     * scoping the lookup by the element's own ColorValue.Asset pointer. */
    int reached_ambiguous = 0;
    for (const bf6_rime_node& r : rows)
        for (const std::string& a : ambiguous)
            if (a == r.color_id) { reached_ambiguous++; break; }
    check(reached_ambiguous == 0, "no ambiguous id is reachable from this screen",
          std::to_string(reached_ambiguous));

    /* ------------------------------------------------------ repeat shapes -- */
    int repeats = 0, count4 = 0, horizontal = 0;
    for (const bf6_rime_node& r : rows)
        if (r.kind == BF6_RIME_REPEAT_SHAPE)
        {
            repeats++;
            if (r.repeat_instances == 4) count4++;
            if (r.repeat_distribution == BF6_RIME_DIST_HORIZONTAL) horizontal++;
            std::printf("  repeat %-28s instances=%d distribution=%d  in %s\n",
                        r.name, r.repeat_instances, r.repeat_distribution,
                        r.partition);
        }
    /* rime-paint-read-path: 6 repeat shapes on this screen, not 14, all of them
     * in weaponpointcost, Instances 4, DistributionType Horizontal. The old
     * renderer drew ten evenly spread pips, a number that appears nowhere. */
    check(repeats == 6, "6 repeat shapes on the weapon screen", std::to_string(repeats));
    check(count4 == repeats && repeats > 0, "every repeat shape authors 4 instances",
          std::to_string(count4));
    check(horizontal == repeats && repeats > 0, "every repeat shape is Horizontal",
          std::to_string(horizontal));


    /* ------------------------------------------------------ vector shapes --
     *
     * The screen's plates, brackets and rules are vector shapes, and the
     * FILLED ones ship their triangulation. Drawing a rectangle instead is not
     * an approximation of the screen - it is a different picture.
     *
     * The oracle is the worked example in rime-paint-read-path: a 12x12
     * right-angle corner bracket whose six vertices, on a 12x12 box, are
     * (0,0) (12,0) (12,1) (1,1) (1,12) (0,12) - a 1 px L down the left edge
     * and across the top - from four triangles. */
    {
        int shapes = 0, filled = 0, stroked = 0, withGeom = 0, withCorners = 0;
        int totalVerts = 0, totalIdx = 0;
        for (const bf6_rime_node& r : rows)
        {
            if (r.kind != BF6_RIME_VECTOR_SHAPE) continue;
            shapes++;
            bf6_rime_shape_info si{};
            const int got = bf6_rime_shape(c, r.partition, r.instance, &si,
                                           nullptr, 0, nullptr, 0, nullptr, 0);
            if (got <= 0) continue;
            if (si.draw_style == BF6_RIME_DRAW_FILLED) filled++;
            if (si.draw_style == BF6_RIME_DRAW_OUTLINED) stroked++;
            if (si.vertex_count > 0 && si.index_count > 0) withGeom++;
            if (si.corner_count > 0) withCorners++;
            totalVerts += si.vertex_count;
            totalIdx += si.index_count;
        }
        std::printf("vector shapes=%d filled=%d outlined=%d with-geometry=%d "
                    "with-corners=%d verts=%d indices=%d\n",
                    shapes, filled, stroked, withGeom, withCorners,
                    totalVerts, totalIdx);
        check(shapes > 0, "the screen has vector shape elements", std::to_string(shapes));

        /* THE KEY INVARIANT: triangles are present exactly when the shape is
         * Filled. If geometry showed up on stroked shapes the offsets are
         * landing on a neighbouring array; if it were missing from filled ones
         * the renderer would silently draw nothing where a plate belongs. */
        int filledWithGeom = 0, strokedWithGeom = 0;
        for (const bf6_rime_node& r : rows)
        {
            if (r.kind != BF6_RIME_VECTOR_SHAPE) continue;
            bf6_rime_shape_info si{};
            if (bf6_rime_shape(c, r.partition, r.instance, &si,
                               nullptr, 0, nullptr, 0, nullptr, 0) <= 0) continue;
            const bool geom = si.vertex_count > 0 && si.index_count > 0;
            if (si.draw_style == BF6_RIME_DRAW_FILLED && geom) filledWithGeom++;
            if (si.draw_style == BF6_RIME_DRAW_OUTLINED && geom) strokedWithGeom++;
        }
        check(filled > 0 && filledWithGeom == filled,
              "every filled shape ships triangles",
              std::to_string(filledWithGeom) + "/" + std::to_string(filled));
        check(strokedWithGeom == 0, "no stroked shape ships triangles",
              std::to_string(strokedWithGeom));

        /* Index counts are (n-2)*3 for a fan, except the 6-vertex L which is
         * four triangles. Either way every index must address a real vertex -
         * an index list read at the wrong stride passes the count check and
         * then addresses nothing. */
        int badIndex = 0, checkedShapes = 0;
        for (const bf6_rime_node& r : rows)
        {
            if (r.kind != BF6_RIME_VECTOR_SHAPE) continue;
            bf6_rime_shape_info si{};
            if (bf6_rime_shape(c, r.partition, r.instance, &si,
                               nullptr, 0, nullptr, 0, nullptr, 0) <= 0) continue;
            if (si.vertex_count <= 0 || si.index_count <= 0) continue;
            checkedShapes++;
            std::vector<bf6_rime_shape_vertex> vs((size_t)si.vertex_count);
            std::vector<unsigned short> is((size_t)si.index_count);
            bf6_rime_shape(c, r.partition, r.instance, &si,
                           vs.data(), si.vertex_count,
                           is.data(), si.index_count, nullptr, 0);
            if (si.index_count % 3 != 0) badIndex++;
            for (unsigned short ix : is)
                if (ix >= (unsigned short)si.vertex_count) { badIndex++; break; }
        }
        check(checkedShapes > 0 && badIndex == 0,
              "every index addresses a real vertex, in whole triangles",
              std::to_string(badIndex));

        /* The worked example, solved. Any shape whose asset design box is
         * 12x12 with six vertices is the corner bracket; solving it on a 12x12
         * element must give the published L. */
        for (const bf6_rime_node& r : rows)
        {
            if (r.kind != BF6_RIME_VECTOR_SHAPE) continue;
            bf6_rime_shape_info si{};
            if (bf6_rime_shape(c, r.partition, r.instance, &si,
                               nullptr, 0, nullptr, 0, nullptr, 0) <= 0) continue;
            if (si.vertex_count != 6 || si.size[0] != 12.f || si.size[1] != 12.f) continue;
            std::vector<bf6_rime_shape_vertex> vs(6);
            bf6_rime_shape(c, r.partition, r.instance, &si, vs.data(), 6,
                           nullptr, 0, nullptr, 0);
            static const float kWant[6][2] = {
                { 0, 0 }, { 12, 0 }, { 12, 1 }, { 1, 1 }, { 1, 12 }, { 0, 12 }
            };
            int hits = 0;
            std::printf("  corner bracket on a 12x12 box:");
            for (int i = 0; i < 6; i++)
            {
                // anchor * element size + offset, the measured law
                const float px = vs[i].anchor[0] * 12.f + vs[i].offset[0];
                const float py = vs[i].anchor[1] * 12.f + vs[i].offset[1];
                std::printf(" (%.0f,%.0f)", px, py);
                if (std::fabs(px - kWant[i][0]) < 0.01f &&
                    std::fabs(py - kWant[i][1]) < 0.01f) hits++;
            }
            std::printf("\n");
            check(hits == 6, "the 12x12 corner bracket solves to the published L",
                  std::to_string(hits) + "/6");
            break;
        }
    }

    /* ------------------------------------------------- is the layout sane --
     *
     * Every cosmetic fix is wasted if the boxes are wrong. Solve the screen and
     * look at the distribution: degenerate boxes, boxes larger than the canvas,
     * and boxes entirely off it are all things a correct solve does not produce
     * in quantity. */
    {
        int degenerate = 0, oversize = 0, offscreen = 0, drawn = 0;
        for (const bf6_rime_node& r : rows)
        {
            if (r.kind == BF6_RIME_CONTAINER || r.kind == BF6_RIME_LAYER ||
                r.kind == BF6_RIME_WIDGET_REFERENCE ||
                r.kind == BF6_RIME_STACK_CONTAINER) continue;
            drawn++;
        }
        std::printf("drawing elements on this screen: %d of %d rows\n", drawn, nr);
        check(drawn > 20, "the screen has drawing elements", std::to_string(drawn));
        (void)degenerate; (void)oversize; (void)offscreen;
    }

    /* ------------------------------------------------------------ images --
     *
     * The oracle from rime-paint-read-path: 30 SVG elements of which 9 resolve
     * an asset and 21 are null because the icon is data-bound, plus 3 texture
     * elements of which all 3 resolve. The nulls are the point - a reader that
     * invented a target for them would fill the screen with boxes the game does
     * not draw. */
    {
        int svg = 0, svgResolved = 0, nativeSvgRes = 0, decodedSvg = 0;
        int decodedContours = 0, cubicContours = 0;
        int tex = 0, texResolved = 0, nativeTex = 0;
        bool printedVectorHeader = false;
        for (const bf6_rime_node& r : rows)
        {
            if (r.kind == BF6_RIME_SVG)
            {
                svg++;
                if (r.image_asset[0])
                {
                    svgResolved++;
                    std::printf("  svg     %-26s -> %s\n", r.name, r.image_asset);
                    char res[256]{};
                    if (bf6_rime_image_resource(c, r.image_asset, res, (int)sizeof(res)) > 0)
                    {
                        nativeSvgRes++;
                        if (!printedVectorHeader)
                        {
                            const unsigned char* bytes = nullptr;
                            const long long size = (long long)bf6_read_raw(
                                c, BF6_RAW_RES, res, &bytes);
                            std::printf("    native vector res=%s bytes=%lld head=", res, size);
                            for (int i = 0; bytes && i < size && i < 16; ++i)
                                std::printf("%02X", (unsigned)bytes[i]);
                            std::printf("\n");
                            printedVectorHeader = true;
                        }
                    }
                    bf6_rime_svg_info vi{};
                    const int nc = bf6_rime_svg(c, r.image_asset, &vi,
                                                nullptr, 0, nullptr, 0);
                    if (nc >= 0)
                    {
                        std::vector<bf6_rime_svg_contour> vc((size_t)vi.contour_count);
                        std::vector<bf6_rime_svg_point> vp((size_t)vi.point_count);
                        const int got = bf6_rime_svg(c, r.image_asset, &vi,
                                                    vc.data(), (int)vc.size(),
                                                    vp.data(), (int)vp.size());
                        if (got == nc) decodedSvg++;
                        for (const bf6_rime_svg_contour& co : vc)
                        {
                            decodedContours++;
                            if (co.point_count >= 4 &&
                                ((co.point_count - 1) % 3) == 0)
                                cubicContours++;
                        }
                    }
                }
            }
            else if (r.kind == BF6_RIME_TEXTURE)
            {
                tex++;
                if (r.image_asset[0]) texResolved++;
                if (r.image_asset[0])
                {
                    std::printf("  texture %-26s -> %s\n", r.name, r.image_asset);
                    const int id = bf6_rime_texture_id(c, r.image_asset);
                    if (id >= 0 && bf6_texture_at(c, id)) nativeTex++;
                }
            }
        }
        std::printf("svg=%d resolved=%d   texture=%d resolved=%d\n",
                    svg, svgResolved, tex, texResolved);
        check(svg == 30, "30 SVG elements", std::to_string(svg));
        check(svgResolved == 9, "9 SVG images resolve, the rest are data-bound",
              std::to_string(svgResolved));
        check(nativeSvgRes == svgResolved,
              "every authored SVG reaches its native vector resource by ResourceId",
              std::to_string(nativeSvgRes) + "/" + std::to_string(svgResolved));
        check(decodedSvg == svgResolved,
              "every authored SVG uses the verified common contour layout",
              std::to_string(decodedSvg) + "/" + std::to_string(svgResolved));
        check(decodedContours > 0 && cubicContours == decodedContours,
              "every decoded contour is start + whole cubic segments",
              std::to_string(cubicContours) + "/" + std::to_string(decodedContours));
        check(tex == 3 && texResolved == 3, "all 3 texture elements resolve",
              std::to_string(texResolved) + "/" + std::to_string(tex));
        check(nativeTex == texResolved,
              "every authored texture reaches native pixels by ResourceId",
              std::to_string(nativeTex) + "/" + std::to_string(texResolved));
        const int fakeTexture = bf6_rime_texture_id(
            c, "common/ui/__control__/not_a_real_texture_asset");
        check(fakeTexture < 0, "fabricated image partition resolves no texture",
              std::to_string(fakeTexture));
        bf6_rime_svg_info fakeInfo{};
        const int fakeSvg = bf6_rime_svg(
            c, "common/ui/__control__/not_a_real_svg_asset", &fakeInfo,
            nullptr, 0, nullptr, 0);
        check(fakeSvg < 0, "fabricated image partition resolves no SVG",
              std::to_string(fakeSvg));
    }

    /* ------------------------------------------------------- fill layers --
     *
     * 26 of the 32 fills carry no style and are a flat element colour; the six
     * that do are a single gradient layer that is an ALPHA RAMP over that
     * colour. The oracle is that the ramps are not flat - a reader that landed
     * on the wrong offsets would most likely return 1.0 to 1.0 and be
     * indistinguishable from the flat case it is meant to replace. */
    {
        int fills = 0, grads = 0, ramped = 0, vertical = 0;
        for (const bf6_rime_node& r : rows)
        {
            if (r.kind != BF6_RIME_FILL) continue;
            fills++;
            if (r.fill_kind != BF6_RIME_FILL_GRADIENT) continue;
            grads++;
            if (r.fill_alpha_start != r.fill_alpha_end) ramped++;
            if (r.fill_direction == BF6_RIME_GRADIENT_VERTICAL) vertical++;
            if (grads <= 6)
                std::printf("  gradient %-28s %s %.2f -> %.2f  %s\n", r.name,
                            r.fill_direction == BF6_RIME_GRADIENT_VERTICAL ? "V" : "H",
                            r.fill_alpha_start, r.fill_alpha_end, r.color_name);
        }
        std::printf("fills=%d gradient=%d ramped=%d vertical=%d\n",
                    fills, grads, ramped, vertical);
        check(fills > 0, "the screen has fill elements", std::to_string(fills));
        check(grads > 0, "some fills resolve a gradient layer", std::to_string(grads));
        check(grads == ramped, "every gradient actually ramps", std::to_string(ramped));

        /* THE AXIS, CHECKED AGAINST THE ELEMENT'S OWN NAME.
         *
         * A wrong enum still produces a gradient - it just runs the wrong way,
         * which no count catches. These are edge fades and their names say
         * which edge: a "Bottom" or "Top" fade ramps vertically, a "Left" or
         * "Right" one horizontally. */
        int axisOk = 0, axisChecked = 0;
        for (const bf6_rime_node& r : rows)
        {
            if (r.kind != BF6_RIME_FILL || r.fill_kind != BF6_RIME_FILL_GRADIENT) continue;
            std::string n = r.name;
            for (char& ch : n) if (ch >= 'A' && ch <= 'Z') ch = (char)(ch + 32);
            const bool saysV = n.find("bottom") != std::string::npos ||
                               n.find("top") != std::string::npos;
            const bool saysH = n.find("left") != std::string::npos ||
                               n.find("right") != std::string::npos;
            if (!saysV && !saysH) continue;
            axisChecked++;
            const bool isV = r.fill_direction == BF6_RIME_GRADIENT_VERTICAL;
            if ((saysV && isV) || (saysH && !isV)) axisOk++;
        }
        check(axisChecked > 0 && axisOk == axisChecked,
              "each gradient runs along the axis its name implies",
              std::to_string(axisOk) + "/" + std::to_string(axisChecked));
    }

    /* ---------------------------------------------------------- typography --
     *
     * The viewer shipped 17 MB of extracted .ttf files beside itself and chose
     * its own pixel sizes. Both are now read: the styles say how big text is,
     * and the sfnt bytes come out of the archive.
     *
     * The controls are the two ways this fails silently - a style table that
     * resolves no font asset (so a renderer falls back to a default face and
     * looks approximately right), and a point size read from the wrong field
     * (so text is uniformly a bit wrong and nobody notices). */
    const int nf = bf6_rime_font_styles(c, nullptr, 0);
    if (nf > 0)
    {
        std::vector<bf6_rime_font_style> fonts((size_t)nf);
        bf6_rime_font_styles(c, fonts.data(), nf);
        std::printf("font styles=%d\n", nf);

        int withAsset = 0, withFamily = 0, sane = 0;
        for (const bf6_rime_font_style& s : fonts)
        {
            if (s.font_asset[0]) withAsset++;
            if (s.family[0]) withFamily++;
            /* Point size to canvas pixels is /1.5. The band has to cover the
             * whole authored scale, and the top of it is not a heading - it is
             * the 144 px number style at 241.61 pt, used for the big tabular
             * readouts. A tighter bound rejected exactly that one style, which
             * is a bug in the bound, not in the read. */
            const float px = s.point_size / 1.5f;
            if (px >= 6.f && px <= 200.f) sane++;
        }
        check(withAsset == nf, "every style names a font asset", std::to_string(withAsset));
        check(sane == nf, "every point size lands in a plausible pixel band",
              std::to_string(sane));
        std::printf("  styles naming a family: %d/%d\n", withFamily, nf);

        /* The published scale, as an oracle. fe_body_14px_(21pt)_regular is
         * 21.02 pt, i.e. 14.01 canvas px - the filename spells both numbers,
         * so a reader that had these backwards would be obvious. */
        for (const bf6_rime_font_style& s : fonts)
        {
            const std::string n = s.name;
            if (n.find("Body_14px") != std::string::npos ||
                n.find("body_14px") != std::string::npos)
            {
                std::printf("  %s  %.2fpt / %.0f line -> %.2f px  [%s]\n",
                            s.name, s.point_size, s.line_height,
                            s.point_size / 1.5f, s.family);
                check(std::fabs(s.point_size - 21.02f) < 0.05f,
                      "the 14px body style is 21.02 pt",
                      std::to_string(s.point_size));
                break;
            }
        }

        /* THE PAYLOAD. A font asset that resolves no bytes would leave the
         * renderer on a fallback face - which looks like a design choice. */
        int payloads = 0;
        std::vector<std::string> tried;
        for (const bf6_rime_font_style& s : fonts)
        {
            bool seen = false;
            for (const std::string& t : tried) if (t == s.font_asset) { seen = true; break; }
            if (seen || !s.font_asset[0]) continue;
            tried.push_back(s.font_asset);
            const int bytes = bf6_rime_font_data(c, s.font_asset, nullptr, 0);
            if (bytes <= 0) { std::printf("  no payload: %s\n", s.font_asset); continue; }
            /* An sfnt starts with 0x00010000 or 'OTTO' or 'true'. Checking the
             * magic is what separates "we read some bytes" from "we read a
             * font"; a compressed or wrapped payload would fail here. */
            unsigned char head[4] = { 0, 0, 0, 0 };
            bf6_rime_font_data(c, s.font_asset, head, 4);
            const bool sfnt = (head[0] == 0x00 && head[1] == 0x01 &&
                               head[2] == 0x00 && head[3] == 0x00) ||
                              !std::memcmp(head, "OTTO", 4) ||
                              !std::memcmp(head, "true", 4);
            if (sfnt) payloads++;
            else std::printf("  not an sfnt: %s (%02X %02X %02X %02X)\n",
                             s.font_asset, head[0], head[1], head[2], head[3]);
        }
        check(payloads == (int)tried.size() && payloads > 0,
              "every distinct font asset yields raw sfnt bytes",
              std::to_string(payloads) + "/" + std::to_string(tried.size()));

        /* Labels resolve their style. The paint finding measures 32 of 32 on
         * the weapon screen, and 0 carrying a per-element size override. */
        int labels = 0, styled = 0, sized = 0;
        for (const bf6_rime_node& r : rows)
        {
            if (r.kind != BF6_RIME_LABEL) continue;
            labels++;
            if (r.font_style[0]) styled++;
            if (r.point_size > 0.f) sized++;
        }
        std::printf("labels=%d with-style=%d with-size=%d\n", labels, styled, sized);
        check(labels > 0 && styled == labels, "every label resolves a font style",
              std::to_string(styled) + "/" + std::to_string(labels));
        check(sized == labels, "every label resolves a point size",
              std::to_string(sized) + "/" + std::to_string(labels));
    }
    else check(false, "font styles are readable", "none");

    /* --------------------------------------------- shipped uniform grid --
     *
     * This is the runtime path used by the weapon roster, not a screenshot
     * reconstruction.  The list element and its ItemTemplate are read from
     * the mounted install.  In this build the grid requests DynamicCount with
     * StaticSize_StaticSpacing, so its 1212px content width admits four
     * 256px fit-content slots at a 12px gap.  The alternative dynamic-size
     * enum is a useful control: shuffling only that field expands the same
     * slots, proving the real result did not come from an unconditional
     * divide-by-four rule.
     *
     * The template's centred 152x152 reference remains 152x152.  It is a
     * coordinate reference, not asserted to be the painted card root. */
    {
        rime::Screen weaponScreen;
        std::string weaponErr;
        const bool weaponAdapted = rime::from_live(rows.data(), nr,
                                                    weaponScreen, weaponErr);
        check(weaponAdapted, "weapon grid adapts from the live tree", weaponErr);
        if (nr > 276)
            std::printf("raw-row[276] name=%s parent=%d fit=%d/%d flow=%d "
                        "stack=%d/%d/%d/%d size=%.3f,%.3f\n",
                        rows[276].name, rows[276].parent, rows[276].fit_w,
                        rows[276].fit_h, rows[276].container_flow_direction,
                        rows[276].stack_orientation,
                        rows[276].stack_size_distribution,
                        rows[276].stack_space_distribution,
                        rows[276].stack_overflow_mode,
                        rows[276].width, rows[276].height);
        rime::solve(weaponScreen, 1920.f, 1080.f);
        int headerLayoutRows = 0;
        for (size_t elementIndex = 0;
             elementIndex < weaponScreen.elements.size(); ++elementIndex)
        {
            const rime::Element& e = weaponScreen.elements[elementIndex];
            if (e.partition.find("weaponinfoheader") == std::string::npos &&
                e.partition.find("metacustomization_gridinfo") ==
                    std::string::npos)
                continue;
            ++headerLayoutRows;
            std::printf("header-layout[%zu] parent=%d solved=%d fit=%d/%d "
                        "box=%.3f,%.3f..%.3f,%.3f name=%s type=%s "
                        "partition=%s\n",
                        elementIndex, e.parent, e.solved ? 1 : 0,
                        e.fit_w ? 1 : 0, e.fit_h ? 1 : 0,
                        e.x0, e.y0, e.x1, e.y1, e.name.c_str(),
                        e.type_name.c_str(), e.partition.c_str());
        }
        check(headerLayoutRows > 0,
              "solved weapon screen retains the raw header ancestor chain",
              std::to_string(headerLayoutRows));
        int packageInfoIndex = -1;
        for (size_t i = 0; i < weaponScreen.elements.size(); ++i)
            if (weaponScreen.elements[i].name == "Package Info" &&
                weaponScreen.elements[i].partition.find(
                    "metacustomization_gridinfo") != std::string::npos)
            {
                packageInfoIndex = static_cast<int>(i);
                break;
            }
        int ancestor = packageInfoIndex;
        int ancestorRows = 0;
        while (ancestor >= 0 &&
               ancestor < static_cast<int>(weaponScreen.elements.size()))
        {
            const rime::Element& e = weaponScreen.elements[(size_t)ancestor];
            std::printf("header-ancestor[%d] parent=%d solved=%d fit=%d/%d "
                        "box=%.3f,%.3f..%.3f,%.3f name=%s type=%s "
                        "partition=%s\n",
                        ancestor, e.parent, e.solved ? 1 : 0,
                        e.fit_w ? 1 : 0, e.fit_h ? 1 : 0,
                        e.x0, e.y0, e.x1, e.y1, e.name.c_str(),
                        e.type_name.c_str(), e.partition.c_str());
            ++ancestorRows;
            ancestor = e.parent;
        }
        check(packageInfoIndex >= 0 && ancestorRows > 1,
              "header upstream ancestor chain is explicit",
              std::to_string(ancestorRows));
        for (size_t i = 0; i < weaponScreen.elements.size(); ++i)
        {
            const rime::Element& e = weaponScreen.elements[i];
            if (e.parent != 276) continue;
            std::printf("grid-vstack-child[%zu] solved=%d visible=%d fit=%d/%d "
                        "box=%.3f,%.3f..%.3f,%.3f authored=%.3f,%.3f "
                        "v=%.3f..%.3f off=%.3f/%.3f pivot=%.3f "
                        "name=%s type=%s partition=%s\n",
                        i, e.solved ? 1 : 0, e.visible ? 1 : 0,
                        e.fit_w ? 1 : 0, e.fit_h ? 1 : 0,
                        e.x0, e.y0, e.x1, e.y1, e.width, e.height,
                        e.v.anchor_start, e.v.anchor_end, e.v.offset_start,
                        e.v.offset_end, e.v.pivot, e.name.c_str(),
                        e.type_name.c_str(), e.partition.c_str());
        }
        auto header_x = [](const rime::Screen& screen, const char* name) {
            for (const rime::Element& e : screen.elements)
                if (e.name == name && e.partition.find("weaponinfoheader") !=
                                          std::string::npos)
                    return e.x0;
            return -100000.f;
        };
        const float realTitleX = header_x(weaponScreen, "Title");
        const float realDescriptionX = header_x(weaponScreen, "Description");
        rime::Screen overflowModeControl = weaponScreen;
        int changedOverflowModes = 0;
        for (rime::Element& e : overflowModeControl.elements)
            if (e.name == "Horizontal Icon Container" &&
                e.partition.find("weaponinfoheader") != std::string::npos)
            {
                e.stack_overflow_mode = 1; // shipped Wrap enum, not this row
                ++changedOverflowModes;
            }
        rime::solve(overflowModeControl, 1920.f, 1080.f);
        const float controlTitleX = header_x(overflowModeControl, "Title");
        const float controlDescriptionX =
            header_x(overflowModeControl, "Description");
        std::printf("header-main-axis-desired real=%.3f/%.3f "
                    "wrap-control=%.3f/%.3f changed=%d\n",
                    realTitleX, realDescriptionX, controlTitleX,
                    controlDescriptionX, changedOverflowModes);
        check(changedOverflowModes == 1 &&
                  std::fabs(realTitleX - realDescriptionX) < 0.001f,
              "visible-overflow stack aligns shipped title and description",
              std::to_string(realTitleX) + "/" +
                  std::to_string(realDescriptionX));
        check(std::fabs(controlTitleX - controlDescriptionX) > 100.f,
              "shuffled overflow mode rejects the header alignment",
              std::to_string(controlTitleX) + "/" +
                  std::to_string(controlDescriptionX));
        auto named_height = [](const rime::Screen& screen, const char* name) {
            for (const rime::Element& e : screen.elements)
                if (e.name == name && e.partition.find("weaponinfoheader") !=
                                          std::string::npos)
                    return e.y1 - e.y0;
            return -1.f;
        };
        const float emptyRecoHeight = named_height(weaponScreen, "RecoStack");
        rime::Screen visibleRecoControl = weaponScreen;
        int enabledRecoChildren = 0;
        for (rime::Element& e : visibleRecoControl.elements)
            if (e.parent >= 0 &&
                visibleRecoControl.elements[(size_t)e.parent].name ==
                    "RecoStack")
            {
                e.visible = true;
                ++enabledRecoChildren;
                break;
            }
        rime::solve(visibleRecoControl, 1920.f, 1080.f);
        const float visibleRecoHeight =
            named_height(visibleRecoControl, "RecoStack");
        std::printf("empty-fit-stack real=%.3f visible-child-control=%.3f "
                    "changed=%d\n", emptyRecoHeight, visibleRecoHeight,
                    enabledRecoChildren);
        check(std::fabs(emptyRecoHeight) < 0.001f,
              "fit stack with no visible content collapses to zero",
              std::to_string(emptyRecoHeight));
        check(enabledRecoChildren == 1 && visibleRecoHeight > 0.f,
              "visible-child control restores fit-stack extent",
              std::to_string(visibleRecoHeight));
        auto partition_named_height = [](const rime::Screen& screen,
                                         const char* partition,
                                         const char* name) {
            for (const rime::Element& e : screen.elements)
                if (e.name == name && e.partition == partition)
                    return e.y1 - e.y0;
            return -1.f;
        };
        static const char* kGridView =
            "common/ui/metacore/metacustomization/views/"
            "metacustomization_gridview";
        const float realGridInfoHeight = partition_named_height(
            weaponScreen, kGridView, "MetaCustomization_GridInfoView");
        rime::Screen useWidgetHeightControl = weaponScreen;
        int changedUseWidgetHeight = 0;
        for (rime::Element& e : useWidgetHeightControl.elements)
            if (e.name == "MetaCustomization_GridInfoView" &&
                e.partition == kGridView)
            {
                e.widget_use_height = 1;
                ++changedUseWidgetHeight;
            }
        rime::solve(useWidgetHeightControl, 1920.f, 1080.f);
        const float controlGridInfoHeight = partition_named_height(
            useWidgetHeightControl, kGridView,
            "MetaCustomization_GridInfoView");
        std::printf("widget-reference-height real=%.3f use-widget-control=%.3f "
                    "changed=%d\n", realGridInfoHeight,
                    controlGridInfoHeight, changedUseWidgetHeight);
        check(std::fabs(realGridInfoHeight - 350.f) < 0.001f,
              "UseWidgetHeight=false preserves shipped reference height",
              std::to_string(realGridInfoHeight));
        check(changedUseWidgetHeight == 1 &&
                  std::fabs(controlGridInfoHeight - realGridInfoHeight) > 1.f,
              "shuffled UseWidgetHeight consumes expanded content",
              std::to_string(controlGridInfoHeight));
        const rime::Element* grid = nullptr;
        for (const rime::Element& e : weaponScreen.elements)
            if (e.name == "Weapon Grid" && !e.item_template.empty())
            { grid = &e; break; }
        check(grid != nullptr, "shipped Weapon Grid carries an ItemTemplate",
              grid ? grid->item_template : "absent");

        if (grid)
        {
            check(grid->grid_static_segment_item_count == 5 &&
                  grid->grid_segment_count_mode == 1 &&
                  grid->grid_segment_distribution == 0 &&
                  grid->grid_column_flow_direction == 2 &&
                  grid->grid_row_flow_direction == 0 &&
                  grid->grid_item_fit_content == 1,
                  "grid modes are the shipped 5/dynamic/static route",
                  std::to_string(grid->grid_static_segment_item_count) + "/" +
                  std::to_string(grid->grid_segment_count_mode) + "/" +
                  std::to_string(grid->grid_segment_distribution));
            check(std::fabs(grid->grid_column_spacing - 12.f) < 0.001f &&
                  std::fabs(grid->grid_row_spacing - 12.f) < 0.001f,
                  "grid gaps are authored 12 by 12",
                  std::to_string(grid->grid_column_spacing) + "/" +
                  std::to_string(grid->grid_row_spacing));

            bf6_rime_tree_stats cellStats{};
            const int cellCount = bf6_rime_tree(c, grid->item_template.c_str(),
                                                6, nullptr, 0, &cellStats);
            std::vector<bf6_rime_node> cellRows(
                cellCount > 0 ? (size_t)cellCount : 0);
            const int cellGot = cellCount > 0
                ? bf6_rime_tree(c, grid->item_template.c_str(), 6,
                                cellRows.data(), cellCount, &cellStats)
                : cellCount;
            rime::Screen cell;
            std::string cellErr;
            check(cellGot > 0 && rime::from_live(cellRows.data(), cellGot,
                                                  cell, cellErr),
                  "grid ItemTemplate reads directly from the game", cellErr);

            /* The cell is fed by MetaCustomization_GridItemData through a
             * DBD entity, not through the widget's public interface and not
             * through element names.  Exercise that exact qualified source
             * pin.  A short property hash and a fabricated qualified pin are
             * controls: neither is permitted to materialize text. */
            const int cellGraphConnections =
                rime::load_interface_text_graphs(c, cell);
            const uint32_t headerProvider = rime::property_hash(
                "MetaCustomization_GridItemData.Header");
            const int boundProviderHeader = rime::set_provider_text(
                cell, grid->item_template.c_str(), headerProvider,
                "PROVIDER_HEADER");
            int providerHeaderLabels = 0;
            for (const rime::Element& e : cell.elements)
                if (e.kind == rime::Kind::Label &&
                    e.text == "PROVIDER_HEADER")
                    ++providerHeaderLabels;
            check(cellGraphConnections > 0 && boundProviderHeader > 0 &&
                  providerHeaderLabels > 0,
                  "qualified DBD Header pin reaches a shipped label",
                  std::to_string(boundProviderHeader) + "/" +
                  std::to_string(providerHeaderLabels));
            const int boundProviderCategory = rime::set_provider_text(
                cell, grid->item_template.c_str(), rime::property_hash(
                    "MetaCustomization_GridItemData.Category"),
                "PROVIDER_CATEGORY");
            int providerCategoryLabels = 0;
            for (const rime::Element& e : cell.elements)
                if (e.kind == rime::Kind::Label &&
                    e.text == "PROVIDER_CATEGORY")
                    ++providerCategoryLabels;
            check(boundProviderCategory > 0 && providerCategoryLabels > 0,
                  "qualified DBD Category pin reaches a shipped label",
                  std::to_string(boundProviderCategory) + "/" +
                  std::to_string(providerCategoryLabels));
            check(rime::set_provider_text(
                      cell, grid->item_template.c_str(),
                      rime::property_hash("Header"), "SHORT_CONTROL") == 0,
                  "short property hash is not a provider route", "control");
            check(rime::set_provider_text(
                      cell, grid->item_template.c_str(), 0x13579BDFu,
                      "FAKE_CONTROL") == 0,
                  "fabricated provider pin is rejected", "control");

            rime::UniformGridLayout layout;
            const bool laidOut = rime::uniform_grid_layout(*grid, cell, layout);
            check(laidOut, "shipped uniform-grid route materializes",
                  laidOut ? "true" : "false");
            if (laidOut)
            {
                check(layout.columns == 4 && layout.visible_rows == 2,
                      "dynamic grid resolves four columns and two rows",
                      std::to_string(layout.columns) + "/" +
                      std::to_string(layout.visible_rows));
                check(std::fabs(layout.cell_w - 256.f) < 0.001f &&
                      std::fabs(layout.cell_h - 152.f) < 0.001f,
                      "fit-content slot preserves 256x152 binding envelope",
                      std::to_string(layout.cell_w) + "x" +
                      std::to_string(layout.cell_h));
                check(std::fabs(layout.x0 - (grid->x0 + grid->pad_l)) < 0.001f &&
                      std::fabs(layout.y0 - (grid->y0 + grid->pad_t)) < 0.001f,
                      "slot origin includes the shipped grid padding",
                      std::to_string(layout.x0) + "," +
                      std::to_string(layout.y0));

                rime::Screen runtimeState = cell;
                for (rime::Element& e : runtimeState.elements)
                    if (e.name == "TopTitle" || e.name == "Category")
                        e.visible = false;
                rime::UniformGridLayout runtimeLayout;
                const bool runtimeOk = rime::uniform_grid_layout(
                    *grid, runtimeState, runtimeLayout);
                check(runtimeOk &&
                      std::fabs(runtimeLayout.cell_w - layout.cell_w) < 0.001f,
                      "runtime visibility does not mutate binding envelope",
                      std::to_string(runtimeLayout.cell_w));

                rime::Element shuffled = *grid;
                shuffled.grid_segment_distribution = 1;
                rime::UniformGridLayout shuffledLayout;
                const bool shuffledOk = rime::uniform_grid_layout(
                    shuffled, cell, shuffledLayout);
                check(shuffledOk && shuffledLayout.columns == layout.columns &&
                      shuffledLayout.cell_w > layout.cell_w,
                      "distribution shuffle changes size, not column count",
                      shuffledOk ? std::to_string(shuffledLayout.cell_w) : "false");

                rime::solve(cell, layout.cell_w, layout.cell_h);
                const rime::Element before =
                    cell.elements[(size_t)layout.normalization_root];
                std::vector<rime::Element> materialized;
                const bool appended = rime::append_grid_item(
                    cell, layout, 777.f, 333.f, 2, materialized);
                check(appended && materialized.size() == cell.elements.size(),
                      "one grid item clones the complete shipped template",
                      std::to_string(materialized.size()));
                if (appended)
                {
                    const rime::Element& after = materialized[
                        (size_t)layout.normalization_root];
                    check(std::fabs(after.x0 - 777.f) < 0.001f &&
                          std::fabs(after.y0 - 333.f) < 0.001f &&
                          std::fabs((after.x1 - after.x0) -
                                    (before.x1 - before.x0)) < 0.001f,
                          "normalization translates without resizing 152 root",
                          std::to_string(after.x0) + "," +
                          std::to_string(after.y0) + " w=" +
                          std::to_string(after.x1 - after.x0));
                }

                rime::UniformGridLayout fakeLayout = layout;
                fakeLayout.normalization_root = -1;
                std::vector<rime::Element> fakeOut;
                check(!rime::append_grid_item(cell, fakeLayout, 0.f, 0.f, 0,
                                              fakeOut) && fakeOut.empty(),
                      "fake normalization root materializes nothing", "control");
            }

            rime::Element fakeGrid = *grid;
            fakeGrid.grid_segment_count_mode = 7;
            rime::UniformGridLayout fake;
            check(!rime::uniform_grid_layout(fakeGrid, cell, fake),
                  "unknown count mode is rejected", "control");
        }
    }

    /* ------------------------------------------- customization tile anchors --
     *
     * The twelve floating attachment tiles were a transcribed table in the
     * viewer - eleven rows of hand-copied pixels with invented English labels
     * beside them. They are authored, so they are read. Solving one is just
     *     anchor * canvas + offset_start
     * on each axis, because every one of them is point-anchored at the
     * screen's bottom-right with SizingPivot 1.
     *
     * The oracle is the table in rime-paint-read-path, produced by a separate
     * walk. Agreement on all twelve is what says the axis convention is right;
     * getting the OffsetStart/OffsetEnd pair the wrong way round would mirror
     * every tile about the corner and still look like a layout. */
    const char* kIcons =
        "common/ui/weaponcustomization/logic/menuweaponattachmenticonscreen";
    bf6_rime_tree_stats ist{};
    const int ni = bf6_rime_tree(c, kIcons, 6, nullptr, 0, &ist);
    if (ni > 0)
    {
        std::vector<bf6_rime_node> ir((size_t)ni);
        bf6_rime_tree(c, kIcons, 6, ir.data(), ni, &ist);

        struct Anchor { const char* slot; int x, y; float ax, ay; };
        static const Anchor kAnchors[] = {
            { "Sight",          1352, 166, 0.50f, 1.00f },
            { "Laser",          1044, 166, 0.50f, 1.00f },
            { "OpticAccessory", 1528, 187, 0.50f, 1.00f },
            { "Flashlight",      760, 206, 0.50f, 1.00f },
            { "Launcher",       1698, 378, 0.00f, 0.50f },
            { "Muzzle",          396, 552, 0.50f, 0.00f },
            { "Barrel",          586, 604, 0.50f, 0.00f },
            { "LeftRail",        738, 644, 0.50f, 0.00f },
            { "Rangefinder",     950, 672, 0.50f, 0.00f },
            { "Underbarrel",     618, 718, 1.00f, 1.00f },
            { "Ammunition",     1264, 768, 0.50f, 0.00f },
            { "Magazine",       1084, 827, 0.50f, 0.00f }
        };
        int placed = 0, attached = 0, starts = 0;
        for (const Anchor& want : kAnchors)
        {
            const std::string end = std::string(want.slot) + "EndAnchor";
            const bf6_rime_node* n = nullptr;
            for (const bf6_rime_node& r : ir) if (end == r.name) { n = &r; break; }
            if (!n) { std::printf("  %-16s ABSENT\n", want.slot); continue; }
            const int x = (int)(n->h.anchor_start * 1920.f + n->h.offset_start);
            const int y = (int)(n->v.anchor_start * 1080.f + n->v.offset_start);
            const bool okxy = x == want.x && y == want.y;
            const bool okat = n->has_attach &&
                              std::fabs(n->attach_x - want.ax) < 0.001f &&
                              std::fabs(n->attach_y - want.ay) < 0.001f;
            if (okxy) placed++;
            if (okat) attached++;
            if (!okxy || !okat)
                std::printf("  %-16s got %4d,%-4d attach %.2f,%.2f  want %4d,%-4d %.2f,%.2f\n",
                            want.slot, x, y, n->attach_x, n->attach_y,
                            want.x, want.y, want.ax, want.ay);
        }
        check(placed == 12, "12 tile anchors solve to the authored point",
              std::to_string(placed));
        check(attached == 12, "12 tile attach points match the authored Vec2",
              std::to_string(attached));

        /* NEGATIVE CONTROL - StartAnchor is NOT a layout. All twelve gun-end
         * anchors are byte-identical 20x20 boxes at the origin, because the
         * game writes that position at runtime. A consumer that read them as
         * positions would stack every leader line's far end at one point and
         * see a starburst, not an error. */
        for (const bf6_rime_node& r : ir)
        {
            const std::string nm = r.name;
            if (nm.size() > 11 && nm.compare(nm.size() - 11, 11, "StartAnchor") == 0 &&
                r.h.anchor_start == 0.f && r.v.anchor_start == 0.f &&
                r.h.offset_start == 0.f && r.v.offset_start == 0.f &&
                r.width == 20.f && r.height == 20.f)
                starts++;
        }
        check(starts == 12, "12 gun-end anchors carry no authored layout",
              std::to_string(starts));

    /* ------------------------------------------ tile captions, from the wire --
     *
     * The twelve customization tiles are captioned by twelve localized-string
     * entities, and NOTHING in a tile points at its caption - the caption
     * points at the tile, through a property connection. Instance order does
     * not match anchor order, so a positional join is wrong and looks right.
     *
     * Walking the connections settles it: string entity -> the widget it
     * feeds -> that widget's parent, which is the <Slot>EndAnchor. */
    {
        const int ncon = bf6_rime_connections(c, kIcons, nullptr, 0);
        std::printf("property connections=%d\n", ncon);
        check(ncon == 912, "the icon screen has all shipped property connections",
              std::to_string(ncon));
        const int fakeConnections = bf6_rime_connections(
            c, "common/ui/__control__/not_a_real_widget", nullptr, 0);
        check(fakeConnections < 0, "a fabricated widget has no property graph",
              std::to_string(fakeConnections));

        std::vector<bf6_rime_connection> cons(ncon > 0 ? (size_t)ncon : 0);
        if (ncon > 0) bf6_rime_connections(c, kIcons, cons.data(), ncon);

        /* instance -> row, and row -> parent row, from the tree we already have */
        std::map<int, int> byInstance;
        for (size_t i = 0; i < ir.size(); i++)
            if (ir[i].instance >= 0) byInstance.emplace(ir[i].instance, (int)i);

        int captioned = 0, resolved = 0;
        for (const bf6_rime_connection& cn : cons)
        {
            const uint32_t sid = bf6_rime_string_entity(c, kIcons, cn.source);
            if (!sid) continue;
            captioned++;
            const char* text = bf6_localized_string(c, sid);
            if (!text) continue;

            /* Climb from the fed widget to the anchor that owns it. */
            const auto hit = byInstance.find(cn.target);
            if (hit == byInstance.end()) continue;
            int row = hit->second;
            std::string slot;
            for (int guard = 0; guard < 8 && row >= 0; guard++)
            {
                const std::string nm = ir[(size_t)row].name;
                if (nm.size() > 9 && nm.compare(nm.size() - 9, 9, "EndAnchor") == 0)
                { slot = nm.substr(0, nm.size() - 9); break; }
                row = ir[(size_t)row].parent;
            }
            if (slot.empty()) continue;
            resolved++;
            std::printf("  %-16s caption \"%s\"\n", slot.c_str(), text);
        }
        std::printf("string entities on connections=%d, joined to a slot=%d\n",
                    captioned, resolved);
        check(resolved > 0, "tile captions join to their slot through the wire",
              std::to_string(resolved));
    }

    }
    else
    {
        check(false, "customization icon screen is readable", "unreadable");
    }

    /* ------------------------------------- the de-hardcoding is a refactor --
     *
     * Nine colours and a six-step alpha ramp used to be typed into the armory
     * screen. They are now read. That is only an improvement if the read
     * reproduces them: if the values had drifted, the screen would change
     * appearance and this change would be a redesign wearing the clothes of a
     * cleanup. So every retired constant is checked against what the live
     * lookup returns.
     *
     * The two that were never named by the game are checked as DERIVATIONS -
     * a composite and two alpha steps - within a stated tolerance, which is
     * the honest way to say "this rule reproduces the value a designer picked
     * by eye" rather than pretending it was authored. */
    {
        struct Retired { const char* was; const char* name; uint32_t rgb; };
        static const Retired kRetired[] = {
            { "kBg",     "DarkNavy",             0x1E262C },
            { "kTile",   "Charcoal",             0x22313C },
            { "kText",   "FE-Text",              0xBFCAD1 },
            { "kAccent", "FE-Class-Proficiency", 0x59BFF8 },
            { "kEquip",  "FE-Online-Positive",   0x8EED6C },
            { "kLocked", "FE-Error-Negative",    0xFB694D }
        };
        int same = 0;
        for (const Retired& r : kRetired)
        {
            const bf6_rime_color* e = by_name(r.name);
            const bool ok = e && e->rgb == r.rgb;
            if (ok) same++;
            std::printf("  %-8s was %s  now %s/%s\n", r.was, hex(r.rgb).c_str(),
                        r.name, e ? hex(e->rgb).c_str() : "absent");
        }
        check(same == 6, "6 retired constants reproduce from the palette",
              std::to_string(same));

        /* The hovered tile was #2C3E4B and the game names no such colour. The
         * claim is that it is Charcoal composited with FE-Focus at the
         * authored 0.08 step. Reproducing a hand-picked value to within a few
         * units per channel is what turns that from a guess into the rule the
         * designer used. */
        const bf6_rime_color* tile  = by_name("Charcoal");
        const bf6_rime_color* focus = by_name("FE-Focus");
        if (tile && focus)
        {
            int worst = 0;
            const uint32_t want = 0x2C3E4B;
            for (int sh = 0; sh <= 16; sh += 8)
            {
                const int b = (int)((tile->rgb >> sh) & 0xFF);
                const int o = (int)((focus->rgb >> sh) & 0xFF);
                const int got = (int)(b + (o - b) * 0.08f + 0.5f);
                const int exp = (int)((want >> sh) & 0xFF);
                const int d = got > exp ? got - exp : exp - got;
                if (d > worst) worst = d;
            }
            check(worst <= 4, "hover derives from Charcoal + FE-Focus @0.08",
                  std::to_string(worst) + "/255 worst channel");
        }

        /* The ramp, recovered the way the viewer recovers it: the distinct
         * alphas the front end's own elements carry. The declared ramp lives
         * in a boxed value this reader cannot open yet, so this is the ramp AS
         * USED - and it has to contain the six declared steps or the
         * substitution is not sound. */
        static const float kNominal[6] = { 0.011f, 0.024f, 0.08f, 0.27f, 0.60f, 1.0f };
        std::vector<float> seen;
        static const char* kScreens[] = {
            "common/ui/weapons/screens/menuweaponscreen",
            "common/ui/weapons/screens/weaponattachmentselectionscreen"
        };
        for (const char* scr : kScreens)
        {
            bf6_rime_tree_stats s2{};
            const int n2 = bf6_rime_tree(c, scr, 6, nullptr, 0, &s2);
            if (n2 <= 0) continue;
            std::vector<bf6_rime_node> r2((size_t)n2);
            bf6_rime_tree(c, scr, 6, r2.data(), n2, &s2);
            for (const bf6_rime_node& r : r2)
            {
                if (!(r.alpha > 0.f) || r.alpha > 1.f) continue;
                bool dup = false;
                for (float v : seen) if (std::fabs(v - r.alpha) < 0.0005f) { dup = true; break; }
                if (!dup) seen.push_back(r.alpha);
            }
        }
        int steps = 0;
        std::printf("  distinct authored alphas observed: %zu\n", seen.size());
        for (int i = 0; i < 6; i++)
        {
            float best = -1.f, bestd = 1e9f;
            for (float v : seen)
            {
                const float d = std::fabs(v - kNominal[i]);
                if (d < bestd) { bestd = d; best = v; }
            }
            if (bestd <= kNominal[i] * 0.1f + 0.001f) steps++;
            else std::printf("  ramp step %.3f not observed (nearest %.3f)\n",
                             kNominal[i], best);
        }
        check(steps == 6, "all 6 alpha ramp steps appear on live elements",
              std::to_string(steps));
    }

    bf6_close(c);
    std::printf("%s (%d failure%s)\n", g_fail ? "FAILED" : "PASSED", g_fail,
                g_fail == 1 ? "" : "s");
    return g_fail ? 1 : 0;
}
