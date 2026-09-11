extends Node
## User settings, kept in user://settings.json. Everything here survives a
## restart; anything about the song lives in the project instead.

const FILE := "user://settings.json"

var data := {
	"accent": "#e0483c",
	"secondary": "#454545",
	"limiter": true,
	"limiter_ceiling": -1.0,
	"scale": 0.0,                 # 0 = follow the desktop
	"max_fps": 120,               # 0 = as fast as the display will take
	"autosave_minutes": 5,        # 0 = off
	"snap": "1/16",
	"metronome": false,
	"recent": [],
	"vst3_dirs": [],
	"sf2_dirs": [],
	"sample_dirs": [],
	"last_dir": "",
	"projects_dir": "",           # empty = Documents/Cadmium
	"last_export_dir": "",
	"follow_playhead": true,
	"piano_roll_scroll": 60,
	"keyboard_octave": 4,
	"midi_input": true,
	"velocity": 0.78,
	"autosave_min": 5,
}

signal changed(key: String)


func _ready() -> void:
	load_settings()


func load_settings() -> void:
	if not FileAccess.file_exists(FILE):
		return
	var f := FileAccess.open(FILE, FileAccess.READ)
	if f == null:
		return
	var parsed = JSON.parse_string(f.get_as_text())
	f.close()
	if typeof(parsed) == TYPE_DICTIONARY:
		for k in parsed.keys():
			if data.has(k):
				data[k] = parsed[k]


func save_settings() -> void:
	var f := FileAccess.open(FILE, FileAccess.WRITE)
	if f == null:
		return
	f.store_string(JSON.stringify(data, "\t"))
	f.close()


func get_value(key: String, fallback = null):
	return data.get(key, fallback)


func set_value(key: String, value) -> void:
	if data.get(key) == value:
		return
	data[key] = value
	save_settings()
	changed.emit(key)


func push_recent(p: String) -> void:
	var r: Array = data.get("recent", [])
	r.erase(p)
	r.insert(0, p)
	while r.size() > 12:
		r.pop_back()
	data["recent"] = r
	save_settings()
	changed.emit("recent")


## The interface follows the desktop's scale, not its DPI -- a 4K screen can
## report 161 dpi at scale 1.0 and scaling off that blows the layout up.
## Where projects live by default: a folder of Cadmium's own under Documents,
## made on first use. Everything that opens a file dialog starts here until you
## have been somewhere else, and exports and autosaves go in beside it.
## Where scores go: the piano roll's own files, beside the projects rather than
## inside any one of them, because the point of a score is that it outlives the
## song it was written for.
func scores_dir() -> String:
	var dir := projects_dir().path_join("Scores")
	DirAccess.make_dir_recursive_absolute(dir)
	return dir


func projects_dir() -> String:
	var custom := String(data.get("projects_dir", ""))
	if not custom.is_empty():
		DirAccess.make_dir_recursive_absolute(custom)
		return custom
	var docs := OS.get_system_dir(OS.SYSTEM_DIR_DOCUMENTS)
	if docs.is_empty():
		docs = Cd.home_dir().path_join("Documents")
	var dir := docs.path_join("Cadmium")
	DirAccess.make_dir_recursive_absolute(dir)
	return dir


func exports_dir() -> String:
	var dir := projects_dir().path_join("Exports")
	DirAccess.make_dir_recursive_absolute(dir)
	return dir


func autosave_dir() -> String:
	var dir := projects_dir().path_join("Autosave")
	DirAccess.make_dir_recursive_absolute(dir)
	return dir


func ui_scale() -> float:
	var s := float(data.get("scale", 0.0))
	if s > 0.05:
		return s
	var screen := DisplayServer.window_get_current_screen()
	return maxf(1.0, DisplayServer.screen_get_scale(screen))
