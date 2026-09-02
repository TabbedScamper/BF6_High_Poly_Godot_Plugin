#include "bf6_core.h"
#include "expression_registry.h"

#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

int main(int argc, char** argv)
{
    const char* exe = argc > 1 ? argv[1] :
        "C:\\Program Files (x86)\\Steam\\steamapps\\common\\Battlefield 6\\bf6.exe";
    char err[1024] = {};
    const int total = bf6_expression_descriptor_operators(exe, nullptr, 0,
                                                           err, (int)sizeof(err));
    if (total <= 0) { std::fprintf(stderr, "%s\n", err); return 2; }
    std::vector<bf6_expression_operator> rows((size_t)total);
    const int again = bf6_expression_descriptor_operators(
        exe, rows.data(), total, err, (int)sizeof(err));
    if (again != total) {
        std::fprintf(stderr, "count/fill drift: %d then %d\n", total, again);
        return 2;
    }
    auto has = [&](uint32_t key) {
        return std::any_of(rows.begin(), rows.end(), [=](const auto& row) {
            return row.key == key;
        });
    };
    std::vector<uint32_t> keys;
    for (const auto& row : rows) keys.push_back(row.key);
    std::sort(keys.begin(), keys.end());
    keys.erase(std::unique(keys.begin(), keys.end()), keys.end());
    const size_t zero_records = (size_t)std::count_if(
        rows.begin(), rows.end(), [](const auto& row) { return row.key == 0; });
    const bool real = has(0x0b201cc7u); // independently identified variable store
    const bool fake = has(0xdeadc0deu);
    const uint32_t name_queries[] = {
        0x74b6c3a9u, // __GetPackedValueValidated, named positive control
        0x0b201cc7u, // descriptor key: must not acquire a literal name
        0xdeadc0deu  // fabricated negative control
    };
    const int names_n = bf6_expression_resolve_operator_names(
        exe, name_queries, 3, nullptr, 0, err, (int)sizeof(err));
    std::vector<bf6_expression_operator_name> names((size_t)std::max(names_n, 0));
    if (names_n)
        bf6_expression_resolve_operator_names(exe, name_queries, 3,
                                               names.data(), names_n,
                                               err, (int)sizeof(err));
    const auto named = std::find_if(names.begin(), names.end(), [](const auto& row) {
        return row.key == 0x74b6c3a9u && row.match_count == 1 &&
               std::strcmp(row.name, "__GetPackedValueValidated") == 0;
    });
    const bool descriptor_misnamed = std::any_of(names.begin(), names.end(), [](const auto& row) {
        return row.key == 0x0b201cc7u;
    });
    const bool fake_named = std::any_of(names.begin(), names.end(), [](const auto& row) {
        return row.key == 0xdeadc0deu;
    });
    const int reflected_n = bf6_expression_reflected_operators(
        exe, nullptr, 0, err, (int)sizeof(err));
    std::vector<bf6_expression_reflected_operator> reflected(
        (size_t)std::max(reflected_n, 0));
    if (reflected_n)
        bf6_expression_reflected_operators(exe, reflected.data(), reflected_n,
                                           err, (int)sizeof(err));
    const bool reflected_anchor = std::any_of(
        reflected.begin(), reflected.end(), [](const auto& row) {
            return row.key == 0x69a5e560u && row.parameter_count == 4;
        });
    const bool reflected_fake = std::any_of(
        reflected.begin(), reflected.end(), [](const auto& row) {
            return row.key == 0xdeadc0deu;
        });
    std::vector<bf6::expression::MethodOperator> methods;
    std::string method_error;
    const std::vector<uint32_t> method_queries = {0xda24cdf6u, 0xdeadc0deu};
    const bool methods_ok = bf6::expression::read_method_operators(
        exe, method_queries, methods, method_error);
    const bool method_anchor = std::any_of(
        methods.begin(), methods.end(), [](const auto& row) {
            return row.key == 0xda24cdf6u;
        });
    const bool method_fake = std::any_of(
        methods.begin(), methods.end(), [](const auto& row) {
            return row.key == 0xdeadc0deu;
        });
    std::printf("current executable descriptor registry\n");
    std::printf("  structural records: %d\n", total);
    std::printf("  distinct keys: %zu\n", keys.size());
    std::printf("  zero-key records: %zu\n", zero_records);
    std::printf("  store-anchor control: %s\n", real ? "present" : "MISSING");
    std::printf("  fake-key control: %s\n", fake ? "PRESENT" : "absent");
    std::printf("  named-anchor control: %s\n",
                named != names.end() ? "__GetPackedValueValidated" : "MISSING");
    std::printf("  descriptor/fake named controls: %s / %s\n",
                descriptor_misnamed ? "MISNAMED" : "absent",
                fake_named ? "MISNAMED" : "absent");
    std::printf("  reflected functions: %d; anchor/fake: %s / %s\n",
                reflected_n, reflected_anchor ? "present" : "MISSING",
                reflected_fake ? "PRESENT" : "absent");
    std::printf("  compact method records: %zu; anchor/fake: %s / %s%s%s\n",
                methods.size(), method_anchor ? "present" : "MISSING",
                method_fake ? "PRESENT" : "absent",
                methods_ok ? "" : "; scan error: ",
                methods_ok ? "" : method_error.c_str());
    return real && !fake && named != names.end() &&
           !descriptor_misnamed && !fake_named && reflected_anchor &&
           !reflected_fake && methods_ok && method_anchor && !method_fake ? 0 : 1;
}
