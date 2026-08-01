# BF6 High-Poly Preview

Editor-only overlays for the BF6 Portal SDK: real high-poly models over the
low-poly proxies, plus Map Context (full terrain, original object layouts,
water) and viewport performance tools.

- The **low-poly proxy stays the source of truth** — it's what the `.tscn`
  saves and what the Portal exporter ships. This plugin never modifies it.
- Overlays are `owner = null` nodes (`_HIPOLY_PREVIEW`, `_MAP_CONTEXT`):
  never serialized, never exported, dropped automatically on scene reload.

## Install

1. Copy this folder to `addons/highpoly_toggle/` in the SDK Godot project.
2. Enable it under Project → Project Settings → Plugins.
3. Press **High-Poly Tools** in the 3D viewport toolbar — beside the SDK's own
   **Apply Texture** button. It opens a floating panel you can move anywhere,
   including onto a second monitor. Models and map data sync automatically in
   the background (scene props first) — no other setup.

The panel is a window rather than a dock because level building wants the
viewport wide, and a permanent right-hand dock costs ~400px of it. Closing the
panel only hides it: the background sync, map-context builds and downloads all
keep running. Its position and open/closed state are remembered per project.

The panel offers a one-click **Update Plugin** button whenever a newer plugin
version is published; model fixes and map-data refreshes arrive on their own.

## Look

Season 4 (Pacific Front) styling: a looping wave backdrop under white controls
on translucent white masks, inside a bright blue outline. Opening it for the
first time in an editor session — or the first time after an update — plays a
short boot sequence: waves, then the Portal logo, then the backdrop dims and
the controls fade in. **Click anywhere to skip it.**

Costs are contained rather than assumed away:

- The video pauses the moment the panel is closed, so a shut panel decodes
  nothing.
- It is encoded at 480×800 (0.8 MB), not at source resolution — it sits behind
  UI at ~28% brightness, so there is nothing to gain from more pixels.
- The control theme is set on the panel root only. Items it doesn't define fall
  through to your editor theme, and the rest of the SDK is untouched.

All of it is data, replaceable without a plugin release:
`theme.json` (palette), `logo.png` (the flash), `waves.ogv` (the backdrop).
Delete any of them and that stage is simply skipped.

## Viewport double-click

- **Doors** swing open/closed like in game.
- **Variant props** (police liveries, barn colour schemes, destroyed shells, …)
  cycle base → variant → … → base. The choice is per instance — two buses can
  wear different liveries — and survives Low/High-Poly toggles. Variants seen
  on the current map come first in the cycle. Doors win when a prop is both.

Full guide: the repository README. Contributor guide: `docs/ARCHITECTURE.md`.
Overlay/fitter internals: `docs/HIGHPOLY-PREVIEW.md`.
