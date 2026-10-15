class_name ChartTimeline
extends Control

signal add_note_requested(time_sec: float, lane: int)
signal note_selected(index: int)
signal note_delete_requested(index: int)
signal note_drag_started
signal note_move_requested(index: int, time_sec: float, lane: int)
signal note_drag_finished
signal seek_requested(time_sec: float)
signal view_changed(start_sec: float, pixels_per_sec: float)

const LEFT_MARGIN := 62.0
const RIGHT_MARGIN := 14.0
const TOP_MARGIN := 42.0
const BOTTOM_MARGIN := 16.0
const LANE_COLORS := [
	Color("55d6ff"), Color("7cf29a"), Color("ffd166"), Color("ff6b9a")
]

var notes: Array[Dictionary] = []
var duration_sec := 20.0
var current_time_sec := 0.0
var view_start_sec := 0.0
var pixels_per_sec := 100.0
var grid_step_sec := 0.25
var grid_offset_sec := 0.0
var seconds_per_beat := 0.5
var beats_per_measure := 4
var snap_enabled := true
var selected_index := -1
var debug_note_results: Dictionary = {}

var _dragging := false
var _drag_index := -1

func _ready() -> void:
	custom_minimum_size = Vector2(500.0, 360.0)
	mouse_filter = Control.MOUSE_FILTER_STOP
	focus_mode = Control.FOCUS_CLICK
	clip_contents = true

func set_notes(value: Array) -> void:
	notes.clear()
	for value_note in value:
		if typeof(value_note) == TYPE_DICTIONARY:
			notes.append(value_note)
	if selected_index >= notes.size():
		selected_index = -1
	queue_redraw()

func set_playhead(value: float) -> void:
	current_time_sec = value
	queue_redraw()

func set_view_start(value: float) -> void:
	view_start_sec = clampf(value, 0.0, maxf(0.0, duration_sec - visible_duration()))
	queue_redraw()

func visible_duration() -> float:
	return maxf(1.0, (size.y - TOP_MARGIN - BOTTOM_MARGIN) / pixels_per_sec)

func reveal_time(time_sec: float) -> void:
	var visible_span := visible_duration()
	var target_line := view_start_sec + visible_span * 0.16
	if time_sec < view_start_sec or time_sec > target_line:
		# 再生位置を上寄りに保ち、先のノーツを下から上へ流す。
		set_view_start(maxf(0.0, time_sec - visible_span * 0.16))
	view_changed.emit(view_start_sec, pixels_per_sec)

func _draw() -> void:
	var content_rect := Rect2(
		LEFT_MARGIN,
		TOP_MARGIN,
		size.x - LEFT_MARGIN - RIGHT_MARGIN,
		size.y - TOP_MARGIN - BOTTOM_MARGIN
	)
	draw_rect(Rect2(Vector2.ZERO, size), Color("080c17"))
	draw_rect(content_rect, Color("10172a"))
	var lane_width := content_rect.size.x / GameConfig.LANE_COUNT

	# 縦型プレビュー：未来のノーツを下側に置き、再生時は下から上へ流す。
	for lane in GameConfig.LANE_COUNT:
		var lane_rect := Rect2(
			content_rect.position.x + lane * lane_width,
			content_rect.position.y,
			lane_width,
			content_rect.size.y
		)
		if lane % 2 == 1:
			draw_rect(lane_rect, Color("0c1324"))
		draw_line(lane_rect.position, Vector2(lane_rect.position.x, content_rect.end.y), Color("2d3856"), 1.0)
		draw_string(
			ThemeDB.fallback_font,
			Vector2(lane_rect.position.x, TOP_MARGIN - 14.0),
			"%d  %s" % [lane, GameConfig.LANE_LABELS[lane]],
			HORIZONTAL_ALIGNMENT_CENTER,
			lane_width,
			17,
			LANE_COLORS[lane]
		)
	draw_line(Vector2(content_rect.end.x, content_rect.position.y), content_rect.end, Color("2d3856"), 1.0)
	draw_string(ThemeDB.fallback_font, Vector2(content_rect.end.x - 116.0, TOP_MARGIN - 14.0), "進行方向 ↑", HORIZONTAL_ALIGNMENT_RIGHT, 110.0, 14, Color("8794b6"))

	_draw_grid(content_rect)

	for index in notes.size():
		var note := notes[index]
		var note_time := float(note["time"])
		if note_time < view_start_sec - 0.2 or note_time > view_start_sec + visible_duration() + 0.2:
			continue
		var rect := _note_rect(index)
		var lane := int(note["lane"])
		var color: Color = LANE_COLORS[lane] if lane >= 0 and lane < GameConfig.LANE_COUNT else Color("ec526f")
		if debug_note_results.has(index):
			var result := str(debug_note_results[index])
			color = Color("62e89c") if result == "PERFECT" else (Color("f6cf67") if result == "GOOD" else Color("ec526f"))
		if index == selected_index:
			var center_y := rect.get_center().y
			var good_height := GameConfig.GOOD_WINDOW_SEC * pixels_per_sec
			draw_rect(
				Rect2(rect.position.x, center_y - good_height, rect.size.x, good_height * 2.0),
				Color(1.0, 0.82, 0.35, 0.14)
			)
			draw_rect(rect.grow(3.0), Color.WHITE, false, 2.0)
		draw_rect(rect, color)
		draw_rect(rect, Color.WHITE, false, 1.0)

	var playhead_y := _time_to_y(current_time_sec)
	if playhead_y >= content_rect.position.y and playhead_y <= content_rect.end.y:
		draw_line(Vector2(content_rect.position.x, playhead_y), Vector2(content_rect.end.x, playhead_y), Color("ff4f78"), 2.0)
		draw_colored_polygon(PackedVector2Array([
			Vector2(content_rect.position.x - 8.0, playhead_y - 6.0),
			Vector2(content_rect.position.x - 8.0, playhead_y + 6.0),
			Vector2(content_rect.position.x, playhead_y)
		]), Color("ff4f78"))

func _draw_grid(content_rect: Rect2) -> void:
	# 細分グリッド。
	var effective_step := maxf(grid_step_sec, 0.001)
	while effective_step * pixels_per_sec < 9.0:
		effective_step *= 2.0
	var first_grid := ceilf((view_start_sec - grid_offset_sec) / effective_step) * effective_step + grid_offset_sec
	var time := first_grid
	var end_time := view_start_sec + visible_duration()
	while time <= end_time + effective_step:
		var y := _time_to_y(time)
		draw_line(Vector2(content_rect.position.x, y), Vector2(content_rect.end.x, y), Color("26324f"), 1.0)
		time += effective_step

	# 拍線。
	var beat_step := maxf(seconds_per_beat, 0.001)
	var first_beat := ceilf((view_start_sec - grid_offset_sec) / beat_step) * beat_step + grid_offset_sec
	time = first_beat
	while time <= end_time + beat_step:
		var y := _time_to_y(time)
		draw_line(Vector2(content_rect.position.x, y), Vector2(content_rect.end.x, y), Color("415172"), 1.0)
		time += beat_step

	# 小節線と小節番号。グリッド基準位置を第1小節の先頭とする。
	var measure_step := beat_step * maxi(1, beats_per_measure)
	var first_measure_index := ceili((view_start_sec - grid_offset_sec) / measure_step)
	time = grid_offset_sec + first_measure_index * measure_step
	while time <= end_time + measure_step:
		var y := _time_to_y(time)
		var measure_number := first_measure_index + 1
		draw_line(Vector2(content_rect.position.x, y), Vector2(content_rect.end.x, y), Color("7184b8"), 2.0)
		if measure_number >= 1:
			draw_string(
				ThemeDB.fallback_font,
				Vector2(4.0, y + 5.0),
				"第%d小節" % measure_number,
				HORIZONTAL_ALIGNMENT_RIGHT,
				LEFT_MARGIN - 10.0,
				13,
				Color("aebbe0")
			)
		first_measure_index += 1
		time += measure_step

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mouse_event := event as InputEventMouseButton
		if mouse_event.pressed and mouse_event.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]:
			var direction := -1.0 if mouse_event.button_index == MOUSE_BUTTON_WHEEL_UP else 1.0
			if mouse_event.ctrl_pressed:
				_zoom_at(mouse_event.position.y, 1.15 if direction < 0.0 else 1.0 / 1.15)
			else:
				set_view_start(view_start_sec + direction * visible_duration() * 0.12)
			view_changed.emit(view_start_sec, pixels_per_sec)
			accept_event()
			return

		if mouse_event.button_index == MOUSE_BUTTON_RIGHT and mouse_event.pressed:
			var right_hit := _hit_test(mouse_event.position)
			if right_hit >= 0:
				note_delete_requested.emit(right_hit)
				accept_event()
			return

		if mouse_event.button_index == MOUSE_BUTTON_LEFT:
			if mouse_event.pressed:
				var lane := _position_to_lane(mouse_event.position)
				if lane < 0:
					return
				var hit := _hit_test(mouse_event.position)
				if mouse_event.double_click and hit < 0:
					add_note_requested.emit(_snap_time(_y_to_time(mouse_event.position.y)), lane)
					accept_event()
					return
				if hit >= 0:
					selected_index = hit
					_drag_index = hit
					_dragging = true
					note_selected.emit(hit)
					note_drag_started.emit()
					queue_redraw()
				else:
					selected_index = -1
					note_selected.emit(-1)
					seek_requested.emit(clampf(_y_to_time(mouse_event.position.y), 0.0, duration_sec))
				accept_event()
			else:
				if _dragging:
					note_drag_finished.emit()
				_dragging = false
				_drag_index = -1

	if event is InputEventMouseMotion and _dragging and _drag_index >= 0:
		var motion := event as InputEventMouseMotion
		var lane := _position_to_lane(motion.position)
		if lane >= 0:
			note_move_requested.emit(_drag_index, _snap_time(_y_to_time(motion.position.y)), lane)
		accept_event()

func _zoom_at(mouse_y: float, factor: float) -> void:
	var anchor_time := _y_to_time(mouse_y)
	pixels_per_sec = clampf(pixels_per_sec * factor, 35.0, 600.0)
	view_start_sec = anchor_time - (mouse_y - TOP_MARGIN) / pixels_per_sec
	set_view_start(view_start_sec)

func _hit_test(position: Vector2) -> int:
	for index in range(notes.size() - 1, -1, -1):
		if _note_rect(index).grow(4.0).has_point(position):
			return index
	return -1

func _note_rect(index: int) -> Rect2:
	var lane_width := (size.x - LEFT_MARGIN - RIGHT_MARGIN) / GameConfig.LANE_COUNT
	var note := notes[index]
	return Rect2(
		LEFT_MARGIN + int(note["lane"]) * lane_width + lane_width * 0.14,
		_time_to_y(float(note["time"])) - 7.0,
		lane_width * 0.72,
		14.0
	)

func _position_to_lane(position: Vector2) -> int:
	if position.x < LEFT_MARGIN or position.x > size.x - RIGHT_MARGIN or position.y < TOP_MARGIN or position.y > size.y - BOTTOM_MARGIN:
		return -1
	var lane_width := (size.x - LEFT_MARGIN - RIGHT_MARGIN) / GameConfig.LANE_COUNT
	return clampi(int((position.x - LEFT_MARGIN) / lane_width), 0, GameConfig.LANE_COUNT - 1)

func _time_to_y(time_sec: float) -> float:
	return TOP_MARGIN + (time_sec - view_start_sec) * pixels_per_sec

func _y_to_time(y: float) -> float:
	return view_start_sec + (y - TOP_MARGIN) / pixels_per_sec

func _snap_time(time_sec: float) -> float:
	if not snap_enabled or grid_step_sec <= 0.0:
		return maxf(0.0, time_sec)
	return maxf(0.0, roundf((time_sec - grid_offset_sec) / grid_step_sec) * grid_step_sec + grid_offset_sec)
