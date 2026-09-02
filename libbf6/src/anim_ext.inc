/* anim_ext.inc - AnimationAssetRelocResource, the container that holds 99.9%
 * of BF6's animation.
 *
 * A translation-unit fragment like the others.
 *
 * WHY THIS AND NOT THE OTHER TWO. The raw (0x185E69A4) and ACL (0x1190E82E)
 * clip containers are fully documented and between them hold a few hundred
 * payloads. This type holds 486,942, and no clip-player node in the game
 * reaches anything else. A consumer that decodes the other two reaches almost
 * no animation at all, which is why this is the one worth implementing.
 *
 * THE FRAMING RULE, which is the whole trick: region 0's OFFSET is the header
 * size, and the header holds as many 12-byte {count, offset, flags}
 * descriptors as fit, with the remainder as trailing dwords. That single rule
 * covers all three framings:
 *
 *     offset 32 -> 2 descriptors + 2 dwords   'DCT ' , 6,244 payloads
 *     offset 48 -> 4 descriptors + 0          'VBR ' ,   254
 *     offset 64 -> 5 descriptors + 1          'RAW ' , 1,697
 *
 * A two-descriptor parser reads a RAW payload as if it had two regions and
 * silently truncates it - the structure still "parses", which is the failure
 * mode this comment exists to prevent.
 */

typedef struct { uint32_t count, offset, flags; } bf6__anim_desc;

struct AnimRelocHandle {
    bf6_anim_reloc            r{};
    std::vector<uint8_t>      bytes;
    std::vector<bf6_anim_region> regions;
};

bf6_anim_reloc* bf6_anim_reloc_read(bf6_ctx* c, const char* res_name)
{
    if (!c || !res_name) return nullptr;
    const uint8_t* d = nullptr;
    const int64_t n = bf6_read_raw(c, BF6_RAW_RES, res_name, &d);
    if (n < 12 || !d) return nullptr;

    auto rd32 = [&](size_t o) { uint32_t v; std::memcpy(&v, d + o, 4); return v; };

    /* Region 0's offset IS the header size. Anything that is not 12n + 4m is
     * not this container - 14 payloads out of 8,209 are rejected this way
     * rather than being forced into a framing they do not have. */
    const uint32_t hdr = rd32(4);
    if (hdr < 12 || hdr > 256 || (size_t)hdr > (size_t)n) return nullptr;
    const uint32_t ndesc = hdr / 12u;
    const uint32_t trail = (hdr - ndesc * 12u);
    if (trail % 4u != 0u || ndesc == 0u) return nullptr;

    AnimRelocHandle* h = new AnimRelocHandle();
    h->bytes.assign(d, d + n);
    const uint8_t* b = h->bytes.data();
    auto r32 = [&](size_t o) { uint32_t v; std::memcpy(&v, b + o, 4); return v; };

    for (uint32_t i = 0; i < ndesc; i++)
    {
        bf6_anim_region g{};
        g.count  = r32((size_t)i * 12 + 0);
        g.offset = r32((size_t)i * 12 + 4);
        g.flags  = r32((size_t)i * 12 + 8);
        /* A TRAILING {0,0} DESCRIPTOR IS A TERMINATOR, NOT A REGION. The
         * 48-byte framing ends with one, and treating its zero offset as a real
         * region makes an otherwise correct chain look broken. */
        if (i > 0 && g.count == 0 && g.offset == 0) break;
        h->regions.push_back(g);
    }

    h->r.framing = (hdr == 32) ? BF6_ANIM_DCT
                 : (hdr == 48) ? BF6_ANIM_VBR
                 : (hdr == 64) ? BF6_ANIM_RAW : BF6_ANIM_UNKNOWN;
    h->r.header_size  = (int32_t)hdr;
    h->r.regions      = h->regions.data();
    h->r.region_count = (int32_t)h->regions.size();
    h->r.data         = h->bytes.data();
    h->r.size         = n;
    c->handles[&h->r] = bf6_ctx::HK_ANIMRELOC;
    return &h->r;
}

void bf6__animreloc_delete(void* p) { delete (AnimRelocHandle*)p; }

/* ------------------------------------------------- the DCT clip codec ----- */

/* Variant A: region 1 is the engine's DctAnimationAsset body. Eight samples
 * share one coefficient block, stored as quantised DCT rows.
 *
 * THE THREE THINGS THAT SILENTLY GO WRONG, all of which still "parse":
 *
 * 1. The descriptor run is only walkable WITH THE FLAGS IN HAND - descriptor i
 *    is 8 + 2*(flags[i] >> 4) bytes. A fixed stride desynchronises the run and
 *    every later channel reads another channel's base coefficients.
 * 2. ALL FOUR LANES are in the width accounting for EVERY channel kind. It is
 *    tempting to budget three lanes for a vector3 or one for a scalar group;
 *    doing so shifts the whole bitstream and still yields plausible numbers.
 * 3. The bitstream is LSB-FIRST. An MSB-first reader produces normalised
 *    four-vectors too, so within-frame checks stay green.
 *
 * The size identity is what catches 1 and 2: predicted stored bytes must equal
 * the bytes actually present, and it is a function of every lane width in every
 * descriptor, so one misresolved nibble moves the total.
 */

struct AnimDctChannel {
    int16_t  base[4];
    uint8_t  rows;                 /* N = flag >> 4 */
    std::vector<uint16_t> width;   /* N width words */
};

struct AnimClipHandle {
    bf6_anim_clip               c{};
    std::vector<uint8_t>        bytes;
    std::vector<AnimDctChannel> ch;
    std::vector<uint16_t>       key_times;
    size_t                      bits_off = 0;   /* into bytes */
    size_t                      bits_len = 0;
    uint32_t                    full_block_bits = 0;
    uint32_t                    first_coef_bits = 0;
    uint16_t                    block_quant = 1;
    uint8_t                     sub_quant_tenths = 0;
    uint8_t                     coef_bit_width = 0;
};

/* LSB-FIRST: bit (pos & 7) of byte (pos >> 3) is result bit 0. */
static inline int32_t bf6__rdbits(const uint8_t* p, size_t len, uint64_t& pos, int w)
{
    if (w <= 0) return 0;
    uint32_t v = 0;
    for (int i = 0; i < w; i++) {
        const size_t byte = (size_t)(pos >> 3);
        const uint32_t bit = (byte < len) ? ((uint32_t)(p[byte] >> (pos & 7)) & 1u) : 0u;
        v |= bit << i;
        pos++;
    }
    if (w < 32 && (v & (1u << (w - 1)))) v |= ~((1u << w) - 1u);   /* sign extend */
    return (int32_t)v;
}

bf6_anim_clip* bf6_anim_clip_open(bf6_ctx* c, const char* res_name)
{
    bf6_anim_reloc* r = bf6_anim_reloc_read(c, res_name);
    if (!r) return nullptr;
    if (r->framing != BF6_ANIM_DCT || r->region_count < 2) { bf6_free(c, r); return nullptr; }

    const size_t   n  = (size_t)r->size;
    const uint32_t r1 = r->regions[1].offset;
    if ((size_t)r1 + 12 > n) { bf6_free(c, r); return nullptr; }

    AnimClipHandle* h = new AnimClipHandle();
    h->bytes.assign(r->data, r->data + n);
    const uint8_t* b = h->bytes.data();
    auto q16 = [&](size_t o) { uint16_t v; std::memcpy(&v, b + o, 2); return v; };

    const uint16_t keyTimes = q16(r1 + 0);
    const uint16_t nq       = q16(r1 + 2);
    const uint16_t nv       = q16(r1 + 4);
    const uint16_t ng       = q16(r1 + 6);
    h->block_quant      = q16(r1 + 8);
    h->sub_quant_tenths = b[r1 + 10];
    h->coef_bit_width   = b[r1 + 11];
    const uint32_t nch = (uint32_t)nq + nv + ng;
    if (!nch || nch > 65535u) { delete h; bf6_free(c, r); return nullptr; }

    /* Region 0 is the sparse key-time list. EMPTY means implicit and dense:
     * every integer 0..frameCount inclusive, so frameCount + 1 samples - the
     * EBX frame count is a last frame INDEX, not a sample count. */
    if (r->regions[0].count) {
        h->key_times.resize(r->regions[0].count);
        std::memcpy(h->key_times.data(), b + r->regions[0].offset,
                    (size_t)r->regions[0].count * 2);
    }

    size_t p = (size_t)r1 + 12;
    if (p + nch > n) { delete h; bf6_free(c, r); return nullptr; }
    std::vector<uint8_t> flags(b + p, b + p + nch);
    p += nch;
    if (p & 1u) p++;                       /* pad ONLY when the cursor is odd */

    h->ch.resize(nch);
    for (uint32_t i = 0; i < nch; i++) {
        AnimDctChannel& ac = h->ch[i];
        ac.rows = (uint8_t)(flags[i] >> 4);
        if (p + 8 + (size_t)ac.rows * 2 > n) { delete h; bf6_free(c, r); return nullptr; }
        for (int k = 0; k < 4; k++) {
            int16_t v; std::memcpy(&v, b + p + (size_t)k*2, 2); ac.base[k] = v;
        }
        p += 8;
        ac.width.resize(ac.rows);
        for (uint32_t k = 0; k < ac.rows; k++) { ac.width[k] = q16(p); p += 2; }
    }
    h->bits_off = p;
    /* THE STREAM ENDS AT REGION 1'S END, NOT AT EOF.
     *
     * region1.count is the body size in bytes, and the payload carries a small
     * relocation tail after it - 10 and 16 bytes on two sampled files, so it is
     * not even a constant to subtract. Measuring the stream as "everything left
     * in the file" silently overstates it by that tail, which breaks the one
     * check that validates the whole width model. */
    const uint64_t body_end = (uint64_t)r->regions[1].offset + r->regions[1].count;
    h->bits_len = (body_end > (uint64_t)p && body_end <= (uint64_t)n)
                ? (size_t)(body_end - (uint64_t)p)
                : (n - p);

    /* Resolve 0xF to the header default BEFORE totalling, or the size identity
     * is computed from nibbles the decoder will not actually use. */
    auto lane = [&](uint16_t w, int l) -> uint32_t {
        const uint32_t nib = (w >> (12 - 4*l)) & 0xFu;
        return (nib == 0xFu) ? (uint32_t)h->coef_bit_width : nib;
    };
    for (uint32_t i = 0; i < nch; i++) {
        const AnimDctChannel& ac = h->ch[i];
        for (uint32_t k = 0; k < ac.rows; k++) {
            uint32_t s = 0;
            for (int l = 0; l < 4; l++) s += lane(ac.width[k], l);
            h->full_block_bits += s;
            if (k == 0) h->first_coef_bits += s;    /* row 0 of every non-empty descriptor */
        }
    }

    h->c.key_time_count = keyTimes;
    h->c.quat_count     = nq;
    h->c.vec3_count     = nv;
    h->c.group_count    = ng;
    h->c.channel_count  = (int32_t)nch;
    h->c.block_count    = (int32_t)(((uint32_t)keyTimes + 7u) / 8u);
    h->c.sparse_times   = h->key_times.empty() ? nullptr : h->key_times.data();
    h->c.sparse_time_count = (int32_t)h->key_times.size();
    h->c.full_block_bits = (int32_t)h->full_block_bits;
    h->c.first_coefficient_bits = (int32_t)h->first_coef_bits;

    /* The serializer's exact bound - a reader checking its own width model. */
    const uint64_t used = (uint64_t)h->c.block_count * h->full_block_bits
                        - (uint64_t)h->first_coef_bits;
    const uint64_t ub   = (used + 7ull) / 8ull;
    const uint64_t a16  = ((ub ? ub : 1ull) + 15ull) & ~15ull;
    h->c.predicted_stream_bytes = (int64_t)(a16 + 16ull);
    h->c.actual_stream_bytes    = (int64_t)h->bits_len;

    bf6_free(c, r);
    c->handles[&h->c] = bf6_ctx::HK_ANIMCLIP;
    return &h->c;
}

int bf6_anim_clip_sample(bf6_ctx* c, bf6_anim_clip* clip, int ordinal, float* out,
                         float* out_quat_magnitude)
{
    if (!c || !clip || !out || ordinal < 0) return 0;
    AnimClipHandle* h = (AnimClipHandle*)clip;
    const uint32_t block = (uint32_t)ordinal >> 3;
    const uint32_t phase = (uint32_t)ordinal & 7u;
    if ((int32_t)block >= clip->block_count) return 0;

    const uint8_t* bits = h->bytes.data() + h->bits_off;
    auto lane = [&](uint16_t w, int l) -> int {
        const uint32_t nib = (w >> (12 - 4*l)) & 0xFu;
        return (nib == 0xFu) ? (int)h->coef_bit_width : (int)nib;
    };

    /* Block zero OMITS coefficient row zero - the descriptor base supplies it -
     * so every later block's offset is short by exactly that one row. */
    uint64_t pos = (block == 0)
                 ? 0ull
                 : (uint64_t)block * h->full_block_bits - (uint64_t)h->first_coef_bits;

    const float t  = (float)h->sub_quant_tenths * 0.1f;
    const float bq = h->block_quant ? (float)h->block_quant : 1.0f;
    float basis[8];
    basis[0] = 0.25f;
    for (int k = 1; k < 8; k++)
        basis[k] = 0.5f * (float)std::cos((2.0 * (double)phase + 1.0) * (double)k
                                          * 3.14159265358979323846 / 16.0);

    for (size_t i = 0; i < h->ch.size(); i++) {
        const AnimDctChannel& ac = h->ch[i];
        int16_t coef[8][4];
        std::memset(coef, 0, sizeof(coef));
        const uint32_t start = (block == 0) ? 1u : 0u;
        for (uint32_t k = start; k < ac.rows; k++)
            for (int l = 0; l < 4; l++)
                coef[k][l] = (int16_t)bf6__rdbits(bits, h->bits_len, pos, lane(ac.width[k], l));
        /* Unchecked int16 wrap, exactly as the engine does it. */
        for (int l = 0; l < 4; l++)
            coef[0][l] = (int16_t)((int32_t)coef[0][l] + (int32_t)ac.base[l]);

        float v[4] = {0.0f, 0.0f, 0.0f, 0.0f};
        for (int k = 0; k < 8; k++) {
            const float qs = (1.0f + (float)k * t) / bq;
            for (int l = 0; l < 4; l++) v[l] += (float)coef[k][l] * qs * basis[k];
        }
        /* Quaternion channels normalise; vector channels do NOT. */
        if (i < (size_t)clip->quat_count) {
            const float d2 = v[0]*v[0] + v[1]*v[1] + v[2]*v[2] + v[3]*v[3];
            /* The PRE-normalisation magnitude is the decode-health signal, and
             * it is the only quaternion check that can fail. The encoder stored
             * a unit quaternion and quantised it, so a correct unpack arrives
             * near 1 before normalising; a wrong-but-consistent bit unpack
             * arrives anywhere. Normalising first and then checking the result
             * is unit is vacuous - it is unit by construction. */
            if (out_quat_magnitude) out_quat_magnitude[i] = std::sqrt(d2);
            if (d2 > 1e-20f) {
                const float s = 1.0f / std::sqrt(d2);
                v[0] *= s; v[1] *= s; v[2] *= s; v[3] *= s;
            }
        }
        std::memcpy(out + i*4, v, sizeof(v));
    }
    return 1;
}

void bf6__animclip_delete(void* p) { delete (AnimClipHandle*)p; }

/* ------------------------------------------------------- sampling by time - */

/* The DCT decoder takes a SAMPLE ORDINAL. Region 0 is what converts a playback
 * time into the surrounding ordinals and the fraction between them:
 *   - empty region 0 means times are implicit and DENSE - every integer from 0
 *     to the owning frame count inclusive, so the ordinal IS the time;
 *   - a non-empty region 0 is a sparse, strictly increasing key-time table, and
 *     two adjacent ordinals can be several frames apart.
 *
 * That distinction matters beyond convenience: on a sparse clip a large change
 * between adjacent ORDINALS is correct rather than a decode fault, because they
 * are not adjacent in TIME.
 */
static void bf6__clip_bracket(const bf6_anim_clip* c, float time, int loop,
                              int* lo, int* hi, float* frac)
{
    const int last = c->key_time_count > 0 ? c->key_time_count - 1 : 0;
    if (c->sparse_times && c->sparse_time_count > 1) {
        /* Sparse: find the bracketing pair by key TIME. */
        const int n = c->sparse_time_count;
        const float t0 = (float)c->sparse_times[0];
        const float tN = (float)c->sparse_times[n - 1];
        float t = time;
        if (loop && tN > t0) {
            const float period = tN - t0;
            t = t0 + std::fmod(std::fmod(t - t0, period) + period, period);
        }
        if (t <= t0)  { *lo = 0;     *hi = 0;     *frac = 0.0f; return; }
        if (t >= tN)  { *lo = n - 1; *hi = n - 1; *frac = 0.0f; return; }
        int a = 0, b = n - 1;
        while (b - a > 1) { const int m = (a + b) / 2;
                            if ((float)c->sparse_times[m] <= t) a = m; else b = m; }
        const float ta = (float)c->sparse_times[a], tb = (float)c->sparse_times[b];
        *lo = a; *hi = b;
        *frac = (tb > ta) ? (t - ta) / (tb - ta) : 0.0f;
        return;
    }
    /* Dense: the ordinal is the time. */
    float t = time;
    if (loop && last > 0) {
        const float period = (float)(last + 1);
        t = std::fmod(std::fmod(t, period) + period, period);
        const int l = (int)std::floor(t);
        *lo = l;
        *hi = (l + 1) % (last + 1);
        *frac = t - (float)l;
        return;
    }
    if (t <= 0.0f)          { *lo = 0;    *hi = 0;    *frac = 0.0f; return; }
    if (t >= (float)last)   { *lo = last; *hi = last; *frac = 0.0f; return; }
    const int l = (int)std::floor(t);
    *lo = l; *hi = l + 1; *frac = t - (float)l;
}

int bf6_anim_clip_sample_time(bf6_ctx* c, bf6_anim_clip* clip, float time, int loop,
                              float* out)
{
    if (!c || !clip || !out) return 0;
    int lo = 0, hi = 0; float f = 0.0f;
    bf6__clip_bracket(clip, time, loop, &lo, &hi, &f);

    if (!bf6_anim_clip_sample(c, clip, lo, out, nullptr)) return 0;
    if (hi == lo || f <= 0.0f) return 1;

    std::vector<float> b((size_t)clip->channel_count * 4);
    if (!bf6_anim_clip_sample(c, clip, hi, b.data(), nullptr)) return 1;

    for (int i = 0; i < clip->channel_count; i++) {
        float* A = out + (size_t)i * 4;
        const float* B = &b[(size_t)i * 4];
        if (i < clip->quat_count) {
            /* Shortest arc, then renormalise. NOTE: the format spec records
             * THAT the engine interpolates, not WHICH interpolation it uses, so
             * this is nlerp with a sign fix rather than a reproduction of the
             * engine's arithmetic. It is correct to within the usual nlerp/slerp
             * difference and is flagged so nobody reads it as measured. */
            float d = A[0]*B[0] + A[1]*B[1] + A[2]*B[2] + A[3]*B[3];
            const float s = (d < 0.0f) ? -1.0f : 1.0f;
            float q[4];
            for (int k = 0; k < 4; k++) q[k] = A[k] + f * (s * B[k] - A[k]);
            const float m2 = q[0]*q[0] + q[1]*q[1] + q[2]*q[2] + q[3]*q[3];
            if (m2 > 1e-20f) { const float r = 1.0f / std::sqrt(m2);
                               for (int k = 0; k < 4; k++) A[k] = q[k] * r; }
        } else {
            for (int k = 0; k < 4; k++) A[k] = A[k] + f * (B[k] - A[k]);
        }
    }
    return 1;
}
