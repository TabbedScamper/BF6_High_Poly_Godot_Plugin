"""BF6 high-poly parity laboratory.

This is an evidence runner, not a content pipeline.  Every game-facing step
reads the mounted Steam installation when it runs.  Files written by this tool
are reports and visual evidence only; no product consumes them at runtime.
"""

from __future__ import annotations

import argparse
import base64
import binascii
import hashlib
import html
import json
import math
import os
from pathlib import Path
import platform
import re
import shutil
import subprocess
import sys
import time
import tomllib
from typing import Any


HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
sys.path.insert(0, str(REPO / "tools"))
from workspace_paths import SDK_ROOT  # the main Godot SDK (bf6-dev.json)
DEFAULT_GAME = Path(r"C:\Program Files (x86)\Steam\steamapps\common\Battlefield 6")
DEFAULT_UNREAL = Path(r"C:\Users\mwalt\Documents\Unreal Projects\BF6_High_Poly")
DEFAULT_OUT = SDK_ROOT / "out" / "paritylab"


def utc_stamp() -> str:
    return time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())


def sha256(path: Path, chunk: int = 1024 * 1024) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        while b := f.read(chunk):
            h.update(b)
    return h.hexdigest()


def file_record(path: Path, hash_file: bool = True) -> dict[str, Any]:
    if not path.is_file():
        return {"path": str(path), "present": False}
    st = path.stat()
    row: dict[str, Any] = {
        "path": str(path), "present": True, "size": st.st_size,
        "mtime_ns": st.st_mtime_ns,
    }
    if hash_file:
        row["sha256"] = sha256(path)
    return row


def resolve_program(names: list[str], candidates: list[Path]) -> str | None:
    for name in names:
        found = shutil.which(name)
        if found:
            return str(Path(found).resolve())
    for candidate in candidates:
        if candidate.is_file():
            return str(candidate.resolve())
    return None


def inventory(game: Path, unreal: Path) -> dict[str, Any]:
    tools = {
        "cmake": resolve_program(["cmake"], [Path(r"C:\Program Files\CMake\bin\cmake.exe")]),
        "msbuild": resolve_program(["msbuild"], []),
        "pix": resolve_program(["WinPixUI", "pixtool"], [
            Path(r"C:\Program Files\Microsoft PIX\WinPixUI.exe"),
            Path(r"C:\Program Files\Microsoft PIX\pixtool.exe"),
        ]),
        "renderdoc": resolve_program(["qrenderdoc", "renderdoccmd"], [
            Path(r"C:\Program Files\RenderDoc\qrenderdoc.exe"),
            Path(r"C:\Program Files\RenderDoc\renderdoccmd.exe"),
        ]),
        "windbg": resolve_program(["WinDbgX", "windbg"], []),
        "dxc": resolve_program(["dxc"], sorted(
            Path(r"C:\Program Files (x86)\Windows Kits\10\bin").glob("*/x64/dxc.exe"),
            reverse=True)),
        "clang_cl": resolve_program(["clang-cl"], []),
        "nsight": resolve_program(["ngfx"], [
            Path(r"C:\Program Files\NVIDIA Corporation\Nsight Graphics\ngfx.exe")
        ]),
        "unreal_editor": resolve_program(["UnrealEditor"], [
            Path(r"C:\Program Files\Epic Games\UE_5.8\Engine\Binaries\Win64\UnrealEditor.exe")
        ]),
        "unreal_insights": resolve_program(["UnrealInsights"], [
            Path(r"C:\Program Files\Epic Games\UE_5.8\Engine\Binaries\Win64\UnrealInsights.exe")
        ]),
    }
    modules = {}
    for name in ("PIL", "numpy"):
        try:
            __import__(name)
            modules[name] = True
        except Exception:
            modules[name] = False
    exe = game / "bf6.exe"
    return {
        "schema": 1,
        "generated_utc": utc_stamp(),
        "host": {
            "platform": platform.platform(),
            "python": sys.version,
            "executable": sys.executable,
        },
        "paths": {
            "sdk_root": str(SDK_ROOT), "repo": str(REPO),
            "game": str(game), "unreal": str(unreal),
        },
        "game_executable": file_record(exe, hash_file=False),
        "python_modules": modules,
        "tools": tools,
    }


def command_doctor(args: argparse.Namespace) -> int:
    doc = inventory(args.game, args.unreal)
    required = {
        "Steam BF6 executable": doc["game_executable"]["present"],
        "CMake": bool(doc["tools"]["cmake"]),
        "Pillow": doc["python_modules"]["PIL"],
        "NumPy": doc["python_modules"]["numpy"],
        "Unreal project": (args.unreal / "BF6_Unreal_SDK.uproject").is_file(),
    }
    if args.json:
        print(json.dumps({**doc, "required": required}, indent=2))
    else:
        print("BF6 PARITY LAB DOCTOR")
        for name, ok in required.items():
            print(f"  {'PASS' if ok else 'FAIL':4}  {name}")
        print("\nOptional runtime diagnostics")
        for name, path in doc["tools"].items():
            if name in ("cmake", "unreal_editor"):
                continue
            print(f"  {'FOUND' if path else 'missing':7}  {name:16} {path or ''}")
        print("\nMissing optional tools do not fail doctor. They unlock the workflows in README.md.")
    return 0 if all(required.values()) else 1


def expand(value: str, variables: dict[str, str]) -> str:
    for key, replacement in variables.items():
        value = value.replace("{" + key + "}", replacement)
    return value


def load_profile(name_or_path: str) -> tuple[Path, dict[str, Any]]:
    path = Path(name_or_path)
    if not path.is_file():
        path = HERE / "profiles" / (name_or_path if name_or_path.endswith(".toml") else name_or_path + ".toml")
    with path.open("rb") as f:
        return path, tomllib.load(f)


def run_step(step: dict[str, Any], variables: dict[str, str], run_dir: Path) -> dict[str, Any]:
    name = str(step["name"])
    exe = Path(expand(str(step["exe"]), variables))
    argv = [str(exe)] + [expand(str(v), variables) for v in step.get("args", [])]
    timeout = float(step.get("timeout_s", 300))
    started = time.time()
    row: dict[str, Any] = {
        "name": name, "argv": argv, "started_utc": utc_stamp(),
        "executable": file_record(exe), "timeout_s": timeout,
    }
    if not exe.is_file():
        row.update(status="missing", returncode=None, duration_s=0.0,
                   failures=[f"executable not found: {exe}"])
        return row
    try:
        cp = subprocess.run(argv, cwd=str(REPO), capture_output=True, text=True,
                            errors="replace", timeout=timeout, shell=False)
        stdout, stderr = cp.stdout, cp.stderr
        row["returncode"] = cp.returncode
    except subprocess.TimeoutExpired as exc:
        stdout = exc.stdout or ""
        stderr = exc.stderr or ""
        if isinstance(stdout, bytes): stdout = stdout.decode(errors="replace")
        if isinstance(stderr, bytes): stderr = stderr.decode(errors="replace")
        row["returncode"] = None
        row["timed_out"] = True
    row["duration_s"] = round(time.time() - started, 6)
    (run_dir / f"{name}.stdout.log").write_text(stdout, encoding="utf-8")
    (run_dir / f"{name}.stderr.log").write_text(stderr, encoding="utf-8")
    failures: list[str] = []
    combined = stdout + "\n" + stderr
    if row.get("returncode") != int(step.get("expected_exit", 0)):
        failures.append(f"exit {row.get('returncode')} != {step.get('expected_exit', 0)}")
    for pattern in step.get("expect", []):
        if not re.search(str(pattern), combined, re.MULTILINE):
            failures.append(f"expected pattern absent: {pattern}")
    for pattern in step.get("forbid", []):
        if re.search(str(pattern), combined, re.MULTILINE):
            failures.append(f"forbidden pattern present: {pattern}")
    row["failures"] = failures
    row["status"] = "pass" if not failures else "fail"
    return row


def write_run_html(report: dict[str, Any], path: Path) -> None:
    rows = []
    for step in report["steps"]:
        failures = "<br>".join(html.escape(x) for x in step.get("failures", []))
        rows.append(
            f"<tr><td>{html.escape(step['name'])}</td><td>{step['status']}</td>"
            f"<td>{step.get('duration_s', 0):.3f}s</td><td>{failures}</td></tr>"
        )
    body = f"""<!doctype html><meta charset=utf-8><title>BF6 parity run</title>
<style>body{{font:14px system-ui;margin:32px;background:#111;color:#ddd}}table{{border-collapse:collapse}}td,th{{padding:8px 12px;border:1px solid #555}}.pass{{color:#8f8}}</style>
<h1>{html.escape(report['profile'])}</h1><p>Overall: <b>{report['status']}</b></p>
<table><tr><th>Step</th><th>Status</th><th>Time</th><th>Evidence</th></tr>{''.join(rows)}</table>"""
    path.write_text(body, encoding="utf-8")


def command_run(args: argparse.Namespace) -> int:
    profile_path, profile = load_profile(args.profile)
    run_dir = args.out / f"{profile.get('name', profile_path.stem)}-{utc_stamp()}"
    run_dir.mkdir(parents=True, exist_ok=False)
    variables = {
        "repo": str(REPO), "sdk": str(SDK_ROOT), "game": str(args.game),
        "unreal": str(args.unreal), "build": str(REPO / "core" / "build" / "Release"),
        "out": str(run_dir), "python": sys.executable, "paritylab": str(Path(__file__).resolve()),
    }
    report: dict[str, Any] = {
        "schema": 1, "profile": profile.get("name", profile_path.stem),
        "description": profile.get("description", ""),
        "profile_file": file_record(profile_path),
        "environment": inventory(args.game, args.unreal), "steps": [],
    }
    for step in profile.get("steps", []):
        print(f"[{step['name']}]", flush=True)
        row = run_step(step, variables, run_dir)
        report["steps"].append(row)
        print(f"  {row['status']} in {row.get('duration_s', 0):.2f}s", flush=True)
        for failure in row.get("failures", []):
            print(f"  - {failure}")
        if row["status"] != "pass" and not args.keep_going:
            break
    report["status"] = "pass" if report["steps"] and all(s["status"] == "pass" for s in report["steps"]) else "fail"
    report["finished_utc"] = utc_stamp()
    (run_dir / "report.json").write_text(json.dumps(report, indent=2), encoding="utf-8")
    write_run_html(report, run_dir / "report.html")
    print(f"\n{report['status'].upper()}  {run_dir}")
    return 0 if report["status"] == "pass" else 1


def _image_modules():
    import numpy as np
    from PIL import Image, ImageChops
    return np, Image, ImageChops


def luma(rgb: Any, np: Any) -> Any:
    return rgb[..., 0] * 0.2126 + rgb[..., 1] * 0.7152 + rgb[..., 2] * 0.0722


def edge_energy(y: Any, np: Any) -> Any:
    gx = np.zeros_like(y); gy = np.zeros_like(y)
    gx[:, 1:] = np.abs(y[:, 1:] - y[:, :-1])
    gy[1:, :] = np.abs(y[1:, :] - y[:-1, :])
    return gx + gy


def corr(a: Any, b: Any, np: Any) -> float:
    aa = a.reshape(-1).astype(np.float64); bb = b.reshape(-1).astype(np.float64)
    aa -= aa.mean(); bb -= bb.mean()
    den = math.sqrt(float(np.dot(aa, aa) * np.dot(bb, bb)))
    return float(np.dot(aa, bb) / den) if den > 1e-20 else 0.0


def global_ssim(a: Any, b: Any, np: Any) -> float:
    aa = a.astype(np.float64); bb = b.astype(np.float64)
    ma, mb = float(aa.mean()), float(bb.mean())
    va, vb = float(aa.var()), float(bb.var())
    cov = float(((aa - ma) * (bb - mb)).mean())
    c1, c2 = (0.01 ** 2), (0.03 ** 2)
    return ((2 * ma * mb + c1) * (2 * cov + c2)) / ((ma * ma + mb * mb + c1) * (va + vb + c2))


def overlap_shift(ref: Any, cand: Any, dx: int, dy: int) -> tuple[Any, Any]:
    h, w = ref.shape[:2]
    rx0=max(0,dx); rx1=min(w,w+dx); ry0=max(0,dy); ry1=min(h,h+dy)
    cx0=max(0,-dx); cx1=min(w,w-dx); cy0=max(0,-dy); cy1=min(h,h-dy)
    return ref[ry0:ry1,rx0:rx1], cand[cy0:cy1,cx0:cx1]


def best_translation(ref: Any, cand: Any, radius: int, np: Any) -> tuple[int, int, float]:
    re = edge_energy(luma(ref, np), np); ce = edge_energy(luma(cand, np), np)
    # Search on a bounded working image; exact scoring happens at full size.
    stride = max(1, int(max(ref.shape[:2]) / 640))
    re = re[::stride, ::stride]; ce = ce[::stride, ::stride]
    rr = max(0, radius // stride)
    best = (0, 0, -2.0)
    for dy in range(-rr, rr + 1):
        for dx in range(-rr, rr + 1):
            a, b = overlap_shift(re, ce, dx, dy)
            score = corr(a, b, np) if a.size else -2.0
            if score > best[2]: best = (dx * stride, dy * stride, score)
    return best


def metrics(ref: Any, cand: Any, np: Any) -> dict[str, float]:
    d = ref.astype(np.float64) - cand.astype(np.float64)
    mse = float(np.mean(d * d)); mae = float(np.mean(np.abs(d)))
    ry, cy = luma(ref, np), luma(cand, np)
    re, ce = edge_energy(ry, np), edge_energy(cy, np)
    return {
        "mae": mae, "rmse": math.sqrt(mse),
        "psnr_db": 99.0 if mse <= 1e-20 else 10 * math.log10(1.0 / mse),
        "luma_correlation": corr(ry, cy, np),
        "ssim_global": global_ssim(ry, cy, np),
        "edge_correlation": corr(re, ce, np),
        "edge_mae": float(np.mean(np.abs(re - ce))),
    }


def block_shuffle(img: Any, block: int, np: Any) -> Any:
    out = img.copy(); h, w = img.shape[:2]
    coords = [(y, x) for y in range(0, h - block + 1, block)
              for x in range(0, w - block + 1, block)]
    if len(coords) < 2: return np.flip(img, axis=1).copy()
    # Fixed rotation preserves the exact histogram and rejects spatial coincidence.
    shift = max(1, len(coords) // 3)
    for i, (y, x) in enumerate(coords):
        sy, sx = coords[(i + shift) % len(coords)]
        out[y:y+block, x:x+block] = img[sy:sy+block, sx:sx+block]
    return out


def command_compare(args: argparse.Namespace) -> int:
    np, Image, _ = _image_modules()
    ref_img = Image.open(args.reference).convert("RGB")
    cand_img = Image.open(args.candidate).convert("RGB")
    if ref_img.size != cand_img.size:
        print(f"size mismatch: reference {ref_img.size}, candidate {cand_img.size}", file=sys.stderr)
        return 2
    ref = np.asarray(ref_img, dtype=np.float32) / 255.0
    cand = np.asarray(cand_img, dtype=np.float32) / 255.0
    dx, dy, search_score = best_translation(ref, cand, args.max_shift, np)
    ar, ac = overlap_shift(ref, cand, dx, dy)
    real = metrics(ar, ac, np)
    shuffled = block_shuffle(ac, args.control_block, np)
    control = metrics(ar, shuffled, np)
    out = args.out
    out.mkdir(parents=True, exist_ok=True)
    diff = np.abs(ar - ac)
    heat = np.zeros_like(diff)
    heat[..., 0] = np.clip(diff.mean(axis=2) * 4.0, 0, 1)
    heat[..., 1] = np.clip(1.0 - diff.mean(axis=2) * 4.0, 0, 1) * 0.15
    Image.fromarray(np.uint8(np.clip(heat, 0, 1) * 255)).save(out / "heatmap.png")
    Image.fromarray(np.uint8(np.clip(ar, 0, 1) * 255)).save(out / "reference_overlap.png")
    Image.fromarray(np.uint8(np.clip(ac, 0, 1) * 255)).save(out / "candidate_aligned.png")
    Image.fromarray(np.uint8(np.clip(ar, 0, 1) * 255)).save(
        out / "blink.gif", save_all=True,
        append_images=[Image.fromarray(np.uint8(np.clip(ac, 0, 1) * 255))],
        duration=450, loop=0)
    report = {
        "schema": 1, "generated_utc": utc_stamp(),
        "reference": file_record(args.reference), "candidate": file_record(args.candidate),
        "alignment": {"dx": dx, "dy": dy, "search_edge_correlation": search_score,
                      "overlap_width": int(ar.shape[1]), "overlap_height": int(ar.shape[0])},
        "real": real, "control": {"method": f"fixed {args.control_block}px block rotation", **control},
        "separation": {k: real[k] - control[k] for k in ("luma_correlation", "ssim_global", "edge_correlation")},
    }
    (out / "report.json").write_text(json.dumps(report, indent=2), encoding="utf-8")
    print(json.dumps(report, indent=2))
    return 0


_QUADRANT_RE = re.compile(
    r"^(control|experiment|gray-bindless) q([0-3]):\s+"
    r"([-+0-9.eE]+)\s+([-+0-9.eE]+)\s+([-+0-9.eE]+)\s+([-+0-9.eE]+)$",
    re.MULTILINE,
)


def _run_dxil_adapter(exe: Path, game: Path, level: str, warp: bool,
                      timeout: float) -> dict[str, Any]:
    argv = [str(exe), str(game), level] + (["--warp"] if warp else [])
    started = time.time()
    try:
        cp = subprocess.run(argv, cwd=str(REPO), capture_output=True, text=True,
                            errors="replace", timeout=timeout, shell=False)
        stdout, stderr, returncode = cp.stdout, cp.stderr, cp.returncode
    except subprocess.TimeoutExpired as exc:
        stdout, stderr, returncode = exc.stdout or "", exc.stderr or "", None
        if isinstance(stdout, bytes): stdout = stdout.decode(errors="replace")
        if isinstance(stderr, bytes): stderr = stderr.decode(errors="replace")
    values: dict[str, list[list[float] | None]] = {
        "control": [None] * 4, "experiment": [None] * 4, "gray-bindless": [None] * 4,
    }
    for match in _QUADRANT_RE.finditer(stdout):
        values[match.group(1)][int(match.group(2))] = [float(match.group(i)) for i in range(3, 7)]
    complete = all(v is not None for group in values.values() for v in group)
    return {
        "mode": "warp" if warp else "hardware", "argv": argv,
        "returncode": returncode, "duration_s": round(time.time() - started, 6),
        "test_pass": returncode == 0 and "routing + live bindless" in stdout and "PASS" in stdout,
        "values_complete": complete, "values": values,
        "stdout": stdout, "stderr": stderr,
    }


def command_dxil_adapters(args: argparse.Namespace) -> int:
    if not args.exe.is_file():
        print(f"dispatch executable not found: {args.exe}", file=sys.stderr)
        return 2
    hardware = _run_dxil_adapter(args.exe, args.game, args.level, False, args.timeout)
    warp = _run_dxil_adapter(args.exe, args.game, args.level, True, args.timeout)
    both_pass = bool(hardware["test_pass"] and warp["test_pass"] and
                     hardware["values_complete"] and warp["values_complete"])
    differences: dict[str, Any] = {}
    if both_pass:
        for group in ("control", "experiment", "gray-bindless"):
            flat = [abs(hardware["values"][group][q][c] - warp["values"][group][q][c])
                    for q in range(4) for c in range(4)]
            differences[group] = {
                "max_abs": max(flat), "mean_abs": sum(flat) / len(flat),
            }
    max_delta = max((v["max_abs"] for v in differences.values()), default=math.inf)
    classification = "MATCH" if both_pass and max_delta <= args.tolerance else "DIVERGENT"
    report = {
        "schema": 1, "generated_utc": utc_stamp(),
        "purpose": "software D3D12 control for the same live BF6 terrain DXIL inputs",
        "executable": file_record(args.exe),
        "game_executable": file_record(args.game / "bf6.exe", hash_file=False),
        "level": args.level, "tolerance": args.tolerance,
        "both_pass": both_pass, "classification": classification,
        "differences": differences, "hardware": hardware, "warp": warp,
    }
    if args.out:
        args.out.mkdir(parents=True, exist_ok=True)
        (args.out / "hardware.stdout.log").write_text(hardware["stdout"], encoding="utf-8")
        (args.out / "hardware.stderr.log").write_text(hardware["stderr"], encoding="utf-8")
        (args.out / "warp.stdout.log").write_text(warp["stdout"], encoding="utf-8")
        (args.out / "warp.stderr.log").write_text(warp["stderr"], encoding="utf-8")
        (args.out / "report.json").write_text(json.dumps(report, indent=2), encoding="utf-8")
    summary = {k: report[k] for k in ("both_pass", "classification", "tolerance", "differences")}
    print(json.dumps(summary, indent=2))
    if not both_pass:
        return 1
    return 1 if args.require_match and classification != "MATCH" else 0


def _decode_page_payload(payload: str, side: int) -> bytes | None:
    try:
        raw = base64.b64decode(payload, validate=True)
    except (binascii.Error, ValueError):
        return None
    return raw if len(raw) == side * side * 4 else None


def command_page_pipe(args: argparse.Namespace) -> int:
    """Exercise the no-file transport intended for the Unreal sidecar seam."""
    if not args.exe.is_file():
        print(f"dispatch executable not found: {args.exe}", file=sys.stderr)
        return 2
    argv = [str(args.exe), str(args.game), args.level, "--page-dispatch",
            f"{args.x:.9g}", f"{args.z:.9g}", "ignored.ppm",
            "--page-size-m", f"{args.span:.9g}", "--stdout-rgba8", "--no-files"]
    started = time.time()
    try:
        cp = subprocess.run(argv, cwd=str(REPO), capture_output=True, text=True,
                            errors="replace", timeout=args.timeout, shell=False)
        stdout, stderr, returncode = cp.stdout, cp.stderr, cp.returncode
    except subprocess.TimeoutExpired as exc:
        stdout, stderr, returncode = exc.stdout or "", exc.stderr or "", None
        if isinstance(stdout, bytes): stdout = stdout.decode(errors="replace")
        if isinstance(stderr, bytes): stderr = stderr.decode(errors="replace")
    marker = next((line for line in stdout.splitlines()
                   if line.startswith("BF6_PAGE_RGBA8_V1 ")), "")
    fields = marker.split(" ", 5)
    meta_ok = False
    side = 0
    raw: bytes | None = None
    lo_x = lo_z = span = math.nan
    if len(fields) == 6:
        try:
            side = int(fields[1]); lo_x=float(fields[2]); lo_z=float(fields[3]); span=float(fields[4])
            meta_ok = side > 0 and math.isfinite(lo_x) and math.isfinite(lo_z) and span > 0
            raw = _decode_page_payload(fields[5], side) if meta_ok else None
        except ValueError:
            pass
    # The transport consumer must reject a syntactically valid but short frame,
    # not merely rely on base64 decoding to throw.
    truncated = _decode_page_payload(fields[5][:-4], side) if len(fields) == 6 and side else None
    control_rejected = truncated is None
    pipe_pass = returncode == 0 and raw is not None and control_rejected
    clean_stdout = "\n".join(line for line in stdout.splitlines()
                              if not line.startswith("BF6_PAGE_RGBA8_V1 ")) + "\n"
    report: dict[str, Any] = {
        "schema": 1, "generated_utc": utc_stamp(), "argv": argv,
        "duration_s": round(time.time()-started, 6), "returncode": returncode,
        "executable": file_record(args.exe),
        "game_executable": file_record(args.game / "bf6.exe", hash_file=False),
        "level": args.level, "requested_center": [args.x, args.z],
        "requested_span_m": args.span, "metadata_valid": meta_ok,
        "side": side, "lo": [lo_x, lo_z], "span_m": span,
        "rgba_bytes": len(raw) if raw is not None else 0,
        "rgba_sha256": hashlib.sha256(raw).hexdigest() if raw is not None else None,
        "control": {"method": "remove one base64 quartet", "rejected": control_rejected},
        "pipe_transport_pass": pipe_pass,
    }
    if args.out:
        args.out.mkdir(parents=True, exist_ok=True)
        (args.out / "stdout.log").write_text(clean_stdout, encoding="utf-8")
        (args.out / "stderr.log").write_text(stderr, encoding="utf-8")
        (args.out / "report.json").write_text(json.dumps(report, indent=2), encoding="utf-8")
        if raw is not None:
            _, Image, _ = _image_modules()
            Image.frombytes("RGBA", (side, side), raw).save(args.out / "page.png")
    print(json.dumps(report, indent=2))
    return 0 if pipe_pass else 1


def command_list(_: argparse.Namespace) -> int:
    for path in sorted((HERE / "profiles").glob("*.toml")):
        _, doc = load_profile(str(path))
        print(f"{doc.get('name', path.stem):24} {doc.get('description', '')}")
    return 0


def parser() -> argparse.ArgumentParser:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--game", type=Path, default=Path(os.environ.get("BF6_GAME_DIR", DEFAULT_GAME)))
    ap.add_argument("--unreal", type=Path, default=Path(os.environ.get("BF6_UNREAL_PROJECT", DEFAULT_UNREAL)))
    sub = ap.add_subparsers(dest="command", required=True)
    p = sub.add_parser("doctor", help="audit required and optional tools")
    p.add_argument("--json", action="store_true"); p.set_defaults(func=command_doctor)
    p = sub.add_parser("list", help="list verification profiles"); p.set_defaults(func=command_list)
    p = sub.add_parser("run", help="run a profile and capture evidence")
    p.add_argument("profile"); p.add_argument("--out", type=Path, default=DEFAULT_OUT)
    p.add_argument("--keep-going", action="store_true"); p.set_defaults(func=command_run)
    p = sub.add_parser("compare", help="align and compare two equal-size captures")
    p.add_argument("reference", type=Path); p.add_argument("candidate", type=Path)
    p.add_argument("--out", type=Path, required=True); p.add_argument("--max-shift", type=int, default=24)
    p.add_argument("--control-block", type=int, default=32); p.set_defaults(func=command_compare)
    p = sub.add_parser("dxil-adapters", help="compare live terrain DXIL on hardware and WARP")
    p.add_argument("--exe", type=Path, default=REPO / "core" / "build" / "Release" / "terraindxil_dispatch_test.exe")
    p.add_argument("--level", default="mp_isolated"); p.add_argument("--timeout", type=float, default=300)
    p.add_argument("--tolerance", type=float, default=1e-5); p.add_argument("--out", type=Path)
    p.add_argument("--require-match", action="store_true"); p.set_defaults(func=command_dxil_adapters)
    p = sub.add_parser("page-pipe", help="validate the no-file RGBA page transport for Unreal")
    p.add_argument("--exe", type=Path, default=REPO / "core" / "build" / "Release" / "terraindxil_dispatch_test.exe")
    p.add_argument("--level", default="mp_isolated");p.add_argument("--x", type=float, default=-778.96216226)
    p.add_argument("--z", type=float, default=412.78984774);p.add_argument("--span", type=float, default=16.0)
    p.add_argument("--timeout", type=float, default=300);p.add_argument("--out", type=Path)
    p.set_defaults(func=command_page_pipe)
    return ap


def main() -> int:
    args = parser().parse_args()
    return int(args.func(args))


if __name__ == "__main__":
    raise SystemExit(main())
