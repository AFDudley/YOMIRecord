#!/usr/bin/env python3
"""End-to-end test of YOMIRecord. Runs inside the container; see README.md.

The container image is hustle's tools/replay_check image: Debian, the
GodotSteam 3.5.1 editor build, Xvfb and ffmpeg. This script:

1. prepares an imported copy of the game with hustle's replay_check prepare(),
2. puts the mod zip under test and the driver mod zip in the game's mods
   folder (ModLoader reads <executable dir>/mods),
3. starts the game normally (Main.tscn) with a fresh user directory,
4. waits for the driver mod's result, and probes each recording with ffprobe.

Exit code 0 means one recording exists with a video and an audio stream, and
the game log has no SCRIPT ERROR. In stable mode (E2E_STABLE=1) it also
requires the audio and video durations to differ by at most 50 ms, and
that ffmpeg trimmed no frames.
"""

from __future__ import annotations

import argparse
import importlib.util
import json
import re
import shutil
import subprocess
import sys
import zipfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
MODS_DIR = Path("/opt/godotsteam/mods")
GAME_TIMEOUT_S = 1800
sys.path.insert(0, str(HERE.parent.parent / "tools"))
import build_zip  # noqa: E402


def load_replay_check(hustle: Path):
    path = hustle / "tools" / "replay_check" / "run.py"
    spec = importlib.util.spec_from_file_location("replay_check_run", path)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    # dataclasses needs the module in sys.modules while it executes.
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def zip_folder(src: Path, prefix: str, dest: Path) -> None:
    """Zip the driver mod as <prefix>/... It has no assets to import."""
    with zipfile.ZipFile(dest, "w", zipfile.ZIP_DEFLATED) as zf:
        for path in sorted(p for p in src.rglob("*") if p.is_file()):
            zf.write(path, f"{prefix}/{path.relative_to(src).as_posix()}")


def probe(path: str) -> dict:
    out = subprocess.run(
        [
            "ffprobe",
            "-v",
            "error",
            "-show_entries",
            "format=duration:stream=codec_type,codec_name,width,height,nb_frames,duration",
            "-of",
            "json",
            path,
        ],
        capture_output=True,
        text=True,
        check=False,
    )
    if out.returncode != 0:
        return {"error": out.stderr.strip()}
    return json.loads(out.stdout)


def recorded_frame_count(log_text: str) -> int | None:
    m = re.search(r"YOMIRecord: Recorded (\d+) frames\.", log_text)
    return int(m.group(1)) if m else None


def duration_check(probe_result: dict, recorded_frames: int | None) -> dict | None:
    """Compare the video and audio stream durations of one recording.

    Returns None when either stream lacks a duration (so there is nothing
    to compare), else a dict with the two durations in ms, their
    difference, and whether ffmpeg trimmed frames from the video.
    """
    streams = probe_result.get("streams", [])
    video = next((s for s in streams if s.get("codec_type") == "video"), None)
    audio = next((s for s in streams if s.get("codec_type") == "audio"), None)
    if not video or not audio or "duration" not in video or "duration" not in audio:
        return None
    video_ms = float(video["duration"]) * 1000.0
    audio_ms = float(audio["duration"]) * 1000.0
    video_frames = int(video.get("nb_frames", 0))
    return {
        "video_ms": video_ms,
        "audio_ms": audio_ms,
        "diff_ms": abs(video_ms - audio_ms),
        "video_frames": video_frames,
        "recorded_frames": recorded_frames,
        "frames_trimmed": recorded_frames is not None
        and video_frames != recorded_frames,
    }


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--hustle", type=Path, required=True)
    ap.add_argument("--work", type=Path, required=True)
    ap.add_argument("--out", type=Path, required=True)
    ap.add_argument("--replay", type=Path, required=True)
    ap.add_argument("--stable", choices=["0", "1"], required=True)
    ap.add_argument(
        "--path-prepend",
        type=Path,
        default=None,
        help="directory put first on the game's PATH, for an ffmpeg wrapper",
    )
    src = ap.add_mutually_exclusive_group(required=True)
    src.add_argument(
        "--mod-src", type=Path, help="mod source tree, built with tools/build_zip.py"
    )
    src.add_argument("--mod-zip", type=Path, help="a mod zip, used as it is")
    args = ap.parse_args()

    rc = load_replay_check(args.hustle)
    rc.start_display()
    work = rc.Work(args.work.resolve())
    rc.prepare(work)

    # ModLoader reads <real executable dir>/mods. If the binary is a link
    # elsewhere (for example into a read-only Nix store), the zips below
    # would be ignored and the game would wait in its menu until the timeout.
    real_mods = Path(rc.os.path.realpath(work.godot)).parent / "mods"
    if real_mods != MODS_DIR:
        raise SystemExit(f"ModLoader reads {real_mods}, not {MODS_DIR}")
    MODS_DIR.mkdir(parents=True, exist_ok=True)
    if args.mod_src:
        build_zip.build(
            args.mod_src,
            work.project,
            lambda: rc.import_assets(work),
            MODS_DIR / "YOMIRecord.zip",
        )
    else:
        shutil.copy(args.mod_zip, MODS_DIR / "YOMIRecord.zip")
    zip_folder(HERE / "YOMIRecordE2E", "YOMIRecordE2E", MODS_DIR / "YOMIRecordE2E.zip")

    out = args.out.resolve()
    if out.exists():
        shutil.rmtree(out)
    out.mkdir(parents=True)
    result_file = out / "result.json"
    log = out / "godot.log"
    # Start from the image's environment: the Nix image sets the GL, EGL and
    # library paths there (hustle's tools/replay_check/nix/image.nix).
    env = dict(rc.os.environ)
    if args.path_prepend:
        env["PATH"] = f"{args.path_prepend.resolve()}:{env['PATH']}"
    env.update(
        {
            "HOME": str(out / "home"),
            # Fresh user:// on every run (ModLoader's version gate, see replay_check).
            "XDG_DATA_HOME": str(out / "xdg"),
            "E2E_REPLAY": str(args.replay.resolve()),
            "E2E_STABLE": args.stable,
            "E2E_RESULT": str(result_file),
        }
    )
    if args.stable == "1":
        # Lockstep pacing (Recorder.gd's stable_record) holds AudioServer
        # locked between video frames, so the shim's faster mixer sleep is
        # safe here. Real-time mode must never get this: without lockstep
        # pacing, the shimmed mixer runs about 10x real time and any
        # real-time capture goes wrong.
        env.update(rc.audio_shim_env(work.project))
    with log.open("w") as fh:
        godot_args = [
            # vglrun when e2e.sh --gpu is set (REPLAY_CHECK_GPU=1).
            *rc.godot_prefix(),
            str(work.godot),
            "--path",
            str(work.project),
            "--audio-driver",
            "Dummy",
            "--resolution",
            "1280x720",
        ]
        if args.stable == "1":
            # Disables real-time sync, so the lockstep capture loop in
            # Recorder.gd's stable_record() renders as fast as the CPU and
            # GPU allow, instead of at the display's real-time pace.
            godot_args += ["--fixed-fps", "60"]
        proc = subprocess.run(
            godot_args,
            stdout=fh,
            stderr=subprocess.STDOUT,
            env=env,
            timeout=GAME_TIMEOUT_S,
            check=False,
        )
    text = log.read_text(errors="replace")
    report: dict = {"godot_exit": proc.returncode}
    report["driver"] = (
        json.loads(result_file.read_text()) if result_file.exists() else None
    )
    report["script_errors"] = rc.script_errors(text)
    report["yomirecord_log"] = [
        line for line in text.splitlines() if line.startswith("YOMIRecord")
    ][:40]
    recordings = (report["driver"] or {}).get("recordings", [])
    report["probes"] = {r: probe(r) for r in recordings}
    recorded_frames = recorded_frame_count(text)
    report["duration_check"] = (
        duration_check(report["probes"][recordings[0]], recorded_frames)
        if args.stable == "1" and len(recordings) == 1
        else None
    )
    # Phase timings from the driver. Capture starts at recording_started,
    # which stable mode emits before it resets the replay, so the reset is
    # in the capture time. Encode is the frame files plus ffmpeg.
    drv = report["driver"] or {}
    if recorded_frames and "capture_end_ms" in drv and "encode_end_ms" in drv:
        capture_s = (drv["capture_end_ms"] - drv["capture_start_ms"]) / 1000
        report["timing"] = {
            "capture_s": capture_s,
            "encode_s": (drv["encode_end_ms"] - drv["capture_end_ms"]) / 1000,
            "capture_speed": round(recorded_frames / 60 / capture_s, 2),
        }
    print(json.dumps(report, indent=2))

    duration_ok = True
    if args.stable == "1":
        dc = report["duration_check"]
        duration_ok = (
            dc is not None and dc["diff_ms"] <= 50.0 and not dc["frames_trimmed"]
        )

    ok = (
        len(recordings) == 1
        and not report["script_errors"]
        and {
            s["codec_type"] for s in report["probes"][recordings[0]].get("streams", [])
        }
        == {"video", "audio"}
        and duration_ok
    )
    print("E2E", "PASS" if ok else "FAIL", f"log {log}")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
