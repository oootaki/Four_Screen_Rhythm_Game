extends Node2D

const LANE_COLORS := [
	Color("55d6ff"),
	Color("7cf29a"),
	Color("ffd166"),
	Color("ff6b9a")
]

@onready var music: MusicController = $MusicController
@onready var input_controller: InputController = $InputController

var chart: Dictionary = {}
var judgement := JudgementManager.new()
var feedback_text := "GET READY"
var feedback_color := Color.WHITE
var feedback_until_msec := 0
var lane_flash_until_msec := [0, 0, 0, 0]
var finished := false
var load_error := ""

func _ready() -> void:
	chart = ChartLoader.load_chart(GameConfig.CHART_PATH)
	if chart.is_empty():
		load_error = "Chart could not be loaded. See the debugger output."
		queue_redraw()
		return

	judgement.configure(chart["notes"])
	music.configure(chart["audio"], chart["offset_sec"], chart["duration_sec"])
	input_controller.lane_pressed.connect(_on_lane_pressed)
	input_controller.restart_requested.connect(_restart)
	input_controller.editor_requested.connect(_open_chart_editor)
	music.start()
	get_viewport().size_changed.connect(queue_redraw)
	queue_redraw()

func _process(_delta: float) -> void:
	if chart.is_empty():
		return

	var song_time := music.get_song_time()
	var misses := judgement.collect_misses(song_time)
	if not misses.is_empty():
		_show_feedback("MISS", Color("ff5470"))

	if not finished and judgement.all_notes_judged() and song_time > float(chart["duration_sec"]):
		finished = true
		feedback_text = "FINISHED"
		feedback_color = Color("a8ffcf")
		feedback_until_msec = 0

	queue_redraw()

func _on_lane_pressed(lane: int) -> void:
	if chart.is_empty() or finished:
		return
	lane_flash_until_msec[lane] = Time.get_ticks_msec() + 90
	var result := judgement.judge_press(lane, music.get_song_time())
	if not result.is_empty():
		var color := Color("7dffb2") if result["result"] == "PERFECT" else Color("ffe082")
		_show_feedback(result["result"], color)

func _restart() -> void:
	if chart.is_empty():
		return
	judgement.configure(chart["notes"])
	finished = false
	feedback_text = "GET READY"
	feedback_color = Color.WHITE
	feedback_until_msec = Time.get_ticks_msec() + int(GameConfig.START_LEAD_IN_SEC * 1000.0)
	music.restart()
	queue_redraw()

func _open_chart_editor() -> void:
	music.player.stop()
	get_tree().change_scene_to_file("res://editor.tscn")

func _show_feedback(text: String, color: Color) -> void:
	feedback_text = text
	feedback_color = color
	feedback_until_msec = Time.get_ticks_msec() + int(GameConfig.FEEDBACK_VISIBLE_SEC * 1000.0)

func _draw() -> void:
	var viewport_size := get_viewport_rect().size
	draw_rect(Rect2(Vector2.ZERO, viewport_size), Color("070a14"))
	if not load_error.is_empty():
		_draw_centered_text(load_error, viewport_size.y * 0.5, 24, Color("ff6b79"))
		return

	var play_width := minf(720.0, viewport_size.x - 80.0)
	var play_left := (viewport_size.x - play_width) * 0.5
	var top_y := 100.0
	var hit_y := viewport_size.y - 125.0
	var lane_width := play_width / GameConfig.LANE_COUNT
	var now_msec := Time.get_ticks_msec()

	# Lanes and separators.
	for lane in GameConfig.LANE_COUNT:
		var lane_rect := Rect2(play_left + lane * lane_width, top_y, lane_width, hit_y - top_y + 30.0)
		var lane_base := Color("11172b") if lane % 2 == 0 else Color("0d1325")
		if now_msec < lane_flash_until_msec[lane]:
			lane_base = LANE_COLORS[lane].darkened(0.68)
		draw_rect(lane_rect, lane_base)
		draw_line(Vector2(lane_rect.position.x, top_y), Vector2(lane_rect.position.x, hit_y + 30.0), Color("35405f"), 2.0)
		draw_string(ThemeDB.fallback_font, Vector2(lane_rect.position.x, hit_y + 70.0), GameConfig.LANE_LABELS[lane], HORIZONTAL_ALIGNMENT_CENTER, lane_width, 28, LANE_COLORS[lane])
	draw_line(Vector2(play_left + play_width, top_y), Vector2(play_left + play_width, hit_y + 30.0), Color("35405f"), 2.0)
	draw_line(Vector2(play_left, hit_y), Vector2(play_left + play_width, hit_y), Color.WHITE, 5.0)

	# Note positions are derived directly from the current song time each frame.
	var song_time := music.get_song_time()
	for note in judgement.notes:
		if note["judged"]:
			continue
		var time_until_hit := float(note["time"]) - song_time
		if time_until_hit > GameConfig.NOTE_TRAVEL_TIME_SEC or time_until_hit < -GameConfig.GOOD_WINDOW_SEC:
			continue
		var progress := 1.0 - time_until_hit / GameConfig.NOTE_TRAVEL_TIME_SEC
		var note_y := lerpf(top_y, hit_y, progress)
		var lane := int(note["lane"])
		var note_rect := Rect2(
			play_left + lane * lane_width + 10.0,
			note_y - 11.0,
			lane_width - 20.0,
			22.0
		)
		draw_rect(note_rect, LANE_COLORS[lane], true)
		draw_rect(note_rect, Color.WHITE, false, 2.0)

	_draw_hud(viewport_size, song_time)

func _draw_hud(viewport_size: Vector2, song_time: float) -> void:
	draw_string(ThemeDB.fallback_font, Vector2(24.0, 40.0), "P0 TAP PROTOTYPE", HORIZONTAL_ALIGNMENT_LEFT, -1.0, 24, Color("c9d5ff"))
	draw_string(ThemeDB.fallback_font, Vector2(viewport_size.x - 230.0, 36.0), "COMBO  %d" % judgement.combo, HORIZONTAL_ALIGNMENT_LEFT, 210.0, 25, Color.WHITE)
	draw_string(ThemeDB.fallback_font, Vector2(24.0, 70.0), "TIME  %05.2f" % maxf(song_time, 0.0), HORIZONTAL_ALIGNMENT_LEFT, -1.0, 18, Color("8290b8"))

	var show_feedback := feedback_until_msec == 0 or Time.get_ticks_msec() <= feedback_until_msec
	if show_feedback:
		_draw_centered_text(feedback_text, 70.0, 30, feedback_color)

	if finished:
		var summary := "PERFECT %d    GOOD %d    MISS %d    MAX COMBO %d" % [
			judgement.perfect_count,
			judgement.good_count,
			judgement.miss_count,
			judgement.max_combo
		]
		_draw_centered_text(summary, viewport_size.y * 0.50, 22, Color("d9e2ff"))
		_draw_centered_text("Press R to replay", viewport_size.y * 0.56, 18, Color("8290b8"))

	var audio_status := "AUDIO: %s" % ("loaded" if music.has_audio else "fallback clock (add audio/prototype.ogg)")
	draw_string(ThemeDB.fallback_font, Vector2(24.0, viewport_size.y - 18.0), audio_status, HORIZONTAL_ALIGNMENT_LEFT, -1.0, 14, Color("66749b"))
	draw_string(ThemeDB.fallback_font, Vector2(viewport_size.x - 190.0, viewport_size.y - 18.0), "F2: CHART EDITOR", HORIZONTAL_ALIGNMENT_RIGHT, 166.0, 14, Color("8290b8"))

func _draw_centered_text(text: String, y: float, font_size: int, color: Color) -> void:
	var width := get_viewport_rect().size.x
	draw_string(ThemeDB.fallback_font, Vector2(0.0, y), text, HORIZONTAL_ALIGNMENT_CENTER, width, font_size, color)
