#include "bf6_core.h"

#include <algorithm>
#include <cctype>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <string>
#include <vector>

static uint32_t name_hash(const char* s)
{
    uint32_t h = 5381u;
    if (!s) return h;
    for (; *s; s++) h = h * 33u ^ (uint8_t)std::tolower((uint8_t)*s);
    return h;
}

static std::vector<std::string> tabs(const std::string& line)
{
    std::vector<std::string> out;
    size_t a = 0;
    for (;;)
    {
        const size_t b = line.find('\t', a);
        if (b == std::string::npos) { out.push_back(line.substr(a)); break; }
        out.push_back(line.substr(a, b - a));
        a = b + 1;
    }
    if (!out.empty() && !out.back().empty() && out.back().back() == '\r') out.back().pop_back();
    return out;
}

int main(int argc, char** argv)
{
    if (argc < 2) { std::fprintf(stderr, "usage: rime_live_test <game-dir> [recorded-oracle.tsv]\n"); return 2; }
    char err[512]{};
    bf6_ctx* c = bf6_open(argv[1], err, (int)sizeof(err));
    if (!c) { std::fprintf(stderr, "open: %s\n", err); return 1; }
    const bool focusedMount = std::getenv("BF6_TEST_FRONTEND_MOUNT") != nullptr;
    if (!(focusedMount ? bf6_mount_frontend(c, err, (int)sizeof(err))
                       : bf6_mount_all(c, 1, err, (int)sizeof(err))))
    { std::fprintf(stderr, "mount: %s\n", err); bf6_close(c); return 1; }

    const char* root = (argc >= 3 && std::strncmp(argv[2], "common/", 7) == 0)
        ? argv[2] : "common/ui/weapons/screens/menuweaponscreen";

    const bool dump_ebx = argc >= 4 && std::strcmp(argv[3], "--dump-ebx") == 0;
    if (dump_ebx)
    {
        std::vector<char> dump(8u * 1024u * 1024u);
        int64_t needed = bf6_ebx_dump(c, root, 5, dump.data(), (int)dump.size());
        if (needed > (int64_t)dump.size())
        {
            dump.resize((size_t)needed);
            needed = bf6_ebx_dump(c, root, 5, dump.data(), (int)dump.size());
        }
        if (needed < 0)
        {
            std::fprintf(stderr, "ebx dump: %s\n", dump.data());
            bf6_close(c);
            return 1;
        }
        std::fputs(dump.data(), stdout);
        bf6_close(c);
        return 0;
    }

    bf6_rime_tree_stats st{};
    const int n = bf6_rime_tree(c, root, 6, nullptr, 0, &st);
    std::vector<bf6_rime_node> rows((size_t)(n > 0 ? n : 0));
    const int got = n > 0 ? bf6_rime_tree(c, root, 6, rows.data(), n, &st) : n;

    const bool dump_rows = argc >= 4 && std::strcmp(argv[3], "--dump-rows") == 0;
    if (dump_rows)
    {
        std::printf("row\tdepth\tparent\tinstance\tkind\tname\ttype\tpartition\tvisible\tcolor_source\timage\tfont\tpoint_size\tx_anchor\tx_offset\ty_anchor\ty_offset\tw\th\n");
        for (size_t i = 0; i < rows.size(); ++i)
        {
            const bf6_rime_node& r = rows[i];
            std::printf("%zu\t%d\t%d\t%d\t%d\t%s\t%s\t%s\t%d\t%d\t%s\t%s\t%.3f\t%.3f\t%.3f\t%.3f\t%.3f\t%.3f\t%.3f\n",
                        i, r.depth, r.parent, r.instance, r.kind, r.name,
                        r.type_name, r.partition, r.visible, r.color_source,
                        r.image_asset, r.font_style, r.point_size,
                        r.h.anchor_start, r.h.offset_start,
                        r.v.anchor_start, r.v.offset_start, r.width, r.height);
        }
    }

    const bool dump_connections = argc >= 4 &&
        std::strcmp(argv[3], "--dump-connections") == 0;
    if (dump_connections)
    {
        const int nc = bf6_rime_connections(c, root, nullptr, 0);
        std::vector<bf6_rime_connection> connections((size_t)(nc > 0 ? nc : 0));
        if (nc > 0) bf6_rime_connections(c, root, connections.data(), nc);
        std::vector<int> by_instance;
        int max_instance = -1;
        for (const bf6_rime_node& r : rows) max_instance = (std::max)(max_instance, r.instance);
        by_instance.assign((size_t)(max_instance + 1), -1);
        for (size_t i = 0; i < rows.size(); ++i)
            if (rows[i].instance >= 0 && rows[i].instance <= max_instance)
                by_instance[(size_t)rows[i].instance] = (int)i;
        std::printf("source_instance\tsource_name\tsource_field\ttarget_instance\ttarget_name\ttarget_field\towner_anchor\tmode\n");
        for (const bf6_rime_connection& cn : connections)
        {
            const int sr = cn.source >= 0 && cn.source <= max_instance
                ? by_instance[(size_t)cn.source] : -1;
            const int tr = cn.target >= 0 && cn.target <= max_instance
                ? by_instance[(size_t)cn.target] : -1;
            std::string owner;
            for (int row = tr, guard = 0; row >= 0 && guard < 16; ++guard)
            {
                const std::string name = rows[(size_t)row].name;
                if (name.size() > 9 && name.compare(name.size() - 9, 9, "EndAnchor") == 0)
                { owner = name; break; }
                row = rows[(size_t)row].parent;
            }
            std::printf("%d\t%s\t0x%08X\t%d\t%s\t0x%08X\t%s\t%d\n",
                        cn.source, sr >= 0 ? rows[(size_t)sr].name : "",
                        cn.source_field, cn.target,
                        tr >= 0 ? rows[(size_t)tr].name : "", cn.target_field,
                        owner.c_str(), cn.mode);
        }
    }

    const bool dump_conditionals = argc >= 4 &&
        std::strcmp(argv[3], "--dump-conditionals") == 0;
    if (dump_conditionals)
    {
        const int nc = bf6_rime_conditional_floats(c, root, nullptr, 0);
        std::vector<bf6_rime_conditional_float> conditional(
            (size_t)(nc > 0 ? nc : 0));
        if (nc > 0)
            bf6_rime_conditional_floats(c, root, conditional.data(), nc);
        std::printf("instance\tvalue_if_true\tvalue_if_false\tauthored_condition\n");
        for (const bf6_rime_conditional_float& row : conditional)
            std::printf("%d\t%.6g\t%.6g\t%d\n", row.instance,
                        row.value_if_true, row.value_if_false,
                        row.authored_condition);
        const int fakeConditional = bf6_rime_conditional_floats(
            c, "common/ui/__control__/not_a_real_screen", nullptr, 0);
        std::printf("conditional-count=%d fake-root=%d\n", nc, fakeConditional);
    }

    const bool dump_interfaces = argc >= 4 &&
        std::strcmp(argv[3], "--dump-interfaces") == 0;
    if (dump_interfaces)
    {
        const int ni = bf6_rime_interface_descriptors(c, root, nullptr, 0);
        std::vector<int32_t> interfaces((size_t)(ni > 0 ? ni : 0));
        if (ni > 0)
            bf6_rime_interface_descriptors(c, root, interfaces.data(), ni);
        std::printf("interface-instance\n");
        for (int32_t instance : interfaces) std::printf("%d\n", instance);
        const int fakeInterface = bf6_rime_interface_descriptors(
            c, "common/ui/__control__/not_a_real_screen", nullptr, 0);
        std::printf("interface-count=%d fake-root=%d\n", ni, fakeInterface);
        const int nf = bf6_rime_interface_fields(c, root, nullptr, 0);
        std::vector<bf6_rime_interface_field> fields((size_t)(nf > 0 ? nf : 0));
        if (nf > 0) bf6_rime_interface_fields(c, root, fields.data(), nf);
        std::printf("field_id\taccess\tkind\tbool\tint\tuint\treal\tstring\n");
        for (const bf6_rime_interface_field& field : fields)
            std::printf("0x%08X\t%d\t%d\t%d\t%lld\t%llu\t%.9g\t%s\n",
                        field.field_id, field.access_type, field.value_kind,
                        field.bool_value, (long long)field.int_value,
                        (unsigned long long)field.uint_value, field.real_value,
                        field.string_value);
        const int fakeFields = bf6_rime_interface_fields(
            c, "common/ui/__control__/not_a_real_screen", nullptr, 0);
        std::printf("interface-field-count=%d fake-root=%d\n", nf, fakeFields);
    }

    const bool dump_shapes = argc >= 4 &&
        std::strcmp(argv[3], "--dump-shapes") == 0;
    if (dump_shapes)
    {
        for (size_t row = 0; row < rows.size(); ++row)
        {
            const bf6_rime_node& r = rows[row];
            if (r.kind != BF6_RIME_VECTOR_SHAPE) continue;
            bf6_rime_shape_info si{};
            if (bf6_rime_shape(c, r.partition, r.instance, &si,
                               nullptr, 0, nullptr, 0, nullptr, 0) <= 0)
                continue;
            std::printf("shape row=%zu name=%s part=%s instance=%d style=%d "
                        "size=%.3fx%.3f thickness=%.3f verts=%d indices=%d corners=%d\n",
                        row, r.name, r.partition, r.instance, si.draw_style,
                        si.size[0], si.size[1], si.thickness, si.vertex_count,
                        si.index_count, si.corner_count);
            std::vector<bf6_rime_shape_vertex> vertices((size_t)si.vertex_count);
            std::vector<unsigned short> indices((size_t)si.index_count);
            std::vector<bf6_rime_shape_corner> corners((size_t)si.corner_count);
            bf6_rime_shape(c, r.partition, r.instance, &si,
                           vertices.data(), si.vertex_count,
                           indices.data(), si.index_count,
                           corners.data(), si.corner_count);
            for (size_t i = 0; i < vertices.size(); ++i)
                std::printf("  v%zu a=(%.3f,%.3f) o=(%.3f,%.3f) rgba=(%.3f,%.3f,%.3f,%.3f)\n",
                            i, vertices[i].anchor[0], vertices[i].anchor[1],
                            vertices[i].offset[0], vertices[i].offset[1],
                            vertices[i].color[0], vertices[i].color[1],
                            vertices[i].color[2], vertices[i].color[3]);
            std::printf("  ix");
            for (unsigned short index : indices) std::printf(" %u", (unsigned)index);
            std::printf("\n");
        }
    }

    const bool dump_lines = argc >= 4 &&
        std::strcmp(argv[3], "--dump-lines") == 0;
    if (dump_lines)
    {
        int decoded = 0;
        for (size_t row = 0; row < rows.size(); ++row)
        {
            const bf6_rime_node& r = rows[row];
            if (r.kind != BF6_RIME_LINE) continue;
            bf6_rime_line_info li{};
            const int count = bf6_rime_line(c, r.partition, r.instance,
                                             &li, nullptr, 0);
            std::printf("line row=%zu name=%s part=%s instance=%d points=%d "
                        "width=%.3f cap=%d relative=%d\n",
                        row, r.name, r.partition, r.instance, count,
                        li.width, li.cap_type, li.relative_coordinates);
            if (count < 0 || count != li.point_count) continue;
            std::vector<bf6_rime_line_point> points((size_t)count);
            if (bf6_rime_line(c, r.partition, r.instance, &li,
                              points.data(), count) != count) continue;
            ++decoded;
            for (size_t i = 0; i < points.size(); ++i)
                std::printf("  p%zu=(%.6g,%.6g)\n", i, points[i].x, points[i].y);
        }
        const int fake = bf6_rime_line(c, root, 0x7fffffff, nullptr, nullptr, 0);
        std::printf("line-decoded=%d fake-instance=%d\n", decoded, fake);
    }

    const bool dump_svgs = argc >= 4 &&
        std::strcmp(argv[3], "--dump-svgs") == 0;
    if (dump_svgs)
    {
        int decoded = 0, cubic = 0, closed = 0, total_contours = 0;
        std::printf("row\tname\tpartition\tinstance\timage\trgb\talpha\tcanvas\tshapes\tcontours\tpoints\tstatus\n");
        for (size_t row = 0; row < rows.size(); ++row)
        {
            const bf6_rime_node& r = rows[row];
            if (r.kind != BF6_RIME_SVG || !r.image_asset[0]) continue;
            bf6_rime_svg_info si{};
            const int count = bf6_rime_svg(c, r.image_asset, &si,
                                            nullptr, 0, nullptr, 0);
            std::printf("%zu\t%s\t%s\t%d\t%s\t%06X\t%.6g\t%.3fx%.3f\t%d\t%d\t%d\t%d\n",
                        row, r.name, r.partition, r.instance, r.image_asset,
                        r.color_rgb & 0xFFFFFFu, r.alpha,
                        si.canvas[0], si.canvas[1], si.shape_count,
                        si.contour_count, si.point_count, count);
            if (count < 0) continue;
            std::vector<bf6_rime_svg_contour> contours((size_t)si.contour_count);
            std::vector<bf6_rime_svg_point> points((size_t)si.point_count);
            const int got_svg = bf6_rime_svg(c, r.image_asset, &si,
                                              contours.data(), (int)contours.size(),
                                              points.data(), (int)points.size());
            if (got_svg != count) continue;
            ++decoded;
            for (size_t ci = 0; ci < contours.size(); ++ci)
            {
                const bf6_rime_svg_contour& co = contours[ci];
                const bool grammar = co.point_count >= 4 &&
                    ((co.point_count - 1) % 3) == 0;
                bool is_closed = false;
                double signed_area = 0.0;
                if (co.point_first >= 0 && co.point_count > 0 &&
                    co.point_first + co.point_count <= (int)points.size())
                {
                    const bf6_rime_svg_point& a = points[(size_t)co.point_first];
                    const bf6_rime_svg_point& b = points[(size_t)(co.point_first + co.point_count - 1)];
                    is_closed = std::abs(a.x - b.x) <= 1e-5f &&
                                std::abs(a.y - b.y) <= 1e-5f;
                    bf6_rime_svg_point previous = a;
                    for (int segment = 0; segment + 3 < co.point_count;
                         segment += 3)
                    {
                        const bf6_rime_svg_point& p0 =
                            points[(size_t)(co.point_first + segment)];
                        const bf6_rime_svg_point& p1 =
                            points[(size_t)(co.point_first + segment + 1)];
                        const bf6_rime_svg_point& p2 =
                            points[(size_t)(co.point_first + segment + 2)];
                        const bf6_rime_svg_point& p3 =
                            points[(size_t)(co.point_first + segment + 3)];
                        for (int sample = 1; sample <= 16; ++sample)
                        {
                            const double t = sample / 16.0;
                            const double u = 1.0 - t;
                            bf6_rime_svg_point current{};
                            current.x = (float)(u*u*u*p0.x + 3*u*u*t*p1.x +
                                                3*u*t*t*p2.x + t*t*t*p3.x);
                            current.y = (float)(u*u*u*p0.y + 3*u*u*t*p1.y +
                                                3*u*t*t*p2.y + t*t*t*p3.y);
                            signed_area += (double)previous.x * current.y -
                                           (double)current.x * previous.y;
                            previous = current;
                        }
                    }
                    signed_area *= 0.5;
                }
                ++total_contours;
                if (grammar) ++cubic;
                if (is_closed) ++closed;
                std::printf("  contour=%zu shape=%d first=%d count=%d flag=%d "
                            "bounds=%.3f,%.3f,%.3f,%.3f cubic=%d closed=%d area=%.6g\n",
                            ci, co.shape, co.point_first, co.point_count, co.flag,
                            co.bounds[0], co.bounds[1], co.bounds[2], co.bounds[3],
                            grammar ? 1 : 0, is_closed ? 1 : 0, signed_area);
            }
        }
        const int fake_svg = bf6_rime_svg(
            c, "common/ui/__control__/not_a_real_svg", nullptr,
            nullptr, 0, nullptr, 0);
        std::printf("svg-decoded=%d contours=%d cubic=%d closed=%d fake=%d\n",
                    decoded, total_contours, cubic, closed, fake_svg);
    }

    for (const bf6_rime_node& row : rows)
        if (row.item_template[0] || row.grid_static_segment_item_count >= 0)
            std::printf("list name=%s type=%s template=%s static=%d col=%.3f row=%.3f col_gap=%.3f row_gap=%.3f dist=%d count_mode=%d col_flow=%d row_flow=%d fit=%d\n",
                        row.name, row.type_name, row.item_template,
                        row.grid_static_segment_item_count,
                        row.grid_column_size, row.grid_row_size,
                        row.grid_column_spacing, row.grid_row_spacing,
                        row.grid_segment_distribution, row.grid_segment_count_mode,
                        row.grid_column_flow_direction, row.grid_row_flow_direction,
                        row.grid_item_fit_content);
    if (std::strcmp(root, "common/ui/weapons/screens/menuweaponscreen") != 0)
        for (const bf6_rime_node& row : rows)
            if (row.depth <= 3)
                std::printf("node depth=%d parent=%d kind=%d name=%s type=%s w=%.3f h=%.3f H=(%.3f %.3f %.3f %.3f %.3f) V=(%.3f %.3f %.3f %.3f %.3f)\n",
                            row.depth, row.parent, row.kind, row.name, row.type_name,
                            row.width, row.height,
                            row.h.anchor_start, row.h.anchor_end, row.h.offset_start,
                            row.h.offset_end, row.h.pivot,
                            row.v.anchor_start, row.v.anchor_end, row.v.offset_start,
                            row.v.offset_end, row.v.pivot);

    // Negative control: an impossible partition must not produce a complete-
    // looking empty tree or reuse the previous root's cache.
    const int fake = bf6_rime_tree(c, "common/ui/__control__/not_a_real_screen",
                                   6, nullptr, 0, nullptr);

    int hash_match = 0, hash_total = 0, shuffled_match = 0;
    int element_hash_match = 0, element_hash_total = 0;
    int point_axes = 0, point_inset_match = 0;
    for (int i = 0; i < got; i++)
    {
        const bf6_rime_node& r = rows[(size_t)i];
        if (r.name[0] && r.name_hash)
        {
            hash_total++;
            if (name_hash(r.name) == r.name_hash) hash_match++;
            if (r.kind != BF6_RIME_WIDGET_REFERENCE)
            {
                element_hash_total++;
                if (name_hash(r.name) == r.name_hash) element_hash_match++;
            }
            const bf6_rime_node& shifted = rows[(size_t)((i + 1) % got)];
            if (shifted.name[0] && name_hash(shifted.name) == r.name_hash) shuffled_match++;
        }
        const bf6_rime_axis* axes[2] = { &r.h, &r.v };
        for (const bf6_rime_axis* a : axes)
            if (a->anchor_start == a->anchor_end)
            {
                point_axes++;
                if (a->offset_start == -a->offset_end) point_inset_match++;
            }
    }

    std::printf("live rows=%d gated=%d unknown=%d unresolved=%d cycles=%d depth_limited=%d duplicate_guid_refs=%d instance_disambiguated=%d name_disambiguated=%d identity_collisions=%d equivalent_aliases=%d ambiguous=%d\n",
                got, st.gated_nodes, st.unknown_types, st.unresolved_refs,
                st.cycles, st.depth_limited, st.duplicate_guid_refs,
                st.instance_disambiguated_refs, st.name_disambiguated_refs,
                st.identity_collision_refs, st.equivalent_alias_refs,
                st.ambiguous_refs);
    std::printf("name-hash real=%d/%d shuffled=%d/%d\n",
                hash_match, hash_total, shuffled_match, hash_total);
    std::printf("name-hash ordinary-elements=%d/%d\n",
                element_hash_match, element_hash_total);
    std::printf("point-anchor inset control=%d/%d fake-root=%d\n",
                point_inset_match, point_axes, fake);
    if (st.unresolved_refs)
        for (int i = 0; i < got; i++)
            if (rows[(size_t)i].kind == BF6_RIME_WIDGET_REFERENCE)
                std::printf("ref %-40s -> %s\n", rows[(size_t)i].name,
                            rows[(size_t)i].reference);
    static const int kRecordedOracleRows = 419;
    std::printf("recorded-oracle rows=%d delta=%+d\n",
                kRecordedOracleRows, got - kRecordedOracleRows);

    int oracle_rows = 0, oracle_match = 0, oracle_rotated_name_match = 0;
    int oracle_lines = 0, oracle_line_match = 0, oracle_line_rotated_match = 0;
    int oracle_progress = 0, oracle_progress_match = 0;
    int progress_orientation_semantic = 0, progress_orientation_flipped = 0;
    int progress_orientation_total = 0;
    int oracle_borders = 0, oracle_border_match = 0;
    const int line_fake_instance = bf6_rime_line(c, root, 0x7fffffff,
                                                  nullptr, nullptr, 0);
    if (argc >= 3 && std::strncmp(argv[2], "common/", 7) != 0)
    {
        std::ifstream f(argv[2]);
        std::string line;
        std::vector<std::vector<std::string>> rec;
        if (std::getline(f, line))
        {
            const std::vector<std::string> h = tabs(line);
            int cdepth = -1, ctype = -1, cname = -1, cpart = -1;
            int clpc = -1, clw = -1, clcap = -1, clrel = -1;
            int cprogress = -1, csegcount = -1, cseggap = -1;
            int cbthick = -1, cbalign = -1, cbgrad = -1;
            for (size_t i = 0; i < h.size(); i++)
            {
                if (h[i] == "depth") cdepth = (int)i;
                else if (h[i] == "element_type") ctype = (int)i;
                else if (h[i] == "element_name") cname = (int)i;
                else if (h[i] == "partition") cpart = (int)i;
                else if (h[i] == "line_point_count") clpc = (int)i;
                else if (h[i] == "line_width") clw = (int)i;
                else if (h[i] == "line_cap") clcap = (int)i;
                else if (h[i] == "line_relative_coords") clrel = (int)i;
                else if (h[i] == "progress") cprogress = (int)i;
                else if (h[i] == "segment_count") csegcount = (int)i;
                else if (h[i] == "segment_gap") cseggap = (int)i;
                else if (h[i] == "border_thickness") cbthick = (int)i;
                else if (h[i] == "border_alignment") cbalign = (int)i;
                else if (h[i] == "border_gradient_dir") cbgrad = (int)i;
            }
            while (std::getline(f, line)) if (!line.empty()) rec.push_back(tabs(line));
            oracle_rows = (int)rec.size();
            std::vector<int> line_rows;
            for (int i = 0; i < got && i < oracle_rows; ++i)
                if (rows[(size_t)i].kind == BF6_RIME_LINE) line_rows.push_back(i);
            for (int i = 0; i < got && i < oracle_rows; i++)
            {
                const std::vector<std::string>& r = rec[(size_t)i];
                const bf6_rime_node& live = rows[(size_t)i];
                if (cdepth < 0 || ctype < 0 || cname < 0 || cpart < 0 ||
                    (int)r.size() <= std::max(std::max(cdepth, ctype), std::max(cname, cpart)))
                    continue;
                const std::string& typ = r[(size_t)ctype];
                const bool type_ok = typ.find('-') != std::string::npos
                    ? typ == live.type_guid : typ == live.type_name;
                const bool depth_ok = std::atoi(r[(size_t)cdepth].c_str()) == live.depth;
                const bool name_ok = r[(size_t)cname] == live.name;
                const bool partition_ok = r[(size_t)cpart] == live.partition;
                if (depth_ok && type_ok && name_ok && partition_ok)
                    oracle_match++;
                else
                    std::printf("oracle mismatch row=%d depth=%d/%s type=%s/%s name=%s/%s partition=%s/%s\n",
                                i, live.depth, r[(size_t)cdepth].c_str(), live.type_name,
                                typ.c_str(), live.name, r[(size_t)cname].c_str(),
                                live.partition, r[(size_t)cpart].c_str());
                const std::vector<std::string>& shifted = rec[(size_t)((i + 1) % oracle_rows)];
                if ((int)shifted.size() > cname && shifted[(size_t)cname] == live.name)
                    oracle_rotated_name_match++;
            }
            auto line_cap = [](const std::string& s) {
                if (s == "None") return 0;
                if (s == "Square") return 1;
                if (s == "Rounded") return 2;
                return -1;
            };
            auto line_matches = [&](const bf6_rime_line_info& li,
                                    const std::vector<std::string>& expected) {
                const int need = std::max(std::max(clpc, clw), std::max(clcap, clrel));
                if (clpc < 0 || clw < 0 || clcap < 0 || clrel < 0 ||
                    (int)expected.size() <= need) return false;
                return li.point_count == std::atoi(expected[(size_t)clpc].c_str()) &&
                       std::fabs(li.width - std::strtof(expected[(size_t)clw].c_str(), nullptr)) <= 1e-5f &&
                       li.cap_type == line_cap(expected[(size_t)clcap]) &&
                       li.relative_coordinates == std::atoi(expected[(size_t)clrel].c_str());
            };
            for (size_t j = 0; j < line_rows.size(); ++j)
            {
                const int i = line_rows[j];
                const bf6_rime_node& live = rows[(size_t)i];
                bf6_rime_line_info li{};
                const int count = bf6_rime_line(c, live.partition, live.instance,
                                                 &li, nullptr, 0);
                ++oracle_lines;
                if (count == li.point_count && line_matches(li, rec[(size_t)i]))
                    ++oracle_line_match;
                const int shifted_i = line_rows[(j + 1) % line_rows.size()];
                if (count == li.point_count && line_matches(li, rec[(size_t)shifted_i]))
                    ++oracle_line_rotated_match;
            }
            auto outline_alignment = [](const std::string& s) {
                if (s == "Inside") return 0;
                if (s == "Center") return 1;
                if (s == "Outside") return 2;
                return -1;
            };
            auto gradient_direction = [](const std::string& s) {
                if (s == "Vertical") return 0;
                if (s == "Horizontal") return 1;
                if (s == "ForwardDiagonal") return 2;
                if (s == "BackwardDiagonal") return 3;
                return -1;
            };
            for (int i = 0; i < got && i < oracle_rows; ++i)
            {
                const bf6_rime_node& live = rows[(size_t)i];
                const std::vector<std::string>& expected = rec[(size_t)i];
                if (live.kind == BF6_RIME_PROGRESS)
                {
                    ++oracle_progress;
                    const int need = std::max(cprogress, std::max(csegcount, cseggap));
                    const bool progress_ok =
                        cprogress >= 0 && csegcount >= 0 && cseggap >= 0 &&
                        (int)expected.size() > need &&
                        std::fabs(live.progress - std::strtof(expected[(size_t)cprogress].c_str(), nullptr)) <= 1e-5f &&
                        live.progress_segment_count == std::atoi(expected[(size_t)csegcount].c_str()) &&
                        /* The oracle intentionally stores three decimals. */
                        std::fabs(live.progress_segment_gap - std::strtof(expected[(size_t)cseggap].c_str(), nullptr)) <= 5.1e-4f;
                    if (progress_ok)
                        ++oracle_progress_match;
                    else
                        std::printf("progress mismatch name=%s part=%s live=(%.6g,%d,%.6g) oracle=(%s,%s,%s) orient=%d\n",
                                    live.name, live.partition, live.progress,
                                    live.progress_segment_count,
                                    live.progress_segment_gap,
                                    cprogress >= 0 && (int)expected.size() > cprogress ? expected[(size_t)cprogress].c_str() : "?",
                                    csegcount >= 0 && (int)expected.size() > csegcount ? expected[(size_t)csegcount].c_str() : "?",
                                    cseggap >= 0 && (int)expected.size() > cseggap ? expected[(size_t)cseggap].c_str() : "?",
                                    live.progress_orientation);
                    const std::string part = live.partition;
                    int semantic = -1;
                    if (part.find("horizontal") != std::string::npos) semantic = 0;
                    else if (part.find("vertical") != std::string::npos) semantic = 1;
                    if (semantic >= 0)
                    {
                        std::printf("progress orientation name=%s part=%s live=%d semantic=%d\n",
                                    live.name, live.partition,
                                    live.progress_orientation, semantic);
                        ++progress_orientation_total;
                        if (live.progress_orientation == semantic)
                            ++progress_orientation_semantic;
                        if (live.progress_orientation == 1 - semantic)
                            ++progress_orientation_flipped;
                    }
                }
                else if (live.kind == BF6_RIME_BORDER)
                {
                    ++oracle_borders;
                    const int need = std::max(cbthick, std::max(cbalign, cbgrad));
                    if (cbthick >= 0 && cbalign >= 0 && cbgrad >= 0 &&
                        (int)expected.size() > need &&
                        std::fabs(live.border_thickness - std::strtof(expected[(size_t)cbthick].c_str(), nullptr)) <= 1e-5f &&
                        live.border_alignment == outline_alignment(expected[(size_t)cbalign]) &&
                        live.border_gradient_direction == gradient_direction(expected[(size_t)cbgrad]))
                        ++oracle_border_match;
                }
            }
        }
        std::printf("oracle row identity=%d/%d rotated-name-control=%d/%d\n",
                    oracle_match, oracle_rows, oracle_rotated_name_match, oracle_rows);
        std::printf("oracle line paint=%d/%d rotated-pair-control=%d/%d fake-instance=%d\n",
                    oracle_line_match, oracle_lines, oracle_line_rotated_match,
                    oracle_lines, line_fake_instance);
        std::printf("oracle progress paint=%d/%d orientation-name=%d/%d flipped-control=%d/%d\n",
                    oracle_progress_match, oracle_progress,
                    progress_orientation_semantic, progress_orientation_total,
                    progress_orientation_flipped, progress_orientation_total);
        std::printf("oracle border paint=%d/%d\n",
                    oracle_border_match, oracle_borders);
    }
    const bool pass = got == kRecordedOracleRows && got == n && st.nodes == got &&
                      st.gated_nodes == got && st.unknown_types == 0 &&
                      st.unresolved_refs == 0 && st.cycles == 0 && st.depth_limited == 0 &&
                      st.duplicate_guid_refs > 0 &&
                      st.instance_disambiguated_refs + st.name_disambiguated_refs +
                          st.identity_collision_refs + st.equivalent_alias_refs ==
                          st.duplicate_guid_refs &&
                      st.ambiguous_refs == 0 &&
                      hash_total > 0 && hash_match > shuffled_match &&
                      element_hash_total > 0 && element_hash_match > shuffled_match &&
                      point_axes > 0 && point_inset_match == point_axes &&
                      fake < 0 && line_fake_instance < 0 &&
                      (argc < 3 || (oracle_rows == got && oracle_match == got &&
                                   oracle_rotated_name_match < oracle_match &&
                                   oracle_lines > 0 && oracle_line_match == oracle_lines &&
                                   oracle_line_rotated_match < oracle_line_match &&
                                   oracle_progress > 0 &&
                                   oracle_progress_match == oracle_progress &&
                                   progress_orientation_total > 0 &&
                                   progress_orientation_semantic == progress_orientation_total &&
                                   progress_orientation_flipped < progress_orientation_semantic &&
                                   oracle_borders > 0 &&
                                   oracle_border_match == oracle_borders));
    bf6_close(c);
    return pass ? 0 : 1;
}
