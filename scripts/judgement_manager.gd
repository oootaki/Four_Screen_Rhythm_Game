class_name JudgementManager
extends RefCounted

var notes: Array[Dictionary] = []
var combo := 0
var max_combo := 0
var perfect_count := 0
var good_count := 0
var miss_count := 0

func configure(source_notes: Array) -> void:
	notes.clear()
	for source_note in source_notes:
		var note: Dictionary = source_note.duplicate(true)
		note["judged"] = false
		note["result"] = ""
		notes.append(note)
	combo = 0
	max_combo = 0
	perfect_count = 0
	good_count = 0
	miss_count = 0

func judge_press(lane: int, song_time: float) -> Dictionary:
	var best_index := -1
	var best_delta := INF

	for index in notes.size():
		var note := notes[index]
		if note["judged"] or int(note["lane"]) != lane:
			continue
		var delta := absf(song_time - float(note["time"]))
		if delta <= GameConfig.GOOD_WINDOW_SEC and delta < best_delta:
			best_index = index
			best_delta = delta

	if best_index < 0:
		return {}

	var result := "PERFECT" if best_delta <= GameConfig.PERFECT_WINDOW_SEC else "GOOD"
	_mark_note(best_index, result)
	combo += 1
	max_combo = maxi(max_combo, combo)
	if result == "PERFECT":
		perfect_count += 1
	else:
		good_count += 1

	return {
		"result": result,
		"lane": lane,
		"delta_sec": song_time - float(notes[best_index]["time"])
	}

func collect_misses(song_time: float) -> Array[Dictionary]:
	var misses: Array[Dictionary] = []
	for index in notes.size():
		var note := notes[index]
		if note["judged"]:
			continue
		if song_time > float(note["time"]) + GameConfig.GOOD_WINDOW_SEC:
			_mark_note(index, "MISS")
			combo = 0
			miss_count += 1
			misses.append({"result": "MISS", "lane": int(note["lane"]), "delta_sec": 0.0})
		else:
			# Notes are time-sorted, so later notes cannot be misses yet.
			break
	return misses

func all_notes_judged() -> bool:
	for note in notes:
		if not note["judged"]:
			return false
	return true

func _mark_note(index: int, result: String) -> void:
	var note := notes[index]
	note["judged"] = true
	note["result"] = result
	notes[index] = note
