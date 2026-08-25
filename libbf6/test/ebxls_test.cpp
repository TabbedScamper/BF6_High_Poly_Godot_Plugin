// Search the mount by name. The workbench tool for building anything on top
// of an install: what partitions exist, what type are they, how big.
//
// It exists because the extract is a SUBSET. Our staged tree pulled only
// common/hardware and common/ui, so anything the game keeps elsewhere - the
// shared slot definition templates among them - is invisible to a filesystem
// search and present in the mount. Guessing that something "does not exist"
// from the extract is how you conclude a thing is absent when it is merely
// unstaged.
//
//   ebxls_test <game_dir> <substring> [--res] [--max N] [--nolevels]
//              [--dump <name> <out.bin>]
#include "bf6_core.h"
#include <cstdio>
#include <cstring>
#include <cstdlib>
#include <string>
#include <vector>
#include <algorithm>

int main(int argc, char** argv)
{
    if (argc < 3)
    {
        std::printf("usage: ebxls_test <game_dir> <substring> [--res] [--max N]"
                    " [--nolevels] [--dump <name> <out.bin>]\n");
        return 2;
    }
    const char* game = argv[1];
    const char* q    = argv[2];
    bool res = false;
    int  maxrows = 40, levels = 1;
    const char* dumpName = nullptr;
    const char* showName = nullptr;
    const char* rimeName = nullptr;
    const char* iconName = nullptr;
    int showDepth = 3;
    const char* dumpOut  = nullptr;
    for (int i = 3; i < argc; i++)
    {
        if      (!std::strcmp(argv[i], "--res"))       res = true;
        else if (!std::strcmp(argv[i], "--nolevels"))  levels = 0;
        else if (!std::strcmp(argv[i], "--max") && i + 1 < argc) maxrows = atoi(argv[++i]);
        else if (!std::strcmp(argv[i], "--show") && i + 1 < argc) showName = argv[++i];
        else if (!std::strcmp(argv[i], "--rime") && i + 1 < argc) rimeName = argv[++i];
        else if (!std::strcmp(argv[i], "--icons") && i + 1 < argc) iconName = argv[++i];
        else if (!std::strcmp(argv[i], "--depth") && i + 1 < argc) showDepth = atoi(argv[++i]);
        else if (!std::strcmp(argv[i], "--dump") && i + 2 < argc)
        { dumpName = argv[++i]; dumpOut = argv[++i]; }
    }

    char err[512] = { 0 };
    bf6_ctx* c = bf6_open(game, err, (int)sizeof(err));
    if (!c) { std::printf("open failed: %s\n", err); return 1; }
    if (!bf6_mount_all(c, levels, err, (int)sizeof(err)))
    { std::printf("mount failed: %s\n", err); bf6_close(c); return 1; }

    if (showName)
    {
        /* Reflection dump: what the record IS, not what bytes sit at an offset. */
        std::vector<char> buf(1 << 22);
        const int64_t n = bf6_ebx_dump(c, showName, showDepth, buf.data(), (int)buf.size());
        std::printf("%s\n", buf.data());
        if (n > (int64_t)buf.size()) std::printf("(truncated: needed %lld bytes)\n", (long long)n);
        bf6_close(c);
        return n < 0 ? 1 : 0;
    }

    if (iconName)
    {
        const int n = bf6_icon_atlas(c, iconName, nullptr, 0);
        std::printf("sprites in %s: %d\n", iconName, n);
        if (n > 0)
        {
            std::vector<bf6_icon_sprite> v((size_t)n);
            const int got = bf6_icon_atlas(c, iconName, v.data(), n);
            for (int i = 0; i < got && i < 24; i++)
            {
                const bf6_icon_sprite& s2 = v[(size_t)i];
                const char* leaf = s2.name ? strrchr(s2.name, '/') : nullptr;
                std::printf("  p%d  uv %.3f,%.3f..%.3f,%.3f  size %4.0fx%-4.0f "
                            "at %4.0f,%-4.0f canvas %.0fx%.0f  %s\n",
                            s2.page, s2.uv[0], s2.uv[1], s2.uv[2], s2.uv[3],
                            s2.size[0], s2.size[1], s2.offset[0], s2.offset[1],
                            s2.canvas[0], s2.canvas[1], leaf ? leaf + 1 : (s2.name ? s2.name : ""));
            }
            // and can we actually load the page it names?
            char pg[512];
            std::snprintf(pg, sizeof(pg), "%s_atlas%d", iconName, v[0].page);
            const int tid = bf6_texture_id_by_name(c, pg);
            std::printf("\npage %s -> id %d\n", pg, tid);
            if (tid >= 0)
            {
                const bf6_texture* t = bf6_texture_at(c, tid);
                if (t) std::printf("  decoded %dx%d fmt %d srgb %d  %d bytes\n",
                                   t->width, t->height, (int)t->format, t->srgb, t->data_len);
                else   std::printf("  DECODE FAILED\n");
            }
        }
        bf6_close(c);
        return n > 0 ? 0 : 1;
    }

    if (rimeName)
    {
        const int n = bf6_rime_elements(c, rimeName, nullptr, 0);
        std::printf("rime elements in %s: %d\n", rimeName, n);
        if (n > 0)
        {
            std::vector<bf6_rime_element> v((size_t)n);
            const int got = bf6_rime_elements(c, rimeName, v.data(), n);
            std::printf("  %-38s %-4s %8s %8s  %-22s %-22s\n",
                        "name", "ref", "width", "height", "h anchor/offset", "v anchor/offset");
            for (int i = 0; i < got && i < 40; i++)
            {
                const bf6_rime_element& r = v[(size_t)i];
                char hb[64], vb[64];
                std::snprintf(hb, sizeof(hb), "%.2f..%.2f %+.0f..%+.0f",
                              r.h.anchor_start, r.h.anchor_end, r.h.offset_start, r.h.offset_end);
                std::snprintf(vb, sizeof(vb), "%.2f..%.2f %+.0f..%+.0f",
                              r.v.anchor_start, r.v.anchor_end, r.v.offset_start, r.v.offset_end);
                // Raw floats, unlabelled: the six-float order inside a layout
                // is what is being established, so printing them under assumed
                // names would hide the answer.
                std::printf("  %-30s h[%6.2f %6.2f %7.1f %7.1f %5.2f %5.2f] "
                            "v[%6.2f %6.2f %7.1f %7.1f %5.2f %5.2f]\n",
                            r.name,
                            r.h.anchor_start, r.h.anchor_end, r.h.offset_start,
                            r.h.offset_end, r.h.pivot, r.h.weight,
                            r.v.anchor_start, r.v.anchor_end, r.v.offset_start,
                            r.v.offset_end, r.v.pivot, r.v.weight);
                if (false) std::printf("  %-38s %-4s %8.1f %8.1f  %-22s %-22s\n",
                            r.name, r.is_widget_ref ? "ref" : "", r.width, r.height, hb, vb);
            }
        }
        bf6_close(c);
        return n > 0 ? 0 : 1;
    }

    if (dumpName)
    {
        const uint8_t* p = nullptr;
        const int64_t n = bf6_read_raw(c, res ? BF6_RAW_RES : BF6_RAW_EBX, dumpName, &p);
        if (n < 0 || !p) { std::printf("could not read %s\n", dumpName); bf6_close(c); return 1; }
        FILE* f = std::fopen(dumpOut, "wb");
        if (!f) { std::printf("could not write %s\n", dumpOut); bf6_close(c); return 1; }
        std::fwrite(p, 1, (size_t)n, f);
        std::fclose(f);
        std::printf("wrote %s (%lld bytes)\n", dumpOut, (long long)n);
        bf6_close(c);
        return 0;
    }

    const int total = res ? bf6_list_res(c, q, nullptr, 0) : bf6_list_ebx(c, q, nullptr, 0);
    std::printf("%s matching \"%s\": %d\n", res ? "res" : "ebx", q, total);
    if (total <= 0) { bf6_close(c); return 1; }

    std::vector<bf6_asset> rows((size_t)total);
    const int got = res ? bf6_list_res(c, q, rows.data(), total)
                        : bf6_list_ebx(c, q, rows.data(), total);

    // Mount order is a hash order and is not stable between runs, so sort or
    // the same command prints a different sample each time.
    std::vector<std::pair<std::string, std::pair<uint32_t, uint32_t>>> v;
    v.reserve((size_t)got);
    for (int i = 0; i < got; i++)
        v.push_back({ rows[(size_t)i].name ? rows[(size_t)i].name : "",
                      { rows[(size_t)i].type, rows[(size_t)i].size } });
    std::sort(v.begin(), v.end());

    for (int i = 0; i < got && i < maxrows; i++)
        std::printf("  %-100s type %-10u %8u B\n",
                    v[(size_t)i].first.c_str(), v[(size_t)i].second.first,
                    v[(size_t)i].second.second);
    if (got > maxrows) std::printf("  ... %d more\n", got - maxrows);

    bf6_close(c);
    return 0;
}
