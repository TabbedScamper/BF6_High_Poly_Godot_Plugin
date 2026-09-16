# Shared cache dependencies

`shared/cache/dependencies.json` defines which code changes affect preparation
in both engines. Run `tools/sync_cache_dependencies.py --unreal-plugin <path>
--write` to deploy the same policy. The tool checks copies without `--write`.

Unknown source files are dependencies by default. Only explicitly reviewed
presentation files are excluded. Menu layout, theme, animation backdrop and
preparation progress display changes therefore do not reset prepared assets.
Mixed UI/renderer files (`BF6HighPoly.cpp`, `highpoly_toggle.gd`) remain
dependencies: cosmetic edits inside those files still invalidate conservatively.

Godot hashes installed dependency files, including native reader binaries.
Unreal's build embeds a dependency fingerprint into the compiled module; it
also includes reader headers. Runtime checks still hash the actual reader DLL,
shaders, content and engine version. The source fingerprint travels inside the
binary, so a loose metadata file cannot pair newer rules with an older build.
Missing build dependencies stop the build. Missing Godot policy/reader files
produce no reusable cache identity.

The policy revision (`cache_contract`) is an explicit cross-engine invalidation
lever for changes that affect cache meaning beyond a file's implementation.
Ordinary reader, prop, terrain and map decoder fixes change their dependency
hashes automatically. Caller-owned blob format versions remain required when
serialized layouts change. Neither bypass nor invalidation deletes user scenes.

Game-file identity still conservatively invalidates the complete generation.
There is no verified map-to-archive dependency graph yet, so this change does
not claim that a patch to one map rebuilds only that map. It also does not change
what is prepared: engine-ready terrain/materials/scene streaming remain separate
work. The first update to this contract requires one fresh preparation.

Regression: `tools/test_cache_dependencies.gd` executes the production Godot
recipe against unchanged, decoder-modified, menu-modified, missing-reader and
unknown-new-code fixtures. Nine controls passed on September 12, 2026.

`tools/test_cache_dependencies_unreal.py --engine-root <UE> --unreal-plugin
<plugin> --output <verification-folder>` compiles the actual `Build.cs` functions
into an isolated harness using Unreal's .NET runtime and assemblies. Its twelve
controls passed: real source reproducibility, relocated copies, both supported
plugin installation layouts, presentation edits, reader/source changes and
missing dependencies. Fixtures stay in the verification folder for inspection;
installed source files are never mutated. These tests check invalidation, not
loading speed.
