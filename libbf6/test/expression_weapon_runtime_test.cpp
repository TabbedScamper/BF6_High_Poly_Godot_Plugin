#include "bf6_core.h"
#include "expression_graph.h"
#include "expression_registry.h"
#include "expression_vm.h"

#include <algorithm>
#include <cstdio>
#include <cstring>
#include <set>
#include <string>
#include <vector>

static const uint32_t kExpressionType = 0x7dd4cc89u;

int main(int argc, char** argv) {
    const char* game = argc > 1 ? argv[1] :
        "C:\\Program Files (x86)\\Steam\\steamapps\\common\\Battlefield 6";
    char err[1024] = {};
    bf6_ctx* ctx = bf6_open(game, err, (int)sizeof(err));
    if (!ctx) { std::fprintf(stderr, "open: %s\n", err); return 2; }
    if (!bf6_mount_frontend(ctx, err, (int)sizeof(err))) {
        std::fprintf(stderr, "mount: %s\n", err); bf6_close(ctx); return 2;
    }
    const int total = bf6_list_res(ctx, nullptr, nullptr, 0);
    std::vector<bf6_asset> assets((size_t)std::max(total, 0));
    const int got = bf6_list_res(ctx, nullptr, assets.data(), total);
    size_t graphs = 0, valid_runs = 0, step_limits = 0;
    size_t builtin_unresolved = 0, null_unresolved = 0;
    size_t guessed = 0, indirect = 0, sound_known = 0;

    for (int i = 0; i < got; ++i) {
        const bf6_asset& asset = assets[(size_t)i];
        if (asset.type != kExpressionType || !asset.name ||
            !std::strstr(asset.name, "common/ui/weapons")) continue;
        ++graphs;
        const uint8_t* raw = nullptr;
        const int64_t bytes = bf6_read_raw(ctx, BF6_RAW_RES, asset.name, &raw);
        bf6::expression::Graph graph;
        std::string parse_error;
        if (bytes <= 0 || !raw ||
            !bf6::expression::parse(raw, (size_t)bytes, graph, parse_error))
            continue;

        std::set<uint32_t> key_set;
        for (const auto& fixup : graph.fixups) key_set.insert(fixup.key);
        std::vector<uint32_t> keys(key_set.begin(), key_set.end());
        std::vector<bf6::expression::NamedOperator> names;
        std::string scan_error;
        if (!bf6::expression::resolve_named_operators(
                std::string(game) + "\\bf6.exe", keys, names, scan_error))
            continue;
        bf6::expression::NamedBuiltins builtins;
        for (const auto& row : names)
            if (row.match_count == 1) builtins.add(row.key, row.name);

        bf6::expression::Instance instance;
        std::string instance_error;
        if (!bf6::expression::make_instance(graph, instance, instance_error))
            continue;
        const auto real = bf6::expression::evaluate(graph, &instance, {}, &builtins);
        bf6::expression::Instance null_instance;
        if (!bf6::expression::make_instance(graph, null_instance, instance_error))
            continue;
        const auto control = bf6::expression::evaluate(graph, &null_instance, {}, nullptr);
        ++valid_runs;
        step_limits += real.termination == bf6::expression::Termination::StepLimit;
        builtin_unresolved += real.unresolved_keys.size();
        null_unresolved += control.unresolved_keys.size();
        guessed += real.guessed_branches;
        indirect += real.approximated_indirect_jumps;
        sound_known += real.result.known && !real.result.tainted ? 1u : 0u;
    }
    bf6_close(ctx);
    std::printf("weapon DiceExpression offline runtime\n");
    std::printf("  parsed/evaluated: %zu / %zu\n", valid_runs, graphs);
    std::printf("  builtin/null-host unresolved uses: %zu / %zu\n",
                builtin_unresolved, null_unresolved);
    std::printf("  guessed branches / indirect approximations: %zu / %zu\n",
                guessed, indirect);
    std::printf("  sound known outputs without provider inputs: %zu\n", sound_known);
    std::printf("  step-limit terminations: %zu\n", step_limits);
    return valid_runs == graphs && graphs > 0 &&
           builtin_unresolved <= null_unresolved && step_limits == 0 ? 0 : 1;
}
