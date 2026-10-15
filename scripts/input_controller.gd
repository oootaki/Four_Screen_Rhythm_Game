class_name InputController
extends Node

signal lane_pressed(lane: int)
signal restart_requested
signal editor_requested

const LANE_ACTIONS := ["lane_0", "lane_1", "lane_2", "lane_3"]
const DEFAULT_KEYS := [KEY_D, KEY_F, KEY_J, KEY_K]

func _ready() -> void:
	for lane in GameConfig.LANE_COUNT:
		_ensure_key_action(LANE_ACTIONS[lane], DEFAULT_KEYS[lane])
	_ensure_key_action("restart_song", KEY_R)
	_ensure_key_action("open_chart_editor", KEY_F2)

func _unhandled_input(event: InputEvent) -> void:
	if event.is_echo():
		return
	for lane in GameConfig.LANE_COUNT:
		if event.is_action_pressed(LANE_ACTIONS[lane]):
			lane_pressed.emit(lane)
			get_viewport().set_input_as_handled()
			return
	if event.is_action_pressed("restart_song"):
		restart_requested.emit()
		get_viewport().set_input_as_handled()
		return
	if event.is_action_pressed("open_chart_editor"):
		get_viewport().set_input_as_handled()
		editor_requested.emit()

func _ensure_key_action(action_name: StringName, physical_key: Key) -> void:
	if not InputMap.has_action(action_name):
		InputMap.add_action(action_name)
	if not InputMap.action_get_events(action_name).is_empty():
		return
	var key_event := InputEventKey.new()
	key_event.physical_keycode = physical_key
	InputMap.action_add_event(action_name, key_event)
