/* Runtime terrain static join, measured against the research oracle.
 *
 * Production reads only the mounted game: current shaderstate DB -> current
 * permutation -> current CompiledBytecode -> BF6's dxcompiler.dll -> CFG case
 * samples. The TSV is passed to this test only as an independent oracle.
 * Controls: shifted layer pairing and invalid bytecode.
 */
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <map>
#include <sstream>
#include <string>
#include <vector>

#include "source.h"
#include "terrainjoin.h"
#include "terrainstatic.h"

using namespace bf6;

struct Triple { int cv = -1, nh = -1, third = -1; };

int main(int argc, char** argv)
{
    if (argc < 4) {
        std::fprintf(stderr, "usage: terrainstatic_live_test <game_dir> <level> <oracle.tsv>\n");
        return 2;
    }
    Source src;
    std::string err;
    if (!src.open(argv[1], err) || !src.mount_level(argv[2], false, err)) {
        std::fprintf(stderr, "mount: %s\n", err.c_str()); return 1;
    }
    TerrainStaticTable table;
    if (!table.load(src, argv[2], err)) {
        std::fprintf(stderr, "live join: %s\n", err.c_str()); return 1;
    }

    std::ifstream in(argv[3]);
    if (!in) { std::fprintf(stderr, "oracle could not be opened\n"); return 1; }
    std::map<int, Triple> expected;
    std::string line;
    while (std::getline(in, line)) {
        if (line.empty() || line[0] == '#') continue;
        std::vector<std::string> c;
        std::stringstream row(line);
        std::string cell;
        while (std::getline(row, cell, '\t')) c.push_back(cell);
        if (c.size() < 7 || c[0] != table.bytecode_guid() || c[1] != "0") continue;
        Triple t;
        const int layer = std::atoi(c[3].c_str());
        t.cv = std::atoi(c[4].c_str());
        t.nh = std::atoi(c[5].c_str());
        t.third = std::atoi(c[6].c_str());
        expected[layer] = t;
    }
    if (expected.empty()) {
        std::fprintf(stderr, "oracle has no row for live GUID %s\n",
                     table.bytecode_guid().c_str());
        return 1;
    }

    int exact = 0, shifted = 0;
    for (const auto& e : expected) {
        int cv = -1, nh = -1, third = -1;
        if (table.layer_descriptors(e.first, cv, nh, third) &&
            cv == e.second.cv && nh == e.second.nh && third == e.second.third) exact++;
        cv = nh = third = -1;
        if (table.layer_descriptors(e.first + 1, cv, nh, third) &&
            cv == e.second.cv && nh == e.second.nh && third == e.second.third) shifted++;
    }

    TerrainDxilJoin fake;
    std::vector<unsigned char> invalid(64, 0);
    std::string fake_err;
    const bool fake_accepted = recover_terrain_dxil_join(src.game_dir(), invalid,
                                                         fake, fake_err);
    std::printf("live GUID %s\n", table.bytecode_guid().c_str());
    std::printf("register base %d, fit %d, adjacent/runner control %d\n",
                table.register_base(), table.register_base_hits(),
                table.register_base_runner_up_hits());
    std::printf("oracle exact %d/%zu; shifted-pair control %d/%zu\n",
                exact, expected.size(), shifted, expected.size());
    std::printf("invalid-bytecode control: %s (%s)\n",
                fake_accepted ? "FAIL accepted" : "PASS rejected", fake_err.c_str());
    if (exact != (int)expected.size() || shifted >= exact || fake_accepted) return 1;
    return 0;
}
