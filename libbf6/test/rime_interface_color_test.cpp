#include "bf6_core.h"

#include <cstdio>
#include <cstring>
#include <map>
#include <set>
#include <string>
#include <utility>
#include <vector>

namespace {

constexpr uint32_t kColorProperty = 0x0ca8c5f8u;
constexpr const char* kColorListValueA =
    "e925b9a5-df01-dac5-98a8-3de13859cc87";
constexpr const char* kColorListValueB =
    "dac5df01-a898-e13d-3859-cc87cd87084e";

uint64_t pin_key(int32_t instance, uint32_t field)
{
    return (uint64_t)(uint32_t)instance << 32 | field;
}

struct ColorPinAudit {
    int pins = 0;
    int real_matches = 0;
    int real_nulls = 0;
    int shuffled_matches = 0;
    int fake_matches = 0;
    int color_list_structs = 0;
};

ColorPinAudit audit_color_pins(bf6_ctx* c, const char* partition)
{
    ColorPinAudit result{};
    const int ni = bf6_rime_interface_descriptors(c, partition, nullptr, 0);
    const int nf = bf6_rime_interface_fields(c, partition, nullptr, 0);
    const int nt = bf6_rime_interface_struct_types(c, partition, nullptr, 0);
    const int nc = bf6_rime_connections(c, partition, nullptr, 0);
    if (ni <= 0 || nf <= 0 || nt < 0 || nc <= 0) return result;

    std::vector<int32_t> interfaces((size_t)ni);
    std::vector<bf6_rime_interface_field> fields((size_t)nf);
    std::vector<bf6_rime_interface_struct_type> struct_types((size_t)nt);
    std::vector<bf6_rime_connection> connections((size_t)nc);
    if (bf6_rime_interface_descriptors(c, partition, interfaces.data(), ni) != ni ||
        bf6_rime_interface_fields(c, partition, fields.data(), nf) != nf ||
        (nt > 0 && bf6_rime_interface_struct_types(
             c, partition, struct_types.data(), nt) != nt) ||
        bf6_rime_connections(c, partition, connections.data(), nc) != nc)
        return result;

    const std::set<int32_t> interface_set(interfaces.begin(), interfaces.end());
    std::map<uint64_t, size_t> by_pin;
    for (size_t field_index = 0; field_index < fields.size(); ++field_index)
    {
        const bf6_rime_interface_field& field = fields[field_index];
        by_pin[pin_key(field.interface_instance, field.field_id)] = field_index;
    }
    for (const bf6_rime_interface_struct_type& type : struct_types)
        if (std::strcmp(type.type_guid, kColorListValueA) == 0 ||
            std::strcmp(type.type_guid, kColorListValueB) == 0)
            ++result.color_list_structs;

    std::set<std::pair<int32_t, uint32_t>> unique_pins;
    for (const bf6_rime_connection& connection : connections)
        if (connection.target_field == kColorProperty &&
            interface_set.count(connection.source) != 0)
            unique_pins.emplace(connection.source, connection.source_field);

    std::vector<std::pair<int32_t, uint32_t>> pins(unique_pins.begin(),
                                                   unique_pins.end());
    result.pins = (int)pins.size();
    for (size_t i = 0; i < pins.size(); ++i)
    {
        const uint64_t real = pin_key(pins[i].first, pins[i].second);
        const auto found = by_pin.find(real);
        if (found != by_pin.end())
        {
            ++result.real_matches;
            if (fields[found->second].value_kind == BF6_RIME_VALUE_NULL)
                ++result.real_nulls;

            /* Shuffled control: replace the exactly joined field row with the
             * next shipped row. It preserves the live value distribution but
             * breaks the (interface instance, field id) pairing. */
            const bf6_rime_interface_field& shuffled =
                fields[(found->second + 1) % fields.size()];
            if (pin_key(shuffled.interface_instance, shuffled.field_id) == real)
                ++result.shuffled_matches;
        }

        if (by_pin.count(pin_key(pins[i].first,
                                 pins[i].second ^ 0xa5a5a5a5u)) != 0)
            ++result.fake_matches;
    }
    return result;
}

} // namespace

int main(int argc, char** argv)
{
    if (argc < 2)
    {
        std::fprintf(stderr, "usage: rime_interface_color_test <game-dir> [--census]\n");
        return 2;
    }
    char err[512]{};
    bf6_ctx* c = bf6_open(argv[1], err, (int)sizeof(err));
    if (!c)
    {
        std::fprintf(stderr, "open: %s\n", err);
        return 1;
    }
    if (!bf6_mount_frontend(c, err, (int)sizeof(err)))
    {
        std::fprintf(stderr, "mount: %s\n", err);
        bf6_close(c);
        return 1;
    }

    const char* color_partitions[] = {
        "common/ui/metacore/metacustomization/widgets/mc_worldiconcommonwidget",
        "common/ui/weapons/widgets/menuweaponproficiencyicon",
    };
    bool controls_pass = true;
    for (const char* partition : color_partitions)
    {
        const ColorPinAudit a = audit_color_pins(c, partition);
        std::printf("color-pins\t%s\tpins=%d real=%d null=%d shuffled=%d fake=%d color-list-structs=%d\n",
                    partition, a.pins, a.real_matches, a.real_nulls,
                    a.shuffled_matches, a.fake_matches, a.color_list_structs);
        controls_pass = controls_pass && a.pins > 0 &&
            a.real_matches == a.pins && a.real_nulls == a.pins &&
            a.shuffled_matches < a.real_matches && a.fake_matches == 0 &&
            a.color_list_structs == 0;
    }

    const bool census = argc >= 3 && std::strcmp(argv[2], "--census") == 0;
    if (!census)
    {
        const int fake = bf6_rime_interface_fields(
            c, "common/ui/__control__/not_a_real_widget", nullptr, 0);
        const int fake_types = bf6_rime_interface_struct_types(
            c, "common/ui/__control__/not_a_real_widget", nullptr, 0);
        std::printf("fake-partition=%d fake-struct-types=%d controls=%s\n",
                    fake, fake_types,
                    controls_pass ? "pass" : "FAIL");
        bf6_close(c);
        return controls_pass && fake < 0 && fake_types < 0 ? 0 : 1;
    }

    const int na = bf6_list_ebx(c, "common/ui", nullptr, 0);
    std::vector<bf6_asset> assets((size_t)(na > 0 ? na : 0));
    const int got = na > 0 ? bf6_list_ebx(c, "common/ui", assets.data(), na) : na;
    std::map<int, int> kinds;
    int readable = 0, descriptors = 0, fields = 0;
    int structs = 0, arrays = 0, color_list_structs = 0;
    std::map<std::string, int> struct_types;
    for (int i = 0; i < got; ++i)
    {
        const char* path = assets[(size_t)i].name;
        if (!path || std::strncmp(path, "common/ui", 9) != 0) continue;
        const int ni = bf6_rime_interface_descriptors(c, path, nullptr, 0);
        if (ni <= 0) continue;
        ++readable;
        descriptors += ni;
        const int nf = bf6_rime_interface_fields(c, path, nullptr, 0);
        if (nf <= 0) continue;
        std::vector<bf6_rime_interface_field> rows((size_t)nf);
        if (bf6_rime_interface_fields(c, path, rows.data(), nf) != nf) continue;
        fields += nf;
        for (const bf6_rime_interface_field& row : rows)
        {
            ++kinds[row.value_kind];
            if (row.value_kind == BF6_RIME_VALUE_STRUCT)
                ++structs;
            if (row.value_kind == BF6_RIME_VALUE_ARRAY) ++arrays;
        }
        const int nt = bf6_rime_interface_struct_types(c, path, nullptr, 0);
        std::vector<bf6_rime_interface_struct_type> types(
            (size_t)(nt > 0 ? nt : 0));
        if (nt > 0 && bf6_rime_interface_struct_types(
                c, path, types.data(), nt) == nt)
            for (const bf6_rime_interface_struct_type& type : types)
            {
                ++struct_types[type.type_guid];
                if (std::strcmp(type.type_guid, kColorListValueA) == 0 ||
                    std::strcmp(type.type_guid, kColorListValueB) == 0)
                    ++color_list_structs;
            }
    }
    const int fake = bf6_rime_interface_fields(
        c, "common/ui/__control__/not_a_real_widget", nullptr, 0);
    const int fake_types = bf6_rime_interface_struct_types(
        c, "common/ui/__control__/not_a_real_widget", nullptr, 0);
    int typed_structs = 0;
    for (const auto& kv : struct_types) typed_structs += kv.second;
    std::printf("assets=%d readable=%d descriptors=%d fields=%d structs=%d typed-structs=%d arrays=%d color-list-structs=%d fake=%d fake-struct-types=%d\n",
                got, readable, descriptors, fields, structs, typed_structs,
                arrays, color_list_structs, fake, fake_types);
    std::printf("kinds");
    for (const auto& kv : kinds) std::printf(" %d=%d", kv.first, kv.second);
    std::printf("\n");
    for (const auto& kv : struct_types)
        std::printf("struct-type\t%s\t%d\n", kv.first.c_str(), kv.second);
    bf6_close(c);
    return controls_pass && fake < 0 && fake_types < 0 &&
        typed_structs == structs && color_list_structs == 0 ? 0 : 1;
}
