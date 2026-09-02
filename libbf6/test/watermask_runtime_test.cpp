/* Runtime ABI proof for the exact CoarseMask utility-raster path. */
#include "bf6_core.h"

#include <cstdio>
#include <cstring>

int main(int argc, char** argv)
{
    if (argc < 4) {
        std::printf("usage: watermask_runtime_test <game_dir> <exe> <level>\n");
        return 2;
    }
    char err[512] = {};
    bf6_ctx* c = bf6_open(argv[1], err, sizeof(err));
    if (!c) { std::printf("OPEN_FAIL %s\n", err); return 1; }
    if (bf6_open_level(c, argv[3], argv[2], 0, err, sizeof(err)) != 0) {
        std::printf("LEVEL_FAIL %s\n", err); bf6_close(c); return 1;
    }
    bf6_water_mask m{};
    const int ok = bf6_level_water_mask(c, argv[3], &m, err, sizeof(err));
    if (!ok) { std::printf("MASK_FAIL %s\n", err); bf6_close(c); return 1; }
    uint32_t page_cells = 0, inline_cells = 0, bad_page_cells = 0;
    for (uint32_t i = 0; i < m.indirection_side * m.indirection_side; ++i) {
        const uint32_t v = m.indirection_u32[i];
        if ((int16_t)(v & 0xffff) < 0) ++inline_cells;
        else {
            ++page_cells;
            if ((v & 0xffff) >= m.page_count) ++bad_page_cells;
        }
    }
    uint64_t hash = 1469598103934665603ull;
    const size_t atlas_bytes = (size_t)m.page_count * m.tile_side * m.tile_side;
    for (size_t i = 0; i < atlas_bytes; ++i) {
        hash ^= m.atlas_r8[i];
        hash *= 1099511628211ull;
    }
    std::printf("REAL version=%u tile=%u interior=%u pages=%u indirection=%u "
                "bounds=(%.1f,%.1f)..(%.1f,%.1f) pageCells=%u inlineCells=%u "
                "badPageCells=%u atlasFnv=%016llX\n",
        m.version, m.tile_side, m.interior_side, m.page_count,
        m.indirection_side, m.bounds_min[0], m.bounds_min[1],
        m.bounds_max[0], m.bounds_max[1], page_cells, inline_cells,
        bad_page_cells, (unsigned long long)hash);

    bf6_water_mask fake{};
    char fake_err[512] = {};
    const int fake_ok = bf6_level_water_mask(c, "mp_not_a_real_level", &fake,
                                              fake_err, sizeof(fake_err));
    std::printf("CONTROL fake_level_rejected=%d (%s)\n", fake_ok ? 0 : 1, fake_err);
    const bool pass = m.version == 1 && m.tile_side == 515 &&
        m.interior_side == 512 && m.page_count == 40 &&
        m.indirection_side == 16 && page_cells == 40 &&
        inline_cells == 216 && bad_page_cells == 0 && !fake_ok;
    std::printf("RESULT %s\n", pass ? "pass" : "fail");
    bf6_close(c);
    return pass ? 0 : 1;
}
