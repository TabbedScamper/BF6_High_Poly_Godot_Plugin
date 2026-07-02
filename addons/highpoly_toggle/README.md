# Low/High-Poly Interchange (BF6 Portal SDK)

Preview your Portal level with the game's actual high-poly, fully-textured
models — without ever touching what gets saved or exported.

- The **low-poly proxy stays the source of truth**: it's what the `.tscn`
  saves and what the Portal exporter ships.
- The **high-poly is an editor-only overlay** (`owner = null` child): never
  serialized, never exported, dropped automatically on scene reload.
- Toggle with the **High-Poly dock**: `Scene → High/Low-Poly`,
  `Selected → High/Low-Poly`.

## Setup

1. Copy this folder to `addons/highpoly_toggle/` in the SDK Godot project and
   enable it under Project Settings → Plugins.
2. Generate preview assets for your level:
   `python tools/deploy_scene.py <your-level.tscn>` (from the pipeline repo).
   Assets land in `res://highpoly/<PropName>/<PropName>.glb`.
3. Reload the project once so Godot imports the GLBs, open your level, and
   click **Scene → High-Poly**.

Placement is conservative: overlays inherit the proxy's transform untouched
when the shapes agree; mismatched assets are skipped (the proxy stays visible)
rather than shown wrong. See `docs/HIGHPOLY-PREVIEW.md` in the pipeline repo
for the full guide, the matching database, and the fix-a-mismatch playbook.
