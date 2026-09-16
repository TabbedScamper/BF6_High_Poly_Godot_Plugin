#!/usr/bin/env python3
"""Sync Unreal-owned menu definitions to both engines; read-only by default.

With --unreal-plugin, Shared/menu in that plugin is authoritative. Without
the parent, --check only validates the standalone Godot snapshot; it cannot
prove freshness. --write always requires the parent and never promotes a
Godot snapshot implicitly.
"""
import argparse
import hashlib
import json
import math
from pathlib import Path
import re

PRODUCT = Path(__file__).resolve().parents[1]
ID = re.compile(r"^[a-z][a-z0-9_]*$")
KINDS = {"toggle", "action", "slider", "choice"}
LAYOUTS = {"stack", "chips", "inline", "native"}
DEFINITIONS = ("menu.json", "theme.json", "preparation.json", "adapters.json")
RUNTIME_DEFINITIONS = DEFINITIONS[:3]


def unique_object(pairs):
    obj = {}
    for key, value in pairs:
        if key in obj:
            raise ValueError(f"duplicate JSON key: {key}")
        obj[key] = value
    return obj


def read_json(path):
    return json.loads(path.read_text(encoding="utf-8-sig"), object_pairs_hook=unique_object)


def validate(menu):
    def require(ok, message):
        if not ok:
            raise ValueError(message)

    require(isinstance(menu, dict) and menu.get("schema") == 1, "unsupported menu schema")
    controls = menu.get("controls")
    require(isinstance(controls, dict) and bool(controls), "controls must be a nonempty object")
    for key, control in controls.items():
        require(bool(ID.fullmatch(key)), f"invalid control id: {key}")
        require(isinstance(control, dict), f"invalid control: {key}")
        require(control.get("kind") in KINDS, f"invalid control kind: {key}")
        for field in ("label", "tip"):
            require(isinstance(control.get(field), str) and bool(control[field]), f"missing {field}: {key}")
        engines = control.get("engines")
        require(isinstance(engines, list) and bool(engines) and
                all(e in {"godot", "unreal"} for e in engines) and
                len(engines) == len(set(engines)), f"invalid engines: {key}")
        overrides = control.get("engine_tips", {})
        require(isinstance(overrides, dict) and all(e in engines and isinstance(t, str) and bool(t)
                for e, t in overrides.items()), f"invalid engine tips: {key}")
    style = menu.get("style", {})
    for key in ("font_scale", "control_font", "status_font", "section_font", "chip_gap", "padding_x", "padding_y"):
        value = style.get(key)
        require(type(value) in (int, float) and math.isfinite(value) and value > 0, f"invalid style value: {key}")
    sections = menu.get("sections")
    require(isinstance(sections, list) and bool(sections), "sections must be a nonempty array")
    section_ids, group_ids, used = set(), set(), set()

    def groups(items):
        require(isinstance(items, list), "groups must be an array")
        for group in items:
            require(isinstance(group, dict), "group must be an object")
            key = group.get("id", "")
            require(isinstance(key, str) and bool(ID.fullmatch(key)) and key not in group_ids, f"invalid/duplicate group id: {key}")
            group_ids.add(key)
            require(group.get("layout") in LAYOUTS, f"invalid group layout: {key}")
            refs = group.get("controls")
            require(isinstance(refs, list), f"controls must be an array: {key}")
            if group["layout"] == "native":
                require(group.get("adapter") is True and not refs, f"native group must be an empty explicit adapter: {key}")
            else:
                require(bool(refs), f"empty control group: {key}")
            for ref in refs:
                require(isinstance(ref, str) and ref in controls, f"unknown control reference: {ref}")
                require(ref not in used, f"duplicate control reference: {ref}")
                used.add(ref)

    groups(menu.get("top_groups", []))
    for section in sections:
        require(isinstance(section, dict), "section must be an object")
        key = section.get("id", "")
        require(isinstance(key, str) and bool(ID.fullmatch(key)) and key not in section_ids, f"invalid/duplicate section id: {key}")
        section_ids.add(key)
        require(all(isinstance(section.get(f), str) and bool(section[f]) for f in ("title", "description")), f"missing section copy: {key}")
        require(type(section.get("open")) is bool, f"invalid default open state: {key}")
        groups(section.get("groups"))
    require(used == set(controls), f"unplaced controls: {sorted(set(controls) - used)}")


def validate_capabilities(menu, capabilities):
    """Capability declarations describe shipped handlers, never planned ports."""
    if not isinstance(capabilities, dict) or capabilities.get("schema") != 1:
        raise ValueError("invalid adapter capability schema")
    for engine in ("godot", "unreal"):
        supported = capabilities.get(engine)
        if not isinstance(supported, dict) or any(k not in KINDS for k in supported.values()):
            raise ValueError(f"invalid {engine} adapter capability kinds")
        advertised = {key: control["kind"] for key, control in menu["controls"].items()
                      if engine in control["engines"]}
        if advertised != supported:
            missing = sorted(set(supported) - set(advertised))
            extra = sorted(set(advertised) - set(supported))
            wrong = sorted(k for k in set(supported) & set(advertised) if supported[k] != advertised[k])
            raise ValueError(f"{engine} capabilities disagree: missing={missing}, unsupported={extra}, wrong_kind={wrong}")


def check_adapter_sources(capabilities, godot_source, unreal_source=None):
    source = godot_source.read_text(encoding="utf-8")
    start = source.index("var menu_bindings := {")
    end = source.index("\n\t}", start)
    actual = set(re.findall(r'"([a-z][a-z0-9_]*)": SharedMenu\.binding\(', source[start:end]))
    if actual != set(capabilities["godot"]):
        raise ValueError(f"Godot source bindings differ from capabilities: {sorted(actual ^ set(capabilities['godot']))}")
    if unreal_source is not None:
        source = unreal_source.read_text(encoding="utf-8")
        start = source.index("const TMap<FString, FString> Ids = {")
        end = source.index("for (auto& Pair : Bindings)", start)
        region = source[start:end]
        actual = set(re.findall(r'\{TEXT\("[^"]+"\), TEXT\("([a-z][a-z0-9_]*)"\)\}', region))
        actual.update(re.findall(r'Bindings\.Add\(TEXT\("([a-z][a-z0-9_]*)"\)', region))
        if 'BF6HighPolyCollisionMenu::Bind(Bindings)' in region:
            collision_source = unreal_source.with_name('BF6HighPolyCollisionMenu.cpp').read_text(encoding='utf-8')
            actual.update(re.findall(r'Controls\.Add\(TEXT\("([a-z][a-z0-9_]*)"\)', collision_source))
        if actual != set(capabilities["unreal"]):
            raise ValueError(f"Unreal source bindings differ from capabilities: {sorted(actual ^ set(capabilities['unreal']))}")


def validate_preparation(definition):
    if not isinstance(definition, dict) or definition.get("schema") != 1:
        raise ValueError("invalid preparation screen schema")
    if not isinstance(definition.get("title"), str) or not definition["title"]:
        raise ValueError("missing preparation screen title")
    for field in ("labels", "scopes"):
        values = definition.get(field)
        if not isinstance(values, dict) or not values or any(not isinstance(v, str) or not v for v in values.values()):
            raise ValueError(f"invalid preparation {field}")
    if set(definition["scopes"]) != {"godot", "unreal"}:
        raise ValueError("preparation scopes must describe both engines")
    phases = definition.get("phases")
    if not isinstance(phases, list) or [p.get("id") for p in phases if isinstance(p, dict)] != ["discovery", "geometry", "verification"]:
        raise ValueError("invalid preparation phase order")
    weights = []
    for phase in phases:
        value = phase.get("weight")
        if type(value) not in (int, float) or not math.isfinite(value) or value <= 0:
            raise ValueError("invalid preparation phase weight")
        if not isinstance(phase.get("label"), str) or not phase["label"]:
            raise ValueError("missing preparation phase label")
        weights.append(value)
    if not math.isclose(sum(weights), 1.0, abs_tol=1e-9):
        raise ValueError("preparation phase weights must sum to 1")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--write", action="store_true", help="copy validated canonical menu and theme into requested targets")
    mode.add_argument("--check", action="store_true", help="read-only drift check (default)")
    parser.add_argument("--unreal-plugin", type=Path, help="BF6HighPoly plugin root")
    parser.add_argument("--installed-addon", type=Path, help="optional installed Godot highpoly_toggle directory")
    parser.add_argument("--promote-snapshot", action="store_true", help="one-time explicit migration: seed an EMPTY Unreal Shared/menu from the reviewed Godot snapshot; requires --write")
    args = parser.parse_args(argv)
    if args.write and not args.unreal_plugin:
        parser.error("--write requires --unreal-plugin: standalone Godot data is a snapshot, not the source of updates")
    if args.promote_snapshot and (not args.write or not args.unreal_plugin):
        parser.error("--promote-snapshot requires --write and --unreal-plugin")
    if args.unreal_plugin and not (args.unreal_plugin / "BF6HighPoly.uplugin").is_file():
        parser.error("--unreal-plugin must contain BF6HighPoly.uplugin")
    if args.installed_addon and not (args.installed_addon / "highpoly_toggle.gd").is_file():
        parser.error("--installed-addon must contain highpoly_toggle.gd")
    snapshot = PRODUCT / "shared/menu"
    parent_menu = args.unreal_plugin / "Shared/menu" if args.unreal_plugin else None
    canonical = parent_menu if parent_menu else snapshot
    if args.promote_snapshot:
        if parent_menu.exists() and any(parent_menu.iterdir()):
            parser.error("--promote-snapshot refuses an existing Unreal menu; edit the parent definitions instead")
        canonical = snapshot
    try:
        payloads = {name: (canonical / name).read_bytes() for name in DEFINITIONS}
        menu = read_json(canonical / "menu.json")
        validate(menu)
        validate_preparation(read_json(canonical / "preparation.json"))
        capabilities = read_json(canonical / "adapters.json")
        validate_capabilities(menu, capabilities)
        unreal_source = (args.unreal_plugin / "Source/BF6HighPoly/Private/BF6HighPoly.cpp") if args.unreal_plugin else None
        check_adapter_sources(capabilities, PRODUCT / "addons/highpoly_toggle/highpoly_toggle.gd", unreal_source)
        palette = read_json(canonical / "theme.json")
        for key in ("accent", "accent_dim", "heading", "splash_bg"):
            if not re.fullmatch(r"#[0-9a-fA-F]{6}(?:[0-9a-fA-F]{2})?", palette.get(key, "")):
                raise ValueError(f"invalid theme color: {key}")
        if any((canonical / name).read_bytes() != payloads[name] for name in DEFINITIONS):
            raise ValueError("definitions changed during validation; retry from a stable parent snapshot")
    except (ValueError, OSError, TypeError) as error:
        print(f"Invalid shared menu at {canonical}: {error}")
        return 2
    targets = [(PRODUCT / "addons/highpoly_toggle", RUNTIME_DEFINITIONS)]
    if args.unreal_plugin:
        targets.append((PRODUCT / "shared/menu", DEFINITIONS))
        targets.append((args.unreal_plugin / "Resources/theme", RUNTIME_DEFINITIONS))
    if args.promote_snapshot:
        targets.insert(0, (parent_menu, DEFINITIONS))
    if args.installed_addon:
        targets.append((args.installed_addon, RUNTIME_DEFINITIONS))
    differences = []
    for target, names in targets:
        for name in names:
            destination = target / name
            matches = destination.is_file() and destination.read_bytes() == payloads[name]
            if not matches and args.write:
                target.mkdir(parents=True, exist_ok=True)
                destination.write_bytes(payloads[name])
                matches = True
            if not matches:
                differences.append(str(destination))
    print(json.dumps({"schema": menu["schema"], "controls": len(menu["controls"]),
                      "menu_sha256": hashlib.sha256(payloads["menu.json"]).hexdigest(),
                      "canonical": str(parent_menu if parent_menu else canonical),
                      "authority": "explicit_snapshot_promotion" if args.promote_snapshot else ("unreal_parent" if args.unreal_plugin else "standalone_snapshot_freshness_unverified"),
                      "targets": [str(t) for t, _names in targets], "different_or_missing": differences,
                      "mode": "write" if args.write else "check"}, indent=2))
    return int(bool(differences))


if __name__ == "__main__":
    raise SystemExit(main())
