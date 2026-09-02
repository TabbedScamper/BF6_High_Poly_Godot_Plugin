// Live factory-package read-path regression.
//
// M4A1 is the positive oracle already established independently through the
// equipment grants and package identifier list.  A deliberately fake
// equipment partition is the negative control: it must produce no rows.
#include "bf6_core.h"

#include <algorithm>
#include <cstdio>
#include <string>
#include <vector>

static std::string find_equipment(bf6_ctx* c, const char* weapon)
{
    const std::string query = std::string("equipment_") + weapon;
    const int n = bf6_list_ebx(c, query.c_str(), nullptr, 0);
    if (n <= 0) return {};
    std::vector<bf6_asset> rows((size_t)n);
    const int got = bf6_list_ebx(c, query.c_str(), rows.data(), n);
    for (int i = 0; i < got; ++i)
    {
        const std::string path = rows[(size_t)i].name ? rows[(size_t)i].name : "";
        const size_t slash = path.find_last_of("/\\");
        std::string stem = slash == std::string::npos ? path : path.substr(slash + 1);
        const size_t dot = stem.find_last_of('.');
        if (dot != std::string::npos) stem.erase(dot);
        if (stem == query) return path;
    }
    return {};
}

int main(int argc, char** argv)
{
    if (argc != 2) { std::printf("usage: factory_fit_test <game_dir>\n"); return 2; }
    char err[512]{};
    bf6_ctx* c = bf6_open(argv[1], err, (int)sizeof(err));
    if (!c || !bf6_mount_all(c, 1, err, (int)sizeof(err)))
    { std::printf("mount failed: %s\n", err); return 1; }

    const std::string equipment = find_equipment(c, "m4a1");
    std::vector<bf6_weapon_fit> rows(32);
    const int n = equipment.empty() ? -1 : bf6_weapon_factory_fits(
        c, equipment.c_str(), rows.data(), (int)rows.size());
    std::vector<std::string> got;
    for (int i = 0; i < n && i < (int)rows.size(); ++i)
    {
        const std::string row = std::string(rows[(size_t)i].slot ? rows[(size_t)i].slot : "") +
                                "=" + (rows[(size_t)i].attachment ? rows[(size_t)i].attachment : "");
        got.push_back(row);
        std::printf("factory\t%s\n", row.c_str());
    }
    std::sort(got.begin(), got.end());
    const std::vector<std::string> oracle = {
        "amo=fmj", "brl=shortbarrel", "mag=regular", "mzl=m4qdflashhider", "scp=xps3"
    };
    const int fake = bf6_weapon_factory_fits(c, "codex_fake_equipment_7f93", nullptr, 0);
    std::printf("m4a1 rows=%d oracle_match=%d; fake rows=%d (negative control)\n",
                n, got == oracle ? 1 : 0, fake);
    bf6_close(c);
    return n == 5 && got == oracle && fake == 0 ? 0 : 1;
}
