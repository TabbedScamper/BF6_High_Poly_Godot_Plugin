/* dofset_test - sum a rig's DOF-set list by component type, in ONE mount.
 *
 * THE TEST THIS EXISTS FOR. A clip records its own channel counts:
 *   quaternionChannelCount  EBX 0x59C0CD8B
 *   vector3ChannelCount     EBX 0xC851ED38
 *   scalarDofCount          EBX 0xA3D92DF7
 * If the DOF-set list a clip names really is the layout its channels bind
 * against, then summing that list's per-set DOF records by component type must
 * reproduce those three numbers. Anything else and the reconstruction is wrong.
 *
 * The .ds records are 8 x u32: (tag, stride, off1, off2, flag, packed, 0, 0).
 * Tag and stride together give the component type; stride is the byte size, so
 * 16 is a quaternion, 12 a vector3 and 4 a scalar.
 */
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>
#include <map>
#include "bf6_core.h"

/* pull the first array of plain integers that follows the given field hash */
static std::vector<long long> field_ints(const std::string& dump, const char* fieldhex)
{
    std::vector<long long> out;
    size_t p = dump.find(fieldhex);
    if (p == std::string::npos) return out;
    size_t line = dump.find('\n', p);
    if (line == std::string::npos) return out;
    size_t q = line + 1;
    while (q < dump.size()) {
        size_t e = dump.find('\n', q);
        if (e == std::string::npos) e = dump.size();
        std::string s = dump.substr(q, e - q);
        size_t c = s.find(':');
        if (c == std::string::npos) break;                 /* end of the array */
        const char* t = s.c_str() + c + 1;
        while (*t == ' ') t++;
        if (!(*t == '-' || (*t >= '0' && *t <= '9'))) break;
        out.push_back(atoll(t));
        q = e + 1;
    }
    return out;
}

int main(int argc, char** argv) {
    if (argc < 3) { std::printf("usage: dofset_test <game> <ds_asset> [more...]\n"); return 2; }
    char err[256] = {0};
    bf6_ctx* ctx = bf6_open(argv[1], err, sizeof(err));
    if (!ctx) { std::printf("open: %s\n", err); return 1; }
    if (!bf6_mount_all(ctx, 1, err, sizeof(err)))
    { std::printf("mount: %s\n", err); bf6_close(ctx); return 1; }

    std::vector<char> buf(64u << 20);
    std::map<std::pair<long long,long long>, long long> tally;   /* (tag,stride) -> count */
    long long grand = 0;
    for (int a = 2; a < argc; a++) {
        const int64_t n = bf6_ebx_dump(ctx, argv[a], 6, buf.data(), (int)buf.size());
        if (n <= 0) { std::printf("  %-28s DUMP FAILED\n", argv[a]); continue; }
        std::string d(buf.data());
        /* A clip-data EBX instead of a DOF set: report its declared channel
         * counts and the DOF-set list it names, so both sides of the test can
         * be gathered in ONE mount. */
        if (d.find("0x59c0cd8b") != std::string::npos) {
            auto one = [&](const char* h) -> long long {
                size_t q = d.find(h); if (q == std::string::npos) return -1;
                size_t e = d.find('\n', q); if (e == std::string::npos) return -1;
                std::string ln = d.substr(q + strlen(h), e - q - strlen(h));
                return atoll(ln.c_str());
            };
            const long long qc = one("0x59c0cd8b"), vc = one("0xc851ed38"), sc2 = one("0xa3d92df7");
            size_t dp = d.find("dofsets/");
            std::string dsl = "?";
            if (dp != std::string::npos) {
                size_t de = d.find('\n', dp);
                dsl = d.substr(dp + 8, de - dp - 8);
            }
            while (!dsl.empty() && (dsl.back()=='\r' || dsl.back()==' ')) dsl.pop_back();
            std::string nm(argv[a]); size_t sl2 = nm.rfind('/');
            std::printf("  CLIP %-44s q=%-4lld v=%-4lld s=%-3lld total=%-4lld  %s\n",
                        sl2==std::string::npos?nm.c_str():nm.c_str()+sl2+1,
                        qc, vc, sc2, qc+vc+sc2, dsl.c_str());
            continue;
        }
        std::vector<long long> v = field_ints(d, "0xf71b7fd3");
        if (v.empty()) v = field_ints(d, "0xF71B7FD3");
        const size_t recs = v.size() / 8;
        std::map<std::pair<long long,long long>, long long> local;
        for (size_t r = 0; r < recs; r++) local[{v[r*8], v[r*8+1]}]++;
        std::string nm(argv[a]);
        size_t sl = nm.rfind('/');
        std::printf("  %-26s words=%-6zu recs=%-5zu ", sl==std::string::npos?nm.c_str():nm.c_str()+sl+1,
                    v.size(), recs);
        for (auto& kv : local) {
            std::printf("(t%lld,s%lld)x%lld ", kv.first.first, kv.first.second, kv.second);
            tally[kv.first] += kv.second;
        }
        std::printf("\n");
        grand += (long long)recs;
    }
    std::printf("\nTOTALS across the list (%lld records)\n", grand);
    long long q = 0, v3 = 0, sc = 0, other = 0;
    for (auto& kv : tally) {
        std::printf("   tag=%-12lld stride=%-6lld count=%lld\n",
                    kv.first.first, kv.first.second, kv.second);
        if (kv.first.second == 16) q  += kv.second;
        else if (kv.first.second == 12) v3 += kv.second;
        else if (kv.first.second == 4)  sc += kv.second;
        else other += kv.second;
    }
    std::printf("\n   by stride:  quaternion(16)=%lld  vector3(12)=%lld  scalar(4)=%lld  other=%lld\n",
                q, v3, sc, other);
    bf6_close(ctx);
    return 0;
}
