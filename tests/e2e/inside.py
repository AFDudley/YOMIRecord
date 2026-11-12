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
the game log has no SCRIPT ERROR.
"""

from __future__ import annotations

import argparse
import importlib.util
import json

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
            "format=duration:stream=codec_type,codec_name,width,height,nb_frames",
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
    env = {
        "PATH": (
            f"{args.path_prepend.resolve()}:/usr/local/bin:/usr/bin:/bin"
            if args.path_prepend
            else "/usr/local/bin:/usr/bin:/bin"
        ),
        "DISPLAY": rc.os.environ["DISPLAY"],
        "LD_LIBRARY_PATH": rc.os.environ["LD_LIBRARY_PATH"],
        "HOME": str(out / "home"),
        # Fresh user:// on every run (ModLoader's version gate, see replay_check).
        "XDG_DATA_HOME": str(out / "xdg"),
        "E2E_REPLAY": str(args.replay.resolve()),
        "E2E_STABLE": args.stable,
        "E2E_RESULT": str(result_file),
    }
    with log.open("w") as fh:
        proc = subprocess.run(
            [
                str(work.godot),
                "--path",
                str(work.project),
                "--audio-driver",
                "Dummy",
                "--resolution",
                "1280x720",
            ],
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
    print(json.dumps(report, indent=2))

    ok = (
        len(recordings) == 1
        and not report["script_errors"]
        and {
            s["codec_type"] for s in report["probes"][recordings[0]].get("streams", [])
        }
        == {"video", "audio"}
    )
    print("E2E", "PASS" if ok else "FAIL", f"log {log}")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
