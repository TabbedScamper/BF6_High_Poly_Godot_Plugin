#!/usr/bin/env python3
"""MANAGED PACKAGE: the ZIP the BF6 Godot Patch (Home) featured-plugin updater installs.

    python tools/package_managed.py [--version X.Y.Z] [--channel development|release] --output <folder>

Built from the WORKING TREE like tools/make_package.sh, but in the Home package
format: every file lives under addons/highpoly_toggle/ and
addons/highpoly_toggle/package-manifest.json lists each file with its SHA-256.
The Home updater refuses any archive whose contents differ from that list.

Publishing: attach the same bytes under two names on the GitHub release:
  BF6_High_Poly_Godot_Plugin-<version>.zip  (Home featured-plugin updater)
  highpoly_toggle.zip                       (the plugin's own in-editor updater)
The script writes both files; they are byte-identical.

The version is stamped into plugin.cfg INSIDE the package only. An existing
output file is never overwritten.
"""
from __future__ import annotations

import argparse
import datetime
import hashlib
import io
import json
import os
import re
import subprocess
import sys
import zipfile
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
ADDON = REPO / "addons" / "highpoly_toggle"
ADDON_PATH = "addons/highpoly_toggle"
PLUGIN_ID = "high_poly"
REPOSITORY = "BF6_High_Poly_Godot_Plugin"
MANIFEST = "package-manifest.json"
OMIT_DIRS = {".godot", "__pycache__", ".git", "tests", "test", "fixtures"}
OMIT_SUFFIXES = {".pyc", ".pyo", ".tmp", ".bak", ".log", ".pdb", ".ilk"}
FIXED_TIME = (1980, 1, 1, 0, 0, 0)
VERSION_RE = re.compile(r"[0-9]+(?:\.[0-9]+){1,3}(?:-[A-Za-z0-9.]+)?")


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def git(*args: str) -> str:
    try:
        return subprocess.run(["git", "-C", str(REPO), *args], capture_output=True, text=True, check=True).stdout.strip()
    except (OSError, subprocess.CalledProcessError):
        return ""


def omitted(relative: str) -> bool:
    parts = relative.split("/")
    name = parts[-1]
    return (any(part.casefold() in OMIT_DIRS for part in parts[:-1]) or name.startswith("~")
            or name == MANIFEST or Path(name).suffix.casefold() in OMIT_SUFFIXES)


def collect() -> dict[str, bytes]:
    files: dict[str, bytes] = {}
    for path in sorted(ADDON.rglob("*")):
        if path.is_symlink():
            raise SystemExit(f"refusing linked path in the addon: {path}")
        if not path.is_file():
            continue
        relative = ADDON_PATH + "/" + path.relative_to(ADDON).as_posix()
        if omitted(relative):
            continue
        files[relative] = path.read_bytes()
    return files


def build(version: str | None, channel: str) -> tuple[bytes, dict]:
    sync = REPO / "tools" / "sync_shared_menu.py"
    if sync.exists():
        subprocess.run([sys.executable, str(sync), "--check"], check=True)
    files = collect()
    config_name = ADDON_PATH + "/plugin.cfg"
    config = files[config_name].decode("utf-8")
    current = re.search(r'^version="([^"]*)"', config, re.M)
    if not current:
        raise SystemExit("plugin.cfg has no version")
    version = version or current.group(1)
    if not VERSION_RE.fullmatch(version):
        raise SystemExit(f"unsafe version: {version}")
    files[config_name] = re.sub(r'^version="[^"]*"', f'version="{version}"', config, count=1, flags=re.M).encode("utf-8")
    commit = git("rev-parse", "--short", "HEAD") or "unknown"
    dirty = bool(git("status", "--porcelain", "--untracked-files=normal", "--", "addons/highpoly_toggle"))
    files[ADDON_PATH + "/BUILD-INFO.txt"] = (
        "BF6 High-Poly Preview, managed package\n"
        f"version   {version}\n"
        f"channel   {channel}\n"
        f"built     {datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')}\n"
        f"commit    {commit}{' (addon had uncommitted changes)' if dirty else ''}\n"
    ).encode("utf-8")
    inventory = {name: sha(data) for name, data in sorted(files.items())}
    manifest = {
        "format": 1,
        "plugin": PLUGIN_ID,
        "repository": REPOSITORY,
        "version": version,
        "channel": channel,
        "release_ready": channel == "release",
        "addon_path": ADDON_PATH,
        "files": inventory,
        "source_commit": commit,
        "source_dirty": dirty,
        "source_digest": sha(json.dumps(inventory, sort_keys=True, separators=(",", ":")).encode()),
    }
    payload = dict(files)
    payload[ADDON_PATH + "/" + MANIFEST] = (json.dumps(manifest, indent=2, sort_keys=True) + "\n").encode()
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
        for name in sorted(payload):
            info = zipfile.ZipInfo(name, date_time=FIXED_TIME)
            info.create_system = 3
            info.external_attr = 0o100644 << 16
            info.compress_type = zipfile.ZIP_DEFLATED
            archive.writestr(info, payload[name], compress_type=zipfile.ZIP_DEFLATED, compresslevel=9)
    data = buffer.getvalue()
    verify(data, manifest)
    return data, manifest


def verify(data: bytes, manifest: dict) -> None:
    """The same inventory rules the Home updater enforces."""
    with zipfile.ZipFile(io.BytesIO(data)) as archive:
        names = archive.namelist()
        manifest_name = ADDON_PATH + "/" + MANIFEST
        if len(names) != len({name.casefold() for name in names}):
            raise SystemExit("duplicate path aliases in archive")
        if set(names) != set(manifest["files"]) | {manifest_name} or len(names) != len(manifest["files"]) + 1:
            raise SystemExit("archive contents differ from the manifest")
        for info in archive.infolist():
            if info.is_dir() or not info.filename.startswith(ADDON_PATH + "/") or ".." in info.filename.split("/"):
                raise SystemExit(f"unsupported archive entry: {info.filename}")
            if info.filename.endswith("/plugin.cfg") and info.filename != ADDON_PATH + "/plugin.cfg":
                raise SystemExit("a second plugin.cfg would be installed")
            if info.file_size > 128 * 1024 * 1024:
                raise SystemExit(f"entry exceeds the updater limit: {info.filename}")
        if json.loads(archive.read(manifest_name)) != manifest:
            raise SystemExit("manifest in archive differs")
        for name, digest in manifest["files"].items():
            if sha(archive.read(name)) != digest:
                raise SystemExit(f"payload hash mismatch: {name}")
    if len(data) > 128 * 1024 * 1024:
        raise SystemExit("archive exceeds the 128 MiB updater limit")


def write_new(path: Path, data: bytes) -> None:
    if path.exists():
        raise SystemExit(f"refusing to overwrite {path}")
    temporary = path.with_name(path.name + ".partial")
    with open(temporary, "xb") as stream:
        stream.write(data)
        stream.flush()
        os.fsync(stream.fileno())
    os.replace(temporary, path)
    if sha(path.read_bytes()) != sha(data):
        raise SystemExit(f"written file failed verification: {path}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--version")
    parser.add_argument("--channel", choices=["development", "release"], default="development")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    data, manifest = build(args.version, args.channel)
    args.output.mkdir(parents=True, exist_ok=True)
    home_name = args.output / f"{REPOSITORY}-{manifest['version']}.zip"
    legacy_name = args.output / f"highpoly_toggle-{manifest['version']}.zip"
    write_new(home_name, data)
    write_new(legacy_name, data)
    print(json.dumps({"version": manifest["version"], "channel": manifest["channel"], "files": len(manifest["files"]),
                      "bytes": len(data), "sha256": sha(data), "commit": manifest["source_commit"],
                      "dirty": manifest["source_dirty"], "home_asset": str(home_name),
                      "legacy_asset": str(legacy_name), "publish_legacy_as": "highpoly_toggle.zip"}, indent=2))


if __name__ == "__main__":
    main()
