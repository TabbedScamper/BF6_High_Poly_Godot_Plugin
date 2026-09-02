#include "bf6_core.h"
#include "rime_list_provider.h"

#include <algorithm>
#include <array>
#include <cctype>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <string>
#include <unordered_set>
#include <vector>

namespace {

using Guid = std::array<uint8_t, 16>;

struct Fixup {
    Guid partition{};
    std::vector<Guid> imports;
};

uint32_t u32(const uint8_t* data)
{
    uint32_t value = 0;
    std::memcpy(&value, data, sizeof(value));
    return value;
}

bool add_fits(size_t value, size_t add, size_t limit)
{
    return value <= limit && add <= limit - value;
}

bool mul_fits(uint32_t count, size_t width, size_t remain)
{
    return width == 0 || static_cast<size_t>(count) <= remain / width;
}

/* Parse only the EFIX partition/import identity needed by this proof.  This is
 * the Frostbite 2021+ order already used by the core Ebx reader: partition,
 * type GUIDs, type signatures, exported count, instance/pointer/resource
 * fixups, then 32-byte (partition GUID, instance GUID) import records.  No
 * executable reflection and no exported GUID table participates. */
bool parse_fixup(const uint8_t* data, size_t size, Fixup& out)
{
    out = Fixup{};
    if (!data || size < 12 || std::memcmp(data, "RIFF", 4) != 0)
        return false;

    size_t efix = 0;
    size_t efix_size = 0;
    for (size_t offset = 12; add_fits(offset, 8, size);) {
        const uint32_t chunk_size = u32(data + offset + 4);
        const size_t payload = offset + 8;
        if (!add_fits(payload, chunk_size, size)) return false;
        if (std::memcmp(data + offset, "EFIX", 4) == 0) {
            efix = payload;
            efix_size = chunk_size;
            break;
        }
        size_t next = payload + chunk_size;
        if (next & 1u) ++next;
        if (next <= offset) return false;
        offset = next;
    }
    if (!efix || efix_size < 16 || !add_fits(efix, efix_size, size))
        return false;

    size_t cursor = efix;
    const size_t end = efix + efix_size;
    auto take = [&](size_t bytes, const uint8_t** pointer = nullptr) {
        if (!add_fits(cursor, bytes, end)) return false;
        if (pointer) *pointer = data + cursor;
        cursor += bytes;
        return true;
    };
    auto count_and_skip = [&](size_t width) {
        const uint8_t* raw = nullptr;
        if (!take(4, &raw)) return false;
        const uint32_t count = u32(raw);
        const size_t remain = end - cursor;
        return mul_fits(count, width, remain) &&
               take(static_cast<size_t>(count) * width);
    };

    const uint8_t* partition = nullptr;
    if (!take(16, &partition)) return false;
    std::copy_n(partition, 16, out.partition.begin());
    if (!count_and_skip(16) || !count_and_skip(4)) return false;
    if (!take(4)) return false; // exported instance count
    if (!count_and_skip(4) || !count_and_skip(4) || !count_and_skip(4))
        return false;

    const uint8_t* raw_count = nullptr;
    if (!take(4, &raw_count)) return false;
    const uint32_t import_count = u32(raw_count);
    if (!mul_fits(import_count, 32, end - cursor)) return false;
    out.imports.reserve(import_count);
    for (uint32_t index = 0; index < import_count; ++index) {
        const uint8_t* record = nullptr;
        if (!take(32, &record)) return false;
        Guid imported{};
        std::copy_n(record, 16, imported.begin());
        out.imports.push_back(imported);
    }
    return true;
}

bool raw_fixup(bf6_ctx* ctx, const char* partition, Fixup& out)
{
    const uint8_t* data = nullptr;
    const int64_t bytes = bf6_read_raw(ctx, BF6_RAW_EBX, partition, &data);
    return bytes > 0 && parse_fixup(data, static_cast<size_t>(bytes), out);
}

bool has_import(const Fixup& value, const Guid& target)
{
    return std::find(value.imports.begin(), value.imports.end(), target) !=
           value.imports.end();
}

bool starts_with(const char* value, const char* prefix)
{
    return value && prefix &&
           std::strncmp(value, prefix, std::strlen(prefix)) == 0;
}

bool cell_basename(const char* value)
{
    if (!value) return false;
    const char* leaf = std::strrchr(value, '/');
    leaf = leaf ? leaf + 1 : value;
    std::string folded(leaf);
    std::transform(folded.begin(), folded.end(), folded.begin(),
                   [](unsigned char ch) { return static_cast<char>(std::tolower(ch)); });
    return folded.find("cell") != std::string::npos;
}

bool contains_folded(const char* value, const char* needle)
{
    if (!value || !needle) return false;
    std::string folded(value);
    std::transform(folded.begin(), folded.end(), folded.begin(),
                   [](unsigned char ch) { return static_cast<char>(std::tolower(ch)); });
    return folded.find(needle) != std::string::npos;
}

struct Contract {
    const char* label;
    const char* dbd;
    const char* expected_cell;
    Guid guid{};
    std::vector<std::string> matches;
};

struct ImportTarget {
    const char* label;
    const char* partition;
    Guid guid{};
    std::vector<std::string> matches;
};

rime_list::Value text_value()
{
    rime_list::Value value{};
    value.kind = rime_list::ValueKind::String;
    value.string = "CONTROL";
    return value;
}

rime_list::Value string_value(const std::string& text)
{
    rime_list::Value value{};
    value.kind = rime_list::ValueKind::String;
    value.string = text;
    return value;
}

rime_list::Value bool_value(bool boolean)
{
    rime_list::Value value{};
    value.kind = rime_list::ValueKind::Bool;
    value.boolean = boolean;
    return value;
}

bool load_cell_screen(bf6_ctx* ctx, const char* partition,
                      rime::Screen& screen)
{
    bf6_rime_tree_stats stats{};
    const int count = bf6_rime_tree(ctx, partition, 6, nullptr, 0, &stats);
    if (count <= 0) return false;
    std::vector<bf6_rime_node> rows(static_cast<size_t>(count));
    if (bf6_rime_tree(ctx, partition, 6, rows.data(), count, &stats) != count)
        return false;
    std::string error;
    return rime::from_live(rows.data(), count, screen, error) &&
           rime::load_interface_text_graphs(ctx, screen) > 0;
}

} // namespace

int main(int argc, char** argv)
{
    if (argc != 2) {
        std::fprintf(stderr, "usage: rime_dynamic_list_cell_test <game-dir>\n");
        return 2;
    }
    char error[512]{};
    bf6_ctx* ctx = bf6_open(argv[1], error, static_cast<int>(sizeof(error)));
    if (!ctx) {
        std::fprintf(stderr, "open failed: %s\n", error);
        return 2;
    }
    if (!bf6_mount_frontend(ctx, error, static_cast<int>(sizeof(error)))) {
        std::fprintf(stderr, "mount failed: %s\n", error);
        bf6_close(ctx);
        return 2;
    }

    Contract contracts[] = {
        {"NavigationTabs",
         "common/ui/universalmenu/assets/databindings/um_navigationdatadbd",
         "common/ui/universalmenu/widgets/universalpanellistcells/um_navigationdatacell"},
        {"TagLabelsList",
         "common/ui/weaponcustomization/assets/databindings/archetypesdbd",
         "common/ui/weapons/widgets/menuweapontagcell"},
    };
    ImportTarget import_targets[] = {
        {"CategoryLabelDBD",
         rime_list::kCategoryLabelDbdPartition},
        {"CollapseButtonDBD",
         rime_list::kCollapseButtonDbdPartition},
        {"NavigationButtonListInterface",
         "common/ui/universalmenu/assets/listinterfaces/"
         "um_navigationbuttonlistcellinterface"},
        {"WeaponCollectionColumnDBD",
         rime_list::kWeaponCollectionColumnDbdPartition},
        {"WeaponProficiencyDBD",
         "common/ui/weapons/assets/databindings/weaponproficiencydbd"},
    };

    bool ok = true;
    const int navigation_row_count =
        bf6_weapon_navigation_rows(ctx, nullptr, 0);
    std::vector<bf6_weapon_navigation_row> navigation_rows(
        static_cast<size_t>(navigation_row_count > 0 ?
                            navigation_row_count : 0));
    const int navigation_rows_got = navigation_row_count > 0
        ? bf6_weapon_navigation_rows(ctx, navigation_rows.data(),
                                     navigation_row_count)
        : navigation_row_count;
    int ordered_rows = 0, nonempty_icons = 0, rotated_order = 0;
    std::unordered_set<int32_t> ordinals;
    for (int index = 0; index < navigation_rows_got; ++index) {
        const bf6_weapon_navigation_row& row =
            navigation_rows[static_cast<size_t>(index)];
        if (row.ordinal == index) ++ordered_rows;
        if (row.icon_asset[0]) ++nonempty_icons;
        ordinals.insert(row.ordinal);
        if (navigation_rows_got > 1 &&
            navigation_rows[static_cast<size_t>((index + 1) %
                                                navigation_rows_got)].ordinal ==
                index)
            ++rotated_order;
    }
    std::printf("weapon-navigation-config\trows=%d/%d\tordered=%d\t"
                "icons=%d\tunique-ordinals=%zu\trotated=%d\n",
                navigation_rows_got, navigation_row_count, ordered_rows,
                nonempty_icons, ordinals.size(), rotated_order);
    ok = ok && navigation_row_count > 0 &&
         navigation_rows_got == navigation_row_count &&
         ordered_rows == navigation_row_count &&
         nonempty_icons == navigation_row_count &&
         ordinals.size() == static_cast<size_t>(navigation_row_count) &&
         rotated_order == 0;

    const int identity_count = bf6_weapon_names(ctx, nullptr, 0);
    std::vector<bf6_weapon_name_row> identities(
        static_cast<size_t>(identity_count > 0 ? identity_count : 0));
    const int identities_got = identity_count > 0
        ? bf6_weapon_names(ctx, identities.data(), identity_count) : -1;
    auto normalized = [](std::string value) {
        std::transform(value.begin(), value.end(), value.begin(),
                       [](unsigned char ch) {
                           return static_cast<char>(std::tolower(ch));
                       });
        if (value.size() > 4 &&
            value.compare(value.size() - 4, 4, ".ebx") == 0)
            value.resize(value.size() - 4);
        return value;
    };
    std::unordered_set<std::string> category_icons;
    for (const bf6_weapon_name_row& identity : identities)
        if (identity.category_icon_asset[0])
            category_icons.insert(normalized(identity.category_icon_asset));
    int category_real = 0, category_fake = 0, primary_real = 0;
    size_t primary_start = navigation_rows.size();
    std::unordered_set<std::string> config_icons_seen;
    for (size_t index = 0; index < navigation_rows.size(); ++index) {
        const bf6_weapon_navigation_row& row = navigation_rows[index];
        const std::string icon = normalized(row.icon_asset);
        if (primary_start == navigation_rows.size() &&
            !config_icons_seen.insert(icon).second)
            primary_start = index;
        if (category_icons.count(icon)) ++category_real;
        if (index >= primary_start && category_icons.count(icon))
            ++primary_real;
        if (category_icons.count("fake/control/" + icon)) ++category_fake;
    }
    std::printf("weapon-navigation-category-join\tidentities=%d/%d\t"
                "unique-category-icons=%zu\treal=%d\tprimary=%d/%zu\t"
                "fake=%d\n",
                identities_got, identity_count, category_icons.size(),
                category_real, primary_real,
                navigation_rows.size() - primary_start, category_fake);
    ok = ok && identities_got == identity_count &&
         primary_start < navigation_rows.size() &&
         primary_real == static_cast<int>(navigation_rows.size() -
                                         primary_start) &&
         category_fake == 0;
    for (Contract& contract : contracts) {
        Fixup dbd{};
        const bool read = raw_fixup(ctx, contract.dbd, dbd);
        std::printf("dbd\t%s\tread=%d\n", contract.dbd, read ? 1 : 0);
        ok = ok && read;
        if (read) contract.guid = dbd.partition;
    }
    for (ImportTarget& target : import_targets) {
        Fixup value{};
        const bool read = raw_fixup(ctx, target.partition, value);
        std::printf("import-target\t%s\tread=%d\n", target.partition,
                    read ? 1 : 0);
        ok = ok && read;
        if (read) target.guid = value.partition;
    }

    /* The visual cell is selected by the record type emitted by the shipped
     * list generator, not by choosing among widgets that happen to implement
     * the generic navigation interface. */
    Fixup navigation_generator{};
    const bool generator_read = raw_fixup(
        ctx, rime_list::kWeaponNavigationGeneratorPartition,
        navigation_generator);
    std::printf("navigation-generator\tread=%d\n", generator_read ? 1 : 0);
    ok = ok && generator_read;
    Fixup back_button{};
    Fixup fake_back_button{};
    const bool back_button_read = raw_fixup(
        ctx, rime_list::kBackButtonPartition, back_button);
    const bool fake_back_button_read = raw_fixup(
        ctx, "common/ui/universalmenu/widgets/visual/__control_backbutton",
        fake_back_button);
    std::printf("back-button\treal=%d\tfake=%d\n",
                back_button_read ? 1 : 0,
                fake_back_button_read ? 1 : 0);
    ok = ok && back_button_read && !fake_back_button_read;

    const int asset_count = bf6_list_ebx(ctx, nullptr, nullptr, 0);
    std::vector<bf6_asset> assets(static_cast<size_t>(std::max(asset_count, 0)));
    const int got = asset_count > 0
        ? bf6_list_ebx(ctx, nullptr, assets.data(), asset_count) : 0;
    int cells = 0;
    int malformed = 0;
    for (int index = 0; index < got; ++index) {
        const char* name = assets[static_cast<size_t>(index)].name;
        if (!starts_with(name, "common/ui/") || !cell_basename(name)) continue;
        ++cells;
        Fixup cell{};
        if (!raw_fixup(ctx, name, cell)) {
            ++malformed;
            continue;
        }
        for (Contract& contract : contracts)
            if (has_import(cell, contract.guid)) contract.matches.emplace_back(name);
        for (ImportTarget& target : import_targets)
            if (has_import(cell, target.guid)) target.matches.emplace_back(name);
    }
    for (ImportTarget& target : import_targets) {
        std::sort(target.matches.begin(), target.matches.end());
        std::printf("import-cell\t%s\tmatches=%zu", target.label,
                    target.matches.size());
        for (const std::string& match : target.matches)
            std::printf("\t%s", match.c_str());
        std::printf("\n");
    }
    const auto collapse_target = std::find_if(
        std::begin(import_targets), std::end(import_targets),
        [](const ImportTarget& value) {
            return std::strcmp(value.label, "CollapseButtonDBD") == 0;
        });
    const auto column_target = std::find_if(
        std::begin(import_targets), std::end(import_targets),
        [](const ImportTarget& value) {
            return std::strcmp(value.label, "WeaponCollectionColumnDBD") == 0;
        });
    const bool generator_emits_collapse =
        collapse_target != std::end(import_targets) && generator_read &&
        has_import(navigation_generator, collapse_target->guid);
    const bool generator_reads_columns =
        column_target != std::end(import_targets) && generator_read &&
        has_import(navigation_generator, column_target->guid);
    const bool unique_collapse_cell =
        collapse_target != std::end(import_targets) &&
        collapse_target->matches.size() == 1 &&
        collapse_target->matches.front() ==
            rime_list::kCollapseButtonCellPartition;
    Guid perturbed_collapse = collapse_target != std::end(import_targets)
        ? collapse_target->guid : Guid{};
    perturbed_collapse[0] ^= 0x80u;
    const bool perturbed_generator_match = generator_read &&
        has_import(navigation_generator, perturbed_collapse);
    std::printf(
        "navigation-record-path\tcolumns=%d\tcollapse=%d\tcell=%d\t"
        "perturbed=%d\n",
        generator_reads_columns ? 1 : 0,
        generator_emits_collapse ? 1 : 0,
        unique_collapse_cell ? 1 : 0,
        perturbed_generator_match ? 1 : 0);
    ok = ok && generator_reads_columns && generator_emits_collapse &&
         unique_collapse_cell && !perturbed_generator_match;

    rime_list::DbdContract category_label_contract{};
    rime_list::DbdContract collapse_contract{};
    rime_list::DbdContract column_contract{};
    rime_list::DbdContract fake_contract{};
    const bool category_contract_ok = rime_list::load_contract(
        ctx, category_label_contract,
        rime_list::kCategoryLabelDbdPartition);
    const bool collapse_contract_ok = rime_list::load_contract(
        ctx, collapse_contract, rime_list::kCollapseButtonDbdPartition);
    const bool column_contract_ok = rime_list::load_contract(
        ctx, column_contract,
        rime_list::kWeaponCollectionColumnDbdPartition);
    const bool fake_contract_ok = rime_list::load_contract(
        ctx, fake_contract,
        "common/ui/universalmenu/assets/databindings/__control_navigationdbd");
    const bool category_fields = category_contract_ok &&
        rime_list::contract_field(category_label_contract, "Label") &&
        rime_list::contract_field(category_label_contract, "IsVisible");
    const bool collapse_fields = collapse_contract_ok &&
        rime_list::contract_field(collapse_contract, "Label") &&
        rime_list::contract_field(collapse_contract, "ButtonType") &&
        rime_list::contract_field(collapse_contract, "IsSelected");
    const bool column_fields = column_contract_ok &&
        rime_list::contract_field(column_contract, "Name") &&
        rime_list::contract_field(column_contract, "FilteredOut") &&
        rime_list::contract_field(column_contract, "IsFocused");
    std::printf(
        "navigation-provider-contracts\tcategory=%d\tcollapse=%d\t"
        "column=%d\tfake=%d\n",
        category_fields ? 1 : 0, collapse_fields ? 1 : 0,
        column_fields ? 1 : 0, fake_contract_ok ? 1 : 0);
    ok = ok && category_fields && collapse_fields && column_fields &&
         !fake_contract_ok;

    rime::Screen collapse_cell{};
    const bool collapse_cell_ok = load_cell_screen(
        ctx, rime_list::kCollapseButtonCellPartition, collapse_cell);
    const char* collapse_bool_fields[] = {
        "IsDisabled", "IsSelected", "IsVisible", "IsInteractionBlocked",
        "IsLabelHidden", "IsIconlHidden", "IsUnselectedLabelVisible",
        "IsProficiencyVisible", "IsFitWidthToContent"
    };
    std::printf("collapse-bool-routes");
    for (const char* name : collapse_bool_fields) {
        const rime_list::DbdField* field =
            rime_list::contract_field(collapse_contract, name);
        rime_list::Record one{};
        if (field) one.put(collapse_contract, field->property_id,
                           bool_value(true));
        rime::Screen probe = collapse_cell;
        const rime_list::BindReport report =
            collapse_cell_ok && field
                ? rime_list::bind_record(
                      probe, rime_list::kCollapseButtonCellPartition,
                      collapse_contract, one)
                : rime_list::BindReport{};
        std::printf("\t%s=%d/%d", name, report.applied_fields,
                    report.applied_targets);
    }
    std::printf("\n");

    const auto category_target = std::find_if(
        std::begin(import_targets), std::end(import_targets),
        [](const ImportTarget& value) {
            return std::strcmp(value.label, "CategoryLabelDBD") == 0;
        });
    const bool unique_category_cell =
        category_target != std::end(import_targets) &&
        category_target->matches.size() == 1 &&
        category_target->matches.front() ==
            rime_list::kCategoryLabelCellPartition;
    std::printf("title-cell-path\tunique=%d\n",
                unique_category_cell ? 1 : 0);
    ok = ok && unique_category_cell;

    /* LocalizedString entities are the only acceptable source for authored
     * presentation text.  Census the bounded armory/view-model neighborhood
     * from this mounted install; the output is diagnostic evidence, never a
     * table consumed by the viewer. */
    int localized_entities = 0;
    for (int index = 0; index < got; ++index) {
        const char* name = assets[static_cast<size_t>(index)].name;
        const bool armory_logic = starts_with(name, "common/ui/weapons/") &&
            (contains_folded(name, "menuweapon") ||
             contains_folded(name, "weaponcollection") ||
             contains_folded(name, "viewlogic"));
        const bool panel_logic = starts_with(name, "common/ui/universalmenu/logic/") &&
            (contains_folded(name, "panel") ||
             contains_folded(name, "category"));
        if (!armory_logic && !panel_logic) continue;
        for (int instance = 0; instance < 256; ++instance) {
            const uint32_t sid = bf6_rime_string_entity(ctx, name, instance);
            if (!sid) continue;
            /* A real entity is sufficient for the positive side of this
             * reader control; the text itself is not a title oracle. */
            (void)bf6_localized_string(ctx, sid);
            ++localized_entities;
        }
    }
    const uint32_t fake_localized = bf6_rime_string_entity(
        ctx, "common/ui/__control__/missing_armory_title", 0);
    std::printf("localized-control\treal=%d\tfake=%u\n",
                localized_entities, fake_localized);
    ok = ok && fake_localized == 0;

    int real = 0;
    int rotated = 0;
    for (size_t index = 0; index < std::size(contracts); ++index) {
        Contract& contract = contracts[index];
        std::sort(contract.matches.begin(), contract.matches.end());
        const bool unique = contract.matches.size() == 1;
        const bool expected = unique &&
            contract.matches.front() == contract.expected_cell;
        real += expected ? 1 : 0;
        std::printf("resolve\t%s\tmatches=%zu\texpected=%d",
                    contract.label, contract.matches.size(), expected ? 1 : 0);
        for (const std::string& match : contract.matches)
            std::printf("\t%s", match.c_str());
        std::printf("\n");
        ok = ok && expected;

        Fixup expected_cell{};
        const bool cell_read = raw_fixup(ctx, contract.expected_cell,
                                         expected_cell);
        const Guid& wrong = contracts[(index + 1) % std::size(contracts)].guid;
        rotated += cell_read && has_import(expected_cell, wrong) ? 1 : 0;

        rime_list::DbdContract dbd{};
        const bool dbd_ok = rime_list::load_contract(ctx, dbd, contract.dbd);
        rime_list::Record record{};
        if (dbd_ok) {
            std::printf("contract\t%s\tdata=%s", contract.label,
                        dbd.data_name.c_str());
            for (const rime_list::DbdField& field : dbd.fields) {
                std::printf("\t%s:%08x:%08x:%016llx", field.name.c_str(),
                            field.property_id, field.provider_id,
                            static_cast<unsigned long long>(field.type_signature));
                record.put(dbd, field.property_id, text_value());
            }
            std::printf("\n");
        }
        const rime_list::RouteReport route = dbd_ok
            ? rime_list::route_contract(ctx, contract.dbd,
                                        contract.expected_cell, nullptr, record)
            : rime_list::RouteReport{};
        const rime_list::RouteReport shuffled = dbd_ok
            ? rime_list::route_contract_shuffled_control(
                  ctx, contract.dbd, contract.expected_cell, nullptr, record)
            : rime_list::RouteReport{};
        std::printf("route\t%s\tfields=%zu\tconnected=%d\tshuffled=%d\n",
                    contract.label, dbd.fields.size(), route.connected,
                    shuffled.connected);
        ok = ok && dbd_ok && !dbd.fields.empty() &&
             route.connected > shuffled.connected;
    }

    /* One executable collection-to-cell slice, using the weapon metadata's
     * current localized trait rather than a synthetic label.  NavigationData
     * intentionally has no label field, so it is not coerced into the class
     * tabs here; its four fields are input concepts/background/sound state. */
    bf6_weapon_ui_info weapon{};
    const bool weapon_ok = bf6_weapon_ui_info_read(ctx, "m4a1", &weapon) != 0 &&
                           weapon.trait_count > 0 && weapon.traits[0];
    const std::string trait = weapon_ok ? weapon.traits[0] : std::string();
    rime_list::DbdContract tag_dbd{};
    const bool tag_dbd_ok = rime_list::load_contract(ctx, tag_dbd,
                                                     contracts[1].dbd);
    const rime_list::DbdField* archetype =
        rime_list::contract_field(tag_dbd, "Archetype");
    const rime_list::DbdField* icon_visibility =
        rime_list::contract_field(tag_dbd, "ArchetypeIconVisibility");
    rime_list::Record tag_record{};
    if (archetype)
        tag_record.put(tag_dbd, archetype->property_id, string_value(trait));
    /* The source array is LocalizedString pointers. It carries no icon row,
     * so the exact DBD projection has false icon visibility. */
    if (icon_visibility)
        tag_record.put(tag_dbd, icon_visibility->property_id,
                       bool_value(false));
    rime::Screen tag_screen{};
    const bool tag_screen_ok = load_cell_screen(ctx, contracts[1].expected_cell,
                                                tag_screen);
    rime::Screen tag_control = tag_screen;
    const rime_list::BindReport tag_bind = tag_screen_ok
        ? rime_list::bind_record(tag_screen, contracts[1].expected_cell,
                                 tag_dbd, tag_record)
        : rime_list::BindReport{};
    const rime_list::BindReport tag_shuffle = tag_screen_ok
        ? rime_list::bind_record_shuffled_control(
              tag_control, contracts[1].expected_cell, tag_dbd, tag_record)
        : rime_list::BindReport{};
    int bound_labels = 0, visible_icons = 0;
    for (const rime::Element& element : tag_screen.elements) {
        if (element.kind == rime::Kind::Label && element.text == trait)
            ++bound_labels;
        if (element.kind == rime::Kind::Svg && element.visible)
            ++visible_icons;
    }
    std::printf("live-tag\tweapon=m4a1\ttrait=%s\tsupplied=%d"
                "\tapplied=%d/%d\tshuffled=%d/%d\n",
                trait.c_str(), tag_bind.supplied, tag_bind.applied_fields,
                tag_bind.applied_targets, tag_shuffle.applied_fields,
                tag_shuffle.applied_targets);
    std::printf("live-tag-state\tlabels=%d\tvisible-icons=%d\n",
                bound_labels, visible_icons);
    ok = ok && weapon_ok && tag_dbd_ok && archetype &&
         icon_visibility && tag_bind.applied_fields == 2 &&
         tag_bind.applied_targets >= 2 && bound_labels == 1 &&
         visible_icons == 0 &&
         tag_shuffle.applied_fields == 0 && tag_shuffle.applied_targets == 0;

    Fixup rejected{};
    const bool rejected_read = raw_fixup(
        ctx, "common/ui/componentlibrary/components/buttons/cl_categorycell",
        rejected);
    const bool category_wrong = rejected_read &&
        has_import(rejected, contracts[0].guid);
    const uint8_t* fake_data = nullptr;
    const int64_t fake = bf6_read_raw(
        ctx, BF6_RAW_EBX,
        "common/ui/definitely_not_a_real_dynamic_list_cell", &fake_data);
    Guid fake_guid = contracts[0].guid;
    fake_guid[0] ^= 0xA5u;
    int fake_matches = 0;
    for (const Contract& contract : contracts)
        for (const std::string& match : contract.matches) {
            Fixup cell{};
            if (raw_fixup(ctx, match.c_str(), cell) && has_import(cell, fake_guid))
                ++fake_matches;
        }
    std::printf("control\tcells=%d\tmalformed=%d\treal=%d/2"
                "\trotated=%d/2\tfake-guid=%d\tfake-partition=%lld"
                "\trejected-categorycell-nav=%d\n",
                cells, malformed, real, rotated, fake_matches,
                static_cast<long long>(fake), category_wrong ? 1 : 0);
    ok = ok && real == 2 && rotated == 0 && fake_matches == 0 && fake < 0 &&
         !category_wrong;

    bf6_close(ctx);
    return ok ? 0 : 1;
}
