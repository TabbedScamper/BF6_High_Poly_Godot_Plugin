/* rime_ext.inc - read the game's UI element tree out of the install.
 *
 * A translation-unit fragment like raw_ext.inc; wire it beside the others.
 *
 * WHY THIS DOES NOT USE THE REFLECTION. Every other reader in this library
 * goes through TypeDb, because the executable's schema is the authority. For
 * Rime it is not: the shipped UI partitions carry an OLDER revision of these
 * types than the exe does. 101 of 1,358 signed types disagree - exactly the
 * Rime element family - while the other 1,257 match byte for byte. Reading a
 * Rime element through the exe's field offsets returns plausible garbage with
 * no error, which is the worst possible failure.
 *
 * So the container is parsed normally (Ebx gives instance offsets and the
 * payload) and the element fields are read at the SHIPPED offsets, recovered
 * from the data itself and cross-checked against the BF6SDK type database:
 *
 *     176  Name                 CString
 *     184  VerticalLayout       6 floats
 *     208  HorizontalLayout     6 floats
 *     296  InstanceNameHash     u32   (djb2-xor of the lowercased Name)
 *     300  Height               float
 *     308  Alpha                float
 *     312  Width                float
 *     316  Visible              u8
 *     317  FitHeightToContent   u8
 *     318  FitWidthToContent    u8
 *     320  Elements             array
 *
 * NOTE THE AXIS ORDER: Vertical comes BEFORE Horizontal. Reading them in
 * declaration order transposes every box on screen, and the result still looks
 * like a plausible layout, which is how it went unnoticed. A name-semantics
 * oracle (an element called *Top must land in the top half of its parent)
 * scores 95.0% with this order and 65.9% with the axes swapped.
 *
 * Widget references are a different type and are NOT swapped: Name at 376,
 * Horizontal at 384, Vertical at 408. Two revisions of it ship (0x4FECC2B2,
 * 1,059 uses, and 0xB2D8C868, 62 uses); both agree on Name@376, so the gate
 * accepts either rather than rejecting the rarer one.
 */

static const uint32_t kRimeNameOff      = 176;
static const uint32_t kRimeVLayoutOff   = 184;
static const uint32_t kRimeHLayoutOff   = 208;
static const uint32_t kRimeNameHashOff  = 296;
static const uint32_t kRimeHeightOff    = 300;
static const uint32_t kRimeAlphaOff     = 308;
static const uint32_t kRimeWidthOff     = 312;
static const uint32_t kRimeVisibleOff   = 316;
static const uint32_t kRimeFitHOff      = 317;
static const uint32_t kRimeFitWOff      = 318;

static const uint32_t kRimeRefNameOff   = 376;
static const uint32_t kRimeRefHOff      = 384;
static const uint32_t kRimeRefVOff      = 408;

namespace {

/* Not a template: this fragment is compiled inside extern "C". */
bool bf6__rime_read(const std::vector<uint8_t>& d, size_t off, void* dst, size_t n)
{
    if (off + n > d.size()) return false;
    std::memcpy(dst, d.data() + off, n);
    return true;
}
bool bf6__rime_f32(const std::vector<uint8_t>& d, size_t off, float& out)
{ return bf6__rime_read(d, off, &out, 4); }
bool bf6__rime_u32(const std::vector<uint8_t>& d, size_t off, uint32_t& out)
{ return bf6__rime_read(d, off, &out, 4); }
bool bf6__rime_u8(const std::vector<uint8_t>& d, size_t off, uint8_t& out)
{ return bf6__rime_read(d, off, &out, 1); }

/* A shipped element name carries trailing padding spaces; a caller comparing
 * it against a reference would never match without this. */
std::string bf6__rime_trim(std::string s)
{
    while (!s.empty() && (s.back() == ' ' || s.back() == '\0')) s.pop_back();
    return s;
}

/* CString in this payload is a 4-byte offset into the partition's own string
 * region. Zero means absent, which is a real state - plenty of elements are
 * unnamed - so it is reported as an empty name rather than as a failure. */
std::string bf6__rime_cstr(const std::vector<uint8_t>& d, size_t off, size_t payload)
{
    uint32_t rel = 0;
    if (!bf6__rime_u32(d, off, rel) || rel == 0) return std::string();
    /* The offset is relative to the payload, like every other pointer here. */
    const size_t abs = payload + rel;
    if (abs >= d.size()) return std::string();
    const char* p = (const char*)d.data() + abs;
    rel = (uint32_t)abs;
    size_t n = 0;
    while (rel + n < d.size() && p[n]) n++;
    return bf6__rime_trim(std::string(p, n));
}

void bf6__rime_axis(const std::vector<uint8_t>& d, size_t off, bf6_rime_axis& a)
{
    float v[6] = { 0, 0, 0, 0, 0, 0 };
    for (int i = 0; i < 6; i++) bf6__rime_f32(d, off + (size_t)i * 4, v[i]);
    /* FIELD ORDER INSIDE A LAYOUT, established from the data rather than
     * assumed. Reading the six floats in the obvious
     * (start, end, offset, offset, pivot, weight) order does not reproduce a
     * single authored box. This order does, on both axes of the same element:
     *
     *   BP_GreebleLine  h -> anchor 0..0, offset 16..-16
     *                   v -> anchor 0..1, offset 88..398
     *
     * Slot 1 is not yet identified and is carried as `weight` rather than
     * being dropped, so nothing is silently discarded. */
    a.anchor_start = v[0];
    a.anchor_end   = v[4];
    a.offset_start = v[5];
    a.offset_end   = v[3];
    a.pivot        = v[2];
    a.weight       = v[1];   /* unidentified; kept, not discarded */
}

}  // namespace

int bf6_rime_elements(bf6_ctx* c, const char* partition,
                      bf6_rime_element* out, int out_max)
{
    if (!c || !partition) return -1;

    std::string terr;
    if (!ensure_types(c, terr)) return -1;      /* container parse still needs it */

    std::string err;
    std::vector<uint8_t> raw = c->src.get_ebx(std::string(partition) + ".ebx", err);
    if (raw.empty()) raw = c->src.get_ebx(partition, err);
    if (raw.empty()) return -1;

    bf6::Ebx e(*c->types);
    /* parse() consumes the buffer, so keep our own copy for the raw reads -
     * the whole point here is to bypass the schema, not to re-derive it. */
    std::vector<uint8_t> keep = raw;
    if (!e.parse(std::move(raw), err)) return -1;

    const std::vector<uint8_t>& d = e.raw().empty() ? keep : e.raw();

    c->rime_names.clear();
    c->rime_names.reserve(e.instance_count());

    int n = 0;
    for (size_t i = 0; i < e.instance_count(); i++)
    {
        /* Instance offsets are PAYLOAD-relative; the buffer is the whole
         * file. Indexing one by the other lands in the header and produces
         * short plausible-looking strings ("FFD") rather than an error. */
        const size_t base = (size_t)e.payload() + (size_t)e.instance_offset(i);

        /* Try the element layout first, then the widget-reference layout. An
         * instance that yields a name under neither is not an element - screen
         * partitions carry plenty of other instances - and is skipped. */
        std::string nm = bf6__rime_cstr(d, base + kRimeNameOff, (size_t)e.payload());
        bool is_ref = false;
        if (nm.empty())
        {
            nm = bf6__rime_cstr(d, base + kRimeRefNameOff, (size_t)e.payload());
            if (!nm.empty()) is_ref = true;
        }
        if (nm.empty()) continue;

        c->rime_names.push_back(nm);
        if (out && n < out_max)
        {
            bf6_rime_element& o = out[n];
            o = bf6_rime_element{};
            o.name = c->rime_names.back().c_str();
            o.is_widget_ref = is_ref ? 1 : 0;

            if (is_ref)
            {
                bf6__rime_axis(d, base + kRimeRefHOff, o.h);
                bf6__rime_axis(d, base + kRimeRefVOff, o.v);
                o.visible = 1;
            }
            else
            {
                /* Vertical BEFORE horizontal - see the note at the top. */
                bf6__rime_axis(d, base + kRimeVLayoutOff, o.v);
                bf6__rime_axis(d, base + kRimeHLayoutOff, o.h);
                bf6__rime_u32(d, base + kRimeNameHashOff, o.name_hash);
                bf6__rime_f32(d, base + kRimeHeightOff,   o.height);
                bf6__rime_f32(d, base + kRimeWidthOff,    o.width);
                bf6__rime_f32(d, base + kRimeAlphaOff,    o.alpha);
                uint8_t b = 0;
                if (bf6__rime_u8(d, base + kRimeVisibleOff, b)) o.visible = b ? 1 : 0;
                if (bf6__rime_u8(d, base + kRimeFitHOff,   b)) o.fit_h   = b ? 1 : 0;
                if (bf6__rime_u8(d, base + kRimeFitWOff,   b)) o.fit_w   = b ? 1 : 0;
            }
            o.instance = (int32_t)i;
        }
        n++;
    }

    /* Re-point after the backing vector has stopped growing, or every name but
     * the last dangles and prints convincing rubbish. */
    if (out)
    {
        const int lim = n < out_max ? n : out_max;
        for (int i = 0; i < lim && i < (int)c->rime_names.size(); i++)
            out[i].name = c->rime_names[(size_t)i].c_str();
    }
    return n;
}
