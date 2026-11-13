extends Node

signal recording_starting()
signal recording_started()
signal recording_ending()
signal recording_ended()

const FRAME_SKIP = 10
const END_BUFFER = 115
# The ffmpeg encoder each recording format needs. post_recording() picks
# the same mapping for the "-c:v" argument.
const FORMAT_ENCODERS = {
	"webm": "libvpx-vp9",
	"avi": "mpeg4",
	"mp4": "libx264",
}

# Loopback host the video encoder's TCP socket uses. Only this mod
# connects to it, so loopback is always reachable and needs no firewall
# exception on Windows.
const VIDEO_HOST = "127.0.0.1"
# How long to wait for ffmpeg to connect to the video socket before
# failing the recording instead of hanging it.
const VIDEO_CONNECT_TIMEOUT_MS = 10000

var recording = false
var rendering = false
var record_effect: AudioEffectRecord
var capture_effect: AudioEffectCapture
var record_effect_bus_index = -1
var recording_id = -1
var recording_bus_volume = 0
var recording_frame_skip = FRAME_SKIP
var recording_frames = []
var recording_end_buffer = END_BUFFER
var recording_show_playback_controls = false
var stable_recording = false
var writer_finished = false
var stable_recording_state
var captured_audio = PoolVector2Array()

var thread_counter_current:int = 0
var thread_counter_final:int = 0
var writer_thread:Thread
var writer_thread_semaphore:Semaphore = Semaphore.new()
var video_port = -1
var video_server: TCP_Server
var video_ffmpeg_thread: Thread
var video_write_failed = false
var rendering_toast = null

var default_recording_bus_volume = -0.130497

onready var options = get_tree().get_root().get_node("ModLoader/YOMIRecord/YOMIRecordOptions")
onready var ffmpeg = get_tree().get_root().get_node("ModLoader/YOMIRecord/FFmpeg")

# NOTE: This recorder sets FX audio volume to a constant value to ensure the recording works well
# For compatibility for https://steamcommunity.com/sharedfiles/filedetails/?id=2939891318

# TODO
# - option menu
#  - gif format?
#       gif quality sucks, I might skip this honestly, maybe limit frames
#       https://superuser.com/questions/1049606/reduce-generated-gif-size-using-ffmpeg
#  - quality slider (https://superuser.com/questions/677576/what-is-crf-used-for-in-ffmpeg)
#       gonna skip this for now, avg recordings are 3MB and wouldnt make sense to have
#       quality slider for 1MB instead
# BUGS
#  - fix resetting in between the P1 WIN screen (and not making tt stay there for the whole recording)

func _ready():
	name = "YOMIRecorder"
	print("YOMIRecord: Recorder spawned")

func generate_timed_name():
	var time = Time.get_datetime_dict_from_system()
	var strings = [str(time.year), str(time.month), str(time.day), str(time.hour), str(time.minute)]
	var string = ""
	for s in strings:
		string += s
		string += "-"
	string += str(time.second)
	return string

# Instead of setting visibility (because UILayer sets it every frame)
# I can use self_modulate to make it invisible
func set_ui_visibility(visible = false):
	var uilayer = get_tree().get_root().get_node("Main/UILayer")
	var to_self_modulate = [
		uilayer.get_node("GameUI/TopInfo"),
		uilayer.get_node("GameUI/TopInfoMP"),
		uilayer.get_node("GameUI/TopInfoReplay"),
		uilayer.get_node("GameUI/HelpButton"),
		uilayer.get_node("GameUI/AdvantageLabel"),
		uilayer.get_node("GameUI/PredictionSettingsOpenButton"),
		uilayer.get_node("P1TurnTimerBar"),
		uilayer.get_node("P1TurnTimerLabel"),
		uilayer.get_node("P2TurnTimerBar"),
		uilayer.get_node("P2TurnTimerLabel"),
		uilayer.get_node("OpponentDisconnectedLabel")
	]
	var to_modulate = [
		uilayer.get_node("GameUI/PausePanel"),
		uilayer.get_node("GameUI/HelpScreen"),
		uilayer.get_node("GameUI/ResetZoomButton"),
		uilayer.get_node("YOMIRecordOptionsWindow"),
		uilayer.get_node("ResimRequestScreen"),
		uilayer.get_node("PostGameButtons"),
		uilayer.get_node("NagWindow"),
		uilayer.get_node("ReplayControls"),
		get_tree().get_root().get_node("Main/HudLayer/HudLayer/HboxContainer"), # Show style buttons
		uilayer.get_node("DiscordRichPresenceLayer") # Discord Rich Presence
	]

	if options.get_option("hide_supermeter"):
		to_modulate.append(uilayer.get_node("GameUI/BottomBar/ActionButtons/VBoxContainer/P1InfoContainer"))
		to_modulate.append(uilayer.get_node("GameUI/BottomBar/ActionButtons/VBoxContainer2/P2InfoContainer"))

	if options.get_option("hide_chat"):
		to_modulate.append(uilayer.get_node("ChatWindow"))

	if not visible:
		for node in to_modulate:
			if node: node.modulate.a = 0
		for node in to_self_modulate:
			if node: node.self_modulate.a = 0
	else:
		for node in to_modulate:
			if node: node.modulate.a = 1
		for node in to_self_modulate:
			if node: node.self_modulate.a = 1

func get_game_viewport():
	var main = get_tree().get_root().get_node("Main")
	return main.get_viewport()


func screenshot():
	var dir = Directory.new()
	if not dir.dir_exists("user://screenshots"):
		dir.make_dir("user://screenshots")

	var hudlayer = get_tree().get_root().get_node("Main/HudLayer/HudLayer")
	var uilayer = get_tree().get_root().get_node("Main/UILayer")
	var ghostlayer = get_tree().get_root().get_node("Main/GhostLayer")
	var p1_action_btns = uilayer.get_node("GameUI/BottomBar/ActionButtons/VBoxContainer/P1ActionButtons")
	var p2_action_btns = uilayer.get_node("GameUI/BottomBar/ActionButtons/VBoxContainer2/P2ActionButtons")
	var replay_controls = uilayer.get_node("ReplayControls")
	var prevHudVis = hudlayer.visible
	var prevGhostVis = ghostlayer.visible
	var prevP1ActionBtnsVis = p1_action_btns.visible
	var prevP2ActionBtnsVis = p2_action_btns.visible
	var showPlaybackControls = not Network.multiplayer_active and Global.show_playback_controls

	hudlayer.visible = not options.get_option("hide_hud")
	ghostlayer.visible = false
	p1_action_btns.visible = false
	p2_action_btns.visible = false
	Global.show_playback_controls = false
	set_ui_visibility(false)
	set_yomirecord_overlay_visible(false)

	var file_name = generate_timed_name() + ".png"
	var filepath = "user://screenshots/" + file_name
	print("YOMIRecord: Saving screenshot to " + filepath)
	yield(VisualServer, "frame_post_draw")

	if options.get_option("use_steam_overlay") and Steam.isOverlayEnabled():
		Steam.triggerScreenshot()
		yield (get_tree(), "idle_frame")
		yield (get_tree(), "idle_frame")
		yield (get_tree(), "idle_frame")
		yield (get_tree(), "idle_frame")
	else:
		var viewport: Viewport = get_game_viewport()
		viewport.set_clear_mode(Viewport.CLEAR_MODE_ONLY_NEXT_FRAME)

		var image = viewport.get_texture().get_data()
		image.flip_y()
		
		var resolution = int(options.get_option("resolution"))
		if resolution < get_viewport().size.y:
			image.generate_mipmaps()
		if resolution != get_viewport().size.y:
			var resolution_scale = float(resolution) / float(get_viewport().size.y)
			image.resize(
				int(get_viewport().size.x * resolution_scale),
				int(get_viewport().size.y * resolution_scale),
				Image.INTERPOLATE_NEAREST
			)
		image.save_png(filepath)
		spawn_file_toast("screenshot", file_name)

	hudlayer.visible = prevHudVis
	ghostlayer.visible = prevGhostVis
	p1_action_btns.visible = prevP1ActionBtnsVis
	p2_action_btns.visible =  prevP2ActionBtnsVis
	Global.show_playback_controls = showPlaybackControls
	set_ui_visibility(true)
	set_yomirecord_overlay_visible(true)

func parse_char_name(char_name: String):
	# Fix modded character names
	if char_name.find("F-") == 0 and char_name.find("__") != -1:
		var name_split: PoolStringArray = char_name.split("__")
		if name_split[0].length() == 34 and name_split[1]:
			return name_split[1]

	return char_name

func get_player_names():
	var p1name = Global.current_game.match_data.selected_characters[1].name
	var p2name = Global.current_game.match_data.selected_characters[2].name
	if Global.current_game.match_data.has("user_data"):
		if Global.current_game.match_data.user_data.has("p1") and Global.current_game.match_data.user_data.p1 != "":
			p1name = Global.current_game.match_data.user_data.p1
		if Global.current_game.match_data.user_data.has("p2") and Global.current_game.match_data.user_data.p2 != "":
			p2name = Global.current_game.match_data.user_data.p2
	return [parse_char_name(p1name), parse_char_name(p2name)]

func get_native_speed():
	if not options.get_option("native_speed"): return null
	var speed = options.get_option("speed")
	if speed == 1: return 1
	elif speed == 0.75 and Global.has_method("get_playback_speed_factor"): return -1
	elif speed == 0.5: return 2
	elif speed == 0.25: return 4
	return null

func spawn_file_toast(type, file_name: String, time_elapsed_msec = -1, frames_taken = -1):
	var toast_container = get_yomirecord_layer().get_node("Overlay/Toasts/ToastContainer")
	var toast = load("res://YOMIRecord/ui/overlay/FileToast.tscn").instance()
	toast_container.add_child(toast)
	toast.file_path = "user://%ss/%s" % [type, file_name]
	toast.folder_path = "user://%ss" % type

	var truncated_filename: String = file_name
	if file_name.length() > 30:
		truncated_filename = truncated_filename.substr(0, 27) + "..."

	if time_elapsed_msec != -1 and frames_taken != -1:
		var time_elapsed = float(time_elapsed_msec) / 1000
		var fps = float(frames_taken) / time_elapsed
		toast.set_text("Saved %s to [color=#fff][u]%s[/u][/color] [color=#555](took %.2fs, %.2f fps)[/color]" % [type, truncated_filename, time_elapsed, fps])
	else:
		toast.set_text("Saved %s to [color=#fff][u]%s[/u][/color]" % [type, file_name])

	toast.pop()

func spawn_text_toast(text, alert = false):
	var toast_container = get_yomirecord_layer().get_node("Overlay/Toasts/ToastContainer")
	var toast = load("res://YOMIRecord/ui/overlay/TextToast.tscn").instance()
	toast_container.add_child(toast)
	toast.set_text(text)
	toast.pop(alert)

func show_rendering_toast():
	set_yomirecord_overlay_visible(true)
	var toast_container = get_yomirecord_layer().get_node("Overlay/Toasts/ToastContainer")
	rendering_toast = load("res://YOMIRecord/ui/overlay/RenderingToast.tscn").instance()
	toast_container.add_child(rendering_toast)
	rendering_toast.show()

func update_rendering_toast(text: String):
	if is_instance_valid(rendering_toast):
		rendering_toast.get_node("HBoxContainer/Label").bbcode_text = text

func hide_rendering_toast():
	if is_instance_valid(rendering_toast):
		rendering_toast.queue_free()
	rendering_toast = null

func hide_rendering_overlay():
	var overlay: MarginContainer = get_yomirecord_layer().get_node("Overlay/RenderingOverlay")
	overlay.visible = false

func get_yomirecord_layer():
	return get_tree().get_root().get_node("ModLoader/YOMIRecord/YOMIRecordLayer")

func set_yomirecord_overlay_visible(visible = true):
	var layer: CanvasLayer = get_yomirecord_layer()
	layer.visible = visible

func change_window_icon(icon: String):
	if OS.get_name() == "Windows":
		OS.set_native_icon("res://YOMIRecord/icon/icon_%s.ico" % icon)

func reset_playback():
	Global.current_game.game_started = false
	Global.current_game.start_playback()

func _set_recording_speed():
	var playback_speed = get_native_speed()
	if playback_speed == null: playback_speed = 1
	Global.playback_speed_mod = playback_speed

func show_options(visible = true):
	var option_menu = get_tree().get_root().get_node("Main/UILayer/YOMIRecordOptionsWindow")
	if visible:
		option_menu.refresh()
		option_menu.show()
	else: option_menu.hide()

func options_menu_visible():
	var option_menu: PanelContainer = get_tree().get_root().get_node("Main/UILayer/YOMIRecordOptionsWindow")
	return option_menu.visible

func _add_record_effect():
	var bus_name = "Fx" if options.get_option("record_fx_only") else "Master"
	record_effect_bus_index = AudioServer.get_bus_index(bus_name)
	record_effect = AudioEffectRecord.new()
	AudioServer.add_bus_effect(record_effect_bus_index, record_effect)
	print("YOMIRecord: Recording audio from the %s bus" % bus_name)

func _remove_record_effect():
	if record_effect == null or record_effect_bus_index < 0: return
	for effect_index in range(AudioServer.get_bus_effect_count(record_effect_bus_index)):
		if AudioServer.get_bus_effect(record_effect_bus_index, effect_index) == record_effect:
			AudioServer.remove_bus_effect(record_effect_bus_index, effect_index)
			break
	record_effect = null
	record_effect_bus_index = -1

func _add_capture_effect():
	var bus_name = "Fx" if options.get_option("record_fx_only") else "Master"
	record_effect_bus_index = AudioServer.get_bus_index(bus_name)
	capture_effect = AudioEffectCapture.new()
	capture_effect.buffer_length = 2.0
	AudioServer.add_bus_effect(record_effect_bus_index, capture_effect)
	print("YOMIRecord: Recording audio from the %s bus" % bus_name)

func _remove_capture_effect():
	if capture_effect == null or record_effect_bus_index < 0: return
	for effect_index in range(AudioServer.get_bus_effect_count(record_effect_bus_index)):
		if AudioServer.get_bus_effect(record_effect_bus_index, effect_index) == capture_effect:
			AudioServer.remove_bus_effect(record_effect_bus_index, effect_index)
			break
	capture_effect = null
	record_effect_bus_index = -1

func _write_stable_audio(path: String):
	# Pack the captured float samples as 16-bit PCM and save a wav.
	# StreamPeerBuffer.put_16 writes a little-endian signed sample, so
	# this needs no manual byte-order or two's-complement work.
	var buffer = StreamPeerBuffer.new()
	for sample in captured_audio:
		buffer.put_16(int(clamp(sample.x, -1.0, 1.0) * 32767.0))
		buffer.put_16(int(clamp(sample.y, -1.0, 1.0) * 32767.0))
	var stream = AudioStreamSample.new()
	stream.format = AudioStreamSample.FORMAT_16_BITS
	stream.stereo = true
	stream.mix_rate = int(AudioServer.get_mix_rate())
	stream.data = buffer.data_array
	stream.save_to_wav(path)
	captured_audio = PoolVector2Array()

func _begin_recording(stable: bool = false):
	emit_signal("recording_starting")

	# Hide Layers
	var hudlayer = get_tree().get_root().get_node("Main/HudLayer/HudLayer")
	hudlayer.visible = not options.get_option("hide_hud")
	recording_show_playback_controls = Global.show_playback_controls
	if not Network.multiplayer_active: Global.show_playback_controls = false
	set_ui_visibility(false)
	set_yomirecord_overlay_visible(false)
	yield (get_tree(), "idle_frame")
	yield (get_tree(), "idle_frame")

	# Prepare the recording directory and the video encoder's TCP
	# listener before touching audio, so a failure here needs no audio
	# cleanup.
	recording_id = randi() % 10000000
	video_write_failed = false
	video_server = _open_video_server()
	if video_server == null:
		set_ui_visibility(true)
		set_yomirecord_overlay_visible(true)
		spawn_text_toast("[color=#ff0000]Error![/color] Could not open the recorder's video socket. Try again.", true)
		recording = false
		return
	Directory.new().make_dir(_local_path())
	_start_video_encoder()

	# Handle Audio and Record Audio Effect
	recording_bus_volume = AudioServer.get_bus_volume_db(AudioServer.get_bus_index("Fx"))
	if not options.get_option("mute_audio"):
		if stable:
			_add_capture_effect()
		else:
			_add_record_effect()

	# Start writer thread: it feeds the video encoder over the socket
	# _start_video_encoder() connected it to.
	writer_thread = Thread.new()
	writer_thread.start(self, "_thread_write", video_server, 0)

	# Window Stuff
	OS.set_window_title("Your Only Move Is HUSTLE (Recording)")
	change_window_icon("recording")

func pre_recording():
	var begin_state = _begin_recording()
	if begin_state is GDScriptFunctionState:
		yield (begin_state, "completed")

	# Reset and Start Playback
	_set_recording_speed()
	reset_playback()
	Global.frame_advance = true
	yield (get_tree(), "idle_frame")
	yield (get_tree(), "idle_frame")
	Global.current_game.advance_frame_input = true
	yield (get_tree(), "idle_frame")
	yield (get_tree(), "idle_frame")
	Global.frame_advance = false

	if not options.get_option("mute_audio"):
		AudioServer.set_bus_volume_db(AudioServer.get_bus_index("Fx"), default_recording_bus_volume)
		record_effect.set_recording_active(true)
	emit_signal("recording_started")

func _wait_for_replay_reset(previous_game):
	while not is_instance_valid(Global.current_game) or Global.current_game == previous_game or not Global.current_game.game_started:
		yield (get_tree(), "idle_frame")

func _reset_stable_playback():
	Global.frame_advance = true
	var previous_game = Global.current_game
	reset_playback()
	var reset_state = _wait_for_replay_reset(previous_game)
	if reset_state is GDScriptFunctionState:
		yield (reset_state, "completed")
	Global.current_game.advance_frame_input = false
	if Global.current_game.get("real_tick") != null: Global.current_game.real_tick = 0
	Global.current_game.set_physics_process(false)
	Global.frame_advance = false

func _capture_recording_frame():
	var viewport: Viewport = get_game_viewport()
	viewport.set_clear_mode(Viewport.CLEAR_MODE_ONLY_NEXT_FRAME)
	var image = viewport.get_texture().get_data()
	recording_frames.append(image)
	writer_thread_semaphore.post()

func _finish_writer(frames_length: int):
	if writer_finished: return
	thread_counter_final = frames_length
	writer_thread_semaphore.post()
	print("YOMIRecord: Render thread signalled to finish at frame %d (of %d)" % [thread_counter_current, frames_length])
	update_rendering_toast("Wrote [color=#fff]%d/%d frames[/color]" % [thread_counter_current, frames_length])
	var last_progress_update = thread_counter_current
	while writer_thread.is_alive():
		yield (get_tree(), "idle_frame")
		if thread_counter_current - last_progress_update != 0:
			last_progress_update = thread_counter_current
			update_rendering_toast("Wrote [color=#fff]%d/%d frames[/color]" % [thread_counter_current, frames_length])
			if thread_counter_current % 10 == 0:
				print("YOMIRecord: Render thread progress %d/%d" % [thread_counter_current, thread_counter_final])
	print("YOMIRecord: Render thread stopped")
	writer_thread.wait_to_finish()
	print("YOMIRecord: Render thread finished")
	writer_finished = true

func _run_ffmpeg(data):
	var output = []
	var exit_code = OS.execute(data[0], data[1], true, output, true, data[2])
	return [exit_code, output]

func _local_path() -> String:
	return "user://yomirecord/_recording_%d" % recording_id

func _global_path() -> String:
	return ProjectSettings.globalize_path(_local_path())

func _video_only_path(format: String) -> String:
	return "%s/video_only.%s" % [_global_path(), format]

# Standard H.264 level limits (macroblocks/second, macroblocks/frame),
# ITU-T H.264 Table A-1, levels 3.0 and up (anything this mod records is
# well above level 2.x's frame sizes). _h264_level() picks the lowest
# level that is legal for the chosen resolution and frame rate.
const H264_LEVELS = [
	["3.0", 40500, 1620],
	["3.1", 108000, 3600],
	["3.2", 216000, 5120],
	["4.0", 245760, 8192],
	["4.1", 245760, 8192],
	["4.2", 522240, 8704],
	["5.0", 589824, 22080],
	["5.1", 983040, 36864],
	["5.2", 2073600, 36864],
	["6.0", 4177920, 139264],
	["6.1", 8355840, 139264],
	["6.2", 16711680, 139264],
]

func _h264_level(res_size: String, framerate: int) -> String:
	var dims = res_size.split("x")
	var mb_width = int(ceil(float(dims[0]) / 16.0))
	var mb_height = int(ceil(float(dims[1]) / 16.0))
	var mbs_per_frame = mb_width * mb_height
	var mbs_per_sec = mbs_per_frame * framerate
	for level in H264_LEVELS:
		if mbs_per_frame <= level[2] and mbs_per_sec <= level[1]:
			return level[0]
	return H264_LEVELS[H264_LEVELS.size() - 1][0]

# Same codec and preset post_recording() used to pass to ffmpeg. The
# "-c:v" name here must match FORMAT_ENCODERS, which record() checks
# before it lets a recording start.
#
# "-preset veryslow" raises libx264's reference-frame count enough that,
# left to pick its own level, it reports one far above what the chosen
# resolution and frame rate need (measured: level 5.0 for plain
# 1280x720, where 3.2 already covers 1280x720 at up to 60 fps). Some
# hardware H.264 decoders mishandle that combination and corrupt the
# picture (reported: smearing in VLC's hardware decoder on an NVIDIA
# GPU; ffmpeg's own software decoder was unaffected). An explicit
# "-level" makes libx264 clip its reference-frame count down to
# whatever that level's buffer size allows, instead of raising the
# level to fit the preset.
func _video_codec_args(format: String, res_size: String, framerate: int) -> PoolStringArray:
	if format == "webm":
		return PoolStringArray(["-c:v", "libvpx-vp9"])
	elif format == "avi":
		return PoolStringArray(["-c:v", "mpeg4"])
	return PoolStringArray(["-c:v", "libx264", "-preset", "veryslow", "-level:v", _h264_level(res_size, framerate)])

func _recording_resolution_size() -> String:
	var resolution = int(options.get_option("resolution"))
	var res_size = "640x360"
	if resolution != 360:
		var resolution_scale = float(resolution) / float(get_viewport().size.y)
		res_size = "%dx%d" % [int(ceil(get_viewport().size.x * resolution_scale)), int(get_viewport().size.y * resolution_scale)]
		if resolution == 480: res_size = "854x480"
	return res_size

func _recording_framerate() -> int:
	var framerate = 60
	if get_native_speed() == null:
		framerate = int(float(60) * options.get_option("speed"))
		if framerate <= 0: framerate = 1
	return framerate

# Opens the TCP listener the video encoder connects to. Godot listens and
# ffmpeg connects to it, not the reverse: this mod launches ffmpeg itself
# (unlike hustle's tools/botplay, where an outside process starts ffmpeg
# before Godot), so Godot must be the side already listening, or
# ffmpeg's connection would race the launch.
func _open_video_server() -> TCP_Server:
	var server = TCP_Server.new()
	video_port = 40000 + (recording_id % 20000)
	var err = server.listen(video_port, VIDEO_HOST)
	if err != OK:
		push_error("YOMIRecord: could not listen on %s:%d for the video encoder (error %d)" % [VIDEO_HOST, video_port, err])
		return null
	return server

# Waits for ffmpeg to connect, with a bounded timeout so a broken ffmpeg
# launch fails the recording instead of hanging it.
func _accept_video_connection(server: TCP_Server) -> StreamPeerTCP:
	var waited_ms = 0
	while not server.is_connection_available():
		if waited_ms >= VIDEO_CONNECT_TIMEOUT_MS:
			push_error("YOMIRecord: ffmpeg did not connect to the video encoder within %d ms" % VIDEO_CONNECT_TIMEOUT_MS)
			return null
		OS.delay_msec(10)
		waited_ms += 10
	return server.take_connection()

# Starts the video encoder before capture begins, so it encodes frames as
# they arrive instead of after the whole recording is captured. It
# writes a video-only file; post_recording() adds the audio track
# afterwards with a fast "-c:v copy" remux. See tests/e2e/README.md,
# "Encode pipeline".
func _start_video_encoder():
	var format = options.get_option("recording_format")
	var viewport_size = get_game_viewport().size
	var res_size = _recording_resolution_size()
	var framerate = _recording_framerate()
	var ffmpegArgs = PoolStringArray([
		"-f", "rawvideo",
		"-pix_fmt", "rgba",
		"-video_size", "%dx%d" % [int(viewport_size.x), int(viewport_size.y)],
		"-framerate", str(framerate),
		"-i", "tcp://%s:%d" % [VIDEO_HOST, video_port],
		"-pix_fmt", "yuv420p",
		"-vf", "vflip",
		"-s", res_size,
		"-sws_flags", "neighbor",
	])
	ffmpegArgs.append_array(_video_codec_args(format, res_size, framerate))
	ffmpegArgs.append(_video_only_path(format))
	print("YOMIRecord: starting video encoder with command: ", ffmpegArgs)
	video_ffmpeg_thread = Thread.new()
	video_ffmpeg_thread.start(self, "_run_ffmpeg", [ffmpeg.ffmpeg_path, ffmpegArgs, options.get_option("exec_console")])

func stable_record():
	# Pre-recording
	var begin_state = _begin_recording(true)
	if begin_state is GDScriptFunctionState:
		yield (begin_state, "completed")
	emit_signal("recording_started")

	# Setup the game
	_set_recording_speed()
	var reset_state = _reset_stable_playback()
	if reset_state is GDScriptFunctionState:
		yield (reset_state, "completed")
	var game = Global.current_game

	var audio_muted = options.get_option("mute_audio")
	var mix_rate = int(AudioServer.get_mix_rate())
	var audio_captured = 0
	captured_audio = PoolVector2Array()
	if not audio_muted:
		AudioServer.set_bus_volume_db(AudioServer.get_bus_index("Fx"), default_recording_bus_volume)

	# Frame by frame recording, one pass. AudioServer stays locked while
	# the frame's physics step and draw run, so the mixer only advances
	# between video frames. After each frame this drains the capture bus
	# until it holds exactly as many samples as the video has played, so
	# the audio clock cannot drift from the video clock.
	# See tests/e2e/README.md, "Stable mode audio".
	var video_end_buffer = END_BUFFER
	# Stable mode steps the game itself, so vsync only slows it down. With a
	# GPU, vsync capped each frame at the display refresh (measured 60.0 fps
	# with an RTX 5070; 252 fps with vsync off). Restored after the loop.
	var vsync_was_enabled = OS.vsync_enabled
	OS.vsync_enabled = false
	while recording:
		if not audio_muted:
			AudioServer.lock()
		game._physics_process(1.0 / 60.0)
		yield (get_tree(), "idle_frame")
		yield (VisualServer, "frame_post_draw")

		_capture_recording_frame()

		if not audio_muted:
			AudioServer.unlock()
			var needed = recording_frames.size() * mix_rate / 60
			while audio_captured < needed:
				var available = capture_effect.get_frames_available()
				if available > 0:
					captured_audio.append_array(capture_effect.get_buffer(available))
					audio_captured += available
				else:
					OS.delay_usec(50)

		if not ReplayManager.playback and game.is_waiting_on_player() and not game.game_finished:
			break
		if game.game_finished:
			if video_end_buffer > 0:
				video_end_buffer -= 1
			else:
				break

	# Restore game
	OS.vsync_enabled = vsync_was_enabled
	game.set_physics_process(true)
	var frames_length = recording_frames.size()
	print("YOMIRecord: Recorded %d frames." % frames_length)

	# post record (this also waits for the worker thread)
	var post_state = post_recording()
	if post_state is GDScriptFunctionState:
		yield (post_state, "completed")

func post_recording():
	recording = false
	rendering = true
	emit_signal("recording_ending")
	var audio_muted = options.get_option("mute_audio")

	# Get the usernames so the player can go elsewhere
	var usernames = get_player_names()
	var video_name = Utils.filter_filename(ReplayManager.generate_mp_replay_name(usernames[0], usernames[1]))

	# Show Layers
	var frames_length = recording_frames.size()
	set_yomirecord_overlay_visible(true)
	set_ui_visibility(true)
	hide_rendering_overlay()
	if not Network.multiplayer_active: Global.show_playback_controls = recording_show_playback_controls

	# Update playback controls slider
	var main = get_tree().get_root().get_node("Main")
	var playback_hslider: HSlider = main.get_node("UILayer/ReplayControls/VBoxContainer/Contents/VBoxContainer/PlaybackSpeed")
	playback_hslider.value = 3 if Global.has_method("get_playback_speed_factor") else 2
	main.get_node("HudLayer/HudLayer").visible = true

	# Save Audio Recording
	if not audio_muted:
		if stable_recording:
			_write_stable_audio("%s/audio.wav" % _local_path())
		else:
			record_effect.set_recording_active(false)
			var recording_stream = record_effect.get_recording()
			recording_stream.save_to_wav("%s/audio.wav" % _local_path())

	print("YOMIRecord: Finishing video encode in %s ..." % _global_path())
	OS.set_window_title("Your Only Move Is HUSTLE (Rendering)")
	change_window_icon("rendering")
	show_rendering_toast()
	yield (get_tree(), "idle_frame")
	yield (get_tree(), "idle_frame")
	var start_time = Time.get_ticks_msec()
	Global.frame_advance = false

	# Wait for the writer thread: it is done once every captured frame
	# has gone to the video encoder over the socket.
	var writer_state = _finish_writer(frames_length)
	if writer_state is GDScriptFunctionState:
		yield (writer_state, "completed")
	recording_frames.clear()
	thread_counter_current = 0
	thread_counter_final = 0

	var dir = Directory.new()
	if not dir.dir_exists("user://recordings"):
		dir.make_dir("user://recordings")

	var format = options.get_option("recording_format")
	video_name += ".%s" % format
	var final_path = ProjectSettings.globalize_path("user://recordings/" + video_name)
	var video_only_path = _video_only_path(format)

	# Wait for the video encoder. Most of the encode already ran while
	# frames streamed in during capture (see _start_video_encoder()); this
	# only waits out whatever backlog is left and the container's final
	# write, so it is now the short part of the render.
	update_rendering_toast("[color=#fff]FFmpeg is encoding video...[/color]")
	while video_ffmpeg_thread.is_alive():
		yield (get_tree(), "idle_frame")
	var video_result = video_ffmpeg_thread.wait_to_finish()
	var exit_code = video_result[0]
	var output = video_result[1]
	print("YOMIRecord: ", output[0] if output.size() > 0 else "")
	print("YOMIRecord: video encode finished with exit code %d" % exit_code)
	if video_write_failed and exit_code == 0:
		exit_code = 1

	# Finalize: add the audio track (if any) with a fast "-c:v copy"
	# remux instead of re-encoding the video a second time, and write the
	# metadata tags. This runs even with audio removed, so the metadata
	# still reaches the final file.
	if exit_code == 0:
		var ffmpegExtraArgs = PoolStringArray()
		if not audio_muted:
			var volume = float(options.get_option("volume")) / 100
			if volume != 1:
				ffmpegExtraArgs.append_array([
					"-filter:a", "volume=%.2f" % volume
				])
			if options.get_option("normalize_audio"):
				ffmpegExtraArgs.append_array([
					"-filter:a", "dynaudnorm"
				])
			var framerate = _recording_framerate()
			# https://superuser.com/a/1667260
			if framerate != 60:
				ffmpegExtraArgs.append_array([
					"-af", "asetrate=44100*%s,aresample=44100" % str(float(framerate) / 60)
				])

		var ffmpegArgs = PoolStringArray(["-i", video_only_path])
		if audio_muted:
			ffmpegArgs.append_array(["-map", "0:v"])
		else:
			ffmpegArgs.append_array([
				"-i", "%s/audio.wav" % _global_path(),
				"-map", "0:v",
				"-map", "1:a",
				"-shortest"
			])
		ffmpegArgs.append_array([
			"-c:v", "copy",
			"-metadata", "title=" + usernames[0].replace('"', '\\"') + " vs " + usernames[1].replace('"', '\\"'),
			"-metadata", "comment=Recording of Your Only Move Is Hustle [%s], created using Y.O.M.I Record" % Global.VERSION.replace('"', '\\"')
		])
		ffmpegArgs.append_array(ffmpegExtraArgs)
		ffmpegArgs.append(final_path)
		print("YOMIRecord: finalizing with command: ", ffmpegArgs)
		update_rendering_toast("[color=#fff]FFmpeg is adding audio...[/color]")
		var finalize_thread = Thread.new()
		var finalize_data = [ffmpeg.ffmpeg_path, ffmpegArgs, options.get_option("exec_console")]
		finalize_thread.start(self, "_run_ffmpeg", finalize_data)
		while finalize_thread.is_alive():
			yield (get_tree(), "idle_frame")
		var finalize_result = finalize_thread.wait_to_finish()
		exit_code = finalize_result[0]
		output = finalize_result[1]
		print("YOMIRecord: ", output[0] if output.size() > 0 else "")

	print("YOMIRecord: Finished rendering with exit code %d" % exit_code)
	hide_rendering_toast()

	if exit_code != 0:
		spawn_text_toast("[color=#ff0000]Error![/color] FFmpeg failed to render that capture, Check with your settings or try again later!", true)
	var time_elapsed = Time.get_ticks_msec() - start_time

	# File Cleanup
	if not options.get_option("skip_files"):
		if dir.open(_local_path()) == OK:
			dir.list_dir_begin()
			var file_name = dir.get_next()
			while file_name != "":
				if file_name != "." and file_name != ".." and not dir.current_is_dir():
					dir.remove(_local_path() + "/" + file_name)
				file_name = dir.get_next()
		dir.remove(_local_path())

	# Variable Cleanup
	recording_frame_skip = FRAME_SKIP
	recording_end_buffer = END_BUFFER
	AudioServer.set_bus_volume_db(AudioServer.get_bus_index("Fx"), recording_bus_volume)
	if stable_recording:
		_remove_capture_effect()
	else:
		_remove_record_effect()

	OS.set_window_title("Your Only Move Is HUSTLE")
	change_window_icon("normal")
	OS.request_attention()
	print("YOMIRecord: Cleanup finished, output file in ", final_path)

	stable_recording = false
	writer_finished = false
	rendering = false
	video_server = null
	emit_signal("recording_ended")
	if exit_code == 0: spawn_file_toast("recording", video_name, time_elapsed, frames_length)

func record():
	if recording or rendering: return false

	if is_instance_valid(Global.current_game):
		if Network.multiplayer_active:
			spawn_text_toast("[color=#ff0000]Error![/color] Can't record while in multiplayer!", true)
			return false
		if ReplayManager.frames[1].size() == 0 or ReplayManager.frames[2].size() == 0:
			spawn_text_toast("[color=#ff0000]Error![/color] There aren't any frames to record!", true)
			return false
		var format = options.get_option("recording_format")
		var encoder_name = FORMAT_ENCODERS.get(format, FORMAT_ENCODERS["mp4"])
		if not ffmpeg.has_encoder(encoder_name):
			push_error("YOMIRecord: ffmpeg at %s has no %s encoder for the %s format" % [ffmpeg.ffmpeg_path, encoder_name, format])
			spawn_text_toast("[color=#ff0000]Error![/color] Your ffmpeg has no %s encoder, so it cannot record %s. Install a full ffmpeg build." % [encoder_name, format], true)
			return false
		recording = true
		if options.get_option("stable_mode"):
			stable_recording = true
			stable_recording_state = stable_record()
		else:
			pre_recording()
		return true
	return false

func _thread_write(server: TCP_Server):
	var socket = _accept_video_connection(server)
	server.stop()
	if socket == null:
		video_write_failed = true
		return
	socket.set_no_delay(true)
	while true:
		writer_thread_semaphore.wait()
		if thread_counter_final > 0 && thread_counter_final == thread_counter_current:
			break
		var frame: Image = recording_frames[thread_counter_current]
		if frame.get_format() != Image.FORMAT_RGBA8:
			frame.convert(Image.FORMAT_RGBA8)
		if socket.put_data(frame.get_data()) != OK:
			push_error("YOMIRecord: lost the connection to the video encoder at frame %d" % thread_counter_current)
			video_write_failed = true
			recording_frames[thread_counter_current] = null
			thread_counter_current += 1
			break
		recording_frames[thread_counter_current] = null
		thread_counter_current += 1
	socket.disconnect_from_host()

func _physics_process(delta):
	if not recording or stable_recording: return

	# Skip leading frames, seems to solve the offset issue and frames bleeding into the editor
	if recording_frame_skip > 0:
		recording_frame_skip -= 1
		return
	
	# Replay stopped playback? End recording early
	if not ReplayManager.playback and Global.current_game.is_waiting_on_player() and not Global.current_game.game_finished:
		return post_recording()

	# Snapshot and Store Image
	_capture_recording_frame()

	# Pad ending frames, to show player win UI
	if Global.current_game.game_finished:
		if recording_end_buffer > 0:
			recording_end_buffer -= 1
			return
		return post_recording()
