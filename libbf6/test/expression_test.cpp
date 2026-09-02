#include "bf6_core.h"
#include "expression_graph.h"
#include "expression_registry.h"

#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <cstdlib>
#include <map>
#include <set>
#include <string>
#include <vector>

static const uint32_t kExpressionType = 0x7dd4cc89u;

int main(int argc, char** argv)
{
    const char* game = argc > 1 ? argv[1] :
        "C:\\Program Files (x86)\\Steam\\steamapps\\common\\Battlefield 6";
    const char* filter = argc > 2 ? argv[2] : "ui/";
    const bool verbose_operators = argc > 3 &&
        std::strcmp(argv[3], "--operators") == 0;
    if (filter && std::strcmp(filter, "--all") == 0) filter = "";
    char err[1024] = {};
    bf6_ctx* ctx = bf6_open(game, err, (int)sizeof(err));
    if (!ctx) { std::fprintf(stderr, "open: %s\n", err); return 2; }
    if (!bf6_mount_frontend(ctx, err, (int)sizeof(err))) {
        std::fprintf(stderr, "frontend mount: %s\n", err); bf6_close(ctx); return 2;
    }

    const int count = bf6_list_res(ctx, nullptr, nullptr, 0);
    std::vector<bf6_asset> assets((size_t)std::max(count, 0));
    const int got = bf6_list_res(ctx, nullptr, assets.data(), count);
    size_t selected = 0, parsed = 0, tiled = 0, records = 0;
    size_t prefix_controls = 0, prefix_rejected = 0;
    size_t fixup_controls = 0, fixup_rejected = 0;
    std::vector<std::string> failures;
    std::set<uint32_t> fixup_keys;
    std::map<uint32_t, size_t> key_uses;
    std::map<uint32_t, std::string> key_graph;
    std::map<uint32_t, std::set<size_t>> key_arities;
    std::map<unsigned, size_t> untiled_kinds;
    std::vector<std::string> untiled_names;

    for (int i = 0; i < got; ++i) {
        const bf6_asset& a = assets[(size_t)i];
        if (a.type != kExpressionType || !a.name) continue;
        if (filter && *filter && !std::strstr(a.name, filter)) continue;
        ++selected;
        const uint8_t* raw = nullptr;
        const int64_t n = bf6_read_raw(ctx, BF6_RAW_RES, a.name, &raw);
        if (n <= 0 || !raw) {
            failures.push_back(std::string(a.name) + ": raw read failed");
            continue;
        }
        bf6::expression::Graph graph;
        std::string why;
        if (!bf6::expression::parse(raw, (size_t)n, graph, why)) {
            failures.push_back(std::string(a.name) + ": " + why);
            continue;
        }
        ++parsed;
        tiled += graph.exact_record_tiling ? 1u : 0u;
        records += graph.records.size();
        for (const bf6::expression::Fixup& fixup : graph.fixups) {
            fixup_keys.insert(fixup.key);
            ++key_uses[fixup.key];
            key_graph.emplace(fixup.key, a.name);
        }
        if (graph.exact_record_tiling)
            for (const bf6::expression::Record& record : graph.records)
                if (record.operator_key)
                    key_arities[record.operator_key].insert(record.operands.size());
        if (!graph.exact_record_tiling) {
            if (untiled_names.size() < 12) untiled_names.push_back(a.name);
            for (const bf6::expression::Record& record : graph.records) {
                if (record.kind != 0x23 && record.kind != 0x28 &&
                    bf6::expression::proven_record_length(record.kind) == 0)
                    ++untiled_kinds[record.kind];
            }
        }

        if (prefix_controls < 64) {
            std::vector<uint8_t> fake(raw, raw + n);
            fake[0] ^= 1;
            bf6::expression::Graph ignored;
            std::string control_error;
            ++prefix_controls;
            if (!bf6::expression::parse(fake.data(), fake.size(), ignored,
                                        control_error)) ++prefix_rejected;
        }
        if (!graph.fixups.empty() && fixup_controls < 64) {
            std::vector<uint8_t> fake(raw, raw + n);
            const size_t at = graph.fixup_table + 4;
            const uint32_t bad = graph.header.record_dwords * 4u;
            fake[at + 0] = (uint8_t)bad;
            fake[at + 1] = (uint8_t)(bad >> 8);
            fake[at + 2] = (uint8_t)(bad >> 16);
            fake[at + 3] = (uint8_t)(bad >> 24);
            bf6::expression::Graph ignored;
            std::string control_error;
            ++fixup_controls;
            if (!bf6::expression::parse(fake.data(), fake.size(), ignored,
                                        control_error)) ++fixup_rejected;
        }
    }

    size_t wrong_type_controls = 0, wrong_type_rejected = 0;
    for (int i = 0; i < got && wrong_type_controls < 32; ++i) {
        const bf6_asset& a = assets[(size_t)i];
        if (!a.name || a.type == kExpressionType || a.size < 0x50 || a.size > 1024 * 1024) continue;
        const uint8_t* raw = nullptr;
        const int64_t n = bf6_read_raw(ctx, BF6_RAW_RES, a.name, &raw);
        if (n <= 0 || !raw) continue;
        bf6::expression::Graph ignored;
        std::string control_error;
        ++wrong_type_controls;
        if (!bf6::expression::parse(raw, (size_t)n, ignored, control_error))
            ++wrong_type_rejected;
    }

    std::printf("DiceExpression raw-install conformance\n");
    std::printf("  filter: %s\n", filter && *filter ? filter : "<all>");
    std::printf("  real parsed: %zu / %zu\n", parsed, selected);
    std::printf("  exact proven-kind tilings: %zu / %zu\n", tiled, parsed);
    std::printf("  materialized records: %zu\n", records);
    if (!untiled_kinds.empty()) {
        std::printf("  unmeasured kinds in untiled graphs:");
        for (const auto& row : untiled_kinds)
            std::printf(" 0x%02X=%zu", row.first, row.second);
        std::printf("\n");
    }
    for (const std::string& name : untiled_names)
        std::printf("  UNTILED %s\n", name.c_str());
    std::printf("  corrupt-prefix control rejected: %zu / %zu\n",
                prefix_rejected, prefix_controls);
    std::printf("  corrupt-fixup control rejected: %zu / %zu\n",
                fixup_rejected, fixup_controls);
    std::printf("  wrong-RES-type control rejected: %zu / %zu\n",
                wrong_type_rejected, wrong_type_controls);

    /* HONOUR BF6_EXE, for the same reason TypeDb::exe_candidates does. The
     * shipping build's `typeinfo` section is ENCRYPTED, and this scan walks
     * that section looking for Function descriptors: against the install it
     * finds zero and reports "no reflected Function descriptors found", which
     * reads as the decode being broken rather than as the section being
     * ciphertext. Hardcoding the install path made this test unrunnable on any
     * EA build. See encrypted-typeinfo-selected-over-a-readable-build. */
    const char* exe_env = std::getenv("BF6_EXE");
    const std::string exe = (exe_env && *exe_env) ? std::string(exe_env)
                                                  : std::string(game) + "\\bf6.exe";
    std::vector<bf6::expression::DescriptorOperator> descriptor_rows;
    std::string registry_error;
    std::set<uint32_t> descriptor_keys;
    if (bf6::expression::read_descriptor_operators(exe, descriptor_rows,
                                                   registry_error))
        for (const auto& row : descriptor_rows) descriptor_keys.insert(row.key);
    std::vector<uint32_t> key_query(fixup_keys.begin(), fixup_keys.end());
    std::vector<bf6::expression::MethodOperator> method_rows;
    if (!bf6::expression::read_method_operators(exe, key_query, method_rows,
                                                registry_error))
        failures.push_back("method registry scan: " + registry_error);
    std::set<uint32_t> method_keys;
    for (const auto& row : method_rows) method_keys.insert(row.key);
    std::vector<bf6::expression::NamedOperator> named_rows;
    if (!bf6::expression::resolve_named_operators(exe, key_query, named_rows,
                                                  registry_error))
        failures.push_back("operator name scan: " + registry_error);
    std::set<uint32_t> named_keys;
    size_t ambiguous_names = 0;
    for (const auto& row : named_rows) {
        if (row.match_count == 1) named_keys.insert(row.key);
        else ++ambiguous_names;
    }
    std::vector<bf6::expression::ReflectedOperator> reflected_rows;
    if (!bf6::expression::read_reflected_operators(exe, reflected_rows,
                                                   registry_error))
        failures.push_back("reflected registry scan: " + registry_error);
    std::set<uint32_t> reflected_keys;
    for (const auto& row : reflected_rows) reflected_keys.insert(row.key);
    size_t descriptor_used = 0, method_used = 0, named_used = 0;
    size_t reflected_used = 0, overlap = 0;
    for (uint32_t key : fixup_keys) {
        const bool d = descriptor_keys.find(key) != descriptor_keys.end();
        const bool m = method_keys.find(key) != method_keys.end();
        const bool n = named_keys.find(key) != named_keys.end();
        const bool r = reflected_keys.find(key) != reflected_keys.end();
        descriptor_used += d ? 1u : 0u;
        method_used += m ? 1u : 0u;
        named_used += n ? 1u : 0u;
        reflected_used += r ? 1u : 0u;
        overlap += ((d ? 1 : 0) + (m ? 1 : 0) +
                    (n ? 1 : 0) + (r ? 1 : 0)) > 1 ? 1u : 0u;
    }
    const size_t resolved_sum = descriptor_used + method_used + named_used + reflected_used;
    const size_t unresolved_keys = resolved_sum <= fixup_keys.size()
        ? fixup_keys.size() - resolved_sum : 0;
    std::printf("  unique operator keys: %zu\n", fixup_keys.size());
    std::printf("  current-exe descriptor/method/named/reflected: %zu / %zu / %zu / %zu\n",
                descriptor_used, method_used, named_used, reflected_used);
    std::printf("  registry overlap/ambiguous/unresolved: %zu / %zu / %zu\n",
                overlap, ambiguous_names, unresolved_keys);
    if (verbose_operators) {
        for (const auto& row : named_rows)
            if (row.match_count == 1)
                std::printf("  NAMED 0x%08X %s uses=%zu\n", row.key,
                            row.name.c_str(), key_uses[row.key]);
    }
    std::vector<uint32_t> unresolved;
    for (uint32_t key : fixup_keys)
        if (descriptor_keys.find(key) == descriptor_keys.end() &&
            method_keys.find(key) == method_keys.end() &&
            named_keys.find(key) == named_keys.end() &&
            reflected_keys.find(key) == reflected_keys.end())
            unresolved.push_back(key);
    std::sort(unresolved.begin(), unresolved.end(), [&](uint32_t a, uint32_t b) {
        if (key_uses[a] != key_uses[b]) return key_uses[a] > key_uses[b];
        return a < b;
    });
    for (size_t i = 0; i < unresolved.size() && i < 64; ++i) {
        const uint32_t key = unresolved[i];
        std::printf("  HOST 0x%08X uses=%zu arity=", key, key_uses[key]);
        const auto ai = key_arities.find(key);
        if (ai == key_arities.end() || ai->second.empty()) std::printf("?");
        else {
            bool first = true;
            for (size_t arity : ai->second) {
                std::printf("%s%zu", first ? "" : ",", arity);
                first = false;
            }
        }
        std::printf(" graph=%s\n", key_graph[key].c_str());
    }
    for (size_t i = 0; i < failures.size() && i < 12; ++i)
        std::printf("  FAIL %s\n", failures[i].c_str());
    if (failures.size() > 12)
        std::printf("  ... %zu more failures\n", failures.size() - 12);

    bf6_close(ctx);
    return parsed == selected && prefix_rejected == prefix_controls &&
           fixup_rejected == fixup_controls &&
           wrong_type_rejected == wrong_type_controls ? 0 : 1;
}
