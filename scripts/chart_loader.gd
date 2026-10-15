class_name ChartLoader
extends RefCounted

static func load_chart(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		push_error("Chart file was not found: %s" % path)
		return {}

	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		push_error("Chart file could not be opened: %s" % path)
		return {}

	var parser := JSON.new()
	var parse_error := parser.parse(file.get_as_text())
	if parse_error != OK:
		push_error("Chart JSON error at line %d: %s" % [parser.get_error_line(), parser.get_error_message()])
		return {}

	var raw = parser.data
	if typeof(raw) != TYPE_DICTIONARY:
		push_error("Chart root must be a JSON object.")
		return {}

	var clean_notes: Array[Dictionary] = []
	var raw_notes = raw.get("notes", [])
	if typeof(raw_notes) != TYPE_ARRAY:
		push_error("Chart 'notes' must be an array.")
		return {}

	for index in raw_notes.size():
		var raw_note = raw_notes[index]
		if typeof(raw_note) != TYPE_DICTIONARY:
			push_warning("Ignoring note %d: expected an object." % index)
			continue
		if raw_note.get("type", "tap") != "tap":
			push_warning("Ignoring note %d: P0 supports tap notes only." % index)
			continue

		var lane := int(raw_note.get("lane", -1))
		var note_time := float(raw_note.get("time", -1.0))
		if lane < 0 or lane >= GameConfig.LANE_COUNT or note_time < 0.0:
			push_warning("Ignoring note %d: invalid time or lane." % index)
			continue

		clean_notes.append({
			"type": "tap",
			"time": note_time,
			"lane": lane,
			"judged": false,
			"result": ""
		})

	clean_notes.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a["time"] < b["time"])
	if clean_notes.is_empty():
		push_error("Chart contains no playable tap notes.")
		return {}

	var last_note_time := float(clean_notes[-1]["time"])
	return {
		"audio": str(raw.get("audio", "res://audio/prototype.ogg")),
		"offset_sec": float(raw.get("offset_sec", 0.0)),
		"duration_sec": maxf(float(raw.get("duration_sec", last_note_time + 2.0)), last_note_time + GameConfig.GOOD_WINDOW_SEC),
		"notes": clean_notes
	}
