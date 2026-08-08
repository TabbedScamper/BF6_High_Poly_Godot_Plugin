@tool
extends RefCounted
class_name HighpolyModes
# The Detail Mode ladder, as pure functions of the dropdown id.
#
# This lives apart from the dock for one reason: the dock is an EditorPlugin, and
# an EditorPlugin cannot be constructed outside a running editor, so nothing in
# it can be tested. These four mappings are exactly where this plugin has been
# bitten more than once — three values that used to be interchangeable and are
# not any more:
#
#   the dropdown id   what the user picked, and what gets SAVED per map
#   the tier          LOW / HIGH, governing the pieces the USER placed
#   the texture mode  0 flat / 1 clay / 2 textured, for the borrowed level
#
# While the list had three entries all three were the same number, so every bug
# in this area is silent by construction: the code reads fine and the wrong rung
# quietly downloads a few gigabytes or repaints a map the wrong colour.
#
#   const   id   your placed pieces   the level around them
#   SDK      0   SDK proxies          nothing
#   LIGHT    3   SDK proxies          real, untextured
#   GREY     1   real, clay           real, untextured
#   TEX      2   real, textured       real, textured
#
# The ids are PERSISTED (as "tex" in the per-map state) and must never be
# renumbered. LIGHT was added after the other three and took the next free id
# rather than the slot it occupies in the list, so list order is by cost and id
# order is by history — they are different sequences and neither can be derived
# from the other.

const SDK := 0
const LIGHT := 3
const GREY := 1
const TEX := 2

# The order the dropdown lists them in: cheapest first.
const ORDER: Array = [SDK, LIGHT, GREY, TEX]

const LABELS: Dictionary = {
	SDK: "Low-Poly (what you export)",
	LIGHT: "Low-Poly + the real level around it",
	GREY: "High-Poly (no textures)",
	TEX: "High-Poly (full textures)",
}

static func label(id: int) -> String:
	return str(LABELS.get(id, LABELS[SDK]))

# Which tier the pieces the USER placed are drawn at.
#
# BOTH low rungs are LOW. The light rung differs only in what it draws AROUND
# those pieces, never in the pieces themselves — that is its whole promise, and
# HighpolySync reads this (via HighpolyLib.detail) to decide whether to fetch
# models for them at all. Testing `id == 0` here, which is what the dock did
# while there were three entries, silently makes the light rung High-Poly.
static func tier(id: int) -> int:
	return HighpolyLib.Tier.LOW if (id == SDK or id == LIGHT) else HighpolyLib.Tier.HIGH

static func textured(id: int) -> bool:
	return id == TEX

# How the borrowed level is drawn: 0 flat SDK orange / 1 clay / 2 textured.
#
# NOT the id. highpoly_mapcontext.gd only understands those three values, and an
# unrecognised one falls silently into the flat branch. The light rung draws its
# surroundings in clay, the same as High-Poly-no-textures: flat orange would be
# the literal reading of "light", but it is also what the rung BELOW already
# shows, so the light rung would have nothing of its own to display.
static func ctx_tex(id: int) -> int:
	return GREY if id == LIGHT else id

# Can this rung fetch anything at all? Everything the Map Context section offers
# costs a download, so this is the single gate they all share.
static func downloads(id: int) -> bool:
	return id != SDK
