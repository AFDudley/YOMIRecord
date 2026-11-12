#!/usr/bin/env python3
"""Build the YOMIRecord release zip.

Runs inside hustle's tools/replay_check container; see README.md,
"Building a release zip". It imports the mod's assets into a throwaway
copy of the game project, then calls tools/build_zip.py to write the zip.
Unlike tests/e2e/inside.py, this script never starts the game.
"""

from __future__ import annotations

import argparse
import importlib.util
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
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


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--hustle", type=Path, required=True)
    ap.add_argument("--work", type=Path, required=True)
    ap.add_argument("--dest", type=Path, required=True)
    args = ap.parse_args()

    rc = load_replay_check(args.hustle)
    rc.start_display()
    work = rc.Work(args.work.resolve())
    rc.prepare(work)

    dest = args.dest.resolve()
    dest.parent.mkdir(parents=True, exist_ok=True)
    entries = build_zip.build(
        HERE.parent, work.project, lambda: rc.import_assets(work), dest
    )
    print(f"wrote {dest} with {len(entries)} entries")
    return 0


if __name__ == "__main__":
    sys.exit(main())
