"""Non-invasive visual oracle recorder for BF6 reconstruction work.

The recorder observes only process existence, Windows Desktop Duplication
output, and (when explicitly requested) operating-system ETW GPU events.  It
does not open the target process, read its memory, inject code, alter game
files, manipulate networking, or launch Battlefield.
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import sys
import time
from typing import Any


HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
from workspace_paths import SDK_ROOT  # the main Godot SDK (bf6-dev.json)
DEFAULT_GAME = Path(r"C:\Program Files (x86)\Steam\steamapps\common\Battlefield 6")
DEFAULT_OUT = SDK_ROOT / "out" / "paritylab" / "oracle"
FFMPEG_CANDIDATES = (
    Path(r"C:\Program Files\Lian-Li\L-Connect 3\x64\ffmpeg.exe"),
    Path(r"C:\Program Files\BlueStacks_nxt\ffmpeg.exe"),
)
CONTROL_PROCESS = "__bf6_oracle_control_never__.exe"


def utc_stamp() -> str:
    return time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())


def sha256(path: Path, chunk: int = 1024 * 1024) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        while block := stream.read(chunk):
            digest.update(block)
    return digest.hexdigest()


def file_record(path: Path, hash_file: bool = True) -> dict[str, Any]:
    if not path.is_file():
        return {"path": str(path), "present": False}
    stat = path.stat()
    result: dict[str, Any] = {
        "path": str(path),
        "present": True,
        "size": stat.st_size,
        "mtime_ns": stat.st_mtime_ns,
    }
    if hash_file:
        result["sha256"] = sha256(path)
    return result


def run_text(argv: list[str], timeout: float = 20.0) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        argv, capture_output=True, text=True, errors="replace", timeout=timeout,
        check=False, shell=False,
    )


def find_ffmpeg(explicit: Path | None) -> Path | None:
    candidates: list[Path] = []
    if explicit:
        candidates.append(explicit)
    found = shutil.which("ffmpeg")
    if found:
        candidates.append(Path(found))
    candidates.extend(FFMPEG_CANDIDATES)
    seen: set[str] = set()
    for candidate in candidates:
        try:
            resolved = candidate.resolve()
        except OSError:
            continue
        key = str(resolved).casefold()
        if key in seen or not resolved.is_file():
            continue
        seen.add(key)
        try:
            filters = run_text([str(resolved), "-hide_banner", "-filters"]).stdout
            encoders = run_text([str(resolved), "-hide_banner", "-encoders"]).stdout
        except (OSError, subprocess.TimeoutExpired):
            continue
        if "ddagrab" in filters and "libx264rgb" in encoders:
            return resolved
    return None


def find_ffprobe(ffmpeg: Path) -> Path | None:
    sibling = ffmpeg.with_name("ffprobe.exe")
    if sibling.is_file():
        return sibling
    found = shutil.which("ffprobe")
    return Path(found).resolve() if found else None


def process_ids(image_name: str) -> list[int]:
    """Enumerate by image name only; this does not open a process handle."""
    cp = run_text([
        "tasklist.exe", "/FI", f"IMAGENAME eq {image_name}", "/FO", "CSV", "/NH",
    ])
    if cp.returncode != 0:
        return []
    result: list[int] = []
    for row in csv.reader(cp.stdout.splitlines()):
        if len(row) < 2 or row[0].startswith("INFO:"):
            continue
        if row[0].casefold() != image_name.casefold():
            continue
        try:
            result.append(int(row[1]))
        except ValueError:
            continue
    return sorted(result)


def ffmpeg_version(ffmpeg: Path) -> str:
    cp = run_text([str(ffmpeg), "-hide_banner", "-version"])
    return cp.stdout.splitlines()[0] if cp.stdout else "unknown"


def ffmpeg_capture_argv(ffmpeg: Path, output: Path, fps: float,
                        output_idx: int, draw_mouse: bool) -> list[str]:
    source = (
        f"ddagrab=output_idx={output_idx}:framerate={fps:g}:"
        f"draw_mouse={1 if draw_mouse else 0}:output_fmt=bgra,"
        "hwdownload,format=bgra,format=bgr0"
    )
    return [
        str(ffmpeg), "-hide_banner", "-loglevel", "info",
        "-filter_complex", source,
        "-c:v", "libx264rgb", "-preset", "ultrafast", "-crf", "0",
        "-pix_fmt", "bgr0", "-y", str(output),
    ]


def stop_child(process: subprocess.Popen[bytes], timeout: float = 30.0) -> tuple[int | None, str]:
    if process.poll() is not None:
        return process.returncode, "already-exited"
    try:
        if process.stdin:
            process.stdin.write(b"q\n")
            process.stdin.flush()
        return process.wait(timeout=timeout), "graceful-q"
    except (BrokenPipeError, OSError, subprocess.TimeoutExpired):
        process.terminate()
        try:
            return process.wait(timeout=10), "terminate"
        except subprocess.TimeoutExpired:
            process.kill()
            return process.wait(timeout=10), "kill"


def codec_control(ffmpeg: Path, directory: Path) -> dict[str, Any]:
    """Prove that the selected RGB codec round-trips bytes exactly."""
    directory.mkdir(parents=True, exist_ok=True)
    source = directory / "source.bgr0"
    encoded = directory / "encoded.mkv"
    decoded = directory / "decoded.bgr0"
    commands = [
        [str(ffmpeg), "-hide_banner", "-loglevel", "error", "-f", "lavfi",
         "-i", "testsrc2=size=256x144:rate=1", "-frames:v", "1",
         "-pix_fmt", "bgr0", "-f", "rawvideo", "-y", str(source)],
        [str(ffmpeg), "-hide_banner", "-loglevel", "error", "-f", "rawvideo",
         "-pixel_format", "bgr0", "-video_size", "256x144", "-framerate", "1",
         "-i", str(source), "-frames:v", "1", "-c:v", "libx264rgb",
         "-preset", "ultrafast", "-crf", "0", "-pix_fmt", "bgr0",
         "-y", str(encoded)],
        [str(ffmpeg), "-hide_banner", "-loglevel", "error", "-i", str(encoded),
         "-frames:v", "1", "-pix_fmt", "bgr0", "-f", "rawvideo",
         "-y", str(decoded)],
    ]
    rows: list[dict[str, Any]] = []
    for argv in commands:
        cp = run_text(argv, timeout=60)
        rows.append({"argv": argv, "returncode": cp.returncode, "stderr": cp.stderr})
        if cp.returncode != 0:
            break
    source_hash = sha256(source) if source.is_file() else None
    decoded_hash = sha256(decoded) if decoded.is_file() else None
    return {
        "method": "generated BGR0 frame -> libx264rgb CRF 0 -> decoded BGR0",
        "source_sha256": source_hash,
        "decoded_sha256": decoded_hash,
        "byte_exact": bool(source_hash and source_hash == decoded_hash),
        "commands": rows,
    }


def start_wpr(run_dir: Path) -> dict[str, Any]:
    status = run_text(["wpr.exe", "-status"])
    status_text = (status.stdout + status.stderr).casefold()
    inactive_markers = (
        "wpr is not recording",
        "recording is not in progress",
        "there are no trace profiles running",
    )
    active = not any(marker in status_text for marker in inactive_markers)
    result: dict[str, Any] = {
        "requested": True,
        "preexisting_session": active,
        "started": False,
        "etl": str(run_dir / "gpu.etl"),
    }
    if active:
        result["error"] = "an ETW/WPR session already exists; it was left untouched"
        return result
    cp = run_text(["wpr.exe", "-start", "GPU", "-filemode"], timeout=30)
    result.update(returncode=cp.returncode, stdout=cp.stdout, stderr=cp.stderr,
                  started=cp.returncode == 0)
    return result


def stop_wpr(state: dict[str, Any]) -> None:
    if not state.get("started"):
        return
    cp = run_text(["wpr.exe", "-stop", str(state["etl"])], timeout=120)
    state.update(stop_returncode=cp.returncode, stop_stdout=cp.stdout,
                 stop_stderr=cp.stderr, stopped=cp.returncode == 0)


def probe_video(ffprobe: Path | None, video: Path) -> dict[str, Any] | None:
    if not ffprobe or not video.is_file():
        return None
    cp = run_text([
        str(ffprobe), "-v", "error", "-show_streams", "-show_format",
        "-of", "json", str(video),
    ], timeout=60)
    if cp.returncode != 0:
        return {"returncode": cp.returncode, "stderr": cp.stderr}
    try:
        return json.loads(cp.stdout)
    except json.JSONDecodeError:
        return {"returncode": cp.returncode, "stdout": cp.stdout}


def extract_frame(ffmpeg: Path, video: Path, output: Path,
                  seek_s: float = 0.0) -> dict[str, Any]:
    cp = run_text([
        str(ffmpeg), "-hide_banner", "-loglevel", "error",
        "-ss", f"{seek_s:.6f}", "-i", str(video),
        "-frames:v", "1", "-pix_fmt", "rgb24", "-y", str(output),
    ], timeout=120)
    return {"seek_s": seek_s, "returncode": cp.returncode, "stderr": cp.stderr,
            "file": file_record(output) if output.is_file() else None}


def write_report(path: Path, report: dict[str, Any]) -> None:
    path.write_text(json.dumps(report, indent=2), encoding="utf-8")


def capture_verdict(report: dict[str, Any], run_dir: Path) -> tuple[bool, dict[str, Any]]:
    capture = report.get("capture", {})
    video = capture.get("video") or {}
    probe = capture.get("probe") or {}
    streams = probe.get("streams") or []
    try:
        duration = float((probe.get("format") or {}).get("duration", 0.0))
    except (TypeError, ValueError):
        duration = 0.0
    log_path = run_dir / "ffmpeg.log"
    try:
        log_tail = log_path.read_text(encoding="utf-8", errors="replace")[-4096:]
    except OSError:
        log_tail = ""
    returncode = capture.get("returncode")
    requested_interrupt = capture.get("exit_reason") == "keyboard-interrupt"
    normal_signal_exit = (
        requested_interrupt and returncode == 255 and
        "Exiting normally, received signal 2." in log_tail
    )
    checks = {
        "video_nonempty": bool(video.get("present") and video.get("size", 0) > 0),
        "container_readable": bool(streams and duration > 0.0),
        "codec_control_byte_exact": bool(
            ((report.get("controls") or {}).get("codec_roundtrip") or {}).get("byte_exact")
        ),
        "encoder_exit_accepted": returncode == 0 or normal_signal_exit,
        "user_requested_interrupt": requested_interrupt,
        "normal_signal_exit": normal_signal_exit,
        "duration_s": duration,
    }
    passed = all(checks[key] for key in (
        "video_nonempty", "container_readable", "codec_control_byte_exact",
        "encoder_exit_accepted",
    ))
    return passed, checks


def verify(args: argparse.Namespace) -> int:
    run_dir = args.run.resolve()
    report_path = run_dir / "report.json"
    try:
        report = json.loads(report_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        print(f"Cannot read {report_path}: {exc}", file=sys.stderr)
        return 2
    ffmpeg = find_ffmpeg(args.ffmpeg)
    video = run_dir / "display-lossless-rgb.mkv"
    if ffmpeg and video.is_file():
        report["capture"]["video"] = file_record(video)
        report["capture"]["probe"] = probe_video(find_ffprobe(ffmpeg), video)
    passed, checks = capture_verdict(report, run_dir)
    report["capture"]["verification"] = checks
    report["status"] = "pass" if passed else "failed"
    report["reverified_utc"] = utc_stamp()
    write_report(report_path, report)
    print(json.dumps({"status": report["status"], "checks": checks,
                      "report": str(report_path)}, indent=2))
    return 0 if passed else 1


def doctor(args: argparse.Namespace) -> int:
    ffmpeg = find_ffmpeg(args.ffmpeg)
    result = {
        "schema": 1,
        "generated_utc": utc_stamp(),
        "ffmpeg": file_record(ffmpeg, hash_file=False) if ffmpeg else None,
        "ffmpeg_version": ffmpeg_version(ffmpeg) if ffmpeg else None,
        "ffprobe": str(find_ffprobe(ffmpeg)) if ffmpeg and find_ffprobe(ffmpeg) else None,
        "wpr": shutil.which("wpr.exe"),
        "target_process": args.target,
        "target_pids_now": process_ids(args.target),
        "negative_control_process": CONTROL_PROCESS,
        "negative_control_pids": process_ids(CONTROL_PROCESS),
        "boundary": {
            "network_changes": False,
            "process_injection": False,
            "process_memory_reads": False,
            "game_file_modification": False,
            "video_surface": "Windows Desktop Duplication API",
            "telemetry_surface": "optional Windows ETW GPU profile",
        },
    }
    print(json.dumps(result, indent=2))
    return 0 if ffmpeg and not result["negative_control_pids"] else 1


def self_test(args: argparse.Namespace) -> int:
    """Run the full watcher against a short-lived loopback ping control."""
    creation_flags = getattr(subprocess, "CREATE_NO_WINDOW", 0)
    control = subprocess.Popen(
        [r"C:\Windows\System32\PING.EXE", "127.0.0.1", "-n", "5"],
        stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL, shell=False, creationflags=creation_flags,
    )
    args.target = "PING.EXE"
    args.wait = 5.0
    args.max_duration = 15.0
    args.exit_grace = 1.0
    args.poll = 0.25
    args.fps = 2.0
    args.draw_mouse = False
    args.min_free_gb = 1.0
    args.wpr_gpu = False
    try:
        return record(args)
    finally:
        if control.poll() is None:
            control.terminate()
            try:
                control.wait(timeout=5)
            except subprocess.TimeoutExpired:
                control.kill()


def record(args: argparse.Namespace) -> int:
    ffmpeg = find_ffmpeg(args.ffmpeg)
    if not ffmpeg:
        print("No FFmpeg build with ddagrab and libx264rgb was found.", file=sys.stderr)
        return 2
    if args.fps <= 0 or args.fps > 60:
        print("--fps must be greater than 0 and at most 60", file=sys.stderr)
        return 2
    free_gb = shutil.disk_usage(args.out.parent if args.out.parent.exists() else SDK_ROOT).free / (1024 ** 3)
    if free_gb < args.min_free_gb:
        print(f"Only {free_gb:.2f} GiB free; --min-free-gb requires {args.min_free_gb:g}.", file=sys.stderr)
        return 2

    run_dir = args.out / f"{utc_stamp()}-{Path(args.target).stem.lower()}"
    run_dir.mkdir(parents=True, exist_ok=False)
    video = run_dir / "display-lossless-rgb.mkv"
    log_path = run_dir / "ffmpeg.log"
    report_path = run_dir / "report.json"
    game_exe = args.game / "bf6.exe"
    report: dict[str, Any] = {
        "schema": 1,
        "generated_utc": utc_stamp(),
        "status": "waiting",
        "host": {"platform": platform.platform(), "python": sys.version},
        "target": {"image_name": args.target, "events": []},
        "game_executable": file_record(game_exe) if game_exe.is_file() else None,
        "capture": {
            "surface": "Windows Desktop Duplication API",
            "output_idx": args.output_idx,
            "fps": args.fps,
            "pixel_contract": "8-bit post-composition BGR0; no chroma subsampling",
            "codec": "libx264rgb CRF 0",
            "draw_mouse": args.draw_mouse,
            "file": str(video),
        },
        "boundary": {
            "network_changes": False,
            "process_injection": False,
            "process_memory_reads": False,
            "game_file_modification": False,
            "target_process_handles_opened": False,
            "target_launched_by_recorder": False,
        },
        "controls": {
            "negative_process": {
                "image_name": CONTROL_PROCESS,
                "pids": process_ids(CONTROL_PROCESS),
            },
            "codec_roundtrip": None,
        },
        "ffmpeg": {"file": file_record(ffmpeg), "version": ffmpeg_version(ffmpeg)},
        "wpr": {"requested": bool(args.wpr_gpu), "started": False},
        "free_gb_before": free_gb,
    }
    write_report(report_path, report)
    if report["controls"]["negative_process"]["pids"]:
        report.update(status="failed", error="impossible negative-control process exists")
        write_report(report_path, report)
        return 1

    print(f"Waiting up to {args.wait:g}s for {args.target} ...")
    wait_started = time.monotonic()
    pids: list[int] = []
    while time.monotonic() - wait_started < args.wait:
        pids = process_ids(args.target)
        if pids:
            break
        time.sleep(min(args.poll, 1.0))
    if not pids:
        report.update(status="target-not-seen", finished_utc=utc_stamp())
        write_report(report_path, report)
        print(f"Target was not seen. Evidence: {report_path}")
        return 3

    report["target"]["events"].append({"utc": utc_stamp(), "state": "seen", "pids": pids})
    report["status"] = "recording"
    report["controls"]["codec_roundtrip"] = codec_control(ffmpeg, run_dir / "codec-control")
    if not report["controls"]["codec_roundtrip"]["byte_exact"]:
        report.update(status="failed", error="lossless RGB codec control failed")
        write_report(report_path, report)
        print(f"Codec control failed. Evidence: {report_path}", file=sys.stderr)
        return 1

    capture_argv = ffmpeg_capture_argv(
        ffmpeg, video, args.fps, args.output_idx, args.draw_mouse,
    )
    report["capture"]["argv"] = capture_argv
    if args.wpr_gpu:
        report["wpr"] = start_wpr(run_dir)
    write_report(report_path, report)

    ffmpeg_process: subprocess.Popen[bytes] | None = None
    log_stream = log_path.open("wb")
    exit_reason = "unknown"
    try:
        ffmpeg_process = subprocess.Popen(
            capture_argv, stdin=subprocess.PIPE, stdout=log_stream,
            stderr=subprocess.STDOUT, shell=False,
        )
        capture_started = time.monotonic()
        absent_since: float | None = None
        last_pids = pids
        print(f"Recording {args.target} to {video}")
        while True:
            now = time.monotonic()
            current = process_ids(args.target)
            if current != last_pids:
                report["target"]["events"].append({
                    "utc": utc_stamp(), "state": "seen" if current else "absent",
                    "pids": current,
                })
                last_pids = current
            if current:
                absent_since = None
            elif absent_since is None:
                absent_since = now
            elif now - absent_since >= args.exit_grace:
                exit_reason = "target-exited"
                break
            if ffmpeg_process.poll() is not None:
                exit_reason = "capture-process-exited"
                break
            if now - capture_started >= args.max_duration:
                exit_reason = "max-duration"
                break
            time.sleep(args.poll)
    except KeyboardInterrupt:
        exit_reason = "keyboard-interrupt"
    finally:
        stop_mode = "not-started"
        returncode: int | None = None
        if ffmpeg_process is not None:
            returncode, stop_mode = stop_child(ffmpeg_process)
        log_stream.close()
        stop_wpr(report["wpr"])

    report["capture"].update(
        returncode=returncode,
        stop_mode=stop_mode,
        exit_reason=exit_reason,
        video=file_record(video) if video.is_file() else None,
        log=file_record(log_path),
    )
    ffprobe = find_ffprobe(ffmpeg)
    report["capture"]["probe"] = probe_video(ffprobe, video)
    if video.is_file() and video.stat().st_size:
        report["capture"]["first_frame"] = extract_frame(
            ffmpeg, video, run_dir / "frame-first.png",
        )
        try:
            duration = float(report["capture"]["probe"]["format"]["duration"])
        except (KeyError, TypeError, ValueError):
            duration = 0.0
        if duration > 1.0:
            report["capture"]["middle_frame"] = extract_frame(
                ffmpeg, video, run_dir / "frame-middle.png", duration * 0.5,
            )
    report["free_gb_after"] = shutil.disk_usage(run_dir).free / (1024 ** 3)
    report["finished_utc"] = utc_stamp()
    video_ok, verification = capture_verdict(report, run_dir)
    report["capture"]["verification"] = verification
    report["status"] = "pass" if video_ok else "failed"
    write_report(report_path, report)
    print(json.dumps({
        "status": report["status"],
        "exit_reason": exit_reason,
        "codec_control_byte_exact": report["controls"]["codec_roundtrip"]["byte_exact"],
        "video": str(video),
        "report": str(report_path),
    }, indent=2))
    return 0 if video_ok else 1


def parser() -> argparse.ArgumentParser:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--ffmpeg", type=Path)
    ap.add_argument("--game", type=Path, default=DEFAULT_GAME)
    ap.add_argument("--target", default="bf6.exe")
    sub = ap.add_subparsers(dest="command", required=True)

    p = sub.add_parser("doctor", help="audit capture support without recording")
    p.set_defaults(func=doctor)

    p = sub.add_parser("self-test", help="exercise capture and automatic stop on a harmless control")
    p.add_argument("--out", type=Path, default=DEFAULT_OUT)
    p.add_argument("--output-idx", type=int, default=0)
    p.set_defaults(func=self_test)

    p = sub.add_parser("verify", help="revalidate a completed recorder directory")
    p.add_argument("run", type=Path)
    p.set_defaults(func=verify)

    p = sub.add_parser("record", help="wait for a process and record display output")
    p.add_argument("--out", type=Path, default=DEFAULT_OUT)
    p.add_argument("--wait", type=float, default=900.0,
                   help="seconds to wait for the target process")
    p.add_argument("--max-duration", type=float, default=300.0,
                   help="maximum recording seconds")
    p.add_argument("--exit-grace", type=float, default=5.0,
                   help="seconds target may disappear before recording stops")
    p.add_argument("--poll", type=float, default=0.5)
    p.add_argument("--fps", type=float, default=2.0,
                   help="lossless RGB frames per second; static parity defaults to 2")
    p.add_argument("--output-idx", type=int, default=0)
    p.add_argument("--draw-mouse", action="store_true")
    p.add_argument("--min-free-gb", type=float, default=10.0)
    p.add_argument("--wpr-gpu", action="store_true",
                   help="also request the Windows ETW GPU profile; off by default")
    p.set_defaults(func=record)
    return ap


def main() -> int:
    args = parser().parse_args()
    return int(args.func(args))


if __name__ == "__main__":
    raise SystemExit(main())
