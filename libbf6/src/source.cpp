#include "source.h"

#include <cstdio>

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

}  // namespace bf6
