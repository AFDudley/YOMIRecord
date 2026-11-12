# YOMIRecord end-to-end test

This test proves that YOMIRecord loads in the game and records a replay to
a working video file. It runs inside podman, against hustle's
`tools/replay_check` container image.

## What it does

1. `tests/e2e/e2e.sh` builds the `localhost/hustle-replay-check` image from
   the hustle repo, then runs `tests/e2e/inside.py` inside it.
2. `inside.py` prepares an imported copy of the game
   (hustle's `replay_check.prepare()`), builds the YOMIRecord mod zip with
   `tools/build_zip.py`, and zips the driver mod
   (`tests/e2e/YOMIRecordE2E`).
3. It copies both zips to the game's mods folder and starts the game
   (`Main.tscn`) with a fresh user directory, the `Dummy` audio driver, and
   a 1280x720 window under Xvfb.
4. The driver mod (`tests/e2e/YOMIRecordE2E/ModMain.gd`) waits for
   YOMIRecord's buttons, sets its options from the `E2E_STABLE` and
   `E2E_REPLAY` environment variables, loads the replay through the real
   in-game replay path, presses YOMIRecord's Record button, and waits for
   the recorder's `recording_ended` signal. It writes what it saw to a JSON
   result file and quits.
5. `inside.py` probes every recording the driver reported with `ffprobe`
   and prints a JSON report: the game's exit code, the driver's result, any
   `SCRIPT ERROR` lines from the log, and the `ffprobe` output for each
   recording.

## Running it

```
tests/e2e/e2e.sh <hustle repo> <replay file> <stable 0|1> [--mod-zip ZIP] [--ffmpeg-wrapper DIR]
```

- `<hustle repo>` is a local checkout of the game.
- `<replay file>` is any `.replay` file the game can load.
- `<stable 0|1>` selects YOMIRecord's stable recording mode (`1`) or its
  real-time mode (`0`).
- `--mod-zip ZIP` tests a prebuilt zip instead of building one from this
  repository's source. Use this to check a release zip loads (see
  README.md, "Building a release zip").
- `--ffmpeg-wrapper DIR` puts `DIR` first on the game's `PATH`. `DIR` must
  hold an executable file named `ffmpeg`. `tests/e2e/ffmpeg_no_libx264`
  holds a wrapper that hides the `libx264` encoder, to test YOMIRecord's
  encoder check (see "Testing the missing-encoder case" below).

Each run writes its log and result to
`.scratch/e2e/run_stable<N>[_no_ffmpeg_encoder]/`:
`godot.log` is the full game log, `result.json` is the driver's report.

## What PASS means

`inside.py` prints `E2E PASS` and exits 0 only when all of the following
hold:

- The game exited.
- The driver mod reported exactly one recording.
- The game log has no `SCRIPT ERROR` line.
- `ffprobe` finds both a video stream and an audio stream in that
  recording.

Any other outcome prints `E2E FAIL` and exits 1. The printed JSON report
says why: check `driver.stage` for where the driver mod stopped, and
`yomirecord_log` for the mod's own log lines.

## Testing the missing-encoder case

YOMIRecord checks that its ffmpeg has an encoder for the chosen recording
format before it starts recording (see upstream issue #3). To test this
check, run with the wrapper that hides `libx264`:

```
tests/e2e/e2e.sh <hustle repo> <replay file> 1 --ffmpeg-wrapper tests/e2e/ffmpeg_no_libx264
```

This run ends with `E2E FAIL`, because no recording is made: that is the
correct outcome. Check instead, in `godot.log`:

- An `ERROR: YOMIRecord: ffmpeg at ffmpeg has no libx264 encoder for the
  mp4 format` line.
- No `SCRIPT ERROR` line.
- `result.json`'s `driver.recording_started` is `false`.
