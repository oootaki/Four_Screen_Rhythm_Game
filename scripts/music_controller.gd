class_name MusicController
extends Node

@onready var player: AudioStreamPlayer = $AudioStreamPlayer

var audio_path := ""
var chart_offset_sec := 0.0
var chart_duration_sec := 0.0
var has_audio := false

var _running := false
var _audio_started := false
var _start_ticks_usec := 0

func configure(path: String, offset_sec: float, duration_sec: float) -> void:
	audio_path = path
	chart_offset_sec = offset_sec
	chart_duration_sec = duration_sec
	has_audio = false
	player.stream = null

	if ResourceLoader.exists(audio_path):
		var loaded_resource = load(audio_path)
		if loaded_resource is AudioStream:
			player.stream = loaded_resource
			has_audio = true
		else:
			push_warning("Configured audio is not an AudioStream: %s" % audio_path)
	else:
		push_warning("No audio at %s; using the fallback clock." % audio_path)

func start() -> void:
	player.stop()
	_audio_started = false
	_running = true
	_start_ticks_usec = Time.get_ticks_usec()

func restart() -> void:
	start()

func get_song_time() -> float:
	if not _running:
		return -GameConfig.START_LEAD_IN_SEC + chart_offset_sec

	var elapsed := _elapsed_since_timeline_start()
	if has_audio and _audio_started and player.playing:
		# Godot's documented low-latency playback estimate. The chart offset is
		# applied to the clock, making later calibration straightforward.
		return player.get_playback_position() \
			+ AudioServer.get_time_since_last_mix() \
			- AudioServer.get_output_latency() \
			+ chart_offset_sec
	return elapsed + chart_offset_sec

func _process(_delta: float) -> void:
	if not _running or _audio_started:
		return
	if _elapsed_since_timeline_start() >= 0.0:
		_audio_started = true
		if has_audio:
			player.play()

func _elapsed_since_timeline_start() -> float:
	return (Time.get_ticks_usec() - _start_ticks_usec) / 1000000.0 - GameConfig.START_LEAD_IN_SEC
