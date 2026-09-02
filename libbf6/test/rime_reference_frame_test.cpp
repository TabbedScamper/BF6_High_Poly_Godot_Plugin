#include "bf6_core.h"
#include "rime.h"

#include <cmath>
#include <cstdio>
#include <cstring>
#include <vector>

int main(int argc, char** argv)
{
    if (argc != 2)
    {
        std::fprintf(stderr, "usage: rime_reference_frame_test <game-dir>\n");
        return 2;
    }
    char err[512]{};
    bf6_ctx* c = bf6_open(argv[1], err, (int)sizeof(err));
    if (!c) { std::fprintf(stderr, "open: %s\n", err); return 1; }
    if (!bf6_mount_frontend(c, err, (int)sizeof(err)))
    {
        std::fprintf(stderr, "mount: %s\n", err);
        bf6_close(c);
        return 1;
    }

    const char* partition =
        "common/ui/componentlibrary/shared/visual/"
        "cl_readabilityfadebackgroundvisual";
    bf6_rime_tree_stats stats{};
    const int count = bf6_rime_tree(c, partition, 6, nullptr, 0, &stats);
    std::vector<bf6_rime_node> rows((size_t)(count > 0 ? count : 0));
    const int got = count > 0
        ? bf6_rime_tree(c, partition, 6, rows.data(), count, &stats) : count;

    int viewport = 0, non_viewport_sentinel = 0;
    std::vector<const bf6_rime_node*> viewport_rows;
    for (const bf6_rime_node& row : rows)
    {
        const bool is_viewport = std::strcmp(
            row.type_name, "RimeViewportStretchContainerElementData") == 0;
        if (!is_viewport)
        {
            if (row.viewport_flow_direction == -1 &&
                row.viewport_extend_top == -1 &&
                row.viewport_extend_bottom == -1 &&
                row.viewport_extend_left == -1 &&
                row.viewport_extend_right == -1)
                non_viewport_sentinel++;
            continue;
        }
        viewport++;
        viewport_rows.push_back(&row);
        std::printf("instance=%d name=%s flow=%d edges=T%d B%d L%d R%d "
                    "H=%.0f..%.0f w=%.0f V=%.0f..%.0f h=%.0f\n",
                    row.instance, row.name, row.viewport_flow_direction,
                    row.viewport_extend_top, row.viewport_extend_bottom,
                    row.viewport_extend_left, row.viewport_extend_right,
                    row.h.anchor_start, row.h.anchor_end, row.width,
                    row.v.anchor_start, row.v.anchor_end, row.height);
    }

    bf6_rime_tree_stats fake_stats{};
    const int fake = bf6_rime_tree(
        c, "common/ui/__control__/not_a_real_screen", 6,
        nullptr, 0, &fake_stats);
    int real_score = 0, rotated_score = 0, comparisons = 0;
    auto expected_edges = [](const bf6_rime_node& row, int out[4]) {
        out[0] = out[1] = out[2] = out[3] = 0; // T B L R
        const bool h_span = row.h.anchor_start == 0.f &&
                            row.h.anchor_end == 1.f;
        const bool v_span = row.v.anchor_start == 0.f &&
                            row.v.anchor_end == 1.f;
        if (h_span && row.v.anchor_start == 1.f &&
            row.v.anchor_end == 1.f)
        {
            out[1] = out[2] = out[3] = 1;
        }
        else if (row.width == 0.f &&
                 row.h.anchor_start == row.h.anchor_end)
        {
            if (row.h.anchor_start == 0.f) out[2] = 1;
            if (row.h.anchor_start == 1.f) out[3] = 1;
        }
        else if (v_span && row.h.anchor_start == row.h.anchor_end)
        {
            out[0] = out[1] = 1;
        }
    };
    for (size_t i = 0; i < viewport_rows.size(); ++i)
    {
        int expected[4]{};
        expected_edges(*viewport_rows[i], expected);
        const int real[4] = {
            viewport_rows[i]->viewport_extend_top,
            viewport_rows[i]->viewport_extend_bottom,
            viewport_rows[i]->viewport_extend_left,
            viewport_rows[i]->viewport_extend_right };
        const bf6_rime_node& rotated =
            *viewport_rows[(i + 1) % viewport_rows.size()];
        const int fake_edges[4] = {
            rotated.viewport_extend_top, rotated.viewport_extend_bottom,
            rotated.viewport_extend_left, rotated.viewport_extend_right };
        for (int edge = 0; edge < 4; ++edge)
        {
            real_score += real[edge] == expected[edge];
            rotated_score += fake_edges[edge] == expected[edge];
            comparisons++;
        }
    }

    rime::Screen screen;
    std::string adapter_error;
    const bool adapted = rime::from_live(rows.data(), got, screen, adapter_error);
    if (adapted) rime::solve(screen, 1920.f, 1080.f);
    rime::ReferenceFrame frame{};
    const bool framed = rime::reference_frame(
        2000.f, 1080.f, 1920.f, 1080.f, frame);
    rime::ReferenceFrame invalid_frame{};
    const bool invalid_framed = rime::reference_frame(
        0.f, 1080.f, 1920.f, 1080.f, invalid_frame);
    float left_stretch_width = -1.f, right_stretch_width = -1.f;
    if (adapted && framed)
    {
        for (const rime::Element& element : screen.elements)
        {
            if (!element.solved) continue;
            rime::ViewportRect rect{};
            if (!rime::viewport_rect(element, frame, 2000.f, 1080.f, rect))
                continue;
            if (element.width == 0.f && element.h.anchor_start == 0.f &&
                element.h.anchor_end == 0.f)
                left_stretch_width = rect.x1 - rect.x0;
            if (element.width == 0.f && element.h.anchor_start == 1.f &&
                element.h.anchor_end == 1.f)
                right_stretch_width = rect.x1 - rect.x0;
        }
    }

    std::printf("rows=%d got=%d viewport=%d non_viewport_sentinel=%d/%d "
                "fake=%d gated=%d unknown=%d\n",
                count, got, viewport, non_viewport_sentinel,
                count - viewport, fake, stats.gated_nodes, stats.unknown_types);
    std::printf("edge-score real=%d/%d rotated-control=%d/%d "
                "frame=(scale=%.6f x0=%.1f y0=%.1f x1=%.1f y1=%.1f) "
                "zero-width-stretch=(left=%.1f right=%.1f)\n",
                real_score, comparisons, rotated_score, comparisons,
                frame.scale, frame.x0, frame.y0, frame.x1, frame.y1,
                left_stretch_width, right_stretch_width);
    bf6_close(c);

    if (count <= 0 || got != count || viewport != 5 ||
        non_viewport_sentinel != count - viewport || fake >= 0 ||
        stats.unknown_types != 0 || real_score != comparisons ||
        rotated_score >= real_score || !adapted || !framed || invalid_framed ||
        std::fabs(frame.x0 - 40.f) > 0.001f ||
        std::fabs(frame.x1 - 1960.f) > 0.001f ||
        std::fabs(left_stretch_width - 40.f) > 0.001f ||
        std::fabs(right_stretch_width - 40.f) > 0.001f)
        return 1;
    return 0;
}
