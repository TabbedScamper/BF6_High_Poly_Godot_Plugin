/* typescan_test - find which partitions contain instances of a TYPE.
 *
 * Locating a type's instances by NAME does not work in this data: assets are
 * not named after the types they contain, and short type words collide with
 * unrelated art (searching "grid" returns restaurantgriddle, "streamer"
 * returns a suppressor attachment). So this scans by the type GUID itself.
 *
 * It reads each partition's RAW bytes and looks for the 16-byte GUID rather
 * than parsing, because a full EBX parse of every partition in a level is
 * minutes of work and a memory search is milliseconds. A hit means the GUID
 * appears in the partition - almost always its type table - which is a
 * candidate, not proof; dump the partition to confirm.
 *
 * GUIDs are matched in BOTH byte orders, because the textual form and the
 * stored form differ across Frostbite tables and guessing wrong silently finds
 * nothing.
 */
#include <cstdio>
#include <cstring>
#include <cstdlib>
#include <string>
#include <vector>
#include "bf6_core.h"

static bool parse_guid(const char* s, unsigned char out[16])
{
    int n = 0;
    for (const char* p = s; *p && n < 16; ) {
        if (*p == '-') { p++; continue; }
        char hex[3] = { p[0], p[1], 0 };
        if (!isxdigit((unsigned char)hex[0]) || !isxdigit((unsigned char)hex[1])) return false;
        out[n++] = (unsigned char)strtol(hex, nullptr, 16);
        p += 2;
    }
    return n == 16;
}

static const unsigned char* find_bytes(const unsigned char* h, size_t hn,
                                       const unsigned char* n, size_t nn)
{
    if (nn > hn) return nullptr;
    for (size_t i = 0; i + nn <= hn; i++)
        if (h[i] == n[0] && std::memcmp(h + i, n, nn) == 0) return h + i;
    return nullptr;
}

int main(int argc, char** argv)
{
    if (argc < 4) {
        std::printf("usage: typescan_test <game> <ebx-search> <type-guid> [max_hits]\n");
        return 2;
    }
    unsigned char g[16], rev[16], mix[16];
    if (!parse_guid(argv[3], g)) { std::printf("bad guid\n"); return 2; }
    for (int i = 0; i < 16; i++) rev[i] = g[15 - i];
    /* THE ORDER THAT ACTUALLY MATCHES. EBX stores a type GUID mixed-endian:
     * first three groups little-endian, last eight bytes as written. Verified
     * against a partition known to hold the type - as-written and full-reverse
     * both MISS and mixed-endian hits, so a scanner without this returns zero
     * everywhere and reads as a clean negative. */
    mix[0]=g[3]; mix[1]=g[2]; mix[2]=g[1]; mix[3]=g[0];
    mix[4]=g[5]; mix[5]=g[4];
    mix[6]=g[7]; mix[7]=g[6];
    for (int i = 8; i < 16; i++) mix[i] = g[i];
    const int max_hits = argc > 4 ? std::atoi(argv[4]) : 20;

    char err[256] = {0};
    bf6_ctx* c = bf6_open(argv[1], err, sizeof(err));
    if (!c) { std::printf("open: %s\n", err); return 1; }
    if (!bf6_mount_all(c, 1, err, sizeof(err))) { std::printf("mount: %s\n", err); return 1; }

    const int total = bf6_list_ebx(c, argv[2], nullptr, 0);
    if (total <= 0) { std::printf("no ebx match '%s'\n", argv[2]); bf6_close(c); return 1; }
    std::vector<bf6_asset> rows((size_t)total);
    const int got = bf6_list_ebx(c, argv[2], rows.data(), total);
    std::printf("scanning %d partitions for %s\n", got, argv[3]);

    int hits = 0, scanned = 0;
    for (int i = 0; i < got && hits < max_hits; i++) {
        const unsigned char* d = nullptr;
        const int64_t n = bf6_read_raw(c, BF6_RAW_EBX, rows[(size_t)i].name, &d);
        if (n <= 0 || !d) continue;
        scanned++;
        const bool mxd = find_bytes(d, (size_t)n, mix, 16) != nullptr;
        const bool fwd = !mxd && find_bytes(d, (size_t)n, g, 16) != nullptr;
        const bool bwd = !mxd && !fwd && find_bytes(d, (size_t)n, rev, 16) != nullptr;
        if (mxd || fwd || bwd) {
            std::printf("  HIT %-84s %s\n", rows[(size_t)i].name, mxd ? "mixed" : (fwd ? "fwd" : "rev"));
            hits++;
        }
    }
    std::printf("\n  scanned %d readable of %d listed, %d hits\n", scanned, got, hits);
    bf6_close(c);
    return hits > 0 ? 0 : 1;
}
