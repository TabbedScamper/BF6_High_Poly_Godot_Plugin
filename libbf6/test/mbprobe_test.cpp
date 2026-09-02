/* mbprobe_test - is Portal's ModBuilder the SAME system as DICE's gems?
 *
 * THE CLAIM UNDER TEST. `gems-are-parameterised-modules-with-a-sim-pres-split`
 * found that 9,713 of the 10,691 game-wide "gems" name hits are Portal
 * user-created content under modbuilder/modbuilderprefabs/createdgems, and set
 * them aside as belonging to the modbuilder unit. That was a FILING decision,
 * not a measurement. If those really are gems, the gem reader written for
 * gamemodes/_shared/gems must read them UNCHANGED - same root type GUID, same
 * interface field, same FieldHashes - and must find an mi_* interface on them.
 *
 * Names are enumerated FROM THE MOUNT, never from a staged list.
 */
#include "source.h"
#include "bf6_core.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <algorithm>
#include <map>
#include <string>
#include <vector>

int main(int argc, char** argv)
{
    if (argc < 2) { std::printf("usage: mbprobe_test <game> [max]\n"); return 2; }
    const int maxn = (argc > 2) ? std::atoi(argv[2]) : 250;

    bf6::Source src; std::string err;
    if (!src.open(argv[1], err)) { std::printf("open: %s\n", err.c_str()); return 1; }
    if (!src.mount_level("", true, err)) { std::printf("mount: %s\n", err.c_str()); return 1; }

    std::vector<std::string> names;
    const std::string want = "modbuilder/modbuilderprefabs/createdgems/gem_";
    for (const auto& kv : src.ebx())
        if (kv.first.find(want) != std::string::npos) names.push_back(kv.first);
    std::sort(names.begin(), names.end());
    std::printf("createdgems partitions in the mount: %zu\n", names.size());
    if ((int)names.size() > maxn) names.resize((size_t)maxn);

    char e2[512] = {0};
    bf6_ctx* c = bf6_open(argv[1], e2, (int)sizeof(e2));
    if (!c) { std::printf("open: %s\n", e2); return 1; }
    if (!bf6_mount_all(c, 1, e2, (int)sizeof(e2))) { std::printf("mount: %s\n", e2); return 1; }

    int read = 0, iface = 0, binds = 0;
    std::map<std::string, int> ifaces;
    for (const std::string& n : names) {
        bf6_gem* g = bf6_gem_read(c, n.c_str());
        if (!g) continue;
        read++;
        if (g->interface_ebx[0]) { iface++; ifaces[g->interface_ebx]++; }
        binds += g->count;
        bf6_free(c, g);
    }
    std::printf("  read as gems      : %d of %zu\n", read, names.size());
    std::printf("  with an mi_ iface : %d\n", iface);
    std::printf("  total pin binds   : %d\n", binds);
    std::printf("  DISTINCT interfaces: %zu\n", ifaces.size());
    for (const auto& kv : ifaces)
        std::printf("      %5d x %s\n", kv.second, kv.first.c_str());

    /* CONTROL: a fabricated createdgem name must read nothing. */
    bf6_gem* fake = bf6_gem_read(c,
        "game/glacierportal/modbuilder/modbuilderprefabs/createdgems/gem__not_a_real_object_zzz");
    std::printf("  fabricated name read: %d (must be 0)\n", fake ? 1 : 0);
    if (fake) bf6_free(c, fake);

    const bool pass = read == (int)names.size() && iface == read && !fake && read > 100;
    std::printf("\n%s\n", pass ? "PASS" : "FAIL");
    bf6_close(c);
    return pass ? 0 : 1;
}
