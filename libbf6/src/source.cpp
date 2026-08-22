#include "source.h"

#include <algorithm>
#include <cstdio>
#include <cstring>
#include <filesystem>

#include "bundle.h"
#include "cas.h"
#include "oodle.h"

namespace bf6 {

static std::vector<uint8_t> read_file(const std::string& path) {
    std::vector<uint8_t> out;
    FILE* f = std::fopen(path.c_str(), "rb");
    if (!f) return out;
    std::fseek(f, 0, SEEK_END);
    long n = std::ftell(f);
    std::fseek(f, 0, SEEK_SET);
    if (n > 0) { out.resize((size_t)n); out.resize(std::fread(out.data(), 1, (size_t)n, f)); }
    std::fclose(f);
    return out;
}

bool Source::open(const std::string& game_dir, std::string& err) {
    game_ = game_dir;
    // The decompressor must be loaded before any CAS read - without it every
    // block decode silently returns empty.
    if (!oodle_open(game_dir)) { err = oodle_error(); return false; }
    return loc_.open(game_dir, err);
}

std::vector<uint8_t> Source::read_seg(const CasLoc& seg, bool allow_raw, std::string& err) {
    std::string path = loc_.cas_path(seg.chunk_id, seg.cas_ix);
    if (path.empty()) {
        err = "no cas file for install chunk";
        return std::vector<uint8_t>();
    }
    return cas_read(path, seg.off, seg.size, allow_raw, err);
}

bool Source::mount_toc(const std::string& toc_path, std::string& err) {
    std::vector<uint8_t> raw = read_file(toc_path);
    if (raw.empty()) { err = "cannot read " + toc_path; return false; }

    Toc toc;
    if (!toc.parse(raw.data(), raw.size(), err)) return false;

    // Loose-chunk map, resolved while the toc body is resident.
    for (const TocChunk& c : toc.chunks) {
        if (!chunks_.count(c.guid)) chunks_[c.guid] = toc.chunk_location(c);
    }

    const std::vector<uint8_t>& body = toc.body();
    for (const TocBundle& b : toc.bundles) {
        std::string e2;
        std::vector<CasLoc> segs = read_segments(body.data(), body.size(),
                                                 (size_t)b.offset, e2);
        if (segs.empty()) continue;
        std::vector<uint8_t> meta = read_seg(segs[0], true, e2);
        if (meta.empty()) continue;
        Payload pay;
        if (!pay.parse(meta.data(), meta.size(), e2)) continue;

        // Positional: entry i of ebx-then-res is segment i+1 (segment 0 is meta).
        size_t si = 1;
        size_t nseg = segs.size();
        for (const auto& e : pay.ebx) {
            if (si < nseg && !ebx_.count(e.first)) {
                EbxEntry ee; ee.loc = segs[si]; ee.dsize = e.second;
                ebx_[e.first] = ee;
            }
            si++;
        }
        for (const PayloadRes& r : pay.res) {
            if (si < nseg && !res_.count(r.name)) {
                ResEntry re; re.loc = segs[si]; re.dsize = r.size;
                re.type = r.type; re.rid = r.rid;
                res_[r.name] = re;
            }
            si++;
        }
        // Bundle chunks come after res, and mesh vertex data lives in one.
        for (const std::string& cid : pay.chunk_id) {
            if (si < nseg && !chunk_seg_.count(cid)) chunk_seg_[cid] = segs[si];
            si++;
        }
    }
    return true;
}

std::vector<uint8_t> Source::get_chunk(const std::string& guid_hex, std::string& err) {
    std::string g = guid_hex;
    for (char& ch : g) if (ch >= 'A' && ch <= 'Z') ch += 32;   // lower
    auto it = chunks_.find(g);
    if (it != chunks_.end()) return read_seg(it->second, false, err);
    auto it2 = chunk_seg_.find(g);
    if (it2 != chunk_seg_.end()) return read_seg(it2->second, false, err);
    err = "chunk " + g.substr(0, 16) + " is in no chunk map";
    return std::vector<uint8_t>();
}

std::vector<uint8_t> Source::get_res(const std::string& name, std::string& err) {
    auto it = res_.find(name);
    if (it == res_.end()) { err = "no res named " + name; return std::vector<uint8_t>(); }
    std::vector<uint8_t> d = read_seg(it->second.loc, false, err);
    if (d.size() != it->second.dsize) {
        char m[96];
        std::snprintf(m, sizeof(m), "res declared %u bytes, got %zu",
                      it->second.dsize, d.size());
        err = m;
        return std::vector<uint8_t>();
    }
    return d;
}

std::vector<uint8_t> Source::get_ebx(const std::string& name, std::string& err) {
    auto it = ebx_.find(name);
    if (it == ebx_.end()) { err = "no ebx named " + name; return std::vector<uint8_t>(); }
    std::vector<uint8_t> d = read_seg(it->second.loc, false, err);
    if (d.size() != it->second.dsize) { err = "ebx size mismatch"; return std::vector<uint8_t>(); }
    return d;
}

// ---------------------------------------------------------------------------
// Partition index
// ---------------------------------------------------------------------------

// A partition's own GUID, out of its EFIX fixup.
//
// Deliberately NOT done by handing the bytes to the deserializer: this is a
// header read of every partition in the mount, and the guid sits in a known
// place. The formatting MUST match the one the EBX reader produces, because
// this index is looked up with the keys that reader hands out: .NET mixed
// endian, first three groups little-endian and the last eight bytes as they lie.
static std::string efix_guid(const std::vector<uint8_t>& raw)
{
    if (raw.size() < 12 || std::memcmp(raw.data(), "RIFF", 4) != 0) return std::string();
    size_t o = 12;
    while (o + 8 <= raw.size())
    {
        uint32_t sz = 0;
        std::memcpy(&sz, raw.data() + o + 4, 4);
        if (std::memcmp(raw.data() + o, "EFIX", 4) == 0)
        {
            const size_t s = o + 8;
            if (s + 16 > raw.size()) return std::string();
            char buf[40];
            const uint8_t* g = raw.data() + s;
            std::snprintf(buf, sizeof(buf),
                "%08x-%04x-%04x-%02x%02x-%02x%02x%02x%02x%02x%02x",
                (unsigned)(g[0] | (g[1] << 8) | (g[2] << 16) | ((unsigned)g[3] << 24)),
                (unsigned)(g[4] | (g[5] << 8)), (unsigned)(g[6] | (g[7] << 8)),
                g[8], g[9], g[10], g[11], g[12], g[13], g[14], g[15]);
            return buf;
        }
        o += 8 + (size_t)sz;
        if (o % 2 == 1) o++;
    }
    return std::string();
}

const std::map<std::string, std::string>& Source::partition_index()
{
    if (pidx_built_) return pidx_;
    pidx_built_ = true;

    // CAS LOCALITY ORDER, not name order. Every partition in the mount is read
    // to get one 16-byte header, so the reads want to run down each archive in
    // the order the blocks lie rather than jumping the disk per name.
    std::vector<const std::pair<const std::string, EbxEntry>*> order;
    order.reserve(ebx_.size());
    for (const auto& kv : ebx_) order.push_back(&kv);
    std::sort(order.begin(), order.end(),
        [](const std::pair<const std::string, EbxEntry>* a,
           const std::pair<const std::string, EbxEntry>* b)
        {
            if (a->second.loc.chunk_id != b->second.loc.chunk_id)
                return a->second.loc.chunk_id < b->second.loc.chunk_id;
            if (a->second.loc.cas_ix != b->second.loc.cas_ix)
                return a->second.loc.cas_ix < b->second.loc.cas_ix;
            if (a->second.loc.off != b->second.loc.off)
                return a->second.loc.off < b->second.loc.off;
            // SAME BYTES UNDER TWO NAMES. An asset shipped at two paths shares
            // one partition guid, so "first name wins" is decided by whatever
            // order the sort happened to leave them in - which is not an order
            // at all when the locations are equal. Broken by name so this index
            // is at least the same on every run. Note the Godot plugin has no
            // such tie-break, so its pick depends on dictionary order and the
            // two readers can legitimately name the same partition differently.
            return a->first < b->first;
        });

    std::string err;
    for (const auto* kv : order)
    {
        std::vector<uint8_t> bytes = get_ebx(kv->first, err);
        if (bytes.empty()) continue;
        const std::string g = efix_guid(bytes);
        // First name wins, so the result is stable across runs.
        if (!g.empty()) pidx_.emplace(g, kv->first + ".ebx");
    }
    return pidx_;
}

// ---------------------------------------------------------------------------
// Finding and mounting a level's archives
// ---------------------------------------------------------------------------

namespace {

std::string lower_slash(const std::string& s)
{
    std::string o = s;
    for (char& c : o)
    {
        if (c == '\\') c = '/';
        else c = (char)std::tolower((unsigned char)c);
    }
    return o;
}

// The SDK names a scene by display name while the game files the level under an
// mp_ id (Portal_Sand -> levels/mp_portal_sand), so both spellings match.
std::vector<std::string> level_dirs(const std::string& level)
{
    std::string l = lower_slash(level);
    std::vector<std::string> out{ "/levels/" + l + "/" };
    if (l.rfind("mp_", 0) != 0) out.push_back("/levels/mp_" + l + "/");
    return out;
}

bool in_level_dir(const std::string& path, const std::vector<std::string>& dirs)
{
    const std::string p = lower_slash(path);
    for (const std::string& d : dirs)
        if (p.find(d) != std::string::npos) return true;
    return false;
}

}  // namespace

bool Source::is_level_toc(const std::string& path)
{
    return lower_slash(path).find("/levels/") != std::string::npos;
}

std::string Source::mount_key(const std::string& path)
{
    const std::string low = lower_slash(path);
    return (low.find("/update/") != std::string::npos ? "1" : "0") + low;
}

std::vector<std::string> Source::available_levels() const
{
    namespace fs = std::filesystem;
    std::vector<std::string> out;
    std::error_code ec;
    for (fs::recursive_directory_iterator it(game_, fs::directory_options::skip_permission_denied, ec), end;
         it != end; it.increment(ec))
    {
        if (ec) { ec.clear(); continue; }
        if (!it->is_directory(ec)) continue;
        const std::string here = lower_slash(it->path().string());
        if (here.size() >= 7 && here.compare(here.size() - 7, 7, "/levels") == 0)
        {
            std::error_code e2;
            for (const auto& sub : fs::directory_iterator(it->path(), e2))
                if (sub.is_directory(e2)) out.push_back(lower_slash(sub.path().filename().string()));
            it.disable_recursion_pending();   // the level dirs need no descent
        }
    }
    std::sort(out.begin(), out.end());
    out.erase(std::unique(out.begin(), out.end()), out.end());
    return out;
}

// THE ORDER IS THE CORRECTNESS, not a tidy-up. Mounting is FIRST WINS: the
// sweep keeps the first entry it sees for a name and skips the rest.
//
// Shared archives therefore go first, so a level cannot displace a global it
// depends on. Among LEVELS the same rule reads backwards from how it sounds:
// the level being read has to come FIRST, or every other level outranks it for
// any name they share, and levels share names freely - the shader-state depots,
// the terrain resources, the section keys. Sorted purely by path, mp_dumbo
// lands wherever the alphabet puts it and the level you are reading resolves
// against another level's data.
//
// So: shared archives, then this level, then everything else purely to make its
// objects reachable.
std::vector<std::string> Source::find_tocs(const std::string& level, bool all_levels) const
{
    namespace fs = std::filesystem;
    std::vector<std::string> shared, lvl;
    const std::vector<std::string> want = level_dirs(level);

    std::error_code ec;
    for (fs::recursive_directory_iterator it(game_, fs::directory_options::skip_permission_denied, ec), end;
         it != end; it.increment(ec))
    {
        if (ec) { ec.clear(); continue; }
        if (!it->is_regular_file(ec)) continue;
        const std::string p = it->path().string();
        if (p.size() < 4 || lower_slash(p).compare(p.size() - 4, 4, ".toc") != 0) continue;
        if (is_level_toc(p))
        {
            if (all_levels || (!level.empty() && in_level_dir(p, want))) lvl.push_back(p);
        }
        else shared.push_back(p);
    }

    auto by_key = [](const std::string& a, const std::string& b)
    { return mount_key(a) < mount_key(b); };
    std::sort(shared.begin(), shared.end(), by_key);
    std::sort(lvl.begin(), lvl.end(), by_key);

    if (all_levels && !level.empty())
    {
        std::vector<std::string> mine, others;
        for (const std::string& p : lvl)
            (in_level_dir(p, want) ? mine : others).push_back(p);
        lvl = mine;
        lvl.insert(lvl.end(), others.begin(), others.end());
    }

    std::vector<std::string> out = shared;
    out.insert(out.end(), lvl.begin(), lvl.end());
    return out;
}

bool Source::mount_level(const std::string& level, bool all_levels, std::string& err)
{
    const std::vector<std::string> tocs = find_tocs(level, all_levels);
    if (tocs.empty()) { err = "no .toc found under " + game_; return false; }
    size_t mounted = 0;
    for (const std::string& t : tocs)
    {
        std::string e;
        if (mount_toc(t, e)) mounted++;
        // A toc that will not mount is not fatal on its own: the install
        // carries archives this reader has no business in. An empty mount is.
    }
    if (mounted == 0) { err = "no .toc mounted"; return false; }
    if (!level.empty())
    {
        bool any_level_toc = false;
        for (const std::string& t : tocs)
            if (is_level_toc(t) && in_level_dir(t, level_dirs(level))) { any_level_toc = true; break; }
        if (!any_level_toc)
        {
            err = "no archives for level '" + level + "'";
            return false;
        }
    }
    return true;
}

}  // namespace bf6
