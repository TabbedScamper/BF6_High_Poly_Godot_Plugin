/* rid_test - resolve EBX ResourceRef ids to the RES they name. */
#include <cstdio>
#include <cstdlib>
#include "bf6_core.h"
int main(int argc, char** argv) {
    if (argc < 3) { std::printf("usage: rid_test <game> <hex_rid> [more...]\n"); return 2; }
    char err[256] = {0};
    bf6_ctx* ctx = bf6_open(argv[1], err, sizeof(err));
    if (!ctx) { std::printf("open: %s\n", err); return 1; }
    if (!bf6_mount_all(ctx, 1, err, sizeof(err)))
    { std::printf("mount: %s\n", err); bf6_close(ctx); return 1; }
    for (int a = 2; a < argc; a++) {
        const uint64_t rid = std::strtoull(argv[a], nullptr, 16);
        char name[512];
        const int ok = bf6_res_by_rid(ctx, rid, name, sizeof(name));
        std::printf("  %016llx -> %s\n", (unsigned long long)rid, ok ? name : "(not found)");
    }
    bf6_close(ctx);
    return 0;
}
