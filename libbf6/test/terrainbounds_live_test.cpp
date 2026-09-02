/* Proves that default ground coverage takes its bounds from the mounted
 * game's splat root rather than from a compiled Portal SDK overlay table.
 *
 * Experiment: no explicit window; returned bounds must equal block 1's root.
 * Control: a small explicit window must equal the requested rectangle and
 *          differ from the root. A fake level must fail to mount.
 */
#include <cmath>
#include <cstdio>
#include <string>
#include <vector>

#include "groundsplat.h"
#include "source.h"
#include "splat.h"

using namespace bf6;

namespace {

bool close4(float a, float b)
{
    return std::fabs(a - b) <= 1.0e-4f;
}

bool load_live_splat(Source& src, const std::string& level, Splat& out,
                     std::string& err)
{
    std::string want = level;
    for (char& c : want) c = (char)std::tolower((unsigned char)c);
    for (const auto& kv : src.res()) {
        std::string name = kv.first;
        for (char& c : name) c = (char)std::tolower((unsigned char)c);
        if (name.find("streamingtree") == std::string::npos ||
            name.find(want) == std::string::npos) continue;
        const std::vector<uint8_t> res = src.get_res(kv.first, err);
        std::vector<uint8_t> block;
        return !res.empty() && Splat::find_block(res, 1, block, err) &&
               out.parse(block, err);
    }
    err = "no live streaming tree for " + level;
    return false;
}

} // namespace

int main(int argc, char** argv)
{
    if (argc < 3) {
        std::fprintf(stderr, "usage: terrainbounds_live_test <game_dir> <level>\n");
        return 2;
    }

    std::string err;
    Source src;
    if (!src.open(argv[1], err) || !src.mount_level(argv[2], false, err)) {
        std::fprintf(stderr, "mount: %s\n", err.c_str());
        return 1;
    }

    Splat splat;
    if (!load_live_splat(src, argv[2], splat, err)) {
        std::fprintf(stderr, "splat: %s\n", err.c_str());
        return 1;
    }
    const float* root_lo = splat.root_min();
    const float* root_hi = splat.root_max();

    GroundCoverageOpts experiment;
    experiment.size = 8;
    experiment.max_slots = 8;
    GroundCoverage whole;
    if (!ground_coverage(src, argv[2], experiment, whole, err)) {
        std::fprintf(stderr, "default coverage: %s\n", err.c_str());
        return 1;
    }
    const bool root_match = close4(whole.lo[0], root_lo[0]) &&
                            close4(whole.lo[1], root_lo[1]) &&
                            close4(whole.hi[0], root_hi[0]) &&
                            close4(whole.hi[1], root_hi[1]);

    GroundCoverageOpts control = experiment;
    control.rect_size = 64.f;
    control.rect_min[0] = (root_lo[0] + root_hi[0]) * .5f - 32.f;
    control.rect_min[1] = (root_lo[1] + root_hi[1]) * .5f - 32.f;
    GroundCoverage window;
    if (!ground_coverage(src, argv[2], control, window, err)) {
        std::fprintf(stderr, "window control: %s\n", err.c_str());
        return 1;
    }
    const bool window_match = close4(window.lo[0], control.rect_min[0]) &&
                              close4(window.lo[1], control.rect_min[1]) &&
                              close4(window.hi[0], control.rect_min[0] + 64.f) &&
                              close4(window.hi[1], control.rect_min[1] + 64.f);
    const bool window_differs = !close4(window.lo[0], whole.lo[0]) ||
                                !close4(window.lo[1], whole.lo[1]) ||
                                !close4(window.hi[0], whole.hi[0]) ||
                                !close4(window.hi[1], whole.hi[1]);

    Source fake;
    std::string fake_err;
    const bool fake_accepted = fake.open(argv[1], fake_err) &&
                               fake.mount_level("__missing_level_control__", false,
                                                fake_err);

    std::printf("live splat root: %.3f %.3f .. %.3f %.3f\n",
                root_lo[0], root_lo[1], root_hi[0], root_hi[1]);
    std::printf("default/root experiment: %s\n", root_match ? "PASS" : "FAIL");
    std::printf("explicit-window control: %s (different from root: %s)\n",
                window_match ? "PASS" : "FAIL", window_differs ? "yes" : "no");
    std::printf("fake-level control: %s\n",
                fake_accepted ? "FAIL/accepted" : "PASS/rejected");
    return root_match && window_match && window_differs && !fake_accepted ? 0 : 1;
}
