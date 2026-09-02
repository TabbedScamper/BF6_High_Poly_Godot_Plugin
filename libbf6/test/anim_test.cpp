/* anim_test - parse AnimationAssetRelocResource payloads and re-run the
 * format spec's own controls through the public ABI.
 *
 * The spec measured these over a full mount; this checks that OUR reader
 * reproduces them, so a regression fails here rather than in a renderer.
 *
 * RAW framing (header 64, five regions):
 *     r1.offset = r0.offset + 2*r0.count
 *     r1.count  = r2.count
 *     r2.offset = r1.offset + 2*r1.count
 *     r3.offset = align16(r2.offset + 2*r2.count)
 *     r4.offset = r3.offset + 16*r3.count
 *     fileSize  = r4.offset + 16*r4.count + 20
 *   regions 1 and 2 are inverse permutations of 0..N-1
 *   the 20-byte trailer reads 4 16 28 40 52 (the descriptors' OFFSET fields,
 *   12*i+4 - NOT their starts, 12*i, which is the control that separates them)
 */
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cmath>
#include <vector>
#include "bf6_core.h"

static uint32_t align16(uint32_t v) { return (v + 15u) & ~15u; }

int main(int argc, char** argv) {
    if (argc < 3) { std::printf("usage: anim_test <game> <res> [more...]\n"); return 2; }
    char err[256] = {0};
    bf6_ctx* ctx = bf6_open(argv[1], err, sizeof(err));
    if (!ctx) { std::printf("open: %s\n", err); return 1; }
    if (!bf6_mount_all(ctx, 1, err, sizeof(err)))
    { std::printf("mount: %s\n", err); bf6_close(ctx); return 1; }

    int n_dct = 0, n_vbr = 0, n_raw = 0, n_bad = 0;
    int dct_open = 0, dct_size = 0;
    long long interp_sparse = 0, interp_sparse_diff = 0, interp_short = 0;
    long long interp_exact = 0, interp_tot = 0, interp_q_unit = 0, interp_q_tot = 0;
    long long quat_unit = 0, quat_tot = 0;
    int raw_chain = 0, raw_perm = 0, raw_inv = 0, raw_trail = 0, raw_ident = 0, raw_tested = 0;
    for (int a = 2; a < argc; a++) {
        bf6_anim_reloc* r = bf6_anim_reloc_read(ctx, argv[a]);
        if (!r) { n_bad++; std::printf("  %-58s NULL\n", argv[a]); continue; }
        const char* fn = r->framing == BF6_ANIM_DCT ? "DCT" :
                         r->framing == BF6_ANIM_VBR ? "VBR" :
                         r->framing == BF6_ANIM_RAW ? "RAW" : "???";
        if (r->framing == BF6_ANIM_DCT) n_dct++;
        else if (r->framing == BF6_ANIM_VBR) n_vbr++;
        else if (r->framing == BF6_ANIM_RAW) n_raw++;
        if (r->framing == BF6_ANIM_DCT)
            for (int gi = 0; gi < r->region_count; gi++)
                std::printf("      region%d count=%u offset=%u flags=%u  (off+cnt=%u)\n",
                            gi, r->regions[gi].count, r->regions[gi].offset,
                            r->regions[gi].flags, r->regions[gi].offset + r->regions[gi].count);
        std::printf("  %-52s %s hdr=%d regions=%d size=%lld\n",
                    argv[a] + (std::strlen(argv[a]) > 52 ? std::strlen(argv[a]) - 52 : 0),
                    fn, r->header_size, r->region_count, (long long)r->size);

        if (r->framing == BF6_ANIM_RAW && r->region_count >= 5) {
            raw_tested++;
            const bf6_anim_region* g = r->regions;
            const bool chain =
                g[1].offset == g[0].offset + 2*g[0].count &&
                g[1].count  == g[2].count &&
                g[2].offset == g[1].offset + 2*g[1].count &&
                g[3].offset == align16(g[2].offset + 2*g[2].count) &&
                g[4].offset == g[3].offset + 16*g[3].count &&
                (uint64_t)r->size == (uint64_t)g[4].offset + 16ull*g[4].count + 20ull;
            if (chain) raw_chain++;

            /* regions 1 and 2 as permutations, and as inverses of each other */
            const uint32_t N = g[1].count;
            std::vector<uint16_t> m1(N), m2(N);
            std::memcpy(m1.data(), r->data + g[1].offset, (size_t)N*2);
            std::memcpy(m2.data(), r->data + g[2].offset, (size_t)N*2);
            std::vector<char> seen1(N, 0), seen2(N, 0);
            bool p1 = true, p2 = true;
            for (uint32_t i = 0; i < N; i++) {
                if (m1[i] < N && !seen1[m1[i]]) seen1[m1[i]] = 1; else p1 = false;
                if (m2[i] < N && !seen2[m2[i]]) seen2[m2[i]] = 1; else p2 = false;
            }
            if (p1 && p2) raw_perm++;
            bool inv = p1 && p2;
            if (inv) for (uint32_t i = 0; i < N; i++) if (m2[m1[i]] != i) { inv = false; break; }
            if (inv) raw_inv++;
            bool ident = true;
            for (uint32_t i = 0; i < N; i++) if (m1[i] != m2[i]) { ident = false; break; }
            if (ident) raw_ident++;

            /* the 20-byte trailer: descriptor OFFSET fields, 12*i+4 */
            const uint8_t* t = r->data + (r->size - 20);
            uint32_t tv[5];
            std::memcpy(tv, t, 20);
            bool tr = true;
            for (int i = 0; i < 5; i++) if (tv[i] != (uint32_t)(12*i + 4)) tr = false;
            if (tr) raw_trail++;
        }

        if (r->framing == BF6_ANIM_DCT) {
            bf6_anim_clip* cl = bf6_anim_clip_open(ctx, argv[a]);
            if (cl) {
                dct_open++;
                /* THE SIZE IDENTITY. A function of every lane width in every
                 * descriptor, so one misresolved nibble moves it. */
                if (cl->predicted_stream_bytes == cl->actual_stream_bytes) dct_size++;
                else if (dct_open <= 6)
                    std::printf("      SIZE predicted %lld actual %lld delta %lld  keytimes=%d blocks=%d ch=%d(q%d v%d g%d)\n",
                               (long long)cl->predicted_stream_bytes,
                               (long long)cl->actual_stream_bytes,
                               (long long)(cl->actual_stream_bytes - cl->predicted_stream_bytes),
                               cl->key_time_count, cl->block_count, cl->channel_count,
                               cl->quat_count, cl->vec3_count, cl->group_count);
                std::vector<float> v((size_t)cl->channel_count * 4);
                std::vector<float> qm((size_t)cl->quat_count, 0.0f);
                /* Unit quaternions at phase 0 of block 0, and at phase 7 of the
                 * LAST block - the residual path, which is a different code
                 * path from block zero. */
                for (int which = 0; which < 2; which++) {
                    const int ord = which == 0 ? 0
                                  : (cl->block_count - 1) * 8 + 7;
                    if (ord >= cl->block_count * 8) continue;
                    if (!bf6_anim_clip_sample(ctx, cl, ord, v.data(), qm.data())) continue;
                    /* PRE-normalisation magnitude - the check that can fail. */
                    for (int q = 0; q < cl->quat_count && q < 8; q++) {
                        quat_tot++;
                        if (qm[(size_t)q] > 0.9f && qm[(size_t)q] < 1.1f) quat_unit++;
                    }
                }
                /* INTERPOLATION CONTROLS.
                 * (a) sampling at an integer time must equal sampling that
                 *     ordinal directly - if it does not, the bracketing is off
                 *     by one, which is invisible in any smoothness measure.
                 * (b) an interpolated quaternion must still be unit. */
                {
                    std::vector<float> a4((size_t)cl->channel_count * 4);
                    std::vector<float> b4((size_t)cl->channel_count * 4);
                    if (bf6_anim_clip_sample(ctx, cl, 3, a4.data(), nullptr) &&
                        bf6_anim_clip_sample_time(ctx, cl, 3.0f, 0, b4.data())) {
                        bool same = true;
                        for (size_t z = 0; z < a4.size(); z++)
                            if (std::fabs(a4[z] - b4[z]) > 1e-5f) { same = false; break; }
                        /* This equivalence only holds on a DENSE clip, where
                         * the ordinal IS the time. On a sparse clip ordinal 3
                         * sits at key time sparse_times[3], so time 3.0 brackets
                         * somewhere else entirely and disagreeing is CORRECT.
                         * Counting both together would report a real failure. */
                        if (cl->sparse_times) { interp_sparse++; if (!same) interp_sparse_diff++; }
                        else if (cl->key_time_count > 4) { interp_tot++; if (same) interp_exact++; }
                        else {
                            /* A clip with 4 or fewer samples: time 3.0 clamps to
                             * the last ordinal while sample(3) may be past the
                             * end, so they are allowed to differ. Counted, not
                             * silently skipped. */
                            interp_short++;
                        }
                    }
                    if (bf6_anim_clip_sample_time(ctx, cl, 3.5f, 0, b4.data())) {
                        for (int q = 0; q < cl->quat_count && q < 8; q++) {
                            const float* p4 = &b4[(size_t)q*4];
                            const double d2 = (double)p4[0]*p4[0] + (double)p4[1]*p4[1]
                                            + (double)p4[2]*p4[2] + (double)p4[3]*p4[3];
                            interp_q_tot++;
                            if (d2 > 0.99 && d2 < 1.01) interp_q_unit++;
                        }
                    }
                }
                bf6_free(ctx, cl);
            }
        }
        bf6_free(ctx, r);
    }
    std::printf("\nframings: DCT %d  VBR %d  RAW %d  unparsed %d\n", n_dct, n_vbr, n_raw, n_bad);
    if (raw_tested) {
        std::printf("RAW controls over %d payloads:\n", raw_tested);
        std::printf("  region chain arithmetic       %d/%d\n", raw_chain, raw_tested);
        std::printf("  r1 and r2 are permutations    %d/%d\n", raw_perm, raw_tested);
        std::printf("  r1 and r2 are inverse maps    %d/%d\n", raw_inv, raw_tested);
        std::printf("  trailer == 4 16 28 40 52      %d/%d\n", raw_trail, raw_tested);
        std::printf("  CONTROL r1 == r2 (spec 58%%)   %d/%d\n", raw_ident, raw_tested);
    }
    if (dct_open) {
        std::printf("DCT controls over %d payloads:\n", dct_open);
        std::printf("  predicted stream bytes == actual %d/%d\n", dct_size, dct_open);
        std::printf("  quaternion magnitude near 1 BEFORE normalising %lld/%lld\n",
                    quat_unit, quat_tot);
        std::printf("  sample_time(3.0) == sample(ordinal 3), DENSE clips %lld/%lld\n",
                    interp_exact, interp_tot);
        std::printf("  ...sparse clips (may legitimately differ): %lld of %lld differ\n",
                    interp_sparse_diff, interp_sparse);
        std::printf("  ...clips too short to test (<= 4 samples): %lld\n", interp_short);
        std::printf("  interpolated quaternions unit at t=3.5 %lld/%lld\n",
                    interp_q_unit, interp_q_tot);
    }
    bf6_close(ctx);
    return 0;
}
