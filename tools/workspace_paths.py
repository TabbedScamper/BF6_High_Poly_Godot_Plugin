"""Workspace paths for the high-poly preview tools.

Every value has an explicit environment override. Otherwise the checkout's
parent folder may hold bf6-dev.json, which names where the main Godot SDK
lives: the newest PortalSDK-<version> under "sdksRoot" (the SDK that the
BF6 Godot SDK shortcut opens, including after an SDK replace). Without that
file the old layout still works: a checkout inside an SDK's
GodotProject/User_Created/tools folder uses that SDK.
"""

from __future__ import annotations

import json
import os
from pathlib import Path
import re


HERE = Path(__file__).resolve().parent
REPO = HERE.parent


def _dev_config() -> dict:
    path = REPO.parent / "bf6-dev.json"
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}
    return value if isinstance(value, dict) and value.get("format") == 1 else {}


def _version_key(name: str):
    match = re.fullmatch(r"PortalSDK-(\d+(?:\.\d+){1,3})", name)
    return tuple(int(part) for part in match.group(1).split(".")) if match else None


def newest_sdk(sdks_root: Path) -> Path | None:
    """The newest PortalSDK-<version> folder that is a complete SDK, or None."""
    best = None
    if sdks_root.is_dir():
        for child in sdks_root.iterdir():
            key = _version_key(child.name)
            if key and (child / "sdk.version.json").is_file() and (child / "GodotProject/project.godot").is_file():
                if best is None or key > best[0]:
                    best = (key, child)
    return best[1] if best else None


CONFIG = _dev_config()


def _default_sdk_root() -> Path:
    if CONFIG.get("sdksRoot"):
        found = newest_sdk(Path(CONFIG["sdksRoot"]))
        if found:
            return found
    return REPO.parents[3]


SDK_ROOT = Path(os.environ.get("PORTAL_SDK_ROOT") or _default_sdk_root()).resolve()
GODOT_PROJECT = Path(
    os.environ.get("BF6_PROJECT")
    or os.environ.get("BF6_SDK_PROJECT")
    or os.environ.get("PORTAL_GODOT_PROJECT")
    or SDK_ROOT / "GodotProject"
).resolve()
GODOT_BIN = Path(
    os.environ.get("GODOT_BIN")
    or SDK_ROOT / "Godot_v4.6.3-stable_win64.exe"
).resolve()
RESEARCH_ROOT = Path(
    os.environ.get("BF6_RESEARCH_ROOT")
    or CONFIG.get("researchRoot")
    or SDK_ROOT / "BF6_Frostbite_Research"
).resolve()
OUTPUT_ROOT = Path(os.environ.get("BF6_HIGHPOLY_OUT") or REPO / "out").resolve()
