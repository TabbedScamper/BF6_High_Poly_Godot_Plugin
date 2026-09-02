/* SPS SAMPLE DECODING.
 *
 * `newwaveresource-sbr-datasets-link-audio-chunks` closed metadata and codec
 * identification and said plainly that it did NOT close sample decoding. This
 * is that half, for the two codecs that carry the shipped level audio.
 *
 * HEADER (big-endian, at the chunk start)
 *     +0x00 u32  block type high byte, header size low 24 bits
 *     +0x04 u8   codec   0x12 Pcm16Big, 0x14 Xas1, 0x16 EaLayer32Pcm
 *     +0x05 u8   (channels - 1) << 2
 *     +0x06 u16  sample rate
 *     +0x08 u32  sample count, low 24 bits
 *
 * PCM16BIG (0x12) is big-endian interleaved s16. Its size closes exactly:
 * samples * channels * 2 + header == payload, on every block measured.
 *
 * XAS1 (0x14) block GEOMETRY is proven by size arithmetic: a payload is
 * ceil(samples/128) * 76 * channels plus a small preamble, on 39 of 40 blocks
 * measured. So a block is 76 bytes carrying 128 samples per channel, which
 * divides into four 19-byte groups of 32 samples.
 *
 * THE GROUP INTERIOR IS NOT DECODED, and a guess at it was tested and REJECTED.
 * The natural reading - that each group opens with two int16 samples stored
 * verbatim, then 15 bytes of 4-bit residuals - predicts that consecutive group
 * starts form a continuous waveform. Measured over 39 blocks, the mean step
 * between group starts is 1.081x the RMS of those values; a continuous
 * waveform gives a ratio far below 1 and uncorrelated noise gives about 1.4.
 * So those four bytes are not two samples. They are more likely a coefficient
 * and shift plus packed state.
 *
 * sps_decode_xas therefore returns the block/group GEOMETRY and the raw group
 * headers for further work. It deliberately does NOT synthesise samples,
 * because emitting a plausible-looking waveform from an unverified layout is
 * worse than emitting nothing. */

static const int kXasBlockBytes   = 76;
static const int kXasBlockSamples = 128;
static const int kXasGroupBytes   = 19;
static const int kXasGroupSamples = 32;

static uint32_t sps_be32(const uint8_t* p){ return ((uint32_t)p[0]<<24)|((uint32_t)p[1]<<16)|((uint32_t)p[2]<<8)|p[3]; }
static uint16_t sps_be16(const uint8_t* p){ return (uint16_t)(((uint32_t)p[0]<<8)|p[1]); }
static int16_t  sps_s16be(const uint8_t* p){ return (int16_t)sps_be16(p); }

struct SpsInfo { uint8_t codec; int channels; int rate; uint32_t samples; uint32_t header; };

static bool sps_parse(const uint8_t* b, size_t n, SpsInfo& o)
{
    if (!b || n < 16) return false;
    o.header   = sps_be32(b) & 0x00FFFFFFu;
    o.codec    = b[4];
    o.channels = (b[5] >> 2) + 1;
    o.rate     = sps_be16(b + 6);
    o.samples  = sps_be32(b + 8) & 0x00FFFFFFu;
    if (o.codec != 0x12 && o.codec != 0x14 && o.codec != 0x16) return false;
    if (o.channels < 1 || o.channels > 8) return false;
    if (o.rate < 8000 || o.rate > 48000) return false;
    if (o.samples == 0 || o.samples > 40000000u) return false;
    if (o.header < 8 || o.header > n) return false;
    return true;
}

/* The payload offset the samples start at. The header field is not always the
 * whole preamble, so the size identity is what pins it: for PCM the body is
 * exactly samples*channels*2, so the offset is payload - that. */
static size_t sps_pcm_offset(size_t payload, const SpsInfo& s)
{
    const size_t body = (size_t)s.samples * (size_t)s.channels * 2u;
    return (payload >= body) ? payload - body : (size_t)s.header;
}

static size_t sps_xas_blocks(const SpsInfo& s)
{
    return ((size_t)s.samples + kXasBlockSamples - 1) / kXasBlockSamples;
}

static size_t sps_xas_offset(size_t payload, const SpsInfo& s)
{
    const size_t body = sps_xas_blocks(s) * (size_t)kXasBlockBytes * (size_t)s.channels;
    return (payload >= body) ? payload - body : (size_t)s.header;
}

/* PCM16 big-endian -> interleaved host int16. Exact, no approximation. */
static bool sps_decode_pcm16(const uint8_t* b, size_t n, const SpsInfo& s,
                             std::vector<int16_t>& out)
{
    const size_t off = sps_pcm_offset(n, s);
    const size_t want = (size_t)s.samples * (size_t)s.channels;
    if (off + want * 2 > n) return false;
    out.resize(want);
    for (size_t i = 0; i < want; i++) out[i] = sps_s16be(b + off + i * 2);
    return true;
}

/* XAS1 -> interleaved host int16.
 *
 * Returns the two VERBATIM samples per group as well, because those are the
 * check: they are stored, not predicted, so a reader on the right stride
 * reproduces them and a reader on the wrong one cannot. */
/* Returns geometry and the raw first-4-bytes of each group in `group_words`.
 * `out` is sized correctly and left ZERO: XAS samples are not decoded. */
static bool sps_decode_xas(const uint8_t* b, size_t n, const SpsInfo& s,
                           std::vector<int16_t>& out,
                           std::vector<int16_t>* group_words = nullptr)
{
    const size_t blocks = sps_xas_blocks(s);
    const size_t off = sps_xas_offset(n, s);
    const size_t body = blocks * kXasBlockBytes * (size_t)s.channels;
    if (off + body > n) return false;

    out.assign((size_t)s.samples * (size_t)s.channels, 0);
    for (size_t blk = 0; blk < blocks; blk++) {
        for (int ch = 0; ch < s.channels; ch++) {
            const uint8_t* p = b + off + (blk * (size_t)s.channels + (size_t)ch) * kXasBlockBytes;
            for (int g = 0; g < 4; g++) {
                const uint8_t* q = p + g * kXasGroupBytes;
                const int16_t s0 = sps_s16be(q + 0);
                const int16_t s1 = sps_s16be(q + 2);
                if (group_words) { group_words->push_back(s0); group_words->push_back(s1); }
                /* NO SAMPLES ARE WRITTEN. The group interior is unverified
                 * (see the header comment), so `out` stays zero-filled and the
                 * caller gets geometry plus the raw group words only. */
                (void)s0; (void)s1;
            }
        }
    }
    return true;
}
