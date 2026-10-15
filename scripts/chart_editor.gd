extends Control

enum EditorMode { EDIT, STEP, RECORD, TEST }

const TIMELINE_SCRIPT := preload("res://scripts/chart_timeline.gd")
const LANE_KEYS := [KEY_D, KEY_F, KEY_J, KEY_K]
const SPEED_VALUES := [0.5, 0.75, 1.0, 1.25, 1.5]
const DIVISION_VALUES := [1, 2, 4, 3, 6]
const DIVISION_LABELS := ["1/4", "1/8", "1/16", "3連符", "6連符"]
const MAX_HISTORY := 100

@onready var audio_player: AudioStreamPlayer = $AudioStreamPlayer

var chart: Dictionary = {
	"audio": "res://audio/prototype.ogg",
	"offset_sec": 0.0,
	"duration_sec": 20.0,
	"notes": [],
	"editor": {"grid_bpm": 120.0, "grid_division": 4, "grid_offset_sec": 0.0, "beats_per_measure": 4}
}
var current_path := GameConfig.CHART_PATH
var current_time_sec := 0.0
var playing := false
var audio_loaded := false
var playback_speed := 1.0
var editor_mode := EditorMode.EDIT
var selected_note := -1
var dirty := false
var _drag_history_pushed := false
var _waiting_for_audio := false
var _undo_stack: Array[Dictionary] = []
var _redo_stack: Array[Dictionary] = []
var _test_judgement := JudgementManager.new()

var timeline: ChartTimeline
var path_label: Label
var audio_path_edit: LineEdit
var offset_spin: SpinBox
var duration_spin: SpinBox
var bpm_spin: SpinBox
var beats_per_measure_spin: SpinBox
var division_option: OptionButton
var grid_offset_spin: SpinBox
var snap_check: CheckButton
var mode_option: OptionButton
var speed_option: OptionButton
var play_button: Button
var note_list: ItemList
var note_time_spin: SpinBox
var note_lane_option: OptionButton
var timeline_scroll: VScrollBar
var auto_follow_check: CheckButton
var debug_label: Label
var status_log: RichTextLabel
var load_dialog: FileDialog
var save_dialog: FileDialog
var audio_dialog: FileDialog
var leave_confirmation: ConfirmationDialog

func _ready() -> void:
	_build_ui()
	_connect_timeline()
	_load_chart(current_path)
	set_process(true)

func _process(delta: float) -> void:
	if playing:
		if audio_loaded and audio_player.playing:
			current_time_sec = audio_player.get_playback_position() \
				+ AudioServer.get_time_since_last_mix() \
				- AudioServer.get_output_latency() \
				+ float(chart["offset_sec"])
		else:
			current_time_sec += delta * playback_speed
			if _waiting_for_audio and current_time_sec >= float(chart["offset_sec"]):
				_start_audio_at_current_time()
		if current_time_sec >= float(chart["duration_sec"]):
			current_time_sec = float(chart["duration_sec"])
			_pause()

	if editor_mode == EditorMode.TEST and playing:
		var misses := _test_judgement.collect_misses(current_time_sec)
		if not misses.is_empty():
			_sync_test_results()
			_set_status("テスト：ミス　コンボ %d" % _test_judgement.combo, true)

	timeline.set_playhead(current_time_sec)
	if auto_follow_check.button_pressed and playing:
		timeline.reveal_time(current_time_sec)
		_sync_scroll_from_timeline()
	_update_debug_label()

func _unhandled_key_input(event: InputEvent) -> void:
	if not event is InputEventKey:
		return
	var key := event as InputEventKey
	if not key.pressed or key.echo:
		return

	if key.keycode == KEY_F2:
		get_viewport().set_input_as_handled()
		_back_to_game()
		return
	if key.ctrl_pressed and key.keycode == KEY_S:
		_save_chart(current_path)
		get_viewport().set_input_as_handled()
		return
	if key.ctrl_pressed and key.keycode == KEY_Z:
		_undo()
		get_viewport().set_input_as_handled()
		return
	if key.ctrl_pressed and key.keycode == KEY_Y:
		_redo()
		get_viewport().set_input_as_handled()
		return

	var focus := get_viewport().gui_get_focus_owner()
	if focus is LineEdit or focus is TextEdit:
		return

	if key.keycode == KEY_SPACE:
		_toggle_playback()
		get_viewport().set_input_as_handled()
		return
	if editor_mode == EditorMode.STEP and key.keycode in [KEY_ENTER, KEY_KP_ENTER]:
		_advance_step_grid()
		get_viewport().set_input_as_handled()
		return
	if key.keycode == KEY_DELETE and selected_note >= 0:
		_delete_note(selected_note)
		get_viewport().set_input_as_handled()
		return

	for lane in GameConfig.LANE_COUNT:
		if key.physical_keycode == LANE_KEYS[lane]:
			_handle_lane_key(lane, key.shift_pressed)
			get_viewport().set_input_as_handled()
			return

func _build_ui() -> void:
	var background := ColorRect.new()
	background.color = Color("070a14")
	background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(background)

	var root_box := VBoxContainer.new()
	root_box.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root_box.offset_left = 8.0
	root_box.offset_top = 8.0
	root_box.offset_right = -8.0
	root_box.offset_bottom = -8.0
	root_box.add_theme_constant_override("separation", 7)
	add_child(root_box)

	var toolbar := HFlowContainer.new()
	root_box.add_child(toolbar)
	_add_button(toolbar, "新規", _new_chart)
	_add_button(toolbar, "読み込み", func() -> void: load_dialog.popup_centered_ratio(0.75))
	_add_button(toolbar, "保存  Ctrl+S", func() -> void: _save_chart(current_path))
	_add_button(toolbar, "名前を付けて保存", func() -> void: save_dialog.popup_centered_ratio(0.75))
	_add_button(toolbar, "元に戻す", _undo)
	_add_button(toolbar, "やり直す", _redo)
	_add_separator(toolbar)
	play_button = _add_button(toolbar, "再生  スペース", _toggle_playback)
	_add_button(toolbar, "停止", _stop)
	mode_option = OptionButton.new()
	mode_option.focus_mode = Control.FOCUS_NONE
	for mode_name in ["編集", "ステップ入力", "記録", "テスト"]:
		mode_option.add_item(mode_name)
	mode_option.item_selected.connect(_on_mode_changed)
	toolbar.add_child(mode_option)
	speed_option = OptionButton.new()
	speed_option.focus_mode = Control.FOCUS_NONE
	for speed in SPEED_VALUES:
		speed_option.add_item("%.2fx" % speed)
	speed_option.select(2)
	speed_option.item_selected.connect(_on_speed_changed)
	toolbar.add_child(speed_option)
	var spacer := Control.new()
	spacer.custom_minimum_size.x = 12.0
	toolbar.add_child(spacer)
	_add_button(toolbar, "譜面を検証", _validate_and_report)
	_add_button(toolbar, "ゲームへ  F2", _back_to_game)

	path_label = Label.new()
	path_label.add_theme_color_override("font_color", Color("8c9abd"))
	root_box.add_child(path_label)

	var split := HSplitContainer.new()
	split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	split.split_offset = 340
	root_box.add_child(split)

	var inspector := VBoxContainer.new()
	inspector.custom_minimum_size.x = 320.0
	inspector.add_theme_constant_override("separation", 6)
	split.add_child(inspector)
	_add_section_label(inspector, "譜面設定")
	var audio_row := HBoxContainer.new()
	inspector.add_child(audio_row)
	audio_path_edit = LineEdit.new()
	audio_path_edit.placeholder_text = "res://audio/prototype.ogg"
	audio_path_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	audio_row.add_child(audio_path_edit)
	_add_button(audio_row, "適用", _apply_audio_path)
	_add_button(audio_row, "...", func() -> void: audio_dialog.popup_centered_ratio(0.75))
	_add_button(audio_row, "音源尺", _use_audio_length)

	var chart_grid := GridContainer.new()
	chart_grid.columns = 2
	inspector.add_child(chart_grid)
	offset_spin = _add_spin_row(chart_grid, "譜面オフセット（秒）", -10.0, 10.0, 0.001)
	duration_spin = _add_spin_row(chart_grid, "譜面の長さ（秒）", 1.0, 7200.0, 0.1)
	bpm_spin = _add_spin_row(chart_grid, "グリッドBPM", 20.0, 400.0, 0.1)
	bpm_spin.value = 120.0
	beats_per_measure_spin = _add_spin_row(chart_grid, "1小節の拍数", 1.0, 16.0, 1.0)
	beats_per_measure_spin.value = 4.0
	chart_grid.add_child(_make_label("グリッド分割"))
	division_option = OptionButton.new()
	division_option.focus_mode = Control.FOCUS_NONE
	for division_label in DIVISION_LABELS:
		division_option.add_item(division_label)
	division_option.select(2)
	chart_grid.add_child(division_option)
	grid_offset_spin = _add_spin_row(chart_grid, "第1小節開始（秒）", -10.0, 10.0, 0.001)
	snap_check = CheckButton.new()
	snap_check.focus_mode = Control.FOCUS_NONE
	snap_check.text = "グリッドにスナップ"
	snap_check.button_pressed = true
	inspector.add_child(snap_check)
	for control in [offset_spin, duration_spin, bpm_spin, beats_per_measure_spin, grid_offset_spin]:
		control.value_changed.connect(_on_chart_setting_changed)
	division_option.item_selected.connect(func(_index: int) -> void: _on_chart_setting_changed(0.0))
	snap_check.toggled.connect(func(enabled: bool) -> void: timeline.snap_enabled = enabled)

	_add_section_label(inspector, "選択中のノーツ")
	var note_grid := GridContainer.new()
	note_grid.columns = 2
	inspector.add_child(note_grid)
	note_time_spin = _add_spin_row(note_grid, "時刻（秒）", 0.0, 7200.0, 0.001)
	note_grid.add_child(_make_label("レーン"))
	note_lane_option = OptionButton.new()
	note_lane_option.focus_mode = Control.FOCUS_NONE
	for lane in GameConfig.LANE_COUNT:
		note_lane_option.add_item("%d  %s" % [lane, GameConfig.LANE_LABELS[lane]])
	note_grid.add_child(note_lane_option)
	var note_buttons := HBoxContainer.new()
	inspector.add_child(note_buttons)
	_add_button(note_buttons, "変更を反映", _update_selected_note)
	_add_button(note_buttons, "複製", _duplicate_selected_note)
	_add_button(note_buttons, "削除", func() -> void: _delete_note(selected_note))

	_add_section_label(inspector, "ノーツ一覧")
	note_list = ItemList.new()
	note_list.focus_mode = Control.FOCUS_NONE
	note_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	note_list.select_mode = ItemList.SELECT_SINGLE
	note_list.item_selected.connect(_select_note)
	inspector.add_child(note_list)

	var right := VBoxContainer.new()
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right.add_theme_constant_override("separation", 5)
	split.add_child(right)
	var timeline_area := HBoxContainer.new()
	timeline_area.size_flags_vertical = Control.SIZE_EXPAND_FILL
	timeline_area.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right.add_child(timeline_area)
	timeline = TIMELINE_SCRIPT.new()
	timeline.size_flags_vertical = Control.SIZE_EXPAND_FILL
	timeline.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	timeline_area.add_child(timeline)
	timeline_scroll = VScrollBar.new()
	timeline_scroll.min_value = 0.0
	timeline_scroll.step = 0.01
	timeline_scroll.custom_minimum_size.x = 24.0
	timeline_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	timeline_scroll.value_changed.connect(func(value: float) -> void: timeline.set_view_start(value))
	timeline_area.add_child(timeline_scroll)

	var scroll_row := HBoxContainer.new()
	right.add_child(scroll_row)
	auto_follow_check = CheckButton.new()
	auto_follow_check.focus_mode = Control.FOCUS_NONE
	auto_follow_check.text = "再生位置を自動追従"
	auto_follow_check.button_pressed = true
	scroll_row.add_child(auto_follow_check)

	debug_label = Label.new()
	debug_label.add_theme_font_size_override("font_size", 17)
	right.add_child(debug_label)
	var help := Label.new()
	help.text = "ステップ入力：DFJKで配置して次へ／Enterで空送り／Shift+DFJKで同じ位置に追加  |  ダブルクリック：追加  |  ドラッグ：移動  |  右クリック／Deleteキー：削除"
	help.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	help.add_theme_color_override("font_color", Color("8290b8"))
	right.add_child(help)
	status_log = RichTextLabel.new()
	status_log.custom_minimum_size.y = 76.0
	status_log.fit_content = false
	status_log.scroll_active = true
	status_log.bbcode_enabled = true
	right.add_child(status_log)

	load_dialog = _make_file_dialog(FileDialog.FILE_MODE_OPEN_FILE, PackedStringArray(["*.json ; 譜面JSON"]))
	load_dialog.title = "譜面を読み込む"
	load_dialog.file_selected.connect(_load_chart)
	save_dialog = _make_file_dialog(FileDialog.FILE_MODE_SAVE_FILE, PackedStringArray(["*.json ; 譜面JSON"]))
	save_dialog.title = "譜面を保存する"
	save_dialog.file_selected.connect(_save_chart)
	audio_dialog = _make_file_dialog(FileDialog.FILE_MODE_OPEN_FILE, PackedStringArray(["*.ogg,*.mp3,*.wav ; 音声ファイル"]))
	audio_dialog.title = "音源を選択する"
	audio_dialog.file_selected.connect(_on_audio_selected)

	leave_confirmation = ConfirmationDialog.new()
	leave_confirmation.title = "未保存の変更"
	leave_confirmation.dialog_text = "保存されていない変更があります。保存せずにゲームへ戻りますか？"
	leave_confirmation.ok_button_text = "保存せず戻る"
	leave_confirmation.cancel_button_text = "キャンセル"
	leave_confirmation.confirmed.connect(_change_to_game)
	add_child(leave_confirmation)

func _connect_timeline() -> void:
	timeline.add_note_requested.connect(_add_note)
	timeline.note_selected.connect(_select_note)
	timeline.note_delete_requested.connect(_delete_note)
	timeline.note_drag_started.connect(_on_note_drag_started)
	timeline.note_move_requested.connect(_move_note_from_timeline)
	timeline.note_drag_finished.connect(_finish_note_drag)
	timeline.seek_requested.connect(_seek)
	timeline.view_changed.connect(func(_start: float, _zoom: float) -> void: _sync_scroll_from_timeline())
	timeline.resized.connect(_sync_scroll_range)

func _load_chart(path: String) -> void:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		_set_status("[color=red]ファイルを開けませんでした：%s[/color]" % path)
		return
	var parser := JSON.new()
	var error := parser.parse(file.get_as_text())
	if error != OK or typeof(parser.data) != TYPE_DICTIONARY:
		_set_status("[color=red]JSONの%d行目にエラーがあります：%s[/color]" % [parser.get_error_line(), parser.get_error_message()])
		return
	var raw: Dictionary = parser.data
	var loaded_notes: Array[Dictionary] = []
	var raw_notes = raw.get("notes", [])
	if typeof(raw_notes) != TYPE_ARRAY:
		_set_status("[color=red]譜面のノーツ欄は配列である必要があります。[/color]")
		return
	for raw_note in raw_notes:
		if typeof(raw_note) == TYPE_DICTIONARY and raw_note.get("type", "tap") == "tap":
			loaded_notes.append({"type": "tap", "time": float(raw_note.get("time", 0.0)), "lane": int(raw_note.get("lane", 0))})
	var raw_editor = raw.get("editor", {})
	if typeof(raw_editor) != TYPE_DICTIONARY:
		raw_editor = {}
	chart = {
		"audio": str(raw.get("audio", "res://audio/prototype.ogg")),
		"offset_sec": float(raw.get("offset_sec", 0.0)),
		"duration_sec": maxf(1.0, float(raw.get("duration_sec", 20.0))),
		"notes": loaded_notes,
		"editor": raw_editor
	}
	_sort_notes()
	current_path = path
	current_time_sec = 0.0
	selected_note = -1
	_undo_stack.clear()
	_redo_stack.clear()
	dirty = false
	_refresh_all()
	_load_audio()
	_set_status("読み込み完了：%s（%dノーツ）" % [path, loaded_notes.size()])
	_validate_and_report(false)

func _new_chart() -> void:
	_push_history()
	chart = {
		"audio": "res://audio/prototype.ogg",
		"offset_sec": 0.0,
		"duration_sec": 20.0,
		"notes": [],
		"editor": {"grid_bpm": 120.0, "grid_division": 4, "grid_offset_sec": 0.0, "beats_per_measure": 4}
	}
	current_path = "res://charts/new_chart.json"
	current_time_sec = 0.0
	selected_note = -1
	_redo_stack.clear()
	_mark_changed()
	_refresh_all()
	_load_audio()
	_set_status("新しい譜面を作成しました。「名前を付けて保存」で保存先を指定してください。")

func _save_chart(path: String) -> void:
	if path.is_empty():
		save_dialog.popup_centered_ratio(0.75)
		return
	_apply_chart_controls(false)
	_sort_notes()
	var clean_notes: Array[Dictionary] = []
	for note in chart["notes"]:
		clean_notes.append({"type": "tap", "time": snappedf(float(note["time"]), 0.000001), "lane": int(note["lane"])})
	var output := {
		"audio": chart["audio"],
		"offset_sec": chart["offset_sec"],
		"duration_sec": chart["duration_sec"],
		"editor": chart["editor"],
		"notes": clean_notes
	}
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		_set_status("[color=red]保存できませんでした：%s[/color]" % path)
		return
	file.store_string(JSON.stringify(output, "  ") + "\n")
	current_path = path
	dirty = false
	_refresh_path_label()
	_set_status("保存完了：%s（%dノーツ）" % [path, clean_notes.size()])

func _add_note(time_sec: float, lane: int) -> void:
	_push_history()
	var clamped_time := clampf(time_sec, 0.0, float(chart["duration_sec"]))
	chart["notes"].append({"type": "tap", "time": clamped_time, "lane": lane})
	_sort_notes()
	selected_note = _find_note_index(clamped_time, lane)
	_mark_changed()
	_refresh_notes()
	_select_note(selected_note)

func _delete_note(index: int) -> void:
	if index < 0 or index >= chart["notes"].size():
		return
	_push_history()
	chart["notes"].remove_at(index)
	selected_note = mini(index, chart["notes"].size() - 1)
	_mark_changed()
	_refresh_notes()
	_select_note(selected_note)

func _duplicate_selected_note() -> void:
	if selected_note < 0 or selected_note >= chart["notes"].size():
		return
	var source: Dictionary = chart["notes"][selected_note]
	_add_note(float(source["time"]) + _grid_step(), int(source["lane"]))

func _update_selected_note() -> void:
	if selected_note < 0 or selected_note >= chart["notes"].size():
		return
	_push_history()
	var note: Dictionary = chart["notes"][selected_note]
	note["time"] = clampf(note_time_spin.value, 0.0, float(chart["duration_sec"]))
	note["lane"] = note_lane_option.selected
	chart["notes"][selected_note] = note
	_sort_notes()
	selected_note = _find_note_index(float(note["time"]), int(note["lane"]))
	_mark_changed()
	_refresh_notes()
	_select_note(selected_note)

func _on_note_drag_started() -> void:
	_push_history()
	_drag_history_pushed = true

func _move_note_from_timeline(index: int, time_sec: float, lane: int) -> void:
	if index < 0 or index >= chart["notes"].size():
		return
	if not _drag_history_pushed:
		_push_history()
		_drag_history_pushed = true
	var note: Dictionary = chart["notes"][index]
	note["time"] = clampf(time_sec, 0.0, float(chart["duration_sec"]))
	note["lane"] = lane
	chart["notes"][index] = note
	selected_note = index
	_mark_changed()
	_refresh_notes(false)

func _finish_note_drag() -> void:
	if selected_note < 0 or selected_note >= chart["notes"].size():
		return
	var moved_note: Dictionary = chart["notes"][selected_note]
	_sort_notes()
	selected_note = _find_note_index(float(moved_note["time"]), int(moved_note["lane"]))
	_drag_history_pushed = false
	_refresh_notes()
	_select_note(selected_note)

func _select_note(index: int) -> void:
	_drag_history_pushed = false
	selected_note = index
	timeline.selected_index = index
	if index >= 0 and index < chart["notes"].size():
		var note: Dictionary = chart["notes"][index]
		note_time_spin.value = float(note["time"])
		note_lane_option.select(clampi(int(note["lane"]), 0, GameConfig.LANE_COUNT - 1))
		if not note_list.is_selected(index):
			note_list.select(index)
		timeline.reveal_time(float(note["time"]))
		_sync_scroll_from_timeline()
	else:
		note_list.deselect_all()
	timeline.queue_redraw()

func _handle_lane_key(lane: int, keep_step_position := false) -> void:
	if editor_mode == EditorMode.STEP:
		_add_step_note(lane, keep_step_position)
	elif editor_mode == EditorMode.RECORD:
		_add_note(_snap_time(current_time_sec), lane)
		_set_status("記録：レーン%s　%.3f秒" % [GameConfig.LANE_LABELS[lane], current_time_sec], true)
	elif editor_mode == EditorMode.TEST:
		var result := _test_judgement.judge_press(lane, current_time_sec)
		if result.is_empty():
			_set_status("テスト：空打ち　レーン%s　%.3f秒" % [GameConfig.LANE_LABELS[lane], current_time_sec], true)
		else:
			_sync_test_results()
			_set_status("テスト：%s　%+dミリ秒　コンボ %d" % [_result_label(str(result["result"])), roundi(float(result["delta_sec"]) * 1000.0), _test_judgement.combo], true)

func _add_step_note(lane: int, keep_position: bool) -> void:
	var grid_time := _nearest_grid_time(current_time_sec)
	if _note_exists(grid_time, lane):
		_set_status("ステップ入力：%.3f秒のレーン%sには既にノーツがあります" % [grid_time, GameConfig.LANE_LABELS[lane]], true)
	else:
		_add_note(grid_time, lane)
		_set_status("ステップ入力：レーン%s　%.3f秒" % [GameConfig.LANE_LABELS[lane], grid_time], true)
	if not keep_position:
		_advance_step_grid()

func _advance_step_grid() -> void:
	var current_grid := _nearest_grid_time(current_time_sec)
	var step := _grid_step()
	var next_grid_index := floori((current_grid - grid_offset_spin.value) / step + 0.0001) + 1
	var next_grid := grid_offset_spin.value + next_grid_index * step
	if next_grid > float(chart["duration_sec"]) + 0.000001:
		_set_status("ステップ入力：譜面の終端です。譜面の長さを延長してください。", true)
		return
	_seek(next_grid)
	timeline.reveal_time(current_time_sec)
	_sync_scroll_from_timeline()
	_set_status("ステップ入力：次のグリッド %.3f秒へ移動" % current_time_sec, true)

func _note_exists(time_sec: float, lane: int) -> bool:
	for note in chart["notes"]:
		if int(note["lane"]) == lane and absf(float(note["time"]) - time_sec) < 0.0005:
			return true
	return false

func _toggle_playback() -> void:
	if editor_mode == EditorMode.STEP:
		_set_status("ステップ入力モードでは再生せずに入力します。曲に合わせる場合は「記録」モードを選んでください。")
		return
	if playing:
		_pause()
	else:
		_play()

func _play() -> void:
	if current_time_sec >= float(chart["duration_sec"]):
		current_time_sec = 0.0
	if editor_mode == EditorMode.TEST:
		_reset_test_from_time(current_time_sec)
	playing = true
	play_button.text = "一時停止  スペース"
	_start_audio_at_current_time()

func _pause() -> void:
	playing = false
	_waiting_for_audio = false
	audio_player.stop()
	play_button.text = "再生  スペース"

func _stop() -> void:
	_pause()
	_seek(0.0)

func _seek(time_sec: float) -> void:
	current_time_sec = clampf(time_sec, 0.0, float(chart["duration_sec"]))
	if playing:
		_start_audio_at_current_time()
	if editor_mode == EditorMode.TEST:
		_reset_test_from_time(current_time_sec)
	timeline.set_playhead(current_time_sec)

func _start_audio_at_current_time() -> void:
	audio_player.stop()
	_waiting_for_audio = false
	if not audio_loaded:
		return
	var audio_time := current_time_sec - float(chart["offset_sec"])
	if audio_time >= 0.0 and audio_player.stream != null and audio_time < audio_player.stream.get_length():
		audio_player.pitch_scale = playback_speed
		audio_player.play(audio_time)
	elif audio_time < 0.0:
		_waiting_for_audio = true

func _on_mode_changed(index: int) -> void:
	editor_mode = index
	if editor_mode == EditorMode.STEP:
		_pause()
		_seek(_nearest_grid_time(current_time_sec))
		timeline.reveal_time(current_time_sec)
		_sync_scroll_from_timeline()
		_set_status("ステップ入力：DFJKで配置して次へ、Enterで空のまま次へ進みます")
		return
	elif editor_mode == EditorMode.TEST:
		_reset_test_from_time(current_time_sec)
	_set_status("モード：%s" % mode_option.get_item_text(index))

func _on_speed_changed(index: int) -> void:
	playback_speed = SPEED_VALUES[index]
	if playing:
		_start_audio_at_current_time()

func _on_chart_setting_changed(_value: float) -> void:
	if timeline == null:
		return
	_apply_chart_controls()

func _apply_chart_controls(mark_dirty := true) -> void:
	chart["offset_sec"] = offset_spin.value
	chart["duration_sec"] = duration_spin.value
	chart["editor"] = {
		"grid_bpm": bpm_spin.value,
		"grid_division": DIVISION_VALUES[division_option.selected],
		"grid_offset_sec": grid_offset_spin.value,
		"beats_per_measure": int(beats_per_measure_spin.value)
	}
	timeline.duration_sec = duration_spin.value
	timeline.grid_step_sec = _grid_step()
	timeline.grid_offset_sec = grid_offset_spin.value
	timeline.seconds_per_beat = 60.0 / maxf(1.0, bpm_spin.value)
	timeline.beats_per_measure = int(beats_per_measure_spin.value)
	timeline.snap_enabled = snap_check.button_pressed
	_sync_scroll_range()
	if mark_dirty:
		_mark_changed()
	timeline.queue_redraw()

func _apply_audio_path() -> void:
	if chart["audio"] != audio_path_edit.text.strip_edges():
		_push_history()
	chart["audio"] = audio_path_edit.text.strip_edges()
	_mark_changed()
	_load_audio()

func _on_audio_selected(path: String) -> void:
	audio_path_edit.text = path
	_apply_audio_path()

func _use_audio_length() -> void:
	if not audio_loaded or audio_player.stream == null:
		_set_status("音源が読み込まれていないため、長さを取得できません。")
		return
	_push_history()
	duration_spin.value = maxf(1.0, audio_player.stream.get_length() + float(chart["offset_sec"]))
	_apply_chart_controls()
	_set_status("譜面の長さを音源に合わせました：%.3f秒" % duration_spin.value)

func _load_audio() -> void:
	audio_player.stop()
	audio_player.stream = null
	audio_loaded = false
	var audio_path := str(chart["audio"])
	if ResourceLoader.exists(audio_path):
		var resource = load(audio_path)
		if resource is AudioStream:
			audio_player.stream = resource
			audio_loaded = true
	_set_status("音源を読み込みました：%s" % audio_path if audio_loaded else "音源がありません：%s（内部時計でプレビューします）" % audio_path, true)

func _validate_and_report(replace_log := true) -> void:
	var messages: Array[String] = []
	var notes: Array = chart["notes"]
	if notes.is_empty():
		messages.append("エラー：ノーツがありません")
	var seen := {}
	var previous_time := -INF
	for index in notes.size():
		var note: Dictionary = notes[index]
		var time := float(note["time"])
		var lane := int(note["lane"])
		if time < 0.0:
			messages.append("エラー：ノーツ%dの時刻が負数です" % index)
		if lane < 0 or lane >= GameConfig.LANE_COUNT:
			messages.append("エラー：ノーツ%dのレーン%dは無効です" % [index, lane])
		if time < previous_time:
			messages.append("エラー：ノーツ%d付近が時刻順ではありません" % index)
		previous_time = time
		var duplicate_key := "%d:%.4f" % [lane, time]
		if seen.has(duplicate_key):
			messages.append("警告：%.3f秒のレーン%dにノーツが重複しています" % [time, lane])
		seen[duplicate_key] = true
	if not notes.is_empty() and float(notes[-1]["time"]) > float(chart["duration_sec"]):
		messages.append("エラー：最後のノーツが譜面の長さを超えています")
	if not ResourceLoader.exists(str(chart["audio"])):
		messages.append("情報：音源がないため、プレビューには内部時計を使用します")
	if messages.is_empty():
		messages.append("問題は見つかりませんでした")
	var report := "\n".join(messages)
	if replace_log:
		status_log.clear()
	status_log.append_text(report + "\n")

func _reset_test_from_time(time_sec: float) -> void:
	_test_judgement.configure(chart["notes"])
	for index in _test_judgement.notes.size():
		if float(_test_judgement.notes[index]["time"]) < time_sec - GameConfig.GOOD_WINDOW_SEC:
			var note: Dictionary = _test_judgement.notes[index]
			note["judged"] = true
			note["result"] = "SKIP"
			_test_judgement.notes[index] = note
	timeline.debug_note_results.clear()
	timeline.queue_redraw()

func _sync_test_results() -> void:
	timeline.debug_note_results.clear()
	for index in _test_judgement.notes.size():
		var result := str(_test_judgement.notes[index]["result"])
		if result in ["PERFECT", "GOOD", "MISS"]:
			timeline.debug_note_results[index] = result
	timeline.queue_redraw()

func _push_history() -> void:
	_undo_stack.append({"chart": chart.duplicate(true), "path": current_path})
	if _undo_stack.size() > MAX_HISTORY:
		_undo_stack.pop_front()
	_redo_stack.clear()

func _undo() -> void:
	if _undo_stack.is_empty():
		return
	_redo_stack.append({"chart": chart.duplicate(true), "path": current_path})
	var state: Dictionary = _undo_stack.pop_back()
	chart = state["chart"]
	current_path = str(state["path"])
	selected_note = -1
	_mark_changed()
	_refresh_all()
	_load_audio()

func _redo() -> void:
	if _redo_stack.is_empty():
		return
	_undo_stack.append({"chart": chart.duplicate(true), "path": current_path})
	var state: Dictionary = _redo_stack.pop_back()
	chart = state["chart"]
	current_path = str(state["path"])
	selected_note = -1
	_mark_changed()
	_refresh_all()
	_load_audio()

func _refresh_all() -> void:
	audio_path_edit.text = str(chart["audio"])
	offset_spin.set_value_no_signal(float(chart["offset_sec"]))
	duration_spin.set_value_no_signal(float(chart["duration_sec"]))
	var editor_settings: Dictionary = chart.get("editor", {})
	bpm_spin.set_value_no_signal(float(editor_settings.get("grid_bpm", 120.0)))
	beats_per_measure_spin.set_value_no_signal(float(editor_settings.get("beats_per_measure", 4)))
	var saved_division := int(editor_settings.get("grid_division", 4))
	var division_index: int = DIVISION_VALUES.find(saved_division)
	division_option.select(maxi(0, division_index))
	grid_offset_spin.set_value_no_signal(float(editor_settings.get("grid_offset_sec", 0.0)))
	timeline.duration_sec = float(chart["duration_sec"])
	timeline.grid_step_sec = _grid_step()
	timeline.grid_offset_sec = grid_offset_spin.value
	timeline.seconds_per_beat = 60.0 / maxf(1.0, bpm_spin.value)
	timeline.beats_per_measure = int(beats_per_measure_spin.value)
	timeline.snap_enabled = snap_check.button_pressed
	_refresh_notes()
	_refresh_path_label()
	_sync_scroll_range()

func _refresh_notes(rebuild_list := true) -> void:
	timeline.set_notes(chart["notes"])
	timeline.selected_index = selected_note
	if rebuild_list:
		note_list.clear()
		for note in chart["notes"]:
			var lane := int(note["lane"])
			var lane_label: String = str(GameConfig.LANE_LABELS[lane]) if lane >= 0 and lane < GameConfig.LANE_COUNT else "?"
			note_list.add_item("%8.3f秒    レーン%d %s" % [float(note["time"]), lane, lane_label])
		if selected_note >= 0 and selected_note < note_list.item_count:
			note_list.select(selected_note)
	timeline.queue_redraw()

func _refresh_path_label() -> void:
	path_label.text = ("● " if dirty else "") + current_path

func _mark_changed() -> void:
	dirty = true
	_refresh_path_label()

func _sort_notes() -> void:
	chart["notes"].sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if is_equal_approx(float(a["time"]), float(b["time"])):
			return int(a["lane"]) < int(b["lane"])
		return float(a["time"]) < float(b["time"])
	)

func _find_note_index(time_sec: float, lane: int) -> int:
	for index in chart["notes"].size():
		var note: Dictionary = chart["notes"][index]
		if is_equal_approx(float(note["time"]), time_sec) and int(note["lane"]) == lane:
			return index
	return -1

func _grid_step() -> float:
	var division: int = int(DIVISION_VALUES[division_option.selected])
	return 60.0 / maxf(1.0, bpm_spin.value) / division

func _snap_time(time_sec: float) -> float:
	if not snap_check.button_pressed:
		return clampf(time_sec, 0.0, float(chart["duration_sec"]))
	return _nearest_grid_time(time_sec)

func _nearest_grid_time(time_sec: float) -> float:
	var step := _grid_step()
	var grid_offset := grid_offset_spin.value
	var snapped_time := roundf((time_sec - grid_offset) / step) * step + grid_offset
	if snapped_time < 0.0:
		snapped_time = grid_offset + ceili(-grid_offset / step) * step
	var chart_duration := float(chart["duration_sec"])
	if snapped_time > chart_duration:
		snapped_time = grid_offset + floori((chart_duration - grid_offset) / step) * step
	return clampf(snapped_time, 0.0, chart_duration)

func _sync_scroll_range() -> void:
	timeline_scroll.max_value = float(chart["duration_sec"])
	timeline_scroll.page = timeline.visible_duration()
	_sync_scroll_from_timeline()

func _sync_scroll_from_timeline() -> void:
	timeline_scroll.set_value_no_signal(timeline.view_start_sec)
	timeline_scroll.max_value = float(chart["duration_sec"])
	timeline_scroll.page = timeline.visible_duration()

func _update_debug_label() -> void:
	var mode_text := mode_option.get_item_text(mode_option.selected)
	var audio_text: String = "音源同期" if audio_loaded else "内部時計"
	var test_text := ""
	if editor_mode == EditorMode.TEST:
		test_text = "  |  パーフェクト %d / グッド %d / ミス %d / コンボ %d" % [_test_judgement.perfect_count, _test_judgement.good_count, _test_judgement.miss_count, _test_judgement.combo]
	debug_label.text = "%.3f / %.3f秒  |  %dノーツ  |  %s  |  %s%s" % [current_time_sec, float(chart["duration_sec"]), chart["notes"].size(), mode_text, audio_text, test_text]

func _set_status(message: String, append := false) -> void:
	if not append:
		status_log.clear()
	status_log.append_text(message + "\n")
	status_log.scroll_to_line(status_log.get_line_count())

func _result_label(result: String) -> String:
	match result:
		"PERFECT":
			return "パーフェクト"
		"GOOD":
			return "グッド"
		"MISS":
			return "ミス"
		_:
			return result

func _back_to_game() -> void:
	if dirty:
		leave_confirmation.popup_centered()
	else:
		_change_to_game()

func _change_to_game() -> void:
	get_tree().change_scene_to_file("res://main.tscn")

func _add_button(parent: Control, text: String, callback: Callable) -> Button:
	var button := Button.new()
	button.text = text
	button.focus_mode = Control.FOCUS_NONE
	button.pressed.connect(callback)
	parent.add_child(button)
	return button

func _add_separator(parent: Control) -> void:
	var separator := VSeparator.new()
	parent.add_child(separator)

func _add_section_label(parent: Control, text: String) -> void:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", 16)
	label.add_theme_color_override("font_color", Color("91a7e8"))
	parent.add_child(label)

func _make_label(text: String) -> Label:
	var label := Label.new()
	label.text = text
	return label

func _add_spin_row(parent: GridContainer, label_text: String, minimum: float, maximum: float, step: float) -> SpinBox:
	parent.add_child(_make_label(label_text))
	var spin := SpinBox.new()
	spin.min_value = minimum
	spin.max_value = maximum
	spin.step = step
	spin.allow_greater = true
	spin.update_on_text_changed = true
	parent.add_child(spin)
	return spin

func _make_file_dialog(mode: int, filters: PackedStringArray) -> FileDialog:
	var dialog := FileDialog.new()
	dialog.access = FileDialog.ACCESS_RESOURCES
	dialog.file_mode = mode
	dialog.filters = filters
	dialog.current_dir = "res://charts" if "json" in filters[0].to_lower() else "res://audio"
	dialog.size = Vector2i(850, 560)
	add_child(dialog)
	return dialog
