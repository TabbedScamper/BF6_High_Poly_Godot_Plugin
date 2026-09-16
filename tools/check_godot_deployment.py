"""Detect stale or incomplete installed high-poly code without modifying it.

This checks deployment identity, not rendering parity or ABI compatibility.
Extra files are reported for review and are never deleted automatically.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path

CODE_SUFFIXES = {'.gd', '.gdshader', '.gdextension', '.dll', '.tres'}


def inventory(root: Path) -> dict[str, str]:
    return {
        p.relative_to(root).as_posix(): hashlib.sha256(p.read_bytes()).hexdigest()
        for p in root.rglob('*')
        if p.is_file() and p.suffix.lower() in CODE_SUFFIXES
        and not any(part.startswith('.') for part in p.relative_to(root).parts)
    }


def check(source: Path, installed: Path) -> dict:
    if not source.is_dir() or not installed.is_dir():
        raise ValueError('Both source and installed add-on directories must exist')
    expected, actual = inventory(source), inventory(installed)
    if not expected or 'plugin.gd' not in expected and 'highpoly_toggle.gd' not in expected:
        raise ValueError('Source is not a high-poly add-on directory')
    missing = sorted(expected.keys() - actual.keys())
    changed = sorted(k for k in expected.keys() & actual.keys() if expected[k] != actual[k])
    return {'source': str(source), 'installed': str(installed), 'checked': len(expected),
            'missing': missing, 'changed': changed, 'extra': sorted(actual.keys() - expected.keys()),
            'matched': not missing and not changed}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path,
                        default=Path(__file__).resolve().parents[1] / 'addons/highpoly_toggle')
    parser.add_argument('--installed-addon', required=True, type=Path)
    parser.add_argument('--report', type=Path)
    args = parser.parse_args()
    try:
        result = check(args.source.resolve(), args.installed_addon.resolve())
    except (OSError, ValueError) as exc:
        parser.exit(2, str(exc) + '\n')
    output = json.dumps(result, indent=2)
    print(output)
    if args.report:
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(output + '\n', encoding='utf-8')
    return 0 if result['matched'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
