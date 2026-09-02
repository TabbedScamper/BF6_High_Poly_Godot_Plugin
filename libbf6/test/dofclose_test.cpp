/* dofclose_test - RECURSIVE closure of a DOF-set list, summed in ONE mount.
 *
 * WHY THIS SUPERSEDES dofset_test's WALK. The first attempt summed only the
 * .ds sets a DSL imports DIRECTLY, and a clip both undershot and overshot that
 * total - which pointed at the walk, not the hypothesis. These DSLs also import
 * SUB-DSLs (arms, lowerbody, ik.feet, camera) and those nest further
 * (arms.dsl -> leftarm.dsl), so a direct-only walk cannot see every set.
 *
 * A per-process walk is not an option: each invocation re-mounts the game, and
 * the cold start dominates. So the closure runs inside a single mount here.
 *
 * NOTE the dedupe. A set reachable by two paths must be counted ONCE, and the
 * pairs in these lists (torso.ds AND torso.dsl side by side) make double
 * counting the obvious way to manufacture a false match.
 */
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>
#include <set>
#include <map>
#include "bf6_core.h"

static bf6_ctx* g_ctx = 0;
static std::vector<char> g_buf;

static std::string dump_of(const std::string& asset, int depth) {
    const int64_t n = bf6_ebx_dump(g_ctx, asset.c_str(), depth, g_buf.data(), (int)g_buf.size());
    if (n <= 0) return std::string();
    return std::string(g_buf.data());
}

/* every "import <path>.(ds|dsl).ebx" in a dump, as bare asset paths */
static std::vector<std::string> imports_of(const std::string& d) {
    std::vector<std::string> out;
    size_t p = 0;
    while ((p = d.find("import ", p)) != std::string::npos) {
        p += 7;
        size_t e = p;
        while (e < d.size() && d[e] != '\n' && d[e] != '\r' && d[e] != ' ') e++;
        std::string s = d.substr(p, e - p);
        if (s.size() > 4 && s.compare(s.size() - 4, 4, ".ebx") == 0) {
            s.erase(s.size() - 4);
            if ((s.size() > 3 && s.compare(s.size()-3,3,".ds") == 0) ||
                (s.size() > 4 && s.compare(s.size()-4,4,".dsl") == 0))
                out.push_back(s);
        }
        p = e;
    }
    return out;
}

static bool ends(const std::string& s, const char* suf) {
    size_t n = strlen(suf);
    return s.size() > n && s.compare(s.size()-n, n, suf) == 0;
}

/* BFS over .dsl nodes, collecting unique .ds leaves */
static void closure(const std::string& root, std::set<std::string>& ds, std::set<std::string>& dsl) {
    std::vector<std::string> q; q.push_back(root);
    while (!q.empty()) {
        std::string cur = q.back(); q.pop_back();
        if (dsl.count(cur)) continue;
        dsl.insert(cur);
        std::string d = dump_of(cur, 4);
        if (d.empty()) { std::printf("  !! dump failed: %s\n", cur.c_str()); continue; }
        for (auto& i : imports_of(d)) {
            if (ends(i, ".dsl")) { if (!dsl.count(i)) q.push_back(i); }
            else ds.insert(i);
        }
    }
}

static std::vector<long long> field_ints(const std::string& dump, const char* fieldhex) {
    std::vector<long long> out;
    size_t p = dump.find(fieldhex);
    if (p == std::string::npos) return out;
    size_t line = dump.find('\n', p);
    if (line == std::string::npos) return out;
    size_t qq = line + 1;
    while (qq < dump.size()) {
        size_t e = dump.find('\n', qq);
        if (e == std::string::npos) e = dump.size();
        std::string s = dump.substr(qq, e - qq);
        size_t c = s.find(':');
        if (c == std::string::npos) break;
        const char* t = s.c_str() + c + 1;
        while (*t == ' ') t++;
        if (!(*t == '-' || (*t >= '0' && *t <= '9'))) break;
        out.push_back(atoll(t));
        qq = e + 1;
    }
    return out;
}

int main(int argc, char** argv) {
    if (argc < 3) { std::printf("usage: dofclose_test <game> <root.dsl> [clip...]\n"); return 2; }
    char err[256] = {0};
    g_ctx = bf6_open(argv[1], err, sizeof(err));
    if (!g_ctx) { std::printf("open: %s\n", err); return 1; }
    if (!bf6_mount_all(g_ctx, 1, err, sizeof(err))) { std::printf("mount: %s\n", err); return 1; }
    g_buf.resize(64u << 20);

    std::set<std::string> ds, dsl;
    closure(argv[2], ds, dsl);
    std::printf("ROOT %s\n  dsl nodes expanded: %zu\n  unique .ds sets:    %zu\n\n",
                argv[2], dsl.size(), ds.size());

    std::map<std::pair<long long,long long>, long long> tally;
    long long grand = 0; long long dof_sum = 0;
    for (auto& a : ds) {
        std::string d = dump_of(a, 6);
        if (d.empty()) { std::printf("  %-30s DUMP FAILED\n", a.c_str()); continue; }
        std::vector<long long> v = field_ints(d, "0xf71b7fd3");
        if (v.empty()) v = field_ints(d, "0xF71B7FD3");
        const size_t recs = v.size() / 8;
        for (size_t r = 0; r < recs; r++) tally[{v[r*8], v[r*8+1]}]++;
        size_t sl = a.rfind('/');
        const long long hdr_n = v.size() > 4 ? v[1] : -1;
        const long long hdr_sz = v.size() > 4 ? v[2] : -1;
        dof_sum += hdr_n > 0 ? hdr_n : 0;
        const bool ok1 = (hdr_sz == 16 + 16*hdr_n);
        std::printf("  DS %-52s dofs=%-4lld recs=%-4zu hdr2=%-5lld %s\n",
                    a.c_str(), hdr_n, recs, hdr_sz, ok1 ? "" : "<<HDR MISMATCH"); (void)sl;
        grand += (long long)recs;
    }

    long long q = 0, v3 = 0, sc = 0, other = 0;
    for (auto& kv : tally) {
        if (kv.first.second == 16) q += kv.second;
        else if (kv.first.second == 12) v3 += kv.second;
        else if (kv.first.second == 4) sc += kv.second;
        else other += kv.second;
    }
    std::printf("\nDECLARED DOF SUM (hdr[1]) = %lld\n", dof_sum);
    std::printf("\nCLOSURE TOTAL: %lld records   quat(16)=%lld vec3(12)=%lld scalar(4)=%lld other=%lld\n",
                grand, q, v3, sc, other);

    for (int a = 3; a < argc; a++) {
        std::string d = dump_of(argv[a], 6);
        if (d.empty()) continue;
        auto one = [&](const char* h) -> long long {
            size_t p = d.find(h); if (p == std::string::npos) return -1;
            size_t e = d.find('\n', p); if (e == std::string::npos) return -1;
            std::string ln = d.substr(p + strlen(h), e - p - strlen(h));
            return atoll(ln.c_str());
        };
        const long long qc = one("0x59c0cd8b"), vc = one("0xc851ed38"), sc2 = one("0xa3d92df7");
        std::string nm(argv[a]); size_t sl = nm.rfind('/');
        /* every 0xfb934722 array length in this clip, in order */
        std::string arrs; size_t ap = 0;
        while ((ap = d.find("0xfb934722", ap)) != std::string::npos) {
            size_t lb = d.find('[', ap), rb = d.find(']', lb);
            if (lb == std::string::npos || rb == std::string::npos) break;
            arrs += d.substr(lb, rb - lb + 1); arrs += " ";
            ap = rb;
        }
        size_t dp2 = d.find("dofsets/"); std::string dsl2 = "?";
        if (dp2 != std::string::npos) { size_t de2 = d.find('\n', dp2); dsl2 = d.substr(dp2+8, de2-dp2-8); }
        while (!dsl2.empty() && (dsl2.back()=='\r' || dsl2.back()==' ')) dsl2.pop_back();
        std::printf("  CLIP %-38s q=%-4lld v=%-4lld s=%-4lld arrays=%-18s %s\n",
                    nm.c_str()+(sl==std::string::npos?0:sl+1), qc, vc, sc2,
                    arrs.c_str(), dsl2.c_str());
    }
    bf6_close(g_ctx);
    return 0;
}
