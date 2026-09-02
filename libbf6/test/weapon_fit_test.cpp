// Runtime control for configured weapon parts.
// A real M4A1 right-rail token must replace at least one authored default;
// a deliberately fake token must replace none. This guards the bounded name
// join used by the native viewer against nearest-neighbour false positives.
#include "bf6_core.h"

#include <algorithm>
#include <cstdio>
#include <string>
#include <vector>

static std::string find_m4_md(bf6_ctx* c)
{
    const int n = bf6_list_ebx(c, "md_m4a1", nullptr, 0);
    if (n <= 0) return {};
    std::vector<bf6_asset> rows((size_t)n);
    const int got = bf6_list_ebx(c, "md_m4a1", rows.data(), n);
    std::string best;
    for (int i = 0; i < got; i++)
    {
        const std::string s = rows[(size_t)i].name ? rows[(size_t)i].name : "";
        if (s.find("/md_m4a1") == std::string::npos || s.find("_bundle") != std::string::npos)
            continue;
        if (best.empty() || s.size() < best.size()) best = s;
    }
    return best;
}

struct Snapshot {
    std::vector<std::string> bundles;
    std::vector<std::string> meshes;
    std::vector<std::string> placements;
    size_t count = 0;
    int offsets = 0;
};

static bool contains_part(const Snapshot& s, const char* wanted, const char* rejected = nullptr)
{
    for (const std::string& b : s.bundles)
        if (b.find(wanted) != std::string::npos &&
            (!rejected || b.find(rejected) == std::string::npos)) return true;
    return false;
}

static bool contains_mesh(const Snapshot& s, const char* wanted, const char* rejected = nullptr)
{
    for (const std::string& m : s.meshes)
        if (m.find(wanted) != std::string::npos &&
            (!rejected || m.find(rejected) == std::string::npos)) return true;
    return false;
}

static std::string placement_for(const Snapshot& s, const char* token)
{
    for (const std::string& p : s.placements)
        if (p.find(token) != std::string::npos) return p;
    return {};
}

static Snapshot read_parts(bf6_ctx* c, const std::string& md, const bf6_weapon_fit* fit,
                           bool configured = true, int fit_count = -1)
{
    std::vector<bf6_weapon_part> out(256);
    const int nf = fit_count >= 0 ? fit_count : (fit ? 1 : 0);
    const int n = configured ? bf6_weapon_configured_parts(c, md.c_str(), fit, nf,
                                                            out.data(), (int)out.size())
                             : bf6_weapon_default_parts(c, md.c_str(), out.data(),
                                                        (int)out.size());
    Snapshot snap;
    if (n < 0 || n > (int)out.size()) return snap;
    snap.count = (size_t)n;
    for (int i = 0; i < n; i++)
    {
        snap.bundles.emplace_back(out[(size_t)i].bundle ? out[(size_t)i].bundle : "");
        snap.meshes.emplace_back(out[(size_t)i].mesh ? out[(size_t)i].mesh : "");
        char placement[512];
        std::snprintf(placement, sizeof(placement), "%s\t%.6f\t%.6f\t%.6f",
            out[(size_t)i].bundle ? out[(size_t)i].bundle : "",
            out[(size_t)i].attach_offset[0], out[(size_t)i].attach_offset[1],
            out[(size_t)i].attach_offset[2]);
        snap.placements.emplace_back(placement);
        if (out[(size_t)i].has_attach_offset) snap.offsets++;
    }
    std::sort(snap.bundles.begin(), snap.bundles.end());
    std::sort(snap.meshes.begin(), snap.meshes.end());
    std::sort(snap.placements.begin(), snap.placements.end());
    return snap;
}

static Snapshot read_all_parts(bf6_ctx* c, const std::string& md)
{
    std::vector<bf6_weapon_part> out(2048);
    const int n = bf6_weapon_parts(c, md.c_str(), out.data(), (int)out.size());
    Snapshot snap;
    if (n < 0 || n > (int)out.size()) return snap;
    snap.count = (size_t)n;
    for (int i = 0; i < n; i++)
        snap.bundles.emplace_back(out[(size_t)i].bundle ? out[(size_t)i].bundle : "");
    for (int i = 0; i < n; i++)
        snap.meshes.emplace_back(out[(size_t)i].mesh ? out[(size_t)i].mesh : "");
    std::sort(snap.bundles.begin(), snap.bundles.end());
    std::sort(snap.meshes.begin(), snap.meshes.end());
    return snap;
}

int main(int argc, char** argv)
{
    if (argc != 2) { std::printf("usage: weapon_fit_test <game_dir>\n"); return 2; }
    char err[512]{};
    bf6_ctx* c = bf6_open(argv[1], err, (int)sizeof(err));
    if (!c || !bf6_mount_all(c, 1, err, (int)sizeof(err)))
    { std::printf("mount failed: %s\n", err); return 1; }
    const std::string md = find_m4_md(c);
    if (md.empty()) { std::printf("md_m4a1 not found\n"); bf6_close(c); return 1; }

    bf6_weapon_fit real{ "rgt", "modulemk3" };
    bf6_weapon_fit fake{ "rgt", "codex_fake_attachment_7f93" };
    bf6_weapon_fit optic{ "scp", "compm5b" };
    bf6_weapon_fit canted{ "sca", "cantedreflex" };
    const auto base = read_parts(c, md, nullptr);
    const auto fitted = read_parts(c, md, &real);
    const auto control = read_parts(c, md, &fake);
    const auto with_optic = read_parts(c, md, &optic);
    const auto with_canted = read_parts(c, md, &canted);
    const auto all_parts = read_all_parts(c, md);

    std::vector<bf6_weapon_fit> factory(32);
    const int factory_count = bf6_weapon_factory_fits(
        c, "common/hardware/weapons/carbine/m4a1/equipment_m4a1",
        factory.data(), (int)factory.size());
    bool factory_requests_muzzle = false;
    bool factory_has_muzzle = false;
    if (factory_count > 0 && factory_count <= (int)factory.size())
    {
        std::printf("factory fits=%d\n", factory_count);
        for (int i = 0; i < factory_count; ++i)
        {
            std::printf("factory fit\t%s\t%s\n",
                        factory[(size_t)i].slot ? factory[(size_t)i].slot : "",
                        factory[(size_t)i].attachment ? factory[(size_t)i].attachment : "");
            if (factory[(size_t)i].slot &&
                std::string(factory[(size_t)i].slot) == "mzl")
                factory_requests_muzzle = true;
        }
        const auto factory_parts = read_parts(c, md, factory.data(), true, factory_count);
        for (const std::string& b : factory_parts.bundles)
            std::printf("factory bundle\t%s\n", b.c_str());
        for (const std::string& m : factory_parts.meshes)
            std::printf("factory mesh\t%s\n", m.c_str());
        factory_has_muzzle = contains_part(factory_parts, "muzzle") ||
                             contains_part(factory_parts, "flash") ||
                             contains_part(factory_parts, "m4qd") ||
                             contains_mesh(factory_parts, "muzzle") ||
                             contains_mesh(factory_parts, "flash") ||
                             contains_mesh(factory_parts, "m4qd");
    }
    std::printf("factory muzzle requested=%d; emitted=%d\n",
                factory_requests_muzzle ? 1 : 0, factory_has_muzzle ? 1 : 0);
    for (size_t i = 0; i < all_parts.bundles.size(); ++i)
    {
        const std::string& b = all_parts.bundles[i];
        if (b.find("muzzle") != std::string::npos ||
            b.find("flash") != std::string::npos ||
            b.find("m4qd") != std::string::npos)
            std::printf("muzzle candidate bundle\t%s\n", b.c_str());
    }
    for (const std::string& m : all_parts.meshes)
        if (m.find("muzzle") != std::string::npos ||
            m.find("flash") != std::string::npos ||
            m.find("m4qd") != std::string::npos)
            std::printf("muzzle candidate mesh\t%s\n", m.c_str());
    const bool real_changed = base.bundles != fitted.bundles;
    const bool fake_changed = base.bundles != control.bundles;
    const bool stock_raised = contains_mesh(base, "ironsight", "folded");
    const bool optic_folded = contains_mesh(with_optic, "ironsight") &&
                              !contains_mesh(with_optic, "ironsight", "folded");
    const bool canted_resolved = contains_part(with_canted, "cantedreddot") ||
                                 contains_mesh(with_canted, "cantedreddot");
    const bool canted_front_folded = contains_mesh(with_canted, "ironsightsfrontfolded");
    std::printf("real modulemk3 changed=%d, parts=%zu, authored_offsets=%d\n",
                real_changed ? 1 : 0, fitted.count, fitted.offsets);
    std::printf("fake id changed=%d, parts=%zu (negative control)\n",
                fake_changed ? 1 : 0, control.count);
    std::printf("stock raised irons=%d; real optic folded irons=%d\n",
                stock_raised ? 1 : 0, optic_folded ? 1 : 0);
    std::printf("canted design alias resolved=%d; front-folded irons=%d\n",
                canted_resolved ? 1 : 0, canted_front_folded ? 1 : 0);
    if (!stock_raised)
    {
        for (const std::string& b : base.bundles) std::printf("stock bundle\t%s\n", b.c_str());
        for (const std::string& m : base.meshes) std::printf("stock mesh\t%s\n", m.c_str());
        for (const std::string& b : all_parts.bundles)
            if (b.find("sight") != std::string::npos || b.find("iron") != std::string::npos)
                std::printf("sight candidate\t%s\n", b.c_str());
    }
    bf6_close(c);
    return real_changed && !fake_changed && fitted.offsets > 0 &&
           stock_raised && optic_folded && canted_resolved && canted_front_folded &&
           factory_requests_muzzle && factory_has_muzzle ? 0 : 1;
}
