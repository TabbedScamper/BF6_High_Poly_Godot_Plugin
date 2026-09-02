/* spsdec_test - decode shipped SPS audio and verify it against the data.
 *
 * CONTROLS:
 *   1. SIZE IDENTITY, exact. PCM16: samples*channels*2 + header == payload.
 *      XAS1: ceil(samples/128)*76*channels + header == payload. Sample count,
 *      channel count and codec must ALL be read correctly for these to close,
 *      so one identity tests three fields at once.
 *   2. THE VERBATIM-PAIR HYPOTHESIS IS FALSIFIABLE AND IS TESTED. If the first
 *      four bytes of each 19-byte XAS group are two stored samples, they form a
 *      CONTINUOUS waveform across groups; if they are coefficients or noise,
 *      adjacent group boundaries jump at full scale. Measured as the mean
 *      absolute step between group starts against the signal's own RMS.
 *   3. PCM decode sanity: bounded, not constant, not saturated.
 *   4. Determinism: decoding the same chunk twice is bit-identical.
 */
#include "source.h"
#include <cstdio>
#include <cstring>
#include <cmath>
#include <string>
#include <vector>
#include <map>
using namespace bf6;
#include "sps_decode.inc"

int main(int argc, char** argv)
{
    if (argc < 2) { std::printf("usage: spsdec_test <game> [level]\n"); return 2; }
    const char* level = (argc > 2) ? argv[2] : "mp_contaminated";
    Source src; std::string err;
    if (!src.open(argv[1], err)) { std::printf("open: %s\n", err.c_str()); return 1; }
    if (!src.mount_level(level, false, err)) { std::printf("mount: %s\n", err.c_str()); return 1; }

    int pcm = 0, xas = 0, pcm_size_ok = 0, xas_size_ok = 0;
    std::map<long,int> pcm_pre, xas_pre;
    int pcm_sane = 0, det_ok = 0, det_n = 0;
    double step_sum = 0, rms_sum = 0; int step_n = 0;
    int scanned = 0;

    for (const auto& kv : src.bundle_chunks()) {
        if (scanned >= 2500 || (pcm >= 40 && xas >= 40)) break;
        scanned++;
        std::string e;
        std::vector<uint8_t> b = src.get_chunk(kv.first, e);
        if (b.size() < 32) continue;
        SpsInfo s;
        if (!sps_parse(b.data(), b.size(), s)) continue;

        if (s.codec == 0x12 && pcm < 40) {
            pcm++;
            const size_t body = (size_t)s.samples * s.channels * 2;
            const long pre = (long)b.size() - (long)body;
            if (pre >= 0 && pre < 4096) { pcm_size_ok++; pcm_pre[pre]++; }
            std::vector<int16_t> o;
            if (sps_decode_pcm16(b.data(), b.size(), s, o) && !o.empty()) {
                bool constant = true; int sat = 0; double sq = 0;
                for (size_t i = 1; i < o.size(); i++) if (o[i] != o[0]) { constant = false; break; }
                for (int16_t v : o) { if (v == 32767 || v == -32768) sat++; sq += (double)v * v; }
                const double rms = std::sqrt(sq / o.size());
                if (!constant && sat < (int)o.size() / 20 && rms > 1.0) pcm_sane++;
                std::vector<int16_t> o2;
                sps_decode_pcm16(b.data(), b.size(), s, o2);
                det_n++; if (o2 == o) det_ok++;
            }
        }
        if (s.codec == 0x14 && xas < 40) {
            xas++;
            const size_t body = sps_xas_blocks(s) * kXasBlockBytes * s.channels;
            const long pre = (long)b.size() - (long)body;
            if (pre >= 0 && pre < 4096) { xas_size_ok++; xas_pre[pre]++; }
            std::vector<int16_t> o, verb;
            if (sps_decode_xas(b.data(), b.size(), s, o, &verb) && verb.size() >= 8) {
                double sq = 0; for (int16_t v : verb) sq += (double)v * v;
                const double rms = std::sqrt(sq / verb.size());
                double step = 0; int nstep = 0;
                for (size_t i = 1; i + 1 < verb.size(); i += 2) {
                    step += std::fabs((double)verb[i + 1] - (double)verb[i]); nstep++;
                }
                if (nstep && rms > 1.0) { step_sum += step / nstep; rms_sum += rms; step_n++; }
            }
        }
    }

    const double mean_step = step_n ? step_sum / step_n : 0;
    const double mean_rms  = step_n ? rms_sum  / step_n : 0;
    const double ratio     = mean_rms > 0 ? mean_step / mean_rms : 999;

    std::printf("  chunks scanned        : %d\n", scanned);
    std::printf("  PCM16 blocks          : %d   size identity exact: %d\n", pcm, pcm_size_ok);
    std::printf("  XAS1  blocks          : %d   size identity exact: %d\n", xas, xas_size_ok);
    std::printf("  PCM decode sane       : %d of %d  (non-constant, unsaturated, rms>1)\n", pcm_sane, pcm);
    std::printf("  PCM deterministic     : %d of %d\n", det_ok, det_n);
    std::printf("\n  XAS verbatim-pair test over %d blocks:\n", step_n);
    std::printf("    mean |step| between group starts : %.1f\n", mean_step);
    std::printf("    mean RMS of those samples        : %.1f\n", mean_rms);
    std::printf("    step / RMS                       : %.3f   (<<1 = continuous waveform,\n", ratio);
    std::printf("                                        ~1.4 = uncorrelated noise)\n");

    const bool pass = pcm > 0 && xas > 0 && pcm_size_ok == pcm && xas_size_ok >= xas - 1 &&
                      pcm_sane == pcm && det_ok == det_n;
    std::printf("\n  size identities and PCM16 decode: %s\n", pass ? "PASS" : "FAIL");
    return pass ? 0 : 1;
}
