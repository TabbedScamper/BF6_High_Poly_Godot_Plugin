#include "bf6_core.h"
#include "offline_profile_provider.h"
#include "rime_list_provider.h"

#include <cstdio>
#include <cstring>

namespace {

bool expect_bool(const rime_list::DbdContract& contract,
                 const rime_list::Record& record, const char* name,
                 bool expected)
{
    const rime_list::DbdField* field = rime_list::contract_field(contract, name);
    const rime_list::Entry* entry = field ? record.find(field->property_id)
                                          : nullptr;
    return entry && entry->value.kind == rime_list::ValueKind::Bool &&
           entry->value.boolean == expected;
}

} // namespace

int main(int argc, char** argv)
{
    if (argc < 2) {
        std::fprintf(stderr,
                     "usage: offline_profile_provider_test <game-dir>\n");
        return 2;
    }
    char error[512]{};
    bf6_ctx* ctx = bf6_open(argv[1], error, static_cast<int>(sizeof(error)));
    if (!ctx) {
        std::fprintf(stderr, "open: %s\n", error);
        return 1;
    }
    if (!bf6_mount_frontend(ctx, error, static_cast<int>(sizeof(error)))) {
        std::fprintf(stderr, "mount: %s\n", error);
        bf6_close(ctx);
        return 1;
    }

    rime_list::DbdContract grid;
    rime_list::DbdContract attachment;
    if (!rime_list::load_contract(ctx, grid,
                                  rime_list::kGridItemDbdPartition) ||
        !rime_list::load_contract(ctx, attachment,
                                  rime_list::kAttachmentDbdPartition)) {
        std::fprintf(stderr, "current-install DBD contract unavailable\n");
        bf6_close(ctx);
        return 1;
    }

    rime_list::Record grid_record;
    const rime_list::DbdField* favorite =
        rime_list::contract_field(grid, "IsFavorite");
    rime_list::Value explicit_favorite;
    explicit_favorite.kind = rime_list::ValueKind::Bool;
    explicit_favorite.boolean = true;
    if (!favorite || !grid_record.put(grid, favorite->property_id,
                                       explicit_favorite)) {
        std::fprintf(stderr, "explicit control value rejected\n");
        bf6_close(ctx);
        return 1;
    }
    const offline_profile::Report grid_report = offline_profile::append_routed(
        ctx, rime_list::kGridItemDbdPartition,
        rime_list::kGridItemCellPartition, grid, grid_record);
    const bool grid_ok = grid_report.candidate_rules == 5 &&
        grid_report.explicit_values_preserved == 1 &&
        grid_report.applied == 2 && grid_report.unrouted == 2 &&
        grid_report.missing_contract_fields == 0 &&
        grid_report.type_mismatches == 0 &&
        grid_report.shuffled_control_routes == 0 &&
        expect_bool(grid, grid_record, "IsFavorite", true) &&
        expect_bool(grid, grid_record, "IsLocked", false) &&
        expect_bool(grid, grid_record, "IsPurchasable", false);

    rime_list::Record attachment_record;
    const offline_profile::Report attachment_report =
        offline_profile::append_routed(
            ctx, rime_list::kAttachmentDbdPartition,
            rime_list::kAttachmentCellPartition, attachment,
            attachment_record);
    const bool attachment_ok = attachment_report.candidate_rules == 3 &&
        attachment_report.applied == 2 && attachment_report.unrouted == 1 &&
        attachment_report.shuffled_control_routes == 0 &&
        expect_bool(attachment, attachment_record, "IsLocked", false) &&
        expect_bool(attachment, attachment_record,
                    "HasLockedFactoryPackage", false);

    rime_list::Record fake_graph_record;
    const offline_profile::Report fake_graph = offline_profile::append_routed(
        ctx, rime_list::kGridItemDbdPartition,
        "common/ui/__control__/not_a_real_widget", grid,
        fake_graph_record);
    const bool fake_ok = fake_graph.applied == 0 &&
        fake_graph.shuffled_control_routes == 0 &&
        fake_graph_record.entries().empty();

    rime_list::DbdContract changed = grid;
    const rime_list::DbdField* changed_locked =
        rime_list::contract_field(changed, "IsLocked");
    if (changed_locked)
        for (rime_list::DbdField& field : changed.fields)
            if (field.property_id == changed_locked->property_id)
                field.type_signature ^= 1ull;
    rime_list::Record changed_record;
    const offline_profile::Report changed_report =
        offline_profile::append_routed(
            ctx, rime_list::kGridItemDbdPartition,
            rime_list::kGridItemCellPartition, changed, changed_record);
    const bool changed_ok = changed_report.type_mismatches == 1 &&
        !expect_bool(changed, changed_record, "IsLocked", false);

    struct ContractAudit {
        const char* partition;
        int rules;
    };
    const ContractAudit audits[] = {
        {rime_list::kCollapseButtonDbdPartition, 1},
        {"common/ui/weaponcustomization/assets/databindings/"
         "weaponcollectioncolumndbd", 2},
        {"common/ui/weaponcustomization/assets/databindings/"
         "weaponcollectionselectedweapondbd", 1},
        {"common/ui/weaponcustomization/assets/databindings/"
         "weaponcustomizationrootdbd", 2},
        {"common/ui/playerprofile/assets/databinding/pp_dbd", 7},
        {"common/ui/playerprofile/assets/databinding/pp_infodbd", 7},
        {"common/ui/system/eaconnect/bfuiphotondatabindingdefinition", 10},
    };
    bool contracts_ok = true;
    int audited_rules = grid_report.candidate_rules +
                        attachment_report.candidate_rules;
    for (const ContractAudit& audit : audits) {
        rime_list::DbdContract contract;
        rime_list::Record sink;
        if (!rime_list::load_contract(ctx, contract, audit.partition)) {
            contracts_ok = false;
            continue;
        }
        const offline_profile::Report report = offline_profile::append_routed(
            ctx, audit.partition, "common/ui/__control__/not_a_real_widget",
            contract, sink);
        audited_rules += report.candidate_rules;
        contracts_ok = contracts_ok &&
            report.candidate_rules == audit.rules &&
            report.missing_contract_fields == 0 &&
            report.type_mismatches == 0 && report.applied == 0 &&
            report.shuffled_control_routes == 0;
    }
    contracts_ok = contracts_ok && audited_rules == 38;

    std::printf(
        "offline-profile provider=%s grid=%d/%d grid-unrouted=%d "
        "attachment=%d/%d attachment-unrouted=%d shuffled=%d fake=%d "
        "type-control=%d contract-rules=%d\n",
        offline_profile::kProviderName, grid_report.applied,
        grid_report.candidate_rules, grid_report.unrouted,
        attachment_report.applied, attachment_report.candidate_rules,
        attachment_report.unrouted,
        grid_report.shuffled_control_routes +
            attachment_report.shuffled_control_routes,
        fake_ok ? 1 : 0, changed_ok ? 1 : 0, audited_rules);
    bf6_close(ctx);
    return grid_ok && attachment_ok && fake_ok && changed_ok && contracts_ok
        ? 0 : 1;
}
