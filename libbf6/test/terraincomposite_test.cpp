/* Validation harness for the terrain ground-material composite.
 *
 * Not shipped. The whole point is that this can FAIL here rather than in a
 * renderer, so it reports the four numbers that separate a real bake from a
 * plausible one and writes a PNG a human can open:
 *
 *   - how many layers reached the window, how many bound a colour sheet, and
 *     how many decoded. A palette that resolves nothing produces a beautiful
 *     uniform colour and no error, so the counts come first;
 *   - the fraction of texels no textured layer covered. Above a few percent
 *     this is a hole, not a bake;
 *   - the mean RGB, and the per-channel standard deviation next to it. A mean
 *     alone cannot tell flat grey from ground; a near-zero deviation can;
 *   - the count of distinct 5-5-5 colours, which is the cheapest thing that
 *     distinguishes texture from a gradient.
 *
 * The PNG writer is here rather than in the library because it is validation
 * scaffolding. It emits stored (uncompressed) deflate blocks inside a real
 * zlib stream, which is a legal PNG every viewer opens and about thirty lines
 * against a dependency.
 *
 *   terraincomposite_test <game_dir> <level> [--out=DIR] [--size=N]
 *       [--window=cx,cz,span] [--splat=N] [--texdim=N] [--threads=N]
 *       [--no-stochastic] [--no-colourmap] [--no-f16] [--tag=NAME]
 */
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <set>
#include <string>
#include <vector>

#include "source.h"
#include "splat.h"
#include "terrainlayers.h"
#include "terraincomposite.h"

using namespace bf6;

namespace {

// ---- PNG ------------------------------------------------------------------

uint32_t crc_table[256];
bool crc_ready = false;

uint32_t crc32_of(const uint8_t* d, size_t n, uint32_t c = 0xFFFFFFFFu)
{
    if (!crc_ready)
    {
        for (uint32_t i = 0; i < 256; i++)
        {
            uint32_t v = i;
            for (int k = 0; k < 8; k++) v = (v & 1) ? 0xEDB88320u ^ (v >> 1) : v >> 1;
            crc_table[i] = v;
        }
        crc_ready = true;
    }
    for (size_t i = 0; i < n; i++) c = crc_table[(c ^ d[i]) & 0xFF] ^ (c >> 8);
    return c;
}

void put32(std::vector<uint8_t>& v, uint32_t x)
{ v.push_back((uint8_t)(x >> 24)); v.push_back((uint8_t)(x >> 16));
  v.push_back((uint8_t)(x >> 8)); v.push_back((uint8_t)x); }

void chunk(std::vector<uint8_t>& out, const char* tag, const std::vector<uint8_t>& data)
{
    put32(out, (uint32_t)data.size());
    const size_t at = out.size();
    out.insert(out.end(), tag, tag + 4);
    out.insert(out.end(), data.begin(), data.end());
    const uint32_t c = crc32_of(out.data() + at, out.size() - at) ^ 0xFFFFFFFFu;
    put32(out, c);
}

bool write_png(const std::string& path, const uint8_t* rgba, int w, int h)
{
    std::vector<uint8_t> raw;
    raw.reserve((size_t)h * (w * 4 + 1));
    for (int y = 0; y < h; y++)
    {
        raw.push_back(0);
        raw.insert(raw.end(), rgba + (size_t)y * w * 4, rgba + (size_t)(y + 1) * w * 4);
    }

    // zlib: header, stored deflate blocks, adler32.
    std::vector<uint8_t> z;
    z.push_back(0x78); z.push_back(0x01);
    size_t at = 0;
    while (at < raw.size())
    {
        const uint16_t n = (uint16_t)std::min<size_t>(65535, raw.size() - at);
        const bool last = (at + n) >= raw.size();
        z.push_back(last ? 1 : 0);
        z.push_back((uint8_t)(n & 0xFF)); z.push_back((uint8_t)(n >> 8));
        z.push_back((uint8_t)(~n & 0xFF)); z.push_back((uint8_t)((~n >> 8) & 0xFF));
        z.insert(z.end(), raw.begin() + at, raw.begin() + at + n);
        at += n;
    }
    uint32_t a = 1, b = 0;
    for (uint8_t v : raw) { a = (a + v) % 65521; b = (b + a) % 65521; }
    put32(z, (b << 16) | a);

    std::vector<uint8_t> png = {0x89, 'P', 'N', 'G', '\r', '\n', 0x1A, '\n'};
    std::vector<uint8_t> ihdr;
    put32(ihdr, (uint32_t)w); put32(ihdr, (uint32_t)h);
    ihdr.push_back(8); ihdr.push_back(6); ihdr.push_back(0);
    ihdr.push_back(0); ihdr.push_back(0);
    chunk(png, "IHDR", ihdr);
    chunk(png, "IDAT", z);
    chunk(png, "IEND", std::vector<uint8_t>());

    FILE* f = std::fopen(path.c_str(), "wb");
    if (!f) return false;
    const bool ok = std::fwrite(png.data(), 1, png.size(), f) == png.size();
    std::fclose(f);
    return ok;
}

// ---- reporting -------------------------------------------------------------

void describe(const char* what, const std::vector<uint8_t>& img, int size)
{
    const double n = (double)size * size;
    double mean[3] = {0, 0, 0}, var[3] = {0, 0, 0};
    for (size_t i = 0; i < img.size(); i += 4)
        for (int c = 0; c < 3; c++) mean[c] += img[i + c];
    for (int c = 0; c < 3; c++) mean[c] /= n;
    for (size_t i = 0; i < img.size(); i += 4)
        for (int c = 0; c < 3; c++)
        { const double d = img[i + c] - mean[c]; var[c] += d * d; }
    std::set<uint16_t> distinct;
    for (size_t i = 0; i < img.size(); i += 4)
        distinct.insert((uint16_t)(((img[i] >> 3) << 10) | ((img[i + 1] >> 3) << 5) |
                                   (img[i + 2] >> 3)));
    std::printf("  %s mean RGB (%.1f, %.1f, %.1f)  sd (%.1f, %.1f, %.1f)  "
                "%zu distinct 5-5-5 colours\n", what,
                mean[0], mean[1], mean[2],
                std::sqrt(var[0] / n), std::sqrt(var[1] / n), std::sqrt(var[2] / n),
                distinct.size());
}

// ---- window scan -----------------------------------------------------------
//
// A bake is only as good as the window it is pointed at, and on these maps the
// layers that bind a colour sheet are NOT the ones that cover most of the
// ground (see the gap note in terraincomposite.h). Rather than pick a window by
// eye and then explain a magenta PNG, this measures it first: for every texel
// of a coarse whole-map pass it asks whether ANY layer covering it has a sheet,
// then integrates that over candidate windows with a summed-area table and
// names the best ones in world coordinates.
int scan_windows(Source& src, const std::string& level, float span, int grid)
{
    std::string err, lvl = level;
    for (char& c : lvl) c = (char)std::tolower((unsigned char)c);
    std::string tree;
    for (const auto& kv : src.res())
    {
        std::string n = kv.first;
        for (char& c : n) c = (char)std::tolower((unsigned char)c);
        if (n.find("streamingtree") != std::string::npos && n.find(lvl) != std::string::npos)
        { tree = kv.first; break; }
    }
    if (tree.empty()) { std::fprintf(stderr, "no streaming tree\n"); return 1; }
    std::vector<uint8_t> res = src.get_res(tree, err), b1;
    if (!Splat::find_block(res, 1, b1, err)) { std::fprintf(stderr, "%s\n", err.c_str()); return 1; }
    Splat sp;
    SplatChunkDir dir;
    if (!sp.parse(b1, err) || !Splat::read_chunk_dir(res, dir, err) ||
        !sp.detect_layout(dir, err))
    { std::fprintf(stderr, "%s\n", err.c_str()); return 1; }

    TerrainLayers tl;
    if (!tl.load(src, level, err)) { std::fprintf(stderr, "palette: %s\n", err.c_str()); return 1; }
    std::vector<uint8_t> sheet(256, 0);
    for (const TerrainLayer& l : tl.layers())
        if (!l.material.base_color().empty() && l.index < 256) sheet[l.index] = 1;

    const int N = grid;
    auto fetch = [&](const std::string& g) { std::string e; return src.get_chunk(g, e); };
    SplatCoverage cov;
    SplatCompositeOpts so;
    if (!sp.composite(dir, fetch, N, cov, err, so))
    { std::fprintf(stderr, "composite: %s\n", err.c_str()); return 1; }

    MaterialRaster mr;
    bool have_base = false;
    { std::vector<uint8_t> b7; MaterialTree mt;
      if (Splat::find_block(res, 7, b7, err) && mt.parse(b7, err))
          have_base = mt.rasterize(N, [&](float cx, float cz, float w)
                                   { return sp.base_list_at(cx, cz, w); },
                                   sp.full_list(), tl.linked_list(),
                                   sp.global_base_list(), mr, err); }

    std::vector<int64_t> sat((size_t)(N + 1) * (N + 1), 0);
    for (int y = 0; y < N; y++)
        for (int x = 0; x < N; x++)
        {
            int hit = 0;
            if (have_base)
            { const uint8_t b = mr.layer[(size_t)y * N + x]; if (b != 255 && sheet[b]) hit = 1; }
            const size_t o = ((size_t)y * N + x) * 4;
            for (int s = 0; s < 4 && !hit; s++)
            { if (!cov.w[o + s]) break; if (sheet[cov.idx[o + s]]) hit = 1; }
            sat[(size_t)(y + 1) * (N + 1) + (x + 1)] =
                hit + sat[(size_t)y * (N + 1) + (x + 1)] +
                sat[(size_t)(y + 1) * (N + 1) + x] - sat[(size_t)y * (N + 1) + x];
        }

    const float world = sp.root_max()[0] - sp.root_min()[0];
    const int wt = std::max(1, (int)(span / world * (float)N));
    std::vector<std::pair<double, std::pair<int, int>>> best;
    for (int y = 0; y + wt <= N; y += std::max(1, wt / 4))
        for (int x = 0; x + wt <= N; x += std::max(1, wt / 4))
        {
            const int64_t s = sat[(size_t)(y + wt) * (N + 1) + (x + wt)]
                            - sat[(size_t)y * (N + 1) + (x + wt)]
                            - sat[(size_t)(y + wt) * (N + 1) + x]
                            + sat[(size_t)y * (N + 1) + x];
            best.push_back({(double)s / ((double)wt * wt), {x, y}});
        }
    std::sort(best.rbegin(), best.rend());
    std::printf("\n%s: best %.0f m windows by textured-layer reach "
                "(%d^2 probe, %.1f m/probe texel)\n",
                level.c_str(), span, N, world / (float)N);
    int shown = 0;
    std::set<std::pair<int, int>> seen;
    for (const auto& b : best)
    {
        const int x = b.second.first, y = b.second.second;
        bool near = false;
        for (const auto& s : seen)
            if (std::abs(s.first - x) < wt && std::abs(s.second - y) < wt) { near = true; break; }
        if (near) continue;
        seen.insert({x, y});
        const float cx = sp.root_min()[0] + (x + wt * 0.5f) / (float)N * world;
        const float cz = sp.root_min()[1] + (y + wt * 0.5f) / (float)N * world;
        std::printf("  %5.1f%% textured   --window=%.0f,%.0f,%.0f\n",
                    100.0 * b.first, cx, cz, span);
        if (++shown >= 8) break;
    }
    return 0;
}

}  // namespace

int main(int argc, char** argv)
{
    if (argc < 3)
    {
        std::fprintf(stderr,
            "usage: terraincomposite_test <game_dir> <level> [--out=DIR] [--size=N]\n"
            "       [--window=cx,cz,span] [--splat=N] [--texdim=N] [--threads=N]\n"
            "       [--no-stochastic] [--no-colourmap] [--no-f16] [--tag=NAME]\n");
        return 2;
    }
    const std::string game = argv[1], level = argv[2];
    // Diagnostic output is local to the invocation. Evidence is promoted to
    // the research corpus only after review, never written there implicitly.
    std::string outdir = "terrain_bake";
    std::string tag;
    TerrainBakeOpts opt;
    opt.size = 1024;
    float scan_span = 0.f;
    int   scan_grid = 1024;
    bool  colourmap_only = false;

    for (int i = 3; i < argc; i++)
    {
        const std::string a = argv[i];
        if (a.rfind("--out=", 0) == 0) outdir = a.substr(6);
        else if (a.rfind("--tag=", 0) == 0) tag = a.substr(6);
        else if (a.rfind("--size=", 0) == 0) opt.size = std::atoi(a.c_str() + 7);
        else if (a.rfind("--splat=", 0) == 0) opt.splat_size = std::atoi(a.c_str() + 8);
        else if (a.rfind("--texdim=", 0) == 0) opt.texture_dim = std::atoi(a.c_str() + 9);
        else if (a.rfind("--threads=", 0) == 0) opt.threads = std::atoi(a.c_str() + 10);
        else if (a == "--no-stochastic") opt.stochastic = false;
        else if (a == "--no-colourmap") opt.colour_map = false;
        else if (a == "--no-f16") opt.quantise_f16 = false;
        else if (a == "--no-prime") opt.prime_first_layer = false;
        // The before/after switch for the statically bound half of the palette.
        else if (a == "--no-static") opt.static_fallback = false;
        else if (a == "--aerial-fallback") opt.fallback_colour_map = true;
        // Write the block-1 aerial photograph for the window and nothing else.
        // A level whose colour map lands in the wrong place is invisible in a
        // finished bake and obvious here.
        else if (a == "--colourmap-only") colourmap_only = true;
        else if (a.rfind("--scan=", 0) == 0) scan_span = (float)std::atof(a.c_str() + 7);
        else if (a.rfind("--scangrid=", 0) == 0) scan_grid = std::atoi(a.c_str() + 11);
        else if (a.rfind("--window=", 0) == 0)
        {
            float v[3] = {0, 0, 0};
            std::sscanf(a.c_str() + 9, "%f,%f,%f", &v[0], &v[1], &v[2]);
            opt.rect_min[0] = v[0] - v[2] * 0.5f;
            opt.rect_min[1] = v[1] - v[2] * 0.5f;
            opt.rect_size = v[2];
        }
    }

    Source src;
    std::string err;
    if (!src.open(game, err)) { std::fprintf(stderr, "open: %s\n", err.c_str()); return 1; }
    if (!src.mount_level(level, false, err))
    { std::fprintf(stderr, "mount: %s\n", err.c_str()); return 1; }

    if (scan_span > 0.f) return scan_windows(src, level, scan_span, scan_grid);

    if (colourmap_only)
    {
        std::string tree;
        std::string lvl = level;
        for (char& c : lvl) c = (char)tolower((unsigned char)c);
        for (const auto& kv : src.res())
        {
            std::string nm = kv.first;
            for (char& c : nm) c = (char)tolower((unsigned char)c);
            if (nm.find("streamingtree") != std::string::npos &&
                nm.find(lvl) != std::string::npos) { tree = kv.first; break; }
        }
        std::vector<uint8_t> res = src.get_res(tree, err), b1;
        Splat sp;
        SplatChunkDir dir;
        if (tree.empty() || res.empty() || !Splat::find_block(res, 1, b1, err) ||
            !sp.parse(b1, err) || !Splat::read_chunk_dir(res, dir, err) ||
            !sp.detect_layout(dir, err))
        { std::fprintf(stderr, "colourmap: %s\n", err.c_str()); return 1; }

        float clo[2] = {sp.root_min()[0], sp.root_min()[1]};
        float chi[2] = {sp.root_max()[0], sp.root_max()[1]};
        if (opt.rect_size > 0.f)
        {
            clo[0] = opt.rect_min[0];              clo[1] = opt.rect_min[1];
            chi[0] = clo[0] + opt.rect_size;       chi[1] = clo[1] + opt.rect_size;
        }
        auto fetch = [&src](const std::string& g)
        { std::string e; return src.get_chunk(g, e); };
        std::vector<uint8_t> rgb;
        std::vector<std::string> fails;
        paint_colour_map(sp, dir, fetch, clo, chi, opt.size, rgb, &fails);
        if (rgb.empty()) { std::fprintf(stderr, "colourmap: nothing painted\n"); return 1; }
        std::vector<uint8_t> rgba((size_t)opt.size * opt.size * 4, 255);
        for (size_t i = 0; i < (size_t)opt.size * opt.size; i++)
            for (int c = 0; c < 3; c++) rgba[i * 4 + c] = rgb[i * 3 + c];
        std::string p = outdir + "/" + level + (tag.empty() ? "" : "_" + tag) +
                        "_colourmap.png";
        std::printf("colour map window x %.1f..%.1f z %.1f..%.1f, %zu slices\n",
                    clo[0], chi[0], clo[1], chi[1],
                    sp.color_slices(dir, fetch).size());
        if (!write_png(p, rgba.data(), opt.size, opt.size))
        { std::fprintf(stderr, "could not write %s\n", p.c_str()); return 1; }
        std::printf("wrote %s\n", p.c_str());
        return 0;
    }

    TerrainBake bake;
    if (!TerrainComposite::bake(src, level, opt, bake, err))
    { std::fprintf(stderr, "bake: %s\n", err.c_str()); return 1; }

    const double texels = (double)bake.size * bake.size;
    std::printf("\n================ %s ================\n", level.c_str());
    std::printf("window : x %.1f..%.1f  z %.1f..%.1f  (%.0f m across)\n",
                bake.lo[0], bake.hi[0], bake.lo[1], bake.hi[1], bake.hi[0] - bake.lo[0]);
    std::printf("raster : %d x %d, %.3f m/texel\n",
                bake.size, bake.size, bake.metres_per_texel);
    std::printf("stochastic %s | colour map %s (%d tiles) | f16 %s | prime %s | static %s\n",
                opt.stochastic ? "on" : "off",
                bake.colour_map_used ? "on" : "off", bake.colour_tiles,
                opt.quantise_f16 ? "on" : "off",
                opt.prime_first_layer ? "on" : "off",
                opt.static_fallback ? "on" : "off");

    std::printf("\nLAYERS  %d in the palette | %d reached this window | "
                "%d bound a colour sheet | %d decoded\n",
                bake.layers_in_palette, bake.layers_present,
                bake.layers_with_sheet, bake.layers_decoded);
    for (const TerrainBakeLayer& l : bake.layers)
    {
        std::printf("  L%-3d %-9s %8llu texels  ", l.layer,
                    l.painted && l.base ? "paint+base" : l.painted ? "painted"
                                        : l.base ? "base" : "-",
                    (unsigned long long)l.texels);
        if (l.decoded)
            std::printf("%-34s %4dx%-4d dxgi %-3d  %.2f m/repeat%s\n",
                        l.asset.c_str(), l.width, l.height, l.dxgi,
                        l.metres_per_repeat,
                        l.tiling_authored ? "" : " (not authored, default)");
        else std::printf("SKIPPED - %s\n", l.failure.c_str());
    }
    if (!bake.failures.empty())
    {
        std::printf("\nFAILURES\n");
        for (const std::string& f : bake.failures) std::printf("  %s\n", f.c_str());
    }

    std::printf("\nRESULT\n");
    std::printf("  zero-coverage texels (no textured layer): %llu (%.2f%%)\n",
                (unsigned long long)bake.texels_untouched,
                100.0 * (double)bake.texels_untouched / texels);
    // HOW MIXED THE GROUND IS. A chroma score cannot see "several textures
    // averaged together"; this is the number that can.
    std::printf("  splat slots evicted: %llu paints, %.4f mask lost per texel\n",
                (unsigned long long)bake.splat_evictions, bake.splat_evicted_mask);
    std::printf("  stack size (textured layers per texel):");
    for (int i = 0; i <= 8; i++)
        if (bake.stack_hist[i])
            std::printf(" %d=%.1f%%", i, 100.0 * (double)bake.stack_hist[i] / texels);
    std::printf("\n  dominant share: evaluator %.1f%%, raw mask %.1f%% | "
                "effective layers %.2f\n",
                100.0 * bake.mix_dominant, 100.0 * bake.mask_dominant,
                bake.mix_participation);
    describe("albedo", bake.albedo, bake.size);
    if (!bake.normal.empty()) describe("normal", bake.normal, bake.size);

    std::string base = outdir + "/" + level + (tag.empty() ? "" : "_" + tag);
    if (!write_png(base + "_albedo.png", bake.albedo.data(), bake.size, bake.size))
        std::fprintf(stderr, "could not write %s_albedo.png\n", base.c_str());
    else std::printf("\nwrote %s_albedo.png\n", base.c_str());
    if (!bake.normal.empty())
    {
        if (write_png(base + "_normal.png", bake.normal.data(), bake.size, bake.size))
            std::printf("wrote %s_normal.png\n", base.c_str());
    }
    return 0;
}
