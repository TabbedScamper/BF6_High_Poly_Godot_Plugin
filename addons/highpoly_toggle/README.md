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
3. Use the **High-Poly** dock (top right). Models and map data download on
   demand — no other setup.

The dock offers a one-click **Update Plugin** button whenever a newer plugin
version is published, and **Update Models** pulls community model fixes.

Full guide: the repository README. Contributor guide: `docs/ARCHITECTURE.md`.
Overlay/fitter internals: `docs/HIGHPOLY-PREVIEW.md`.
