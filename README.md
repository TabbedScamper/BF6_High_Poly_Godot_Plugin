# BF6 Portal High-Poly Preview

Build Battlefield 6 Portal maps in the SDK's Godot editor against the
**actual in-game models** — fully textured high-poly overlays on top of the
SDK's low-poly proxies. Non-destructive: the proxies stay the source of
truth (they're what saves and exports); the high-poly view is an editor-only
overlay you can toggle on and off at any time.

Companion to the **[BF6 Model Viewer](https://github.com/TabbedScamper/BF6_Model_Viewer)** — browse every prop in 3D and submit model fixes (they flow to everyone automatically).

## Quick start

1. Copy `addons/highpoly_toggle/` into your Portal SDK Godot project's
   `addons/` folder and enable it (Project Settings → Plugins).
2. Set the registry URL once:
   Project Settings → add `highpoly/manifest_url` =
   `https://<models-host>/plugin-manifest.json`
3. Deploy assets for your level: `python tools/deploy_scene.py <level.tscn>`
   (or download a prepared prop pack into `res://highpoly/`).
4. Reload the project, open your level, and hit **Scene → High-Poly** in the
   High-Poly dock.

**Update Models** in the dock pulls corrected models from the registry —
it compares content hashes and downloads only what changed, only for props
you have deployed.

## How it works, limits, and fixing bad matches

See `docs/HIGHPOLY-PREVIEW.md` — the full guide covers the overlay design,
the conservative auto-fitter (identity-first; wrong-shaped assets are skipped
rather than shown distorted), the SDK validator interplay, the proxy→model
matching database, and the playbook for correcting a mismatched prop.

Found a broken model? Submit a fix to the [BF6_Model_Viewer](https://github.com/TabbedScamper/BF6_Model_Viewer) registry — once approved it
ships to every user's next **Update Models** click.
