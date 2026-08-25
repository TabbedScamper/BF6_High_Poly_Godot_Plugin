// Rime: draw the game's OWN screen, rather than an ImGui panel dressed up to
// look like it.
//
// The distinction matters and it is the whole point of this file. Putting the
// game's fonts and palette on ImGui widgets gets you something BF6-flavoured
// with none of its actual structure - no background plates, no button chrome,
// no element tree. The screen is authored data: a tree of Rime elements with
// anchors, offsets, pivots, weights and stack rules. So interpret it.
//
// ImGui is still here, but only as a QUAD BATCHER. Every rect and glyph goes
// through ImDrawList at absolute pixel coordinates; none of ImGui's layout or
// widget code participates. That reuse is worth a great deal of time and costs
// nothing in fidelity, because a draw list is just a vertex buffer.
#pragma once
#include <cstdint>
#include <string>
#include <vector>

namespace rime {

// The element vocabulary the armory screens actually use, by frequency over
// the 237 elements of the 20 armory partitions.
enum class Kind {
    WidgetReference,   // 67  instantiates another partition
    Container,         // 52  layout only
    StackContainer,    // 30  layout, one axis, spacing + padding
    Label,             // 22  text
    LayerEntity,       // 21  a screen layer root
    RepeatShape,       // 14  the point-cost pip strip
    VectorShape,       //  9  plates and chrome
    Fill,              //  5  solid background
    Svg,               //  2
    Movie,             //  1  video panel; drawn as a placeholder
    Unknown
};

// One axis of the box model. Anchors are fractions of the parent; offsets are
// in authored pixels. Pivot and weight are carried through but their exact
// semantics are still being established - see solve() before trusting them.
struct Axis {
    float anchor_start = 0.f, anchor_end = 0.f;
    float offset_start = 0.f, offset_end = 0.f;
    float pivot = 0.f, weight = 0.f;
    bool  present = false;
};

struct Element {
    Kind        kind = Kind::Unknown;
    std::string type_name;
    std::string name;
    uint32_t    name_hash = 0;
    int         depth = 0;
    Axis        h, v;
    int         stack_orientation = -1;   // 0/1 when a stack, -1 otherwise
    float       item_spacing = 0.f;
    float       pad_l = 0.f, pad_t = 0.f, pad_r = 0.f, pad_b = 0.f;
    std::string references_widget;

    // Filled by solve(): the absolute rect in authored pixels.
    float x0 = 0.f, y0 = 0.f, x1 = 0.f, y1 = 0.f;
    bool  solved = false;
    int   parent = -1;
};

struct Screen {
    std::string partition;
    std::vector<Element> elements;        // depth-ordered, as authored
};

// Load the element trees.
//
// INTERIM SOURCE, and deliberately marked as such: this reads the extracted
// ui_armory_screen_tree.tsv rather than parsing the partitions live. The
// values in it came from the game, but a derived file goes stale the way the
// weapon cards did. The loader is isolated behind this one call so swapping to
// a live read is a drop-in once the Rime string-reference mechanism is pinned
// down - the element names live in the partition's own string table and are
// not referenced by a plain table-relative u32, which is the open piece.
bool load_tree_tsv(const char* path, std::vector<Screen>& out, std::string& err);

// Load the SOLVED layout: every element with its absolute rect already
// computed and verified, references instantiated, 408 rows for the weapon
// screen with zero negative sizes.
//
// Preferred over solving here, because the box law is subtle enough that our
// first reading got it wrong in three separate ways. The shipped element base
// stores VerticalLayout BEFORE HorizontalLayout - the reverse of what was
// first recorded - so a consumer reading them in declaration order silently
// transposes every axis. offset_end is an INWARD inset, not a same-direction
// offset: on all 14,077 point-anchored axes in common/ui, offset_start ==
// -offset_end exactly, which only makes sense if both edges are being put on
// the same line and the box is then SELF-SIZED from its own Width/Height and
// placed by the pivot. And stacks sequence their children in REVERSE array
// order (40/40 horizontal, 13/13 vertical) while painting in array order.
bool load_solved_tsv(const char* path, std::vector<Screen>& out, std::string& err);

// Resolve every element to an absolute rect inside a canvas.
//
// THE BOX LAW IS NOT YET SETTLED, which is why this is one function and not
// scattered through the renderer. Two authored cases disagree under a naive
// inward-inset reading:
//     v_anchor 1..1, v_offset -20..20   should be a ~40 px bar on the bottom
//     h_anchor 0..0, h_offset 16..-16   should be a thin vertical line
// Whatever the engine does has to satisfy both. Until that is measured this
// uses the reading that satisfies the first and flags the second, and every
// caller goes through here so there is exactly one place to correct.
void solve(Screen& s, float canvas_w, float canvas_h);

Kind kind_of(const std::string& type_name);

// Expand every RimeWidgetReference into the tree of the partition it names.
//
// A screen is not one partition. menuweaponscreen is 8 elements, of which 6
// are references; the actual grid, info panel, point cost and stat bars each
// live in their own partition and are INSTANTIATED into the parent's box.
// Without this a consumer draws six empty rectangles and concludes the screen
// is nearly empty, which is what it looked like.
//
// Returns a flattened tree with the referenced children inlined at the
// reference's depth. `unresolved` receives the count of references whose
// partition is not in `all` - they stay as leaves, because a widget we do not
// have is a gap to show, not a thing to invent.
Screen instantiate(const std::vector<Screen>& all, size_t root, int max_depth,
                   int* unresolved);

}  // namespace rime
