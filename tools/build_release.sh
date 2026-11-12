#!/usr/bin/env bash
# Build the YOMIRecord release zip in podman. See README.md, "Building a
# release zip".
#
# Usage: tools/build_release.sh <hustle repo> <dest zip>
#
# The image is hustle's tools/replay_check image (built the same way as
# tests/e2e/e2e.sh). Mounts use the same absolute paths inside and outside
# the container: the game repository read-only, this repository read-only,
# and a work directory under .scratch/ read-write.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
hustle="$(realpath "$1")"
dest="$(realpath -m "$2")"

work="$repo/.scratch/release/work"
mkdir -p "$work" "$(dirname "$dest")"

# hustle builds its image with Nix and loads it as localhost/hustle-replay-check.
"$hustle/tools/replay_check/build.sh" > /dev/null
exec podman run --rm --init \
  -v "$repo:$repo:ro" -v "$hustle:$hustle:ro" \
  -v "$work:$work" -v "$(dirname "$dest"):$(dirname "$dest")" \
  --entrypoint python3 localhost/hustle-replay-check \
  "$repo/tools/build_release_zip.py" --hustle "$hustle" --work "$work" --dest "$dest"
