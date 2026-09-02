/*
 * One-mount census for the shipped BF6 front end.
 *
 * This is deliberately a proof harness, not a generated manifest.  Every row
 * is discovered from the installed game on this run.  The viewer can only
 * claim to reproduce the boot-to-armory route once the screens, graph imports,
 * and property wires below remain readable together.
 *
 *   frontend_flow_test <game-dir> [--all]
 */
#include "bf6_core.h"

#include <algorithm>
#include <cctype>
#include <cstdio>
#include <cstring>
#include <string>
#include <map>
#include <unordered_map>
#include <vector>

static bool contains(const std::string& s, const char* q)
{
    return s.find(q) != std::string::npos;
}

static bool in_frontend_route(const std::string& p)
{
    if (!contains(p, "/screens/")) return false;
    return contains(p, "common/ui/bootflow/") ||
           contains(p, "game/glacierflow/flow_mainmenu/ui/screens/") ||
           contains(p, "common/ui/universalmenu/") ||
           contains(p, "common/ui/weapons/") ||
           contains(p, "common/ui/weaponcustomization/");
}

static const char* stage_of(const std::string& p)
{
    if (contains(p, "bootflow") && contains(p, "legal")) return "LEGAL";
    if (contains(p, "bootflow")) return "BOOT";
    if (contains(p, "weaponcustomization")) return "ATTACH";
    if (contains(p, "/weapons/")) return "WEAPONS";
    return "HOME";
}

int main(int argc, char** argv)
{
    if (argc < 2)
    {
        std::fprintf(stderr, "usage: frontend_flow_test <game-dir> [--all]\n");
        return 2;
    }
    const bool show_all = argc > 2 && std::strcmp(argv[2], "--all") == 0;
    char err[512]{};
    bf6_ctx* c = bf6_open(argv[1], err, (int)sizeof(err));
    if (!c) { std::fprintf(stderr, "open: %s\n", err); return 1; }
    if (!bf6_mount_all(c, 1, err, (int)sizeof(err)))
    {
        std::fprintf(stderr, "mount: %s\n", err);
        bf6_close(c);
        return 1;
    }

    const int asset_count = bf6_list_ebx(c, "/screens/", nullptr, 0);
    std::vector<bf6_asset> assets((size_t)std::max(asset_count, 0));
    if (asset_count > 0) bf6_list_ebx(c, "/screens/", assets.data(), asset_count);

    std::vector<std::string> screens;
    for (const bf6_asset& a : assets)
        if (a.name && in_frontend_route(a.name)) screens.emplace_back(a.name);
    std::sort(screens.begin(), screens.end());
    screens.erase(std::unique(screens.begin(), screens.end()), screens.end());

    int readable = 0, rows_total = 0, wires_total = 0;
    int real_text_to_label = 0, shuffled_text_to_label = 0;
    int unknown = 0, unresolved = 0, ambiguous = 0;
    std::vector<std::string> unreadable;
    std::map<std::string, int> unknown_types;
    std::map<std::string, std::string> unknown_samples;
    std::map<std::string, int> unresolved_targets;
    std::vector<std::string> authored_svg_assets;

    std::printf("front-end screen candidates=%zu (live mount)\n", screens.size());
    for (const std::string& path : screens)
    {
        bf6_rime_tree_stats st{};
        const int n = bf6_rime_tree(c, path.c_str(), 8, nullptr, 0, &st);
        if (n <= 0)
        {
            unreadable.push_back(path);
            if (show_all) std::printf("  %-7s unreadable  %s\n", stage_of(path), path.c_str());
            continue;
        }

        std::vector<bf6_rime_node> rows((size_t)n);
        const int got = bf6_rime_tree(c, path.c_str(), 8, rows.data(), n, &st);
        if (got != n) { unreadable.push_back(path); continue; }
        readable++;
        rows_total += got;
        unknown += st.unknown_types;
        unresolved += st.unresolved_refs;
        ambiguous += st.ambiguous_refs;

        std::unordered_map<int32_t, int32_t> local_kind;
        for (const bf6_rime_node& row : rows)
        {
            if (path == row.partition) local_kind[row.instance] = row.kind;
            if (row.kind == BF6_RIME_UNKNOWN)
            {
                char sig[16]{};
                std::snprintf(sig, sizeof(sig), "%08X", row.type_signature);
                const std::string key = std::string(row.type_guid) + "\t0x" + sig +
                                        "\t" + row.type_name;
                unknown_types[key]++;
                if (!unknown_samples.count(key))
                    unknown_samples[key] = path + " -> " + row.partition +
                                           " :: " + row.name;
            }
            if (row.kind == BF6_RIME_WIDGET_REFERENCE && !row.reference[0])
                unresolved_targets[path + "\t" + row.name]++;
            if (row.kind == BF6_RIME_SVG && row.image_asset[0])
                authored_svg_assets.emplace_back(row.image_asset);
        }

        const int nw = bf6_rime_connections(c, path.c_str(), nullptr, 0);
        std::vector<bf6_rime_connection> wires((size_t)std::max(nw, 0));
        if (nw > 0) bf6_rime_connections(c, path.c_str(), wires.data(), nw);
        wires_total += std::max(nw, 0);

        for (int i = 0; i < nw; ++i)
        {
            const bf6_rime_connection& w = wires[(size_t)i];
            const bool target_is_label = local_kind.count(w.target) &&
                local_kind[w.target] == BF6_RIME_LABEL;
            if (target_is_label && bf6_rime_string_entity(c, path.c_str(), w.source))
                real_text_to_label++;

            /* Control: keep the target and field, rotate only the producer.
             * A merely plausible connection reader scores similarly here; the
             * authored graph should bind substantially more string producers
             * to labels than this pairing. */
            const int32_t shuffled_source = wires[(size_t)((i + 1) % nw)].source;
            if (target_is_label && bf6_rime_string_entity(c, path.c_str(), shuffled_source))
                shuffled_text_to_label++;
        }

        if (show_all || contains(path, "bootflow") ||
            contains(path, "menuweaponscreen") ||
            contains(path, "weaponattachmentcategoryscreen") ||
            contains(path, "weaponattachmentselectionscreen"))
            std::printf("  %-7s rows=%-5d wires=%-5d gaps=%d/%d/%d  %s\n",
                        stage_of(path), got, std::max(nw, 0),
                        st.unknown_types, st.unresolved_refs, st.ambiguous_refs,
                        path.c_str());
    }

    const char* milestones[] = {
        "game/glacierflow/flow_mainmenu/ui/screens/bootflowlogoscreen",
        "game/glacierflow/flow_mainmenu/ui/screens/bootflowstartscreen",
        "common/ui/bootflow/legal/screens/bootflow_legalscreen",
        "common/ui/weapons/screens/menuweaponscreen",
        "common/ui/weaponcustomization/screens/weaponattachmentcategoryscreen",
        "common/ui/weapons/screens/weaponattachmentselectionscreen"
    };
    int milestones_present = 0;
    for (const char* m : milestones)
        if (std::binary_search(screens.begin(), screens.end(), std::string(m)))
            milestones_present++;

    const char* attachment_category =
        "common/ui/weaponcustomization/screens/weaponattachmentcategoryscreen";
    const int category_events =
        bf6_rime_event_connections(c, attachment_category, nullptr, 0);
    const int fake_events = bf6_rime_event_connections(
        c, "common/ui/__control__/not_a_real_widget", nullptr, 0);
    std::vector<bf6_rime_event_connection> category_event_rows(
        (size_t)std::max(category_events, 0));
    if (category_events > 0)
        bf6_rime_event_connections(c, attachment_category,
                                   category_event_rows.data(), category_events);
    int client_events = 0, server_events = 0;
    for (const bf6_rime_event_connection& event : category_event_rows)
    {
        client_events += event.mode == 2;
        server_events += event.mode == 3;
    }

    std::vector<char> graph(1 << 20);
    const int64_t graph_bytes = bf6_ebx_dump(
        c, "common/ui/bootflow/assets/bootflowgraph", 5,
        graph.data(), (int)graph.size());
    const std::string graph_text = graph_bytes > 0 ? std::string(graph.data()) : std::string();
    int graph_imports = 0;
    for (size_t at = 0; (at = graph_text.find("import ", at)) != std::string::npos; at += 7)
        graph_imports++;
    const bool legal_import = contains(graph_text,
        "common/ui/bootflow/legal/assets/bootflowlegalflowgraph.ebx");
    const bool fake_import = contains(graph_text,
        "common/ui/__control__/not_a_real_subgraph.ebx");

    const int fake_root = bf6_rime_tree(c,
        "common/ui/__control__/not_a_real_screen", 8, nullptr, 0, nullptr);
    const int fake_search = bf6_list_ebx(c,
        "common/ui/__control__/not_a_real_screen", nullptr, 0);

    const char* main_hub =
        "common/ui/universalmenu/menucomponents/mainmenucomponent/logic/mainmenu_screenhub";
    const int hub_count = bf6_ui_hub_entries(c, main_hub, nullptr, 0);
    std::vector<bf6_ui_hub_entry> hub((size_t)std::max(hub_count, 0));
    if (hub_count > 0) bf6_ui_hub_entries(c, main_hub, hub.data(), hub_count);
    int home_hub = 0, home_children = -1;
    for (const bf6_ui_hub_entry& row : hub)
    {
        if (show_all) std::printf("  hub child[%d] %s\n", row.instance, row.blueprint);
        if (contains(row.blueprint, "mainmenu_home_screenhub"))
        {
            home_hub++;
            home_children = bf6_ui_hub_entries(c, row.blueprint, nullptr, 0);
        }
    }
    const int fake_hub = bf6_ui_hub_entries(
        c, "common/ui/__control__/not_a_real_screenhub", nullptr, 0);

    /* Do not infer semantics from the asset name.  The six checked-string
     * entities in BootFlowScreenNameProvider localize to accessibility option
     * labels, not splash-screen names.  Census them as a regression/control,
     * but explicitly do not use them to invent a boot order. */
    const char* boot_provider =
        "common/ui/bootflow/logic/bootflowscreennameprovider";
    int boot_provider_strings = 0, boot_provider_localized = 0;
    for (int instance = 0; instance < 64; ++instance)
    {
        const uint32_t sid = bf6_rime_string_entity(c, boot_provider, instance);
        if (!sid) continue;
        boot_provider_strings++;
        const char* value = bf6_localized_string(c, sid);
        if (value && value[0]) boot_provider_localized++;
        if (show_all)
            std::printf("  boot provider localized-ref[%d] sid=%u text=%s\n", instance, sid,
                        value && value[0] ? value : "<not-localized>");
    }
    const uint32_t fake_provider_string = bf6_rime_string_entity(
        c, "common/ui/__control__/not_a_real_provider", 7);

    const char* boot_hub = "common/ui/bootflow/logic/bootflow_screens_hub";
    const int boot_hub_count = bf6_ui_hub_entries(c, boot_hub, nullptr, 0);
    std::vector<bf6_ui_hub_entry> boot_hub_rows(
        (size_t)std::max(boot_hub_count, 0));
    if (boot_hub_count > 0)
        bf6_ui_hub_entries(c, boot_hub, boot_hub_rows.data(), boot_hub_count);
    int boot_logic_blueprints = 0;
    for (const bf6_ui_hub_entry& row : boot_hub_rows)
    {
        if (contains(row.blueprint, "/logic/")) boot_logic_blueprints++;
        if (show_all) std::printf("  boot hub child[%d] %s\n",
                                  row.instance, row.blueprint);
    }

    bf6_photon_bundle_info photon{};
    const int photon_count = bf6_photon_offline_assets(c, &photon, nullptr, 0);
    std::vector<bf6_photon_asset> photon_rows((size_t)std::max(photon_count, 0));
    if (photon_count > 0)
        bf6_photon_offline_assets(c, &photon, photon_rows.data(), photon_count);
    int photon_png = 0, photon_svg = 0, photon_font = 0;
    for (const bf6_photon_asset& row : photon_rows)
    {
        photon_png += row.kind == BF6_PHOTON_ASSET_PNG;
        photon_svg += row.kind == BF6_PHOTON_ASSET_SVG;
        photon_font += row.kind == BF6_PHOTON_ASSET_FONT;
    }
    const int64_t fake_chunk = bf6_read_raw(
        c, BF6_RAW_CHUNK, "00000000000000000000000000000001", nullptr);

    std::sort(authored_svg_assets.begin(), authored_svg_assets.end());
    authored_svg_assets.erase(
        std::unique(authored_svg_assets.begin(), authored_svg_assets.end()),
        authored_svg_assets.end());
    int svg_resolved = 0, svg_decoded = 0, svg_structural_reject = 0;
    for (const std::string& asset : authored_svg_assets)
    {
        bf6_rime_svg_info info{};
        const int got = bf6_rime_svg(c, asset.c_str(), &info, nullptr, 0, nullptr, 0);
        if (got >= 0) { svg_resolved++; svg_decoded += info.contour_count > 0; }
        else if (got == -2) svg_structural_reject++;
        if (show_all)
        {
            char resource[512]{};
            const int rn = bf6_rime_image_resource(c, asset.c_str(), resource,
                                                    (int)sizeof(resource));
            std::printf("  authored svg status=%d shapes=%d contours=%d points=%d asset=%s resource=%s\n",
                        got, info.shape_count, info.contour_count, info.point_count,
                        asset.c_str(), rn >= 0 ? resource : "<unresolved>");
        }
    }

    std::printf("\nreadable=%d/%zu rows=%d wires=%d gaps unknown=%d unresolved=%d ambiguous=%d\n",
                readable, screens.size(), rows_total, wires_total,
                unknown, unresolved, ambiguous);
    std::printf("text->label real=%d shuffled-source-control=%d\n",
                real_text_to_label, shuffled_text_to_label);
    std::printf("route milestones=%d/%zu boot-graph-imports=%d legal-subgraph=%d fake-import=%d\n",
                milestones_present, sizeof(milestones) / sizeof(milestones[0]),
                graph_imports, legal_import ? 1 : 0, fake_import ? 1 : 0);
    std::printf("attachment-category events=%d client=%d server=%d fake-events=%d\n",
                category_events, client_events, server_events, fake_events);
    std::printf("negative controls fake-root=%d fake-search=%d\n", fake_root, fake_search);
    std::printf("main ScreenHub children=%d home=%d home-children=%d fake-hub=%d\n",
                hub_count, home_hub, home_children, fake_hub);
    std::printf("boot ScreenHub static-blueprints=%d logic-blueprints=%d (screens are provider-driven)\n",
                boot_hub_count, boot_logic_blueprints);
    std::printf("boot provider accessibility refs=%d localized=%d fake-provider=%u (not screen order)\n",
                boot_provider_strings, boot_provider_localized,
                fake_provider_string);
    std::printf("Photon offline assets=%d png=%d svg=%d font=%d controls=%d/%d/%d chunk=%lld fake-chunk=%lld\n",
                photon_count, photon_png, photon_svg, photon_font,
                photon.ranges_in_bounds, photon.ranges_contiguous,
                photon.signatures_valid, (long long)photon.chunk_size,
                (long long)fake_chunk);
    std::printf("front-end authored SVG assets=%zu resolved=%d decoded=%d structural-reject=%d\n",
                authored_svg_assets.size(), svg_resolved, svg_decoded,
                svg_structural_reject);
    if (!unknown_types.empty())
    {
        std::printf("unknown concrete element types:\n");
        for (const auto& it : unknown_types)
            std::printf("  x%-3d %s  sample=%s\n", it.second, it.first.c_str(),
                        unknown_samples[it.first].c_str());
    }
    if (!unresolved_targets.empty())
    {
        std::printf("unresolved widget references:\n");
        for (const auto& it : unresolved_targets)
            std::printf("  x%-3d %s\n", it.second, it.first.c_str());
    }
    if (!unreadable.empty())
    {
        std::printf("non-Rime or unreadable /screens/ assets:\n");
        for (const std::string& path : unreadable)
            std::printf("  %s\n", path.c_str());
    }

    /* Some /screens/ assets are view-model/expression partitions rather than
     * Rime roots, so readability is intentionally not required to equal the
     * name census.  The six concrete route milestones are the hard oracle. */
    const bool pass = milestones_present == (int)(sizeof(milestones) / sizeof(milestones[0])) &&
                      graph_bytes > 0 && graph_imports > 0 && legal_import && !fake_import &&
                      readable >= 6 && rows_total > 0 && wires_total > 0 &&
                      real_text_to_label > shuffled_text_to_label &&
                      category_events == 15 && client_events == 15 &&
                      server_events == 0 && fake_events < 0 &&
                      hub_count == 9 && home_hub == 1 && home_children >= 0 &&
                      boot_hub_count == 4 && boot_logic_blueprints == boot_hub_count &&
                      boot_provider_strings == 6 && fake_provider_string == 0 &&
                      photon_count == 231 && photon.asset_count == photon_count &&
                      photon_png == 217 && photon_svg == 4 && photon_font == 10 &&
                      photon.ranges_in_bounds == photon_count &&
                      photon.ranges_contiguous == photon_count &&
                      photon.signatures_valid == photon_count &&
                      photon.chunk_size > 0 && fake_chunk < 0 &&
                      svg_structural_reject == 0 &&
                      fake_root < 0 && fake_search == 0 && fake_hub < 0;
    bf6_close(c);
    return pass ? 0 : 1;
}
