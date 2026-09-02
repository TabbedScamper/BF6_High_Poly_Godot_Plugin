/* eal3mp3_test - are standard MPEG frames present inside EA Layer3 0x44 frames?
 * Dumps one block's first data frame so it can be fed to a reference decoder. */
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
    if (argc < 2) { std::printf("usage: eal3mp3_test <game> [level] [outfile]\n"); return 2; }
    const char* level = (argc > 2) ? argv[2] : "mp_contaminated";
    const char* out   = (argc > 3) ? argv[3] : nullptr;
    Source src; std::string err;
    if (!src.open(argv[1], err)) { std::printf("open: %s\n", err.c_str()); return 1; }
    if (!src.mount_level(level, false, err)) { std::printf("mount: %s\n", err.c_str()); return 1; }

    int blocks = 0, scanned = 0; long sync = 0, bytes = 0;
    for (const auto& kv : src.loose_chunks()) {
        if (blocks >= 30 || scanned >= 3000) break;
        scanned++;
        std::string e;
        std::vector<uint8_t> b = src.get_chunk(kv.first, e);
        if (b.size() < 256) continue;
        SpsInfo s;
        if (!sps_parse(b.data(), b.size(), s) || s.codec != 0x16) continue;
        std::vector<Eal3Frame> fr;
        if (!sps_eal3_frames(b.data(), b.size(), s, fr)) continue;
        blocks++;
        for (const Eal3Frame& f : fr) {
            if (f.tag != 0x44) continue;
            for (size_t i = f.offset + 4; i + 1 < f.offset + f.size; i++) {
                bytes++;
                if (b[i] == 0xFF && (b[i+1] & 0xE0) == 0xE0) sync++;
            }
        }
        if (out && blocks == 1) {
            /* write the whole payload body so a reference decoder can be tried */
            FILE* o = std::fopen(out, "wb");
            if (o) { std::fwrite(b.data() + s.header, 1, b.size() - s.header, o); std::fclose(o);
                     std::printf("wrote %zu body bytes to %s (chunk %s, %u samples, %d Hz, %d ch)\n",
                                 b.size() - s.header, out, kv.first.substr(0,16).c_str(),
                                 s.samples, s.rate, s.channels); }
        }
    }
    const double expect = bytes / 2048.0;   /* random 11-bit sync rate ~ 1/2048 per byte */
    std::printf("\n  blocks %d   data bytes %ld\n", blocks, bytes);
    std::printf("  0xFF Ex/Fx sync candidates : %ld\n", sync);
    std::printf("  expected by chance (1/2048): %.0f\n", expect);
    std::printf("  ratio observed/chance      : %.2f  (>>1 would mean real MPEG frames inline)\n",
                expect > 0 ? sync / expect : 0.0);
    return 0;
}
