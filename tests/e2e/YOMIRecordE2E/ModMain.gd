extends Node

# End-to-end driver for Your Only Move Is Record. See tests/e2e/README.md.
#
# The ModLoader loads this as a second mod, next to YOMIRecord. The driver
# acts as a player: it loads a replay through the in-game replay path,
# presses the mod's Record button, and waits for the mod to report the end
# of the recording. It writes what it saw to E2E_RESULT as JSON and quits.
#
# Environment:
#   E2E_REPLAY  path of the .replay file
#   E2E_STABLE  "1" for the mod's stable mode, "0" for real-time mode
#   E2E_RESULT  path of the JSON result file

const RECORD_BUTTON = "Main/UILayer/ReplayControls/VBoxContainer/Contents/VBoxContainer/YOMIRecordPlaybackOptions/RecordPlayback"
const RECORDER = "ModLoader/YOMIRecord/YOMIRecorder"
const OPTIONS = "ModLoader/YOMIRecord/YOMIRecordOptions"
const FFMPEG = "ModLoader/YOMIRecord/FFmpeg"

var result = {"stage": "start"}

func _init(_modLoader = null):
	name = "YOMIRecordE2E"

func _ready():
	call_deferred("_run")

func _run():
	var tree = get_tree()
	# ModLoader runs every ModMain before this deferred call, so a missing
	# YOMIRecord node means the mod did not load at all.
	if tree.root.get_node_or_null("ModLoader/YOMIRecord") == null:
		result.stage = "mod_not_loaded"
		_finish()
		return
	# YOMIRecord injects its buttons from a deferred call in MLMainHook._ready.
	# The outer test timeout catches a mod that never injects them.
	result.stage = "wait_for_injection"
	while tree.root.get_node_or_null(RECORD_BUTTON) == null:
		yield(tree, "idle_frame")
	var recorder = tree.root.get_node(RECORDER)
	var options = tree.root.get_node(OPTIONS)
	var ffmpeg = tree.root.get_node(FFMPEG)
	result.ffmpeg_path = ffmpeg.ffmpeg_path
	options.set_option("stable_mode", OS.get_environment("E2E_STABLE") == "1")
	options.set_option("mute_audio", false)

	result.stage = "load_replay"
	var main = tree.root.get_node("Main")
	var match_data = ReplayManager.load_replay(OS.get_environment("E2E_REPLAY"))
	main._on_loaded_replay(match_data)
	while !(is_instance_valid(Global.current_game) and Global.current_game.game_started):
		yield(tree, "idle_frame")

	result.stage = "record"
	recorder.connect("recording_ended", self, "_on_recording_ended")
	tree.root.get_node(RECORD_BUTTON).emit_signal("pressed")
	result.recording_started = recorder.recording
	if !recorder.recording:
		_finish()

func _on_recording_ended():
	result.stage = "ended"
	var dir = Directory.new()
	var files = []
	if dir.open("user://recordings") == OK:
		dir.list_dir_begin(true, true)
		var f = dir.get_next()
		while f != "":
			files.append(ProjectSettings.globalize_path("user://recordings/" + f))
			f = dir.get_next()
	result.recordings = files
	_finish()

func _finish():
	var f = File.new()
	f.open(OS.get_environment("E2E_RESULT"), File.WRITE)
	f.store_string(JSON.print(result))
	f.close()
	print("YOMIRECORD_E2E_DONE " + JSON.print(result))
	get_tree().quit(0)
