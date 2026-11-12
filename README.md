<div align=center>
  
  [![Your Only Move Is Record](https://get.snaz.in/AKXSRCW.png)](https://steamcommunity.com/sharedfiles/filedetails/?id=2940624397)
 
  A mod for [Your Only Move Is Hustle](https://store.steampowered.com/app/2212330/) that allows you to record and screenshot replays.
  
  You can download the mod [here](https://steamcommunity.com/sharedfiles/filedetails/?id=2940624397).
  
</div>

## Building a release zip

The GitHub release workflow (`.github/workflows/release.yml`) tags a
release but does not attach a zip. A zip built with a plain `zip -r . `
fails to load: the game's ModLoader needs every file under a
"YOMIRecord/" folder in the zip, and it needs the mod's .png files
already imported to .stex files, which only the Godot editor can
produce.

To build a zip the ModLoader can load, run, from the repository root:

```
tools/build_release.sh <path to a checkout of the hustle game repo> <dest zip>
```

This runs inside hustle's `tools/replay_check` podman container. It
imports the mod's assets into a throwaway copy of the game project, then
calls `tools/build_zip.py` to write the zip. Upload the result to the
GitHub release by hand.

Check a built zip loads before you upload it:

```
tests/e2e/e2e.sh <hustle repo> <a .replay file> 1 --mod-zip <dest zip>
```

See `tests/e2e/README.md` for what this test does and what PASS means.
