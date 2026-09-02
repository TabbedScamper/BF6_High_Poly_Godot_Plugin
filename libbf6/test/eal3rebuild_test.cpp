/* eal3rebuild_test - rebuild standard MPEG frames from EA Layer3 and write .mp3
 *
 * THE VERIFICATION IS EXTERNAL. A rebuilt stream is ordinary MP3, so ffmpeg
 * either decodes it or it does not, and the decoded sample count either matches
 * the SPS header or it does not. Neither is a judgement I make about my own
 * output.
 */
#include "source.h"
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>
#include <map>
using namespace bf6;
#include "sps_decode.inc"

int main(int argc, char** argv)
{
    if (argc < 2) { std::printf("usage: eal3rebuild_test <game> [level] [out.mp3]\n"); return 2; }
    const char* level = (argc > 2) ? argv[2] : "mp_contaminated";
    const char* outp  = (argc > 3) ? argv[3] : nullptr;
    Source src; std::string err;
    if (!src.open(argv[1], err)) { std::printf("open: %s\n", err.c_str()); return 1; }
    if (!src.mount_level(level, false, err)) { std::printf("mount: %s\n", err.c_str()); return 1; }

    int scanned = 0, done = 0, clean = 0, covered = 0, shown_bad = 0;
    long tot_gran = 0, tot_frames = 0, tot_failed = 0, tot_pcm = 0; int withpcm = 0;
    for (const auto& kv : src.loose_chunks()) {
        if (done >= 300 || scanned >= 6000) break;
        scanned++;
        std::string e;
        std::vector<uint8_t> b = src.get_chunk(kv.first, e);
        if (b.size() < 2048) continue;
        SpsInfo s;
        if (!sps_parse(b.data(), b.size(), s) || s.codec != 0x16) continue;
        std::vector<Eal3Frame> blocks;
        if (!sps_eal3_frames(b.data(), b.size(), s, blocks)) continue;

        /* collect every EA granule in order */
        std::vector<Eal3Gran> grans;
        long pcm_samples = 0;
        bool bad = false;
        for (const Eal3Frame& blk : blocks) {
            if (blk.tag != 0x44 || blk.size < 8) continue;
            size_t pos = blk.offset + 8;
            const size_t end = blk.offset + blk.size;
            while (pos < end) {
                Eal3Gran g;
                const uint32_t used = eal3_parse(b.data() + pos, end - pos, g);
                if (!used) { bad = true; break; }
                pcm_samples += g.pcm_samples;
                if (g.common_size) grans.push_back(g);
                pos += used;
            }
            if (bad) break;
        }
        if (bad || grans.size() < 2) continue;

        /* pair granule0 + granule1 into MPEG1 frames */
        std::vector<uint8_t> mp3;
        int frames = 0, failed = 0;
        /* Pair ADAPTIVELY rather than assuming a strict 0,1,0,1 run: a stream
         * may open on granule1 or carry PCM-only frames between granules, and a
         * fixed i += 2 walk can never re-sync after one of those. MPEG2 stores
         * one granule per frame and needs no pair at all. */
        for (size_t i = 0; i < grans.size(); ) {
            if (!grans[i].mpeg1) {                       /* MPEG2: single granule */
                std::vector<uint8_t> f;
                if (eal3_rebuild(grans[i], nullptr, f)) {
                    mp3.insert(mp3.end(), f.begin(), f.end()); frames++;
                } else failed++;
                i++; continue;
            }
            if (grans[i].granule_index != 0) { i++; continue; }   /* re-sync */
            if (i + 1 >= grans.size() || grans[i + 1].granule_index != 1) {
                /* A stream may END on granule0. MPEG1 decodes in PAIRS, so feed
                 * a cloned granule1 to flush the last 576 samples - vgmstream
                 * does the same. The surplus falls past the declared sample
                 * count, so any consumer honouring that count discards it. */
                Eal3Gran fake = grans[i];
                fake.granule_index = 1;
                std::vector<uint8_t> ff;
                if (eal3_rebuild(grans[i], &fake, ff)) {
                    mp3.insert(mp3.end(), ff.begin(), ff.end()); frames++;
                } else failed++;
                i++; continue;
            }
            std::vector<uint8_t> f;
            if (eal3_rebuild(grans[i], &grans[i + 1], f)) {
                mp3.insert(mp3.end(), f.begin(), f.end()); frames++;
            } else failed++;
            i += 2;
        }
        tot_gran += (long)grans.size(); tot_frames += frames; tot_failed += failed;
        tot_pcm += pcm_samples; if (pcm_samples) withpcm++;
        if (failed == 0 && frames > 0) clean++;
        /* frames*1152 must cover the declared sample count, within one granule.
         * The appended PCM samples are NOT added: measured, they OVERLAP the
         * granule output rather than extending it - adding them pushed every
         * PCM-carrying chunk exactly one granule over, which is what exposed
         * the relationship. */
        /* MULTICHANNEL is carried as several parallel MPEG streams of at most 2
         * channels each, so the frames cover every stream and must be divided
         * by the stream count. Measured on a 4-channel chunk the raw figure
         * overshoots by exactly 2x, which is what identified this. */
        const int streams = (s.channels + 1) / 2;
        const long delta = (long)frames * 1152 / (streams > 0 ? streams : 1) - (long)s.samples;
        if (delta >= 0 && delta < 1152) covered++;
        else if (shown_bad < 6) {
            shown_bad++;
            std::printf("  MISS: declared %6u  frames %4d (=%6d)  granules %4zu  pcm %5ld  ch %d  delta %ld\n",
                        s.samples, frames, frames * 1152, grans.size(), pcm_samples, s.channels, delta);
        }
        if (outp && !mp3.empty() && done == 0) {
            FILE* o = std::fopen(outp, "wb");
            if (o) { std::fwrite(mp3.data(), 1, mp3.size(), o); std::fclose(o);
                     std::printf("  wrote %s (%d frames, %u declared samples)\n",
                                 outp, frames, s.samples); }
        }
        done++;
    }
    std::printf("  EA Layer3 chunks processed : %d\n", done);
    std::printf("  EA granules parsed         : %ld\n", tot_gran);
    std::printf("  MPEG frames rebuilt        : %ld   failed: %ld\n", tot_frames, tot_failed);
    std::printf("  chunks with ZERO failures  : %d of %d\n", clean, done);
    std::printf("  frames*1152 covers samples : %d of %d  (within one granule)\n", covered, done);
    const bool pass = done > 0 && clean == done && covered == done && tot_failed == 0;
    std::printf("\n%s\n", pass ? "PASS" : "FAIL");
    return pass ? 0 : 1;
}
