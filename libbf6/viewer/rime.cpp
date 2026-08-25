#include "rime.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <map>

namespace rime {

Kind kind_of(const std::string& t)
{
    if (t.rfind("RimeWidgetReference", 0) == 0)        return Kind::WidgetReference;
    if (t == "RimeStackContainerElementData")          return Kind::StackContainer;
    if (t == "RimeContainerElementData")               return Kind::Container;
    if (t == "RimeLabelElementData")                   return Kind::Label;
    if (t == "RimeLayerEntityData")                    return Kind::LayerEntity;
    if (t == "RimeRepeatShapeElementData")             return Kind::RepeatShape;
    if (t == "RimeVectorShapeElementData")             return Kind::VectorShape;
    if (t == "RimeFillElementData")                    return Kind::Fill;
    if (t == "RimeSvgElementData")                     return Kind::Svg;
    if (t == "RimeMovieElementData")                   return Kind::Movie;
    // Stretch containers hold the edge gradient fills; they lay out and their
    // Fill children draw.
    if (t == "RimeViewportStretchContainerElementData") return Kind::Container;
    // The widget-reference element ships as a bare type guid in retail.
    if (t.rfind("ca959de9", 0) == 0)                    return Kind::WidgetReference;
    return Kind::Unknown;
}

namespace {

// An empty cell is not a zero: "no anchor authored" and "anchor at 0.0" mean
// different things, and collapsing them puts full-bleed layers at zero size.
bool cell(const std::string& s, float& out)
{
    if (s.empty()) return false;
    out = (float)atof(s.c_str());
    return true;
}

std::vector<std::string> split_tab(const std::string& line)
{
    std::vector<std::string> f;
    size_t a = 0;
    for (;;)
    {
        const size_t b = line.find('\t', a);
        if (b == std::string::npos) { f.push_back(line.substr(a)); break; }
        f.push_back(line.substr(a, b - a));
        a = b + 1;
    }
    // Authored names carry trailing padding spaces in the partition; strip so
    // a name compares equal to the one a widget reference asks for.
    for (std::string& s : f)
    {
        while (!s.empty() && (s.back() == ' ' || s.back() == '\r')) s.pop_back();
        while (!s.empty() && s.front() == ' ') s.erase(s.begin());
    }
    return f;
}

}  // namespace

bool load_tree_tsv(const char* path, std::vector<Screen>& out, std::string& err)
{
    FILE* f = fopen(path, "rb");
    if (!f) { err = std::string("cannot open ") + path; return false; }

    std::string all;
    char buf[8192];
    size_t n;
    while ((n = fread(buf, 1, sizeof(buf), f)) > 0) all.append(buf, n);
    fclose(f);

    std::vector<std::string> lines;
    for (size_t a = 0; a < all.size();)
    {
        size_t b = all.find('\n', a);
        if (b == std::string::npos) b = all.size();
        lines.push_back(all.substr(a, b - a));
        a = b + 1;
    }
    if (lines.size() < 2) { err = "tree file has no rows"; return false; }

    std::map<std::string, int> col;
    {
        const std::vector<std::string> h = split_tab(lines[0]);
        for (size_t i = 0; i < h.size(); i++) col[h[i]] = (int)i;
    }
    auto need = [&](const char* c) { return col.count(c) ? col[c] : -1; };
    const int cPart = need("partition"), cDepth = need("depth");
    const int cType = need("element_type"), cName = need("element_name");
    if (cPart < 0 || cDepth < 0 || cType < 0) { err = "tree file missing columns"; return false; }

    std::map<std::string, size_t> index;
    for (size_t li = 1; li < lines.size(); li++)
    {
        if (lines[li].empty()) continue;
        const std::vector<std::string> r = split_tab(lines[li]);
        if ((int)r.size() <= cType) continue;

        const std::string part = r[(size_t)cPart];
        if (index.find(part) == index.end())
        {
            index[part] = out.size();
            out.push_back(Screen{ part, {} });
        }
        Screen& s = out[index[part]];

        Element e;
        e.type_name = r[(size_t)cType];
        e.kind = kind_of(e.type_name);
        e.depth = atoi(r[(size_t)cDepth].c_str());
        if (cName >= 0 && (int)r.size() > cName) e.name = r[(size_t)cName];

        auto ax = [&](const char* a, const char* b, const char* c, const char* d,
                      const char* p, const char* w, Axis& out_axis)
        {
            const int ia = need(a), ib = need(b), ic = need(c), id = need(d);
            const int ip = need(p), iw = need(w);
            bool any = false;
            if (ia >= 0 && (int)r.size() > ia) any |= cell(r[(size_t)ia], out_axis.anchor_start);
            if (ib >= 0 && (int)r.size() > ib) any |= cell(r[(size_t)ib], out_axis.anchor_end);
            if (ic >= 0 && (int)r.size() > ic) any |= cell(r[(size_t)ic], out_axis.offset_start);
            if (id >= 0 && (int)r.size() > id) any |= cell(r[(size_t)id], out_axis.offset_end);
            if (ip >= 0 && (int)r.size() > ip) cell(r[(size_t)ip], out_axis.pivot);
            if (iw >= 0 && (int)r.size() > iw) cell(r[(size_t)iw], out_axis.weight);
            out_axis.present = any;
        };
        ax("h_anchor_start", "h_anchor_end", "h_offset_start", "h_offset_end",
           "h_pivot", "h_weight", e.h);
        ax("v_anchor_start", "v_anchor_end", "v_offset_start", "v_offset_end",
           "v_pivot", "v_weight", e.v);

        const int cSt = need("stack_orientation"), cSp = need("item_spacing");
        if (cSt >= 0 && (int)r.size() > cSt && !r[(size_t)cSt].empty())
            e.stack_orientation = atoi(r[(size_t)cSt].c_str());
        if (cSp >= 0 && (int)r.size() > cSp && !r[(size_t)cSp].empty())
            e.item_spacing = (float)atof(r[(size_t)cSp].c_str());
        const char* pads[4] = { "pad_l", "pad_t", "pad_r", "pad_b" };
        float* dst[4] = { &e.pad_l, &e.pad_t, &e.pad_r, &e.pad_b };
        for (int i = 0; i < 4; i++)
        {
            const int ci = need(pads[i]);
            if (ci >= 0 && (int)r.size() > ci) cell(r[(size_t)ci], *dst[i]);
        }
        const int cRef = need("references_widget");
        if (cRef >= 0 && (int)r.size() > cRef) e.references_widget = r[(size_t)cRef];

        s.elements.push_back(std::move(e));
    }
    return true;
}

namespace {

// "common/ui/.../foo.ebx" -> "common/ui/.../foo", so a reference compares
// equal to the partition key it names.
std::string strip_ebx(std::string p)
{
    for (char& ch : p) ch = (char)(ch >= 'A' && ch <= 'Z' ? ch + 32 : ch);
    if (p.size() > 4 && p.compare(p.size() - 4, 4, ".ebx") == 0) p.resize(p.size() - 4);
    return p;
}

void inline_tree(const std::vector<Screen>& all,
                 const std::map<std::string, size_t>& index,
                 size_t src, int base_depth, int depth_left,
                 std::vector<std::string>& open,
                 Screen& out, int* unresolved)
{
    const Screen& s = all[src];
    for (const Element& e : s.elements)
    {
        Element c = e;
        c.depth = base_depth + e.depth;
        out.elements.push_back(c);

        if (e.kind != Kind::WidgetReference || e.references_widget.empty()) continue;
        const std::string key = strip_ebx(e.references_widget);

        auto it = index.find(key);
        if (it == index.end()) { if (unresolved) (*unresolved)++; continue; }
        if (depth_left <= 0) continue;

        // A widget that reaches itself would recurse forever. Cheap guard: a
        // partition already open on this path is not entered again.
        bool cycle = false;
        for (const std::string& o : open) if (o == key) { cycle = true; break; }
        if (cycle) continue;

        open.push_back(key);
        inline_tree(all, index, it->second, c.depth + 1, depth_left - 1, open, out, unresolved);
        open.pop_back();
    }
}

}  // namespace

Screen instantiate(const std::vector<Screen>& all, size_t root, int max_depth,
                   int* unresolved)
{
    Screen out;
    if (root >= all.size()) return out;
    out.partition = all[root].partition;
    if (unresolved) *unresolved = 0;

    std::map<std::string, size_t> index;
    for (size_t i = 0; i < all.size(); i++) index[strip_ebx(all[i].partition)] = i;

    std::vector<std::string> open;
    open.push_back(strip_ebx(all[root].partition));
    inline_tree(all, index, root, 0, max_depth, open, out, unresolved);
    return out;
}

void solve(Screen& s, float canvas_w, float canvas_h)
{
    // Depth gives the tree: the nearest preceding element of depth-1 is the
    // parent. The rows are authored in traversal order, so this is exact and
    // needs no id resolution.
    std::vector<int> stack;
    for (size_t i = 0; i < s.elements.size(); i++)
    {
        Element& e = s.elements[i];
        while (!stack.empty() && s.elements[(size_t)stack.back()].depth >= e.depth)
            stack.pop_back();
        e.parent = stack.empty() ? -1 : stack.back();
        stack.push_back((int)i);
    }

    for (Element& e : s.elements)
    {
        float px0 = 0.f, py0 = 0.f, px1 = canvas_w, py1 = canvas_h;
        if (e.parent >= 0)
        {
            const Element& p = s.elements[(size_t)e.parent];
            px0 = p.x0; py0 = p.y0; px1 = p.x1; py1 = p.y1;
        }

        // THE BOX LAW, single site, currently the reading that reproduces the
        // bottom-bar case:
        //     edge = parent_start + anchor * parent_extent + offset
        // applied to both edges independently. This makes
        //     anchor 1..1, offset -20..20  ->  a 40 px band on the far edge
        // which is right, and
        //     anchor 0..0, offset 16..-16  ->  a NEGATIVE extent
        // which is not. The second is flagged rather than clamped silently, so
        // a wrong law shows up as a visible complaint instead of a plausible
        // rectangle. Replace this block, and only this block, when measured.
        const float pw = px1 - px0, ph = py1 - py0;
        if (e.h.present) { e.x0 = px0 + e.h.anchor_start * pw + e.h.offset_start;
                           e.x1 = px0 + e.h.anchor_end   * pw + e.h.offset_end; }
        else             { e.x0 = px0; e.x1 = px1; }
        if (e.v.present) { e.y0 = py0 + e.v.anchor_start * ph + e.v.offset_start;
                           e.y1 = py0 + e.v.anchor_end   * ph + e.v.offset_end; }
        else             { e.y0 = py0; e.y1 = py1; }

        e.solved = (e.x1 >= e.x0) && (e.y1 >= e.y0);
    }
}


bool load_solved_tsv(const char* path, std::vector<Screen>& out, std::string& err)
{
    FILE* f = fopen(path, "rb");
    if (!f) { err = std::string("cannot open ") + path; return false; }
    std::string all;
    char buf[8192];
    size_t n;
    while ((n = fread(buf, 1, sizeof(buf), f)) > 0) all.append(buf, n);
    fclose(f);

    std::vector<std::string> lines;
    for (size_t a = 0; a < all.size();)
    {
        size_t b = all.find('\n', a);
        if (b == std::string::npos) b = all.size();
        lines.push_back(all.substr(a, b - a));
        a = b + 1;
    }
    if (lines.size() < 2) { err = "solved file has no rows"; return false; }

    std::map<std::string, int> col;
    {
        const std::vector<std::string> hh = split_tab(lines[0]);
        for (size_t i = 0; i < hh.size(); i++) col[hh[i]] = (int)i;
    }
    auto ix = [&](const char* c2) { return col.count(c2) ? col[c2] : -1; };
    const int cScr = ix("screen"), cDep = ix("depth"), cTyp = ix("element_type");
    const int cNam = ix("element_name"), cX = ix("x"), cY = ix("y");
    const int cW = ix("w"), cH = ix("h"), cVis = ix("visible");
    if (cTyp < 0 || cX < 0 || cY < 0 || cW < 0 || cH < 0)
    { err = "solved file missing x/y/w/h"; return false; }

    std::map<std::string, size_t> index;
    for (size_t li = 1; li < lines.size(); li++)
    {
        if (lines[li].empty()) continue;
        const std::vector<std::string> r = split_tab(lines[li]);
        if ((int)r.size() <= cH) continue;

        const std::string scr = cScr >= 0 ? r[(size_t)cScr] : std::string("screen");
        if (index.find(scr) == index.end())
        { index[scr] = out.size(); out.push_back(Screen{ scr, {} }); }
        Screen& s2 = out[index[scr]];

        Element e;
        e.type_name = r[(size_t)cTyp];
        e.kind = kind_of(e.type_name);
        if (cDep >= 0) e.depth = atoi(r[(size_t)cDep].c_str());
        if (cNam >= 0 && (int)r.size() > cNam) e.name = r[(size_t)cNam];

        const float x = (float)atof(r[(size_t)cX].c_str());
        const float y = (float)atof(r[(size_t)cY].c_str());
        const float w = (float)atof(r[(size_t)cW].c_str());
        const float hgt = (float)atof(r[(size_t)cH].c_str());
        e.x0 = x; e.y0 = y; e.x1 = x + w; e.y1 = y + hgt;

        // An element the game hides is not drawn. Skipping it here rather than
        // at draw time keeps the count honest.
        bool vis = true;
        if (cVis >= 0 && (int)r.size() > cVis)
        {
            const std::string v = r[(size_t)cVis];
            vis = !(v == "0" || v == "False" || v == "false");
        }
        e.solved = vis && w > 0.f && hgt > 0.f;
        s2.elements.push_back(std::move(e));
    }
    return true;
}


}  // namespace rime
