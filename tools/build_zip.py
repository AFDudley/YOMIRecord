"""Build the YOMIRecord mod zip that the game's ModLoader can load.

Runs inside hustle's tools/replay_check container (see tests/e2e/README.md).

Two rules come from the game, not from this mod:

1. Layout. ModLoader._checkMetadata reads "<folder>/_metadata", where
   <folder> is the first path segment of each ModMain.gd entry. So every file
   must sit under "YOMIRecord/" in the zip. The v1.4.0 GitHub release zip has
   its files at the root, and the ModLoader reports "No metadata in mod:
   ModMain.gd".
2. Imported assets. An exported game cannot load a raw .png through
   ResourceLoader. The .tscn files of this mod reference .png textures, so
   the zip must carry each "<file>.png.import" remap file and the
   ".import/<file>.png-<md5>.stex" file it points to. This script gets them
   by importing the mod inside a copy of the game project.
"""

from __future__ import annotations

import re
import shutil
import zipfile
from pathlib import Path
from typing import Callable

MOD_NAME = "YOMIRecord"
# Files in the repository that are not part of the mod.
EXCLUDE = {
    ".git",
    ".github",
    ".scratch",
    "tests",
    "tools",
    ".gitignore",
    "__workshop_data.json",
}
DEST_FILES_RE = re.compile(r"^dest_files=\[(.*)\]$", re.M)


def mod_files(src: Path) -> list[Path]:
    """Mod files, without generated .import files. Excluded trees are never walked."""
    out: list[Path] = []
    for top in sorted(src.iterdir()):
        if top.name in EXCLUDE:
            continue
        candidates = [top] if top.is_file() else sorted(top.rglob("*"))
        out.extend(
            p for p in candidates if p.is_file() and not p.name.endswith(".import")
        )
    return out


def build(
    src: Path, project: Path, import_assets: Callable[[], None], dest: Path
) -> list[str]:
    """Import the mod in `project`, write `dest`, and return the zip entries."""
    staged = project / MOD_NAME
    if staged.exists():
        shutil.rmtree(staged)
    for path in mod_files(src):
        target = staged / path.relative_to(src)
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(path, target)
    import_assets()

    entries: dict[str, Path] = {}
    for path in sorted(staged.rglob("*")):
        if not path.is_file():
            continue
        entries[path.relative_to(project).as_posix()] = path
        if path.name.endswith(".import"):
            match = DEST_FILES_RE.search(path.read_text())
            if match is None:
                raise RuntimeError(f"{path}: no dest_files line")
            for res_path in re.findall(r'"res://([^"]+)"', match.group(1)):
                imported = project / res_path
                if not imported.exists():
                    raise RuntimeError(f"{path}: {imported} was not imported")
                entries[res_path] = imported

    with zipfile.ZipFile(dest, "w", zipfile.ZIP_DEFLATED) as zf:
        for name in sorted(entries):
            zf.write(entries[name], name)
    shutil.rmtree(staged)
    return sorted(entries)
