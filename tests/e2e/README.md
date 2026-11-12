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

## Stable mode audio

Stable mode (`options.stable_mode`) steps the game by hand to capture video
frames exactly, with no frame drops. Before this change it then replayed
the recording a second time in real time to capture audio, through the
Dummy audio driver. That driver's mixer thread runs slightly slower than
real time in the test container, so the second pass drifted and ffmpeg's
`-shortest` trimmed a few video frames.

`Recorder.gd`'s `stable_record()` now records audio in the same single
pass as the video. It adds an `AudioEffectCapture` to the recorded bus
(the same bus the `record_fx_only` option already chooses). While each
video frame's physics step and draw run, it holds `AudioServer.lock()`,
so the mixer cannot advance. After the frame, it unlocks and drains the
capture effect until the capture holds exactly
`frames_captured * mix_rate / 60` samples, then locks again for the next
frame. This keeps the audio sample count locked to the video frame count,
with no second pass and no drift.

This test's harness (`inside.py`) also loads hustle's
`tools/replay_check/audio_sleep_shim.c`, built into the container image,
and passes Godot `--fixed-fps 60`, for stable-mode runs only.
`--fixed-fps` disables Godot's real-time sync, so the lockstep loop's
render and draw run as fast as the CPU and GPU allow, instead of at the
display's real-time pace. The shim shortens the Dummy driver's sleep
between mix buffers, so the lockstep loop's audio catch-up drain is not
the bottleneck either. Measured in this container, with full game
rendering: about 1.8x real time (see "Measuring stable-mode speed"
below), with the same sample accuracy as without the shim.

**The shim is safe only under lockstep pacing.** `AudioServer.lock()`
blocks the mixer thread while each video frame processes, so the shim's
faster sleep only shortens the catch-up drain between frames. A run with
no lockstep pacing has nothing to block the mixer, so the shim makes it
mix about 10x real time throughout, and any real-time capture in that run
is wrong. This is why `inside.py` loads the shim only when
`E2E_STABLE=1`.

### Measuring stable-mode speed

To measure the recording phase alone (not ffmpeg's render phase after
it), time `Recorder.gd`'s `recording_starting` and `recording_ending`
signals, which it emits right before the frame loop starts and right
after it ends. `godot.log` has no timestamps by default, so add a
temporary print to a driver mod (for example `tests/e2e/YOMIRecordE2E/ModMain.gd`):
connect both signals, print `Time.get_ticks_msec()` from each handler,
then take the difference. Speed is
`(recorded frames / 60) / (elapsed ms / 1000)`.

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
- In stable mode (`<stable 0|1>` is `1`) only: the video and audio stream
  durations, from `ffprobe`, differ by at most 50 ms, and the video's
  `nb_frames` matches the `YOMIRecord: Recorded N frames.` log line. This
  is `report.duration_check` in the printed JSON.

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
