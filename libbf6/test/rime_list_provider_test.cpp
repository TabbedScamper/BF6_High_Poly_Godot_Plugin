#include "bf6_core.h"
#include "rime_list_provider.h"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

namespace {

uint32_t property_hash(const char* name)
{
    uint32_t hash = 5381u;
    if (!name) return hash;
    for (const unsigned char* p =
             reinterpret_cast<const unsigned char*>(name); *p; ++p)
        hash = hash * 33u ^ *p;
    return hash;
}

uint32_t shuffled_hash(uint32_t id)
{
    return ((id << 8) | (id >> 24)) ^ 0xA5A5A5A5u;
}

bool check_catalogue(const rime_list::FieldSpec* fields, size_t count,
                     const char* label)
{
    bool ok = true;
    for (size_t i = 0; i < count; ++i) {
        const uint32_t measured = property_hash(fields[i].name);
        if (measured != fields[i].id) {
            std::fprintf(stderr, "%s hash mismatch %s: 0x%08X != 0x%08X\n",
                         label, fields[i].name, measured, fields[i].id);
            ok = false;
        }
    }
    return ok;
}

bool load_tree(bf6_ctx* ctx, const char* partition,
               std::vector<bf6_rime_node>& rows)
{
    bf6_rime_tree_stats stats{};
    const int count = bf6_rime_tree(ctx, partition, 6, nullptr, 0, &stats);
    if (count <= 0) return false;
    rows.resize(static_cast<size_t>(count));
    return bf6_rime_tree(ctx, partition, 6, rows.data(), count, &stats) ==
           count;
}

bool load_item_screen(bf6_ctx* ctx, const char* partition,
                      rime::Screen& screen)
{
    std::vector<bf6_rime_node> rows;
    if (!load_tree(ctx, partition, rows)) return false;
    std::string err;
    if (!rime::from_live(rows.data(), static_cast<int>(rows.size()), screen,
                         err))
        return false;
    return rime::load_interface_text_graphs(ctx, screen) > 0;
}

rime_list::Value string_value(const char* text)
{
    rime_list::Value value{};
    value.kind = rime_list::ValueKind::String;
    value.string = text ? text : "";
    return value;
}

rime_list::Value bool_value(bool state)
{
    rime_list::Value value{};
    value.kind = rime_list::ValueKind::Bool;
    value.boolean = state;
    return value;
}

rime_list::Value real_value(double number)
{
    rime_list::Value value{};
    value.kind = rime_list::ValueKind::Real;
    value.real = number;
    return value;
}

rime_list::Value int_value(int64_t number)
{
    rime_list::Value value{};
    value.kind = rime_list::ValueKind::Int;
    value.integer = number;
    return value;
}

} // namespace

int main(int argc, char** argv)
{
    if (argc < 2) {
        std::fprintf(stderr, "usage: rime_list_provider_test <game-dir>\n");
        return 2;
    }

    size_t nr = 0, ni = 0;
    const rime_list::FieldSpec* roots = rime_list::root_fields(&nr);
    const rime_list::FieldSpec* items = rime_list::item_fields(&ni);
    if (!check_catalogue(roots, nr, "root") ||
        !check_catalogue(items, ni, "item"))
        return 1;

    size_t nh = 0;
    const rime_list::FieldSpec* headers = rime_list::header_fields(&nh);
    if (!check_catalogue(headers, nh, "header")) return 1;

    /* Fake-token control: a field that is not in the game's DBD contract must
     * not enter a provider snapshot. */
    rime_list::Record provider;
    rime_list::Value null_value{};
    if (provider.put(0xDEADBEEFu, null_value)) {
        std::fprintf(stderr, "fabricated field token was accepted\n");
        return 1;
    }
    for (size_t i = 0; i < ni; ++i) {
        if (!provider.put(items[i].id, null_value)) {
            std::fprintf(stderr, "known item field rejected: %s\n", items[i].name);
            return 1;
        }
    }
    /* Absence, not an invented false/zero, is the required initial state. */
    rime_list::Record empty;
    if (empty.find(0xFE59922Bu) || empty.find(0x30A05175u) ||
        empty.find(0x414F43D2u)) {
        std::fprintf(stderr, "provider inferred favorite/lock/package state\n");
        return 1;
    }

    char err[512]{};
    bf6_ctx* ctx = bf6_open(argv[1], err, static_cast<int>(sizeof(err)));
    if (!ctx) {
        std::fprintf(stderr, "open: %s\n", err);
        return 1;
    }
    if (!bf6_mount_frontend(ctx, err, static_cast<int>(sizeof(err)))) {
        std::fprintf(stderr, "mount: %s\n", err);
        bf6_close(ctx);
        return 1;
    }

    const char* root = "common/ui/weapons/screens/menuweaponscreen";
    bf6_rime_tree_stats stats{};
    const int count = bf6_rime_tree(ctx, root, 6, nullptr, 0, &stats);
    std::vector<bf6_rime_node> rows(static_cast<size_t>(count > 0 ? count : 0));
    const int got = count > 0
        ? bf6_rime_tree(ctx, root, 6, rows.data(), count, &stats) : count;
    if (got <= 0) {
        std::fprintf(stderr, "menu weapon tree unavailable: %d\n", got);
        bf6_close(ctx);
        return 1;
    }

    const rime_list::ContractReport contract =
        rime_list::inspect(ctx, root, rows.data(), got);
    const rime_list::ContractReport fake_collection =
        rime_list::inspect(ctx, root, rows.data(), got,
                           rime_list::kGridItemCollectionData);
    const int fake_partition = bf6_rime_tree(
        ctx, "common/ui/__control__/not_a_real_screen", 1,
        nullptr, 0, nullptr);

    rime_list::DbdContract dbd;
    rime_list::DbdContract fake_dbd;
    bf6_rime_dbd_field direct_dbd[256]{};
    char direct_dbd_name[256]{};
    const int direct_dbd_count = bf6_rime_dbd_fields(
        ctx, rime_list::kGridItemDbdPartition,
        direct_dbd_name, static_cast<int>(sizeof(direct_dbd_name)),
        direct_dbd, 256);
    const int direct_fake_dbd_count = bf6_rime_dbd_fields(
        ctx, "common/ui/__control__/not_a_real_griditemdbd",
        nullptr, 0, nullptr, 0);
    const bool dbd_ok = rime_list::load_item_contract(ctx, dbd);
    const bool fake_dbd_ok = rime_list::load_item_contract(
        ctx, fake_dbd, "common/ui/__control__/not_a_real_griditemdbd");
    int dbd_catalogue_matches = 0;
    int dbd_direct_matches = 0;
    if (dbd_ok) {
        for (size_t index = 0; index < dbd.fields.size(); ++index) {
            const rime_list::DbdField& field = dbd.fields[index];
            const rime_list::FieldSpec* spec = rime_list::item_field(field.property_id);
            if (spec && field.name == spec->name) ++dbd_catalogue_matches;
            if (index < 256 && field.name == direct_dbd[index].name &&
                field.type_signature == direct_dbd[index].type_signature)
                ++dbd_direct_matches;
            std::printf("dbd-field name=%s property=0x%08X provider=0x%08X "
                        "type-signature=%llu\n",
                        field.name.c_str(), field.property_id, field.provider_id,
                        static_cast<unsigned long long>(field.type_signature));
        }
    }
    std::printf("dbd-contract loaded=%d data=%s fields=%zu catalogue=%d "
                "direct=%d direct-matches=%d direct-fake=%d fake-loaded=%d\n",
                dbd_ok ? 1 : 0, dbd.data_name.c_str(), dbd.fields.size(),
                dbd_catalogue_matches, direct_dbd_count, dbd_direct_matches,
                direct_fake_dbd_count, fake_dbd_ok ? 1 : 0);

    rime_list::DbdContract header_dbd;
    rime_list::DbdContract fake_header_dbd;
    const bool header_dbd_ok = rime_list::load_contract(
        ctx, header_dbd, rime_list::kHeaderInfoDbdPartition);
    const bool fake_header_dbd_ok = rime_list::load_contract(
        ctx, fake_header_dbd,
        "common/ui/__control__/not_a_real_headerinfodbd");
    int header_catalogue_matches = 0;
    rime_list::Record header_provider;
    if (header_dbd_ok) {
        for (const rime_list::DbdField& field : header_dbd.fields) {
            const rime_list::FieldSpec* spec =
                rime_list::header_field(field.property_id);
            if (spec && field.name == spec->name) ++header_catalogue_matches;
            if (!header_provider.put(header_dbd, field.property_id,
                                     null_value)) {
                std::fprintf(stderr, "header contract field rejected: %s\n",
                             field.name.c_str());
                bf6_close(ctx);
                return 1;
            }
            std::printf("header-dbd-field name=%s property=0x%08X "
                        "provider=0x%08X type-signature=%llu\n",
                        field.name.c_str(), field.property_id,
                        field.provider_id,
                        static_cast<unsigned long long>(field.type_signature));
        }
    }
    const bool fake_header_field_accepted =
        header_provider.put(header_dbd, 0xDEADBEEFu, null_value);
    const rime_list::DbdField* header_title_by_name =
        rime_list::contract_field(header_dbd, "HeaderTitle");
    const rime_list::DbdField* header_title_by_id =
        rime_list::contract_field(header_dbd, 0x8B3FE95Au);
    const rime_list::DbdField* fake_header_name =
        rime_list::contract_field(header_dbd, "DefinitelyNotAHeaderField");
    std::printf("header-dbd-contract loaded=%d data=%s fields=%zu "
                "catalogue=%d fake-dbd-loaded=%d fake-field-accepted=%d\n",
                header_dbd_ok ? 1 : 0, header_dbd.data_name.c_str(),
                header_dbd.fields.size(), header_catalogue_matches,
                fake_header_dbd_ok ? 1 : 0,
                fake_header_field_accepted ? 1 : 0);

    std::printf("root-wire real=%d bottom-cap=%d wrong-target=%d "
                "fake-collection-hash=%d fake-partition=%d lists=%zu\n",
                contract.exact_root_wires, contract.bottom_cap_wires,
                contract.wrong_target_wires, fake_collection.exact_root_wires,
                fake_partition, contract.lists.size());
    for (const rime_list::DataList& list : contract.lists) {
        std::printf("list part=%s instance=%d name=%s template=%s "
                    "spacing=%.3f sizeDist=%d flow=%d spaceDist=%d preserve=%d\n",
                    list.partition.c_str(), list.instance, list.name.c_str(),
                    list.item_template.c_str(), list.item_spacing,
                    list.size_distribution, list.flow_direction,
                    list.space_distribution, list.preserve_fit_content);
    }

    const rime_list::RouteReport real_route =
        rime_list::route(ctx,
                         "common/ui/metacore/metacustomization/widgets/metacustomization_griditemcell",
                         provider);
    const rime_list::RouteReport shuffled_route =
        rime_list::route_shuffled_control(
            ctx,
            "common/ui/metacore/metacustomization/widgets/metacustomization_griditemcell",
            provider);
    std::printf("item-route supplied=%d declared=%d connected=%d unrouted=%d "
                "shuffled-declared=%d shuffled-connected=%d\n",
                real_route.supplied, real_route.declared, real_route.connected,
                real_route.unrouted, shuffled_route.declared,
                shuffled_route.connected);
    std::printf("exact-connected-fields");
    for (uint32_t field : real_route.connected_fields) {
        const rime_list::FieldSpec* spec = rime_list::item_field(field);
        std::printf(" %s(0x%08X)", spec ? spec->name : "?", field);
    }
    std::printf("\n");
    for (const rime_list::RouteReport::Evidence& evidence : real_route.evidence) {
        const rime_list::FieldSpec* spec = rime_list::item_field(evidence.field);
        std::printf("route-evidence field=%s(0x%08X) provider=0x%08X "
                    "part=%s declare=%d "
                    "source=%d target=%d\n",
                    spec ? spec->name : "?", evidence.field,
                    evidence.provider_field,
                    evidence.partition.c_str(), evidence.interface_declarations,
                    evidence.source_wires, evidence.target_wires);
    }

    /* A real armory card, populated only from the mounted install.  This is
     * deliberately separate from the synthetic routing census above: it
     * proves the localized Header/Factory pair survives the complete live
     * DBD -> cell graph. */
    const int weapon_name_count = bf6_weapon_names(ctx, nullptr, 0);
    std::vector<bf6_weapon_name_row> weapon_names(
        static_cast<size_t>(weapon_name_count > 0 ? weapon_name_count : 0));
    const int weapon_name_got = weapon_name_count > 0
        ? bf6_weapon_names(ctx, weapon_names.data(), weapon_name_count) : 0;
    const bf6_weapon_name_row* m4_name = nullptr;
    int fake_weapon_rows = 0;
    for (const bf6_weapon_name_row& row : weapon_names) {
        if (std::strcmp(row.weapon, "m4a1") == 0) m4_name = &row;
        if (std::strcmp(row.weapon, "codex_fake_weapon_7f93") == 0)
            ++fake_weapon_rows;
    }
    const char* factory_localized =
        bf6_localized_string(ctx, 3038496759u);
    const char* fake_localized =
        bf6_localized_string(ctx, 0xF7E3D19Bu);
    const int m4_icon_texture = m4_name && m4_name->icon_asset[0]
        ? bf6_texture_id_by_name(ctx, m4_name->icon_asset) : -1;
    const bf6_texture* m4_icon = m4_icon_texture >= 0
        ? bf6_texture_at(ctx, m4_icon_texture) : nullptr;
    const int fake_icon_texture = bf6_texture_id_by_name(
        ctx,
        "common/ui/assets/images/hardware/generated/control/"
        "t_ui_codex_fake_weapon_7f93_archetype_icon");
    rime::Screen armory_card;
    const bool armory_card_ok = load_item_screen(
        ctx, rime_list::kGridItemCellPartition, armory_card);
    rime_list::Record armory_card_record;
    auto card_put = [&](const char* name, const rime_list::Value& value) {
        const rime_list::DbdField* field =
            rime_list::contract_field(dbd, name);
        return field && armory_card_record.put(dbd, field->property_id, value);
    };
    const bool armory_record_ok = m4_name && m4_name->name[0] &&
        m4_name->factory_label[0] &&
        card_put("Header", string_value(m4_name->name)) &&
        card_put("SubHeader", string_value(m4_name->factory_label)) &&
        card_put("IsHeaderVisible", bool_value(true)) &&
        card_put("IsCategoryVisible", bool_value(false));
    const bool armory_fake_field_accepted = armory_card_record.put(
        dbd, 0xF7E3D19Bu, string_value("CONTROL"));
    rime::Screen armory_card_control = armory_card;
    const rime_list::BindReport armory_card_bind =
        armory_card_ok && armory_record_ok
            ? rime_list::bind_record(
                  armory_card, rime_list::kGridItemCellPartition,
                  dbd, armory_card_record)
            : rime_list::BindReport{};
    const rime_list::BindReport armory_card_shuffle =
        armory_card_ok && armory_record_ok
            ? rime_list::bind_record_shuffled_control(
                  armory_card_control, rime_list::kGridItemCellPartition,
                  dbd, armory_card_record)
            : rime_list::BindReport{};
    if (m4_name) {
        struct CardProbe { const char* field; rime_list::Value value; };
        const CardProbe probes[] = {
            { "Header", string_value(m4_name->name) },
            { "SubHeader", string_value(m4_name->factory_label) },
            { "IsHeaderVisible", bool_value(true) },
            { "IsIconVisible", bool_value(true) },
            { "IsCategoryVisible", bool_value(false) },
        };
        for (const CardProbe& probe : probes) {
            rime_list::Record one;
            const rime_list::DbdField* field =
                rime_list::contract_field(dbd, probe.field);
            if (field) one.put(dbd, field->property_id, probe.value);
            rime::Screen one_screen;
            const bool one_ok = load_item_screen(
                ctx, rime_list::kGridItemCellPartition, one_screen);
            const rime_list::BindReport one_bind = one_ok
                ? rime_list::bind_record(
                      one_screen, rime_list::kGridItemCellPartition,
                      dbd, one)
                : rime_list::BindReport{};
            std::printf("armory-card-field %s supplied=%d applied=%d "
                        "targets=%d unrouted=%d unsupported=%d ambiguous=%d\n",
                        probe.field, one_bind.supplied,
                        one_bind.applied_fields, one_bind.applied_targets,
                        one_bind.unrouted, one_bind.unsupported_values,
                        one_bind.ambiguous);
        }
    }
    int armory_name_labels = 0, armory_factory_labels = 0;
    int armory_control_labels = 0;
    if (m4_name)
        for (const rime::Element& element : armory_card.elements) {
            if (element.kind != rime::Kind::Label) continue;
            if (element.text == m4_name->name) ++armory_name_labels;
            if (element.text == m4_name->factory_label)
                ++armory_factory_labels;
        }
    for (const rime::Element& element : armory_card_control.elements)
        if (element.kind == rime::Kind::Label && m4_name &&
            (element.text == m4_name->name ||
             element.text == m4_name->factory_label))
            ++armory_control_labels;
    std::printf("armory-card rows=%d/%d m4=%d factory-direct=%d "
                "icon=%d/%dx%d fake-icon=%d fake-rows=%d fake-loc=%d "
                "fake-field=%d "
                "real=%d/%d labels=%d/%d shuffled=%d labels=%d\n",
                weapon_name_got, weapon_name_count, m4_name ? 1 : 0,
                factory_localized && m4_name &&
                    std::strcmp(factory_localized,
                                m4_name->factory_label) == 0 ? 1 : 0,
                m4_icon_texture,
                m4_icon ? m4_icon->width : 0,
                m4_icon ? m4_icon->height : 0,
                fake_icon_texture,
                fake_weapon_rows, fake_localized ? 1 : 0,
                armory_fake_field_accepted ? 1 : 0,
                armory_card_bind.applied_fields,
                armory_card_bind.applied_targets,
                armory_name_labels, armory_factory_labels,
                armory_card_shuffle.applied_fields,
                armory_control_labels);


    const rime_list::RouteReport header_route = rime_list::route_contract(
        ctx, rime_list::kHeaderInfoDbdPartition,
        rime_list::kGridInfoPartition,
        rime_list::kWeaponInfoHeaderPartition, header_provider);
    const rime_list::RouteReport header_shuffled =
        rime_list::route_contract_shuffled_control(
            ctx, rime_list::kHeaderInfoDbdPartition,
            rime_list::kGridInfoPartition,
            rime_list::kWeaponInfoHeaderPartition, header_provider);
    const rime_list::RouteReport header_fake_target =
        rime_list::route_contract(
            ctx, rime_list::kHeaderInfoDbdPartition,
            rime_list::kGridInfoPartition,
            "common/ui/__control__/not_a_real_header_widget",
            header_provider);
    const rime_list::RouteReport header_fake_dbd =
        rime_list::route_contract(
            ctx, "common/ui/__control__/not_a_real_headerinfodbd",
            rime_list::kGridInfoPartition,
            rime_list::kWeaponInfoHeaderPartition, header_provider);
    std::printf("header-route supplied=%d connected=%d absent=%d "
                "shuffled=%d fake-target=%d fake-dbd=%d\n",
                header_route.supplied, header_route.connected,
                header_route.unrouted, header_shuffled.connected,
                header_fake_target.connected, header_fake_dbd.connected);
    std::printf("header-exact-routed");
    for (uint32_t field : header_route.connected_fields) {
        const rime_list::FieldSpec* spec = rime_list::header_field(field);
        std::printf(" %s(0x%08X)", spec ? spec->name : "?", field);
    }
    std::printf("\nheader-explicitly-absent");
    for (uint32_t field : header_route.unrouted_fields) {
        const rime_list::FieldSpec* spec = rime_list::header_field(field);
        std::printf(" %s(0x%08X)", spec ? spec->name : "?", field);
    }
    std::printf("\n");
    for (const rime_list::RouteReport::Evidence& evidence :
         header_route.evidence) {
        const rime_list::FieldSpec* spec =
            rime_list::header_field(evidence.field);
        std::printf("header-route-evidence field=%s(0x%08X) "
                    "provider=0x%08X source=%d target-token=%d "
                    "header-target=%d\n",
                    spec ? spec->name : "?", evidence.field,
                    evidence.provider_field, evidence.source_wires,
                    evidence.target_wires, evidence.target_widget_wires);
    }

    rime::Screen header_screen;
    std::string header_screen_err;
    const bool header_screen_ok = rime::from_live(
        rows.data(), got, header_screen, header_screen_err) &&
        rime::load_interface_text_graphs(ctx, header_screen) > 0;
    const rime::Screen header_screen_without_defaults = header_screen;
    const int header_defaults_applied = header_screen_ok
        ? rime::apply_interface_defaults(header_screen) : 0;
    rime_list::Record header_values;
    const rime_list::DbdField* header_title_field =
        rime_list::contract_field(header_dbd, "HeaderTitle");
    const rime_list::DbdField* header_category_field =
        rime_list::contract_field(header_dbd, "Category");
    int header_default_edges = 0;
    uint32_t header_default_child_field = 0;
    std::string header_default_child_partition;
    for (const rime::Screen::InterfaceTextGraph& graph :
         header_screen_without_defaults.interface_text_graphs) {
        if (graph.partition != rime_list::kGridInfoPartition) continue;
        const std::vector<int32_t>& interfaces = graph.interfaces;
        for (const bf6_rime_interface_field& field : graph.defaults) {
            if (field.value_kind != BF6_RIME_VALUE_BOOL ||
                !field.bool_value ||
                std::find(interfaces.begin(), interfaces.end(),
                          field.interface_instance) == interfaces.end())
                continue;
            for (const bf6_rime_connection& wire : graph.connections) {
                if (wire.source != field.interface_instance ||
                    wire.source_field != field.field_id)
                    continue;
                for (const rime::Element& element :
                     header_screen_without_defaults.elements)
                    if (element.partition == graph.partition &&
                        element.instance == wire.target &&
                        element.kind == rime::Kind::WidgetReference &&
                        element.references_widget ==
                            rime_list::kWeaponInfoHeaderPartition) {
                        ++header_default_edges;
                        header_default_child_field = wire.target_field;
                        header_default_child_partition =
                            element.references_widget;
                    }
            }
        }
    }
    if (header_title_field)
        header_values.put(header_dbd, header_title_field->property_id,
                          string_value("SUBTITLE_CONTROL_FACTORY"));
    if (header_category_field)
        header_values.put(header_dbd, header_category_field->property_id,
                          string_value("TITLE_CONTROL_M4A1"));

    rime::Screen header_default_real = header_screen_without_defaults;
    rime::Screen header_default_shuffled = header_screen_without_defaults;
    rime::Screen header_default_fake = header_screen_without_defaults;
    const int header_default_real_set = header_default_edges == 1
        ? rime::set_interface_bool_field(
              header_default_real, header_default_child_partition.c_str(),
              header_default_child_field, true) : 0;
    const int header_default_shuffled_set = header_default_edges == 1
        ? rime::set_interface_bool_field(
              header_default_shuffled,
              header_default_child_partition.c_str(),
              shuffled_hash(header_default_child_field), true) : 0;
    const int header_default_fake_set = header_default_edges == 1
        ? rime::set_interface_bool_field(
              header_default_fake,
              "common/ui/__control__/not_a_real_header_widget",
              header_default_child_field, true) : 0;
    auto direct_header_values = [&](rime::Screen& screen) {
        if (!header_title_field || !header_category_field) return;
        rime::set_provider_text(screen, rime_list::kGridInfoPartition,
                                header_title_field->provider_id,
                                "DEFAULT_CONTROL_SUBTITLE");
        rime::set_provider_text(screen, rime_list::kGridInfoPartition,
                                header_category_field->provider_id,
                                "DEFAULT_CONTROL_TITLE");
    };
    direct_header_values(header_default_real);
    direct_header_values(header_default_shuffled);
    direct_header_values(header_default_fake);
    auto count_default_labels = [](const rime::Screen& screen,
                                   int& title, int& subtitle,
                                   int& duplicated_subtitle) {
        title = subtitle = duplicated_subtitle = 0;
        for (const rime::Element& element : screen.elements) {
            if (element.kind != rime::Kind::Label) continue;
            if (element.name == "Title" &&
                element.text == "DEFAULT_CONTROL_TITLE") ++title;
            if (element.name == "Subtitle" &&
                element.text == "DEFAULT_CONTROL_SUBTITLE") ++subtitle;
            if (element.text == "DEFAULT_CONTROL_SUBTITLE")
                ++duplicated_subtitle;
        }
    };
    int default_real_title = 0, default_real_subtitle = 0,
        default_real_duplicate = 0;
    int default_shuffled_title = 0, default_shuffled_subtitle = 0,
        default_shuffled_duplicate = 0;
    int default_fake_title = 0, default_fake_subtitle = 0,
        default_fake_duplicate = 0;
    count_default_labels(header_default_real, default_real_title,
                         default_real_subtitle, default_real_duplicate);
    count_default_labels(header_default_shuffled, default_shuffled_title,
                         default_shuffled_subtitle,
                         default_shuffled_duplicate);
    count_default_labels(header_default_fake, default_fake_title,
                         default_fake_subtitle, default_fake_duplicate);
    std::printf("header-default-cross edges=%d field=0x%08X applied=%d "
                "real=%d/%d/%d shuffled-set=%d shuffled=%d/%d/%d "
                "fake-set=%d fake=%d/%d/%d\n", header_default_edges,
                header_default_child_field, header_default_real_set,
                default_real_title, default_real_subtitle,
                default_real_duplicate, header_default_shuffled_set,
                default_shuffled_title, default_shuffled_subtitle,
                default_shuffled_duplicate, header_default_fake_set,
                default_fake_title, default_fake_subtitle,
                default_fake_duplicate);
    if (header_category_field) {
        const int direct_count = bf6_rime_connections(
            ctx, rime_list::kGridInfoPartition, nullptr, 0);
        std::vector<bf6_rime_connection> direct(
            direct_count > 0 ? static_cast<size_t>(direct_count) : 0);
        if (direct_count > 0)
            bf6_rime_connections(ctx, rime_list::kGridInfoPartition,
                                 direct.data(), direct_count);
        uint32_t header_title_child_field = 0;
        for (const bf6_rime_connection& wire : direct)
            if (wire.source_field == header_category_field->provider_id ||
                (header_title_field && wire.source_field ==
                                           header_title_field->provider_id)) {
                std::printf("header-direct-wire source-field=0x%08X "
                            "source=%d target=%d target-field=0x%08X\n",
                            wire.source_field, wire.source, wire.target,
                            wire.target_field);
                if (header_title_field && wire.source_field ==
                                              header_title_field->provider_id)
                    header_title_child_field = wire.target_field;
            }
        const int header_interface_count = bf6_rime_interface_descriptors(
            ctx, rime_list::kWeaponInfoHeaderPartition, nullptr, 0);
        std::vector<int32_t> header_interfaces(
            header_interface_count > 0
                ? static_cast<size_t>(header_interface_count) : 0);
        if (header_interface_count > 0)
            bf6_rime_interface_descriptors(
                ctx, rime_list::kWeaponInfoHeaderPartition,
                header_interfaces.data(), header_interface_count);
        const int header_wire_count = bf6_rime_connections(
            ctx, rime_list::kWeaponInfoHeaderPartition, nullptr, 0);
        std::vector<bf6_rime_connection> header_wires(
            header_wire_count > 0 ? static_cast<size_t>(header_wire_count) : 0);
        if (header_wire_count > 0)
            bf6_rime_connections(ctx, rime_list::kWeaponInfoHeaderPartition,
                                 header_wires.data(), header_wire_count);
        for (const bf6_rime_connection& wire : header_wires)
            if ((wire.source_field == header_category_field->property_id ||
                 wire.source_field == header_title_child_field) &&
                std::find(header_interfaces.begin(), header_interfaces.end(),
                          wire.source) != header_interfaces.end())
            {
                std::printf("header-child-wire source-field=0x%08X source=%d "
                            "target=%d target-field=0x%08X\n",
                            wire.source_field, wire.source, wire.target,
                            wire.target_field);
                for (const rime::Element& element : header_screen.elements)
                    if (element.partition ==
                            rime_list::kWeaponInfoHeaderPartition &&
                        element.instance == wire.target)
                        std::printf("header-category-target kind=%d name=%s "
                                    "ref=%s\n",
                                    static_cast<int>(element.kind),
                                    element.name.c_str(),
                                    element.references_widget.c_str());
            }
    }
    for (const rime::Screen::InterfaceTextGraph& graph :
         header_screen.interface_text_graphs)
        if (graph.partition == rime_list::kGridInfoPartition)
            for (const bf6_rime_connection& wire : graph.connections)
                if ((header_title_field && wire.source_field ==
                                               header_title_field->provider_id) ||
                    (header_category_field && wire.source_field ==
                                                  header_category_field->provider_id)) {
                    const rime::Element* target = nullptr;
                    for (const rime::Element& element : header_screen.elements)
                        if (element.partition == graph.partition &&
                            element.instance == wire.target) {
                            target = &element;
                            break;
                        }
                    std::printf("header-bind-wire source-field=0x%08X "
                                "source=%d target=%d target-field=0x%08X "
                                "ref=%s\n", wire.source_field, wire.source,
                                wire.target, wire.target_field,
                                target ? target->references_widget.c_str() : "");
                }
    rime::Screen header_screen_shuffled = header_screen;
    rime::Screen header_title_only = header_screen;
    rime::Screen header_category_only = header_screen;
    rime_list::Record header_title_value;
    rime_list::Record header_category_value;
    if (header_title_field)
        header_title_value.put(header_dbd, header_title_field->property_id,
                               string_value("TITLE_ONLY_CONTROL"));
    if (header_category_field)
        header_category_value.put(header_dbd,
                                  header_category_field->property_id,
                                  string_value("CATEGORY_ONLY_CONTROL"));
    const rime_list::BindReport header_title_only_bind = header_screen_ok
        ? rime_list::bind_record(header_title_only,
                                 rime_list::kGridInfoPartition, header_dbd,
                                 header_title_value)
        : rime_list::BindReport{};
    const rime_list::BindReport header_category_only_bind = header_screen_ok
        ? rime_list::bind_record(header_category_only,
                                 rime_list::kGridInfoPartition, header_dbd,
                                 header_category_value)
        : rime_list::BindReport{};
    const rime_list::BindReport header_bind = header_screen_ok
        ? rime_list::bind_record(header_screen, rime_list::kGridInfoPartition,
                                 header_dbd, header_values)
        : rime_list::BindReport{};
    const rime_list::BindReport header_bind_shuffled = header_screen_ok
        ? rime_list::bind_record_shuffled_control(
              header_screen_shuffled, rime_list::kGridInfoPartition,
              header_dbd, header_values)
        : rime_list::BindReport{};
    int title_control_labels = 0;
    int category_control_labels = 0;
    for (const rime::Element& element : header_screen.elements) {
        if (element.kind != rime::Kind::Label) continue;
        if (element.text == "TITLE_CONTROL_M4A1" && element.name == "Title")
            ++title_control_labels;
        if (element.text == "SUBTITLE_CONTROL_FACTORY" &&
            element.name == "Subtitle") ++category_control_labels;
    }
    int shuffled_control_labels = 0;
    for (const rime::Element& element : header_screen_shuffled.elements)
        if (element.kind == rime::Kind::Label &&
            (element.text == "TITLE_CONTROL_M4A1" ||
             element.text == "SUBTITLE_CONTROL_FACTORY"))
            ++shuffled_control_labels;
    int title_only_labels = 0, category_only_labels = 0;
    for (const rime::Element& element : header_title_only.elements)
        if (element.kind == rime::Kind::Label &&
            element.text == "TITLE_ONLY_CONTROL") {
            ++title_only_labels;
            std::printf("header-title-only-target part=%s name=%s "
                        "visible=%d parent=%d\n", element.partition.c_str(),
                        element.name.c_str(), element.visible ? 1 : 0,
                        element.parent);
        }
    for (const rime::Element& element : header_category_only.elements)
        if (element.kind == rime::Kind::Label &&
            element.text == "CATEGORY_ONLY_CONTROL") ++category_only_labels;
    std::printf("header-runtime-bind fields=%d targets=%d ambiguous=%d "
                "title-labels=%d category-labels=%d shuffled-fields=%d "
                "shuffled-labels=%d title-only=%d/%d category-only=%d/%d\n",
                header_bind.applied_fields, header_bind.applied_targets,
                header_bind.ambiguous, title_control_labels,
                category_control_labels,
                header_bind_shuffled.applied_fields,
                shuffled_control_labels,
                header_title_only_bind.applied_fields, title_only_labels,
                header_category_only_bind.applied_fields,
                category_only_labels);

    /* The other armory runtime lists use the same two-stage path: locate the
     * exact live list and its shipped ItemTemplate, then bind only fields
     * declared by that list family's mounted DBD. */
    constexpr const char* kPackages =
        "common/ui/weapons/screens/menuweaponpackagesscreen";
    constexpr const char* kGridView =
        "common/ui/metacore/metacustomization/views/"
        "metacustomization_gridview";
    constexpr const char* kPicker =
        "common/ui/weapons/screens/weaponattachmentselectionscreen";
    std::vector<bf6_rime_node> package_rows;
    std::vector<bf6_rime_node> picker_rows;
    const bool package_tree_ok = load_tree(ctx, kPackages, package_rows);
    const bool picker_tree_ok = load_tree(ctx, kPicker, picker_rows);
    rime_list::DataList package_grid;
    rime_list::DataList picker_grid;
    int package_matches = 0;
    int picker_matches = 0;
    const bool package_grid_ok = package_tree_ok && rime_list::find_unique_list(
        package_rows.data(), static_cast<int>(package_rows.size()), kGridView,
        "Weapon Grid", package_grid, &package_matches);
    const bool picker_grid_ok = picker_tree_ok && rime_list::find_unique_list(
        picker_rows.data(), static_cast<int>(picker_rows.size()), kPicker,
        "Selection Grid", picker_grid, &picker_matches);
    rime_list::DataList fake_list;
    int fake_list_matches = -1;
    const bool fake_list_ok = package_tree_ok && rime_list::find_unique_list(
        package_rows.data(), static_cast<int>(package_rows.size()), kGridView,
        "Definitely Not A Shipped List", fake_list, &fake_list_matches);

    std::vector<bf6_rime_node> duplicate_rows = package_rows;
    if (package_grid_ok)
        duplicate_rows.push_back(package_rows[static_cast<size_t>(
            package_grid.row)]);
    rime_list::DataList duplicate_list;
    int duplicate_matches = 0;
    const bool duplicate_list_ok = package_grid_ok &&
        rime_list::find_unique_list(
            duplicate_rows.data(), static_cast<int>(duplicate_rows.size()),
            kGridView, "Weapon Grid", duplicate_list, &duplicate_matches);

    rime_list::DataList stat_list;
    rime_list::DataList nav_list;
    rime_list::DataList tag_list;
    int stat_matches = 0, nav_matches = 0, tag_matches = 0;
    const bool stat_list_ok = rime_list::find_unique_list(
        rows.data(), got,
        "common/ui/weaponcustomization/widgets/weaponattributes",
        "ProgressBarList", stat_list, &stat_matches);
    const bool nav_list_ok = rime_list::find_unique_list(
        rows.data(), got,
        "common/ui/metacore/metacustomization/"
        "metacustomization_filtertabsview",
        "NavigationTabs", nav_list, &nav_matches);
    const bool tag_list_ok = rime_list::find_unique_list(
        rows.data(), got, rime_list::kWeaponInfoHeaderPartition,
        "TagLabelsList", tag_list, &tag_matches);
    std::printf("runtime-lists package=%d/%d template=%s "
                "attachment=%d/%d template=%s stat=%d/%d template=%s "
                "nav=%d/%d template='%s' tags=%d/%d template='%s' "
                "fake=%d/%d duplicate=%d/%d\n",
                package_grid_ok ? 1 : 0, package_matches,
                package_grid.item_template.c_str(),
                picker_grid_ok ? 1 : 0, picker_matches,
                picker_grid.item_template.c_str(),
                stat_list_ok ? 1 : 0, stat_matches,
                stat_list.item_template.c_str(),
                nav_list_ok ? 1 : 0, nav_matches,
                nav_list.item_template.c_str(),
                tag_list_ok ? 1 : 0, tag_matches,
                tag_list.item_template.c_str(), fake_list_ok ? 1 : 0,
                fake_list_matches, duplicate_list_ok ? 1 : 0,
                duplicate_matches);

    rime_list::DbdContract attachment_dbd;
    rime_list::DbdContract stat_dbd;
    const bool attachment_dbd_ok = rime_list::load_contract(
        ctx, attachment_dbd, rime_list::kAttachmentDbdPartition);
    const bool stat_dbd_ok = rime_list::load_contract(
        ctx, stat_dbd, rime_list::kIconizedAttributesDbdPartition);
    rime_list::Record attachment_all;
    rime_list::Record stat_all;
    if (attachment_dbd_ok)
        for (const rime_list::DbdField& field : attachment_dbd.fields)
            attachment_all.put(attachment_dbd, field.property_id, null_value);
    if (stat_dbd_ok)
        for (const rime_list::DbdField& field : stat_dbd.fields)
            stat_all.put(stat_dbd, field.property_id, null_value);
    const rime_list::RouteReport attachment_route =
        rime_list::route_contract(ctx, rime_list::kAttachmentDbdPartition,
                                  rime_list::kAttachmentCellPartition, nullptr,
                                  attachment_all);
    const rime_list::RouteReport attachment_shuffle =
        rime_list::route_contract_shuffled_control(
            ctx, rime_list::kAttachmentDbdPartition,
            rime_list::kAttachmentCellPartition, nullptr, attachment_all);
    const rime_list::RouteReport stat_route = rime_list::route_contract(
        ctx, rime_list::kIconizedAttributesDbdPartition,
        rime_list::kIconizedAttributesCellPartition, nullptr, stat_all);
    const rime_list::RouteReport stat_shuffle =
        rime_list::route_contract_shuffled_control(
            ctx, rime_list::kIconizedAttributesDbdPartition,
            rime_list::kIconizedAttributesCellPartition, nullptr, stat_all);
    std::printf("runtime-contracts attachment=%d data=%s fields=%zu "
                "route=%d shuffled=%d stat=%d data=%s fields=%zu "
                "route=%d shuffled=%d\n",
                attachment_dbd_ok ? 1 : 0,
                attachment_dbd.data_name.c_str(), attachment_dbd.fields.size(),
                attachment_route.connected, attachment_shuffle.connected,
                stat_dbd_ok ? 1 : 0, stat_dbd.data_name.c_str(),
                stat_dbd.fields.size(), stat_route.connected,
                stat_shuffle.connected);
    rime::Screen attachment_cell;
    rime::Screen stat_cell;
    const bool attachment_cell_ok = load_item_screen(
        ctx, rime_list::kAttachmentCellPartition, attachment_cell);
    const bool stat_cell_ok = load_item_screen(
        ctx, rime_list::kIconizedAttributesCellPartition, stat_cell);
    rime_list::Record attachment_values;
    rime_list::Record stat_values;
    const rime_list::DbdField* attachment_name =
        rime_list::contract_field(attachment_dbd, "AbbreviatedName");
    const rime_list::DbdField* attachment_default =
        rime_list::contract_field(attachment_dbd, "IsDefault");
    const rime_list::DbdField* attachment_weight =
        rime_list::contract_field(attachment_dbd, "Weight");
    const rime_list::DbdField* attachment_factory =
        rime_list::contract_field(attachment_dbd, "HasLockedFactoryPackage");
    const rime_list::DbdField* attachment_reference =
        rime_list::contract_field(attachment_dbd,
                                  "HasHardwareIconReference");
    const rime_list::DbdField* attachment_empty =
        rime_list::contract_field(attachment_dbd, "IsEmptyAttachment");
    const rime_list::DbdField* attachment_partlooks =
        rime_list::contract_field(attachment_dbd, "HasPartLooks");
    const rime_list::DbdField* stat_value =
        rime_list::contract_field(stat_dbd, "Value");
    const rime_list::DbdField* stat_delta =
        rime_list::contract_field(stat_dbd, "Delta");
    const rime_list::DbdField* stat_delta_visible =
        rime_list::contract_field(stat_dbd, "IsDeltaVisible");
    const rime_list::DbdField* stat_delta_positive =
        rime_list::contract_field(stat_dbd, "IsDeltaPositve");
    const rime_list::DbdField* stat_localized =
        rime_list::contract_field(stat_dbd, "LocalizedValue");
    if (attachment_name)
        attachment_values.put(attachment_dbd, attachment_name->property_id,
                              string_value("LIVE_ATTACHMENT"));
    if (attachment_default)
        attachment_values.put(attachment_dbd,
                              attachment_default->property_id,
                              bool_value(true));
    if (attachment_weight)
        attachment_values.put(attachment_dbd, attachment_weight->property_id,
                              int_value(10));
    if (attachment_factory)
        attachment_values.put(attachment_dbd, attachment_factory->property_id,
                              bool_value(false));
    if (attachment_reference)
        attachment_values.put(attachment_dbd,
                              attachment_reference->property_id,
                              bool_value(false));
    if (attachment_empty)
        attachment_values.put(attachment_dbd, attachment_empty->property_id,
                              bool_value(false));
    if (attachment_partlooks)
        attachment_values.put(attachment_dbd,
                              attachment_partlooks->property_id,
                              bool_value(false));
    if (stat_value)
        stat_values.put(stat_dbd, stat_value->property_id, real_value(0.625));
    if (stat_delta)
        stat_values.put(stat_dbd, stat_delta->property_id, real_value(0.125));
    if (stat_delta_visible)
        stat_values.put(stat_dbd, stat_delta_visible->property_id,
                        bool_value(true));
    if (stat_delta_positive)
        stat_values.put(stat_dbd, stat_delta_positive->property_id,
                        bool_value(true));
    if (stat_localized)
        stat_values.put(stat_dbd, stat_localized->property_id,
                        string_value("62.5"));
    rime::Screen attachment_control = attachment_cell;
    rime::Screen stat_control = stat_cell;
    const rime_list::BindReport attachment_bind = attachment_cell_ok
        ? rime_list::bind_record(attachment_cell,
                                 rime_list::kAttachmentCellPartition,
                                 attachment_dbd, attachment_values)
        : rime_list::BindReport{};
    const rime_list::BindReport attachment_bind_control = attachment_cell_ok
        ? rime_list::bind_record_shuffled_control(
              attachment_control, rime_list::kAttachmentCellPartition,
              attachment_dbd, attachment_values)
        : rime_list::BindReport{};
    const rime_list::BindReport stat_bind = stat_cell_ok
        ? rime_list::bind_record(stat_cell,
                                 rime_list::kIconizedAttributesCellPartition,
                                 stat_dbd, stat_values)
        : rime_list::BindReport{};
    const rime_list::BindReport stat_bind_control = stat_cell_ok
        ? rime_list::bind_record_shuffled_control(
              stat_control, rime_list::kIconizedAttributesCellPartition,
              stat_dbd, stat_values)
        : rime_list::BindReport{};
    uint32_t recursive_child_field = 0;
    std::string recursive_child_partition;
    int recursive_child_routes = 0;
    if (attachment_name)
        for (const rime::Screen::InterfaceTextGraph& graph :
             attachment_cell.interface_text_graphs)
            if (graph.partition == rime_list::kAttachmentCellPartition)
                for (const bf6_rime_connection& wire : graph.connections)
                    if (wire.source_field == attachment_name->provider_id) {
                        const rime::Element* target = nullptr;
                        for (const rime::Element& element :
                             attachment_cell.elements)
                            if (element.partition == graph.partition &&
                                element.instance == wire.target) {
                                target = &element;
                                break;
                            }
                        std::printf("attachment-bind-wire source=%d "
                                    "target=%d target-field=0x%08X "
                                    "kind=%d ref=%s\n", wire.source,
                                    wire.target, wire.target_field,
                                    target ? static_cast<int>(target->kind) : -1,
                                    target ? target->references_widget.c_str()
                                           : "");
                        if (target && target->kind ==
                                          rime::Kind::WidgetReference) {
                            recursive_child_field = wire.target_field;
                            recursive_child_partition =
                                target->references_widget;
                            ++recursive_child_routes;
                        }
                    }
    if (stat_value)
        for (const rime::Screen::InterfaceTextGraph& graph :
             stat_cell.interface_text_graphs)
            if (graph.partition == rime_list::kIconizedAttributesCellPartition)
                for (const bf6_rime_connection& wire : graph.connections)
                    if (wire.source_field == stat_value->provider_id) {
                        const rime::Element* target = nullptr;
                        for (const rime::Element& element : stat_cell.elements)
                            if (element.partition == graph.partition &&
                                element.instance == wire.target) {
                                target = &element;
                                break;
                            }
                        std::printf("stat-bind-wire source=%d target=%d "
                                    "target-field=0x%08X kind=%d ref=%s\n",
                                    wire.source, wire.target, wire.target_field,
                                    target ? static_cast<int>(target->kind) : -1,
                                    target ? target->references_widget.c_str()
                                           : "");
                    }
    rime::Screen recursive_real = attachment_control;
    rime::Screen recursive_shuffled = attachment_control;
    rime::Screen recursive_fake = attachment_control;
    const int recursive_real_applied = recursive_child_routes == 1
        ? rime::set_interface_text_field(
              recursive_real, recursive_child_partition.c_str(),
              recursive_child_field, "RECURSIVE_REAL")
        : 0;
    const int recursive_shuffled_applied = recursive_child_routes == 1
        ? rime::set_interface_text_field(
              recursive_shuffled, recursive_child_partition.c_str(),
              shuffled_hash(recursive_child_field), "RECURSIVE_SHUFFLED")
        : 0;
    const int recursive_fake_applied = recursive_child_routes == 1
        ? rime::set_interface_text_field(
              recursive_fake, "common/ui/__control__/not_a_real_widget",
              recursive_child_field, "RECURSIVE_FAKE")
        : 0;
    std::printf("runtime-binding attachment=%d targets=%d ambiguous=%d "
                "shuffled=%d stat=%d targets=%d ambiguous=%d shuffled=%d\n",
                attachment_bind.applied_fields,
                attachment_bind.applied_targets, attachment_bind.ambiguous,
                attachment_bind_control.applied_fields,
                stat_bind.applied_fields, stat_bind.applied_targets,
                stat_bind.ambiguous, stat_bind_control.applied_fields);
    std::printf("recursive-field routes=%d field=0x%08X part=%s real=%d "
                "shuffled=%d fake=%d\n", recursive_child_routes,
                recursive_child_field, recursive_child_partition.c_str(),
                recursive_real_applied, recursive_shuffled_applied,
                recursive_fake_applied);

    rime::Screen package_screen;
    std::string package_screen_err;
    const bool package_screen_ok = package_tree_ok && rime::from_live(
        package_rows.data(), static_cast<int>(package_rows.size()),
        package_screen, package_screen_err);
    if (package_screen_ok) rime::solve(package_screen, 1920.f, 1080.f);
    const rime::Element* package_grid_element = nullptr;
    for (const rime::Element& element : package_screen.elements)
        if (element.partition == kGridView && element.name == "Weapon Grid" &&
            element.item_template == rime_list::kGridItemCellPartition) {
            if (package_grid_element) {
                package_grid_element = nullptr;
                break;
            }
            package_grid_element = &element;
        }
    rime::Screen package_cell;
    const bool package_cell_ok = load_item_screen(
        ctx, rime_list::kGridItemCellPartition, package_cell);
    rime::UniformGridLayout package_layout;
    const bool package_layout_ok = package_grid_element && package_cell_ok &&
        rime::uniform_grid_layout(*package_grid_element, package_cell,
                                  package_layout);
    if (package_layout_ok)
        rime::solve(package_cell, package_layout.cell_w,
                    package_layout.cell_h);
    rime_list::Record package_value;
    const rime_list::DbdField* package_header =
        rime_list::contract_field(dbd, "Header");
    if (package_header)
        package_value.put(dbd, package_header->property_id,
                          string_value("LIVE_PACKAGE"));
    std::vector<rime::Element> package_items;
    rime_list::BindReport package_append_bind;
    const bool package_append_ok = package_layout_ok &&
        rime_list::append_bound_grid_item(
            package_cell, package_layout, dbd, package_value,
            rime_list::kGridItemCellPartition, package_layout.x0,
            package_layout.y0, 0, package_items, &package_append_bind);

    rime::Screen picker_screen;
    std::string picker_screen_err;
    const bool picker_screen_ok = picker_tree_ok && rime::from_live(
        picker_rows.data(), static_cast<int>(picker_rows.size()),
        picker_screen, picker_screen_err);
    if (picker_screen_ok) rime::solve(picker_screen, 1920.f, 1080.f);
    const rime::Element* picker_grid_element = nullptr;
    for (const rime::Element& element : picker_screen.elements)
        if (element.partition == kPicker && element.name == "Selection Grid" &&
            element.item_template == rime_list::kAttachmentCellPartition) {
            if (picker_grid_element) {
                picker_grid_element = nullptr;
                break;
            }
            picker_grid_element = &element;
        }
    rime::Screen picker_cell;
    const bool picker_cell_ok = load_item_screen(
        ctx, rime_list::kAttachmentCellPartition, picker_cell);
    if (picker_cell_ok) {
        int layer = -1;
        for (size_t i = 0; i < picker_cell.elements.size(); ++i)
            if (picker_cell.elements[i].parent < 0) layer = static_cast<int>(i);
        for (size_t i = 0; i < picker_cell.elements.size(); ++i) {
            const rime::Element& element = picker_cell.elements[i];
            const bool depth_one = element.parent == layer;
            const bool depth_two = element.parent >= 0 &&
                picker_cell.elements[(size_t)element.parent].parent == layer;
            if (!depth_one && !depth_two) continue;
            std::printf("picker-cell-element index=%zu parent=%d kind=%d name=%s "
                        "w=%.3f h=%.3f ah=%.3f/%.3f av=%.3f/%.3f widget=%s\n", i,
                        element.parent, static_cast<int>(element.kind),
                        element.name.c_str(), element.width, element.height,
                        element.h.anchor_start, element.h.anchor_end,
                        element.v.anchor_start, element.v.anchor_end,
                        element.references_widget.c_str());
        }
    }
    rime::UniformGridLayout picker_layout;
    if (picker_grid_element)
        std::printf("picker-grid box=%.3f/%.3f-%.3f/%.3f sizes=%.3f/%.3f "
                    "static=%d mode=%d dist=%d fit=%d gaps=%.3f/%.3f\n",
                    picker_grid_element->x0, picker_grid_element->y0,
                    picker_grid_element->x1, picker_grid_element->y1,
                    picker_grid_element->grid_column_size,
                    picker_grid_element->grid_row_size,
                    picker_grid_element->grid_static_segment_item_count,
                    picker_grid_element->grid_segment_count_mode,
                    picker_grid_element->grid_segment_distribution,
                    picker_grid_element->grid_item_fit_content,
                    picker_grid_element->grid_column_spacing,
                    picker_grid_element->grid_row_spacing);
    const bool picker_layout_ok = picker_grid_element && picker_cell_ok &&
        rime::uniform_grid_layout(*picker_grid_element, picker_cell,
                                  picker_layout);
    if (picker_layout_ok)
        rime::solve(picker_cell, picker_layout.cell_w, picker_layout.cell_h);
    rime_list::Record picker_value;
    if (attachment_name)
        picker_value.put(attachment_dbd, attachment_name->property_id,
                         string_value("LIVE_ATTACHMENT"));
    std::vector<rime::Element> picker_items;
    rime_list::BindReport picker_append_bind;
    const bool picker_append_ok = picker_layout_ok &&
        rime_list::append_bound_grid_item(
            picker_cell, picker_layout, attachment_dbd, picker_value,
            rime_list::kAttachmentCellPartition, picker_layout.x0,
            picker_layout.y0, 0, picker_items, &picker_append_bind);
    std::printf("runtime-materialize package=%d layout=%d columns=%d "
                "bind=%d/%d elements=%zu attachment=%d layout=%d columns=%d "
                "bind=%d/%d "
                "elements=%zu\n", package_append_ok ? 1 : 0,
                package_layout_ok ? 1 : 0, package_layout.columns,
                package_append_bind.applied_fields,
                package_append_bind.applied_targets, package_items.size(),
                picker_append_ok ? 1 : 0, picker_layout_ok ? 1 : 0,
                picker_layout.columns,
                picker_append_bind.applied_fields,
                picker_append_bind.applied_targets, picker_items.size());

    bool ok = true;
    ok = ok && contract.interface_descriptors > 0;
    ok = ok && contract.exact_root_wires == 1;
    ok = ok && contract.bottom_cap_wires == 1;
    ok = ok && contract.wrong_target_wires == 0;
    ok = ok && !contract.lists.empty();
    ok = ok && fake_collection.exact_root_wires == 0;
    ok = ok && fake_partition == -1;
    ok = ok && dbd_ok && dbd.data_name == "MetaCustomization_GridItemData";
    ok = ok && dbd.fields.size() == ni && dbd_catalogue_matches == (int)ni;
    ok = ok && direct_dbd_count == static_cast<int>(ni);
    ok = ok && std::strcmp(direct_dbd_name, dbd.data_name.c_str()) == 0;
    ok = ok && dbd_direct_matches == static_cast<int>(ni);
    ok = ok && direct_fake_dbd_count == -1;
    ok = ok && !fake_dbd_ok;
    ok = ok && real_route.connected == 29;
    ok = ok && shuffled_route.connected == 0;
    ok = ok && real_route.connected > shuffled_route.connected;
    ok = ok && weapon_name_count > 0 &&
        weapon_name_got == weapon_name_count && m4_name;
    ok = ok && factory_localized && m4_name &&
        std::strcmp(factory_localized, m4_name->factory_label) == 0;
    ok = ok && m4_name && m4_name->icon_asset[0] &&
        m4_icon_texture >= 0 && m4_icon && m4_icon->data_len > 0;
    ok = ok && fake_icon_texture == -1;
    ok = ok && fake_weapon_rows == 0 && !fake_localized &&
        !armory_fake_field_accepted;
    ok = ok && armory_card_ok && armory_record_ok;
    ok = ok && armory_card_bind.supplied == 4 &&
        armory_card_bind.applied_fields == 4 &&
        armory_card_bind.applied_targets >= 4;
    ok = ok && armory_name_labels >= 1 && armory_factory_labels >= 1;
    ok = ok && armory_card_shuffle.applied_fields == 0 &&
        armory_control_labels == 0;
    ok = ok && header_dbd_ok;
    ok = ok && header_dbd.data_name ==
        "MetaCustomization_HeaderInfoData";
    ok = ok && header_dbd.fields.size() == nh;
    ok = ok && header_catalogue_matches == static_cast<int>(nh);
    ok = ok && !fake_header_dbd_ok && !fake_header_field_accepted;
    ok = ok && header_title_by_name && header_title_by_id;
    ok = ok && header_title_by_name == header_title_by_id;
    ok = ok && header_title_by_name->provider_id == 0xA271E44Au;
    ok = ok && !fake_header_name;
    ok = ok && header_route.connected == 16;
    ok = ok && header_route.unrouted == 7;
    ok = ok && header_shuffled.connected == 0;
    ok = ok && header_fake_target.connected == 0;
    ok = ok && header_fake_dbd.connected == 0;
    ok = ok && header_route.connected > header_shuffled.connected;
    ok = ok && header_screen_ok && header_title_field &&
        header_category_field;
    ok = ok && header_defaults_applied > 0 && header_default_edges == 1;
    /* The real authored bool crosses the WidgetReference and selects Category
     * for Title while HeaderTitle remains Subtitle.  Perturbing the exact
     * child field, or its partition, leaves the authored-false null model:
     * HeaderTitle is duplicated and Category does not reach Title. */
    ok = ok && default_real_title == 1 && default_real_subtitle == 1 &&
        default_real_duplicate == 1;
    ok = ok && header_default_shuffled_set == 0 &&
        default_shuffled_title == 0 && default_shuffled_subtitle == 1 &&
        default_shuffled_duplicate == 2;
    ok = ok && header_default_fake_set == 0 && default_fake_title == 0 &&
        default_fake_subtitle == 1 && default_fake_duplicate == 2;
    ok = ok && header_bind.supplied == 2 && header_bind.declared == 2;
    ok = ok && header_bind.applied_fields == 2 && header_bind.unrouted == 0 &&
        title_control_labels == 1 && category_control_labels == 1;
    ok = ok && header_title_only_bind.applied_fields == 1 &&
        title_only_labels == 1;
    ok = ok && header_category_only_bind.applied_fields == 1 &&
        category_only_labels == 1;
    ok = ok && header_bind_shuffled.applied_fields == 0 &&
        shuffled_control_labels == 0;
    ok = ok && package_grid_ok && package_matches == 1;
    ok = ok && package_grid.item_template ==
        rime_list::kGridItemCellPartition;
    ok = ok && picker_grid_ok && picker_matches == 1;
    ok = ok && picker_grid.item_template ==
        rime_list::kAttachmentCellPartition;
    ok = ok && stat_list_ok && stat_matches == 1;
    ok = ok && stat_list.item_template ==
        rime_list::kIconizedAttributesCellPartition;
    ok = ok && nav_list_ok && nav_matches == 1 &&
        nav_list.item_template.empty();
    ok = ok && tag_list_ok && tag_matches == 1 &&
        tag_list.item_template.empty();
    ok = ok && !fake_list_ok && fake_list_matches == 0;
    ok = ok && !duplicate_list_ok && duplicate_matches == 2;
    ok = ok && attachment_dbd_ok && attachment_dbd.fields.size() == 21;
    ok = ok && stat_dbd_ok && stat_dbd.fields.size() == 10;
    ok = ok && attachment_route.connected == 15 &&
        attachment_shuffle.connected == 0;
    ok = ok && stat_route.connected == 6 && stat_shuffle.connected == 0;
    ok = ok && attachment_name && attachment_default && stat_value &&
        stat_delta;
    ok = ok && attachment_bind.applied_fields == 3 &&
        attachment_bind_control.applied_fields == 0;
    ok = ok && stat_bind.applied_fields == 1 &&
        stat_bind_control.applied_fields == 0;
    ok = ok && recursive_child_routes == 1 && recursive_real_applied > 0;
    ok = ok && recursive_shuffled_applied == 0 &&
        recursive_fake_applied == 0;
    ok = ok && package_screen_ok && package_layout_ok && package_header;
    ok = ok && package_layout.columns == 4;
    ok = ok && package_append_ok && package_append_bind.applied_fields == 1 &&
        package_items.size() == package_cell.elements.size();
    ok = ok && picker_screen_ok && picker_layout_ok;
    ok = ok && picker_layout.columns == 6 &&
        std::fabs(picker_layout.cell_w - 166.f) < 0.001f &&
        std::fabs(picker_layout.cell_h - 142.f) < 0.001f;
    ok = ok && picker_append_ok && picker_append_bind.applied_fields == 1 &&
        picker_items.size() == picker_cell.elements.size();

    bf6_close(ctx);
    if (!ok) {
        std::fprintf(stderr, "live list/provider contract failed\n");
        return 1;
    }
    return 0;
}
