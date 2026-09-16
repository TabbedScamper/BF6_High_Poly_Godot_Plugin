#!/usr/bin/env python3
"""Validate and synchronize the shared cache dependency policy. Read-only by default."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil

PRODUCT = Path(__file__).resolve().parents[1]


def validate(data):
    if data.get("schema") != 1 or type(data.get("cache_contract")) is not int or data["cache_contract"] < 1:
        raise ValueError("Unsupported cache dependency contract")
    for engine in ("godot", "unreal"):
        policy = data[engine]
        for field in ("roots", "extensions", "required", "exclude"):
            values = policy[field]
            if not isinstance(values, list) or any(not isinstance(value, str) or not value for value in values):
                raise ValueError(f"Invalid {engine}.{field}")
            if len(set(values)) != len(values):
                raise ValueError(f"Duplicate {engine}.{field}")
        for value in policy["roots"] + policy["required"] + policy["exclude"]:
            if ".." in value or "\\" in value or ":" in value or value.startswith("/"):
                raise ValueError(f"Unsafe dependency path: {value}")
        if not policy["roots"] or not policy["extensions"] or not policy["required"]:
            raise ValueError(f"Empty dependency policy: {engine}")
        if set(policy["required"]) & set(policy["exclude"]):
            raise ValueError(f"Required dependency excluded: {engine}")


def snapshot(root, data, engine):
    """Dependency evidence for audits; runtime consumers compute their own recipe."""
    validate(data)
    root = Path(root)
    policy = data[engine]
    for required in policy["required"]:
        if not (root / required).is_file():
            raise ValueError(f"Missing required dependency: {required}")
    result = {}
    for folder in policy["roots"]:
        path = root / folder
        if not path.is_dir():
            raise ValueError(f"Missing dependency root: {folder}")
        for file in path.rglob("*"):
            relative = file.relative_to(root).as_posix()
            if file.is_file() and not any(part.startswith((".", "~")) for part in Path(relative).parts):
                if file.suffix.lstrip(".").lower() in policy["extensions"] and relative not in policy["exclude"]:
                    result[relative] = hashlib.sha256(file.read_bytes()).hexdigest()
    return dict(sorted(result.items()))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--unreal-plugin", type=Path)
    parser.add_argument("--installed-godot-addon", type=Path)
    parser.add_argument("--write", action="store_true")
    args = parser.parse_args()
    source = PRODUCT / "shared/cache/dependencies.json"
    data = json.loads(source.read_text(encoding="utf-8-sig"))
    validate(data)
    targets = [PRODUCT / "addons/highpoly_toggle/cache_dependencies.json"]
    if args.unreal_plugin:
        snapshot(args.unreal_plugin, data, "unreal")
        targets.append(args.unreal_plugin / "Resources/cache_dependencies.json")
    if args.installed_godot_addon:
        targets.append(args.installed_godot_addon / "cache_dependencies.json")
    snapshot(PRODUCT / "addons/highpoly_toggle", data, "godot")
    different = []
    for target in targets:
        if args.write:
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(source, target)
        if not target.is_file() or source.read_bytes() != target.read_bytes():
            different.append(str(target))
    print(json.dumps({"matched": not different, "different": different, "targets": [str(p) for p in targets]}))
    return bool(different)


if __name__ == "__main__":
    raise SystemExit(main())
