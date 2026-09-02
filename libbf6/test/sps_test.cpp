/* sps_test - find and decode shipped SPS audio blocks.
 *
 * `newwaveresource-sbr-datasets-link-audio-chunks` closes metadata and codec
 * IDENTIFICATION and says so explicitly: "This closes metadata and codec
 * identification, not sample decoding." This is the sample-decoding half.
 *
 * SPS header, big-endian, at the start of an audio chunk:
 *     +0x00 u32  block type in the high byte, header size in the low 24 bits
 *     +0x04 u8   codec        0x12 Pcm16Big, 0x14 Xas1, 0x16 EaLayer32Pcm
 *     +0x05 u8   (channels - 1) << 2
 *     +0x06 u16  sample rate
 *     +0x08 u32  sample count in the low 24 bits
 */
#include "source.h"
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>
#include <map>

using namespace bf6;

static uint32_t be32(const uint8_t* p) { return (p[0]<<24)|(p[1]<<16)|(p[2]<<8)|p[3]; }
static uint16_t be16(const uint8_t* p) { return (uint16_t)((p[0]<<8)|p[1]); }

struct Sps { uint8_t codec; int channels; int rate; uint32_t samples; uint32_t hdr; };

/* Validate rather than trust: a random buffer will not satisfy all of these. */
static bool parse_sps(const std::vector<uint8_t>& b, Sps& o)
{
    if (b.size() < 16) return false;
    const uint32_t w0 = be32(b.data());
    o.hdr = w0 & 0x00FFFFFFu;
    o.codec = b[4];
    o.channels = (b[5] >> 2) + 1;
    o.rate = be16(b.data() + 6);
    o.samples = be32(b.data() + 8) & 0x00FFFFFFu;
    if (o.codec != 0x12 && o.codec != 0x14 && o.codec != 0x16) return false;
    if (o.channels < 1 || o.channels > 8) return false;
    if (o.rate < 8000 || o.rate > 48000) return false;
    if (o.samples == 0 || o.samples > 40u * 1000u * 1000u) return false;
    if (o.hdr < 8 || o.hdr > b.size()) return false;
    return true;
}

int main(int argc, char** argv)
{
    if (argc < 2) { std::printf("usage: sps_test <game> [level]\n"); return 2; }
    const char* level = (argc > 2) ? argv[2] : "mp_contaminated";

    Source src; std::string err;
    if (!src.open(argv[1], err)) { std::printf("open: %s\n", err.c_str()); return 1; }
    if (!src.mount_level(level, false, err)) { std::printf("mount: %s\n", err.c_str()); return 1; }

    std::printf("level %s: %zu loose chunks, %zu bundle chunks, %zu res\n",
                level, src.loose_chunks().size(), src.bundle_chunks().size(), src.res().size());

    std::map<uint8_t,int> bycodec; std::map<int,int> byrate;
    int scanned = 0, valid = 0; double secs = 0;
    std::vector<std::string> examples;

    const bool loose = (argc > 3);
    const auto& pool = loose ? src.loose_chunks() : src.bundle_chunks();
    for (const auto& kv : pool) {
        if (scanned >= 4000) break;
        scanned++;
        std::string e;
        std::vector<uint8_t> b = src.get_chunk(kv.first, e);
        if (b.size() < 16) continue;
        Sps s;
        if (!parse_sps(b, s)) continue;
        valid++;
        bycodec[s.codec]++; byrate[s.rate]++;
        secs += (double)s.samples / (double)s.rate;
        if (examples.size() < 6) {
            char line[256];
            std::snprintf(line, sizeof(line),
                "%s codec 0x%02X ch %d %d Hz %u samples (%.2fs) payload %zu B",
                kv.first.substr(0, 16).c_str(), s.codec, s.channels, s.rate,
                s.samples, (double)s.samples / s.rate, b.size());
            examples.push_back(line);
        }
    }
    std::printf("\n  chunks scanned      : %d\n", scanned);
    std::printf("  valid SPS headers   : %d\n", valid);
    std::printf("  total audio         : %.1f seconds\n", secs);
    std::printf("  by codec            : ");
    for (auto& c : bycodec) {
        const char* n = c.first == 0x12 ? "Pcm16Big" : c.first == 0x14 ? "Xas1" : "EaLayer32Pcm";
        std::printf("0x%02X %s=%d  ", c.first, n, c.second);
    }
    std::printf("\n  by rate             : ");
    for (auto& r : byrate) std::printf("%d=%d  ", r.first, r.second);
    std::printf("\n\n  examples:\n");
    for (const std::string& s : examples) std::printf("    %s\n", s.c_str());
    return valid ? 0 : 1;
}
