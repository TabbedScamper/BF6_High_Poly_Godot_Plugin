// The armory FLOW: pick a category, pick a weapon, edit its attachments.
//
// The goal here is functional parity, not a pixel-perfect reimplementation of
// the Rime element tree. The game's flow is:
//
//     [category tabs]  ->  [weapon grid]  ->  [customize]  ->  [slot picker]
//      ASSAULT RIFLE        tile per         slot tiles       options for one
//      CARBINE, SMG...      weapon, with     around the       slot, each with
//                           cost/lock/pips   3D weapon        its points cost
//
// with a points budget spent across the fitted set ("ATTACHMENT POINTS
// 70/100") and the camera reframing onto whichever slot is being edited.
//
// Everything it shows is read from the install at runtime: the categories from
// the screen's own config asset, the roster and slots from the mount's name
// table, the costs from the attachment records. Nothing is loaded from an
// exported table.
//
// Drawn through ImDrawList as a quad batcher, in the game's own palette and
// typefaces, with square corners - the front end has no rounded-rectangle
// idiom (5,709 of 7,402 authored corners have curvature exactly 0).
#pragma once
#include <map>
#include <string>
#include <vector>

namespace bf6 { struct Armory; struct ArmoryWeapon; }
struct ImFont;

namespace armory_ui {

enum class Page { Weapons, Customize, SlotPicker };

struct Fitted {
    // slot code -> attachment token. Empty means the slot is unfitted, which
    // is a real state and not the same as "no such slot".
    std::map<std::string, std::string> by_slot;
};

struct State {
    Page        page = Page::Weapons;
    std::string category;        // weapon class tab: assaultrifle, carbine...
    std::string weapon;          // "carbine/m4a1"
    std::string slot;            // slot code being edited, when on SlotPicker
    Fitted      fitted;

    // The points budget, read from the weapon's own equipment record: 100 on
    // primaries, 60 on sidearms. -1 until read.
    int budget = -1;

    // Set when the user picks something, so the caller can reframe the camera
    // and rebuild the mesh without polling every field for changes.
    bool weapon_changed = false;
    bool slot_changed   = false;
};

// Draw one weapon's outline sprite into a rect, if the caller has it.
// A hook rather than a dependency: the UI should not know how an atlas is
// loaded, and a weapon with no atlas (melee, vehicle) simply draws nothing.
typedef bool (*DrawIconFn)(const char* weapon_bare, const char* weapon_class,
                           float x, float y, float w, float h, void* user);

struct Fonts {
    ImFont* header = nullptr;   // BF_HEADLINE_SEMI_BOLD
    ImFont* label  = nullptr;   // BF_SUB_HEADLINE_BOLD
    ImFont* body   = nullptr;   // BFText-Regular
    ImFont* mono   = nullptr;   // BF_SUB_HEADLINE_MONO, for costs and counts
};

// Points spent by the current fitted set, and the per-attachment cost lookup
// that produced it. Separate so a caller can show both halves of "70/100".
int spent(const bf6::Armory& a, const State& s);

// Draw the whole flow for one frame. Returns true if anything changed that the
// caller needs to act on (new weapon, new slot, new fitted part).
bool draw(const bf6::Armory& a, State& s, const Fonts& f,
          float x, float y, float w, float h,
          DrawIconFn icon = nullptr, void* icon_user = nullptr);

}  // namespace armory_ui
