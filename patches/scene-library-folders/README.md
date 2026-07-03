# Scene Library folder view (FX/SFX declutter)

Patched `scene_library.gd` for the Scene Library addon (MIT, by Mansur Isaev
and contributors) that the Portal SDK uses for its Object Library.

What it adds:
- Collections named `<Map> FX`, `<Map> SFX`, `FX - All Maps`, `SFX - All Maps`
  are hidden from the tab bar and surfaced instead as **FX** and **SFX**
  folder items at the top-left of every map's asset grid.
- Double-click a folder to browse it (map-exclusive effects listed first,
  then the global set); the Back item returns to the map's props.
- Folders can't be dragged into the scene; props behave exactly as stock.

Install: replace `addons/scene-library/scripts/scene_library.gd` with this
file (keep a backup), then reorganize your `scene_library.json` so FX/SFX
live in collections named as above.
