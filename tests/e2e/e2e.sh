#!/usr/bin/env bash
# Run the YOMIRecord end-to-end test in podman. See tests/e2e/README.md.
#
# Usage: tests/e2e/e2e.sh <hustle repo> <replay> <stable 0|1> \
#   [--mod-zip ZIP] [--ffmpeg-wrapper DIR] [--gpu CDI_DEVICE]
#
# --gpu passes one GPU (a CDI name from `nvidia-ctk cdi list`) into the
# container, and the game renders on it through VirtualGL (hustle's
# tools/replay_check/README.md, "GPU rendering").
#
# The image is hustle's tools/replay_check image (container.sh builds it).
# Mounts use the same absolute paths inside and outside the container:
# both repositories read-only, the replay read-only, and this repository's
# .scratch/ read-write for the work copy and the results.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
hustle="$(realpath "$1")"
replay="$(realpath "$2")"
stable="$3"
shift 3
mod_args=(--mod-src "$repo")
extra_args=()
mounts=()
gpu=()
out_suffix=""
while (($#)); do
  case "$1" in
  --mod-zip)
    zip="$(realpath "$2")"
    mod_args=(--mod-zip "$zip")
    mounts+=(-v "$zip:$zip:ro")
    shift 2
    ;;
  --gpu)
    # Same GPU settings as hustle's tools/replay_check/container.sh --gpu.
    gpu=(--device "$2" -e REPLAY_CHECK_GPU=1 -e VGL_READBACK=none -e __GL_YIELD=USLEEP)
    out_suffix="${out_suffix}_gpu"
    shift 2
    ;;
  --ffmpeg-wrapper)
    wrapper_dir="$(realpath "$2")"
    extra_args+=(--path-prepend "$wrapper_dir")
    out_suffix="_no_ffmpeg_encoder"
    shift 2
    ;;
  *)
    echo "e2e.sh: unknown argument $1" >&2
    exit 1
    ;;
  esac
done

scratch="$repo/.scratch/e2e"
mkdir -p "$scratch"
# hustle builds its image with Nix and loads it as localhost/hustle-replay-check.
"$hustle/tools/replay_check/build.sh" > /dev/null
exec podman run --rm --init "${gpu[@]}" \
  -v "$repo:$repo:ro" -v "$hustle:$hustle:ro" -v "$scratch:$scratch" \
  -v "$replay:$replay:ro" "${mounts[@]}" \
  --entrypoint python3 localhost/hustle-replay-check \
  "$repo/tests/e2e/inside.py" --hustle "$hustle" --work "$scratch/work" \
  --out "$scratch/run_stable$stable$out_suffix" --replay "$replay" \
  --stable "$stable" "${mod_args[@]}" "${extra_args[@]}"
