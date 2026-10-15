class_name GameConfig
extends RefCounted

const LANE_COUNT := 4
const LANE_LABELS := ["D", "F", "J", "K"]

# All timing values are seconds. These are prototype values and intentionally
# live in one place so later play testing can tune them without touching logic.
const PERFECT_WINDOW_SEC := 0.055
const GOOD_WINDOW_SEC := 0.120
const NOTE_TRAVEL_TIME_SEC := 1.0
const START_LEAD_IN_SEC := 1.25
const FEEDBACK_VISIBLE_SEC := 0.55

const CHART_PATH := "res://charts/test_chart.json"
