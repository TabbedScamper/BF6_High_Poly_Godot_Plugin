/* clipinfo_test - what a clip's own header says about its channels, next to
 * what the owning EBX declares. If the two agree, the clip's channel vector is
 * the declared one and only the ORDER is open. */
#include <cstdio>
#include <vector>
#include <cmath>
#include "bf6_core.h"

int main(int argc, char** argv) {
    if (argc < 3) { std::printf("usage: clipinfo_test <game> <res> [more...]\n"); return 2; }
    char err[256] = {0};
    bf6_ctx* c = bf6_open(argv[1], err, sizeof(err));
    if (!c) { std::printf("open: %s\n", err); return 1; }
    if (!bf6_mount_all(c, 1, err, sizeof(err))) { std::printf("mount: %s\n", err); return 1; }
    for (int a = 2; a < argc; a++) {
        bf6_anim_clip* cl = bf6_anim_clip_open(c, argv[a]);
        if (!cl) { std::printf("  %-52s OPEN FAILED\n", argv[a]); continue; }
        const char* nm = argv[a]; for (const char* p = argv[a]; *p; p++) if (*p=='/') nm = p+1;
        std::printf("  %-44s quat=%-4d vec3=%-4d group=%-3d chan=%-4d keys=%-5d blocks=%-4d sparse=%s(%d) bytes %lld/%lld\n",
            nm, cl->quat_count, cl->vec3_count, cl->group_count, cl->channel_count,
            cl->key_time_count, cl->block_count,
            cl->sparse_times ? "yes" : "no", cl->sparse_time_count,
            (long long)cl->predicted_stream_bytes, (long long)cl->actual_stream_bytes);
        /* Where does the animation actually STOP changing? Scan every ordinal
         * and measure the L1 delta against the previous sample across ALL
         * channels. If key_time_count is inflated, the tail is exactly zero. */
        std::vector<float> cur((size_t)cl->channel_count * 4), prev((size_t)cl->channel_count * 4);
        int last_change = -1, zero_run = 0, first_zero = -1;
        for (int o = 0; o < cl->key_time_count; o++) {
            if (!bf6_anim_clip_sample(c, cl, o, cur.data(), nullptr)) break;
            if (o > 0) {
                double dl = 0.0;
                for (size_t k = 0; k < cur.size(); k++) dl += std::fabs(cur[k] - prev[k]);
                if (dl > 1e-6) { last_change = o; zero_run = 0; first_zero = -1; }
                else { if (first_zero < 0) first_zero = o; zero_run++; }
            }
            prev = cur;
        }
        std::printf("      last ordinal that CHANGES: %d of %d   trailing identical run: %d (from %d)\n",
                    last_change, cl->key_time_count - 1, zero_run, first_zero);
    }
    bf6_close(c);
    return 0;
}
