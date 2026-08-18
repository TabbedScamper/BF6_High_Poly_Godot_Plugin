/* toc_test - validate the SuperBundle TOC parse against the Godot plugin.
 *
 *   toc_test <toc_path>
 *
 * Prints bundle/chunk counts, the first bundle name, and the first chunk's
 * guid + chunk_location. BF6Toc.new().parse(...) on the same file must agree.
 */
#include <cstdio>
#include <string>
#include <vector>

#include "toc.h"

static std::vector<uint8_t> read_file(const char* p) {
    std::vector<uint8_t> out;
    FILE* f = std::fopen(p, "rb");
    if (!f) return out;
    std::fseek(f, 0, SEEK_END);
    long n = std::ftell(f);
    std::fseek(f, 0, SEEK_SET);
    if (n > 0) { out.resize((size_t)n); out.resize(std::fread(out.data(), 1, (size_t)n, f)); }
    std::fclose(f);
    return out;
}

int main(int argc, char** argv) {
    if (argc < 2) { std::printf("usage: toc_test <toc_path>\n"); return 2; }
    std::vector<uint8_t> raw = read_file(argv[1]);
    if (raw.empty()) { std::printf("cannot read %s\n", argv[1]); return 1; }

    bf6::Toc toc;
    std::string err;
    if (!toc.parse(raw.data(), raw.size(), err)) {
        std::printf("parse failed: %s\n", err.c_str());
        return 1;
    }
    std::printf("BUNDLES=%zu CHUNKS=%zu\n", toc.bundles.size(), toc.chunks.size());
    if (!toc.bundles.empty())
        std::printf("BUNDLE0 name=%s offset=%lld size=%u\n",
            toc.bundles[0].name.c_str(), (long long)toc.bundles[0].offset,
            toc.bundles[0].size);
    if (!toc.chunks.empty()) {
        bf6::CasLoc l = toc.chunk_location(toc.chunks[0]);
        std::printf("CHUNK0 guid=%s loc=%u,%u,%u,%u\n",
            toc.chunks[0].guid.c_str(), l.chunk_id, l.cas_ix, l.off, l.size);
    }
    return 0;
}
