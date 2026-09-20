## The song: channels, patterns, playlist, mixer, automation.
##
## Plain data on purpose. The engine holds the same information in C++ and is
## the authority while audio runs; this is the authority for editing, undo and
## the file on disk. App keeps the two in step.
class_name CdProject
extends RefCounted

const FORMAT := 1

var name := "Untitled"
var path := ""
var bpm := 140.0
var sig_num := 4
var sig_den := 4
## Ticks per quarter note. Nothing in the editor is measured in ticks -- beats
## are floats here -- but a MIDI file has to be, and this is the resolution it
## is written at.
var ppq := 480
var author := ""

## {name, color, plugin, mixer, vol, pan, mute, solo, transpose, root}
var channels: Array = []
## {name, color, length, notes:[{ch,beat,len,key,vel,pan}]}
var patterns: Array = []
## {type, index, track, start, length, offset, gain, mute, pitch}
var clips: Array = []
## {name, height, mute, color}
var tracks: Array = []
## {name, vol, pan, mute, solo, route, color, sends:[...], inserts:[plugin|null]}
var mixer: Array = []
## {name, target, a, b, plugin_ref, points:[{beat,value,curve}], lo, hi}
var automations: Array = []
## {path, name}
var assets: Array = []

## The marked stretch of the arrangement, in beats: what loops, and what
## "Marked region" exports. Both zero means nothing is marked.
var mark_a := 0.0
var mark_b := 0.0

var dirty := false


static func plugin_dict(kind: String, id: String, pl_path: String = "", pl_name: String = "") -> Dictionary:
	return {
		"kind": kind,          # "stock" | "vst3"
		"id": id,              # stock id, or the VST3 class id
		"path": pl_path,       # VST3 bundle
		"name": pl_name,
		"params": {},          # index -> value
		"strings": {},         # key -> value (sample paths, soundfont, preset)
		"state": "",           # VST3 opaque state, base64
	}


func _init() -> void:
	reset()


func reset() -> void:
	name = "Untitled"
	path = ""
	bpm = 140.0
	sig_num = 4
	sig_den = 4
	ppq = 480
	channels.clear()
	patterns.clear()
	clips.clear()
	tracks.clear()
	mixer.clear()
	automations.clear()
	assets.clear()
	for i in range(17):
		mixer.append(new_mixer_track(i))
	for i in range(12):
		tracks.append({"name": "Track %d" % (i + 1), "height": 46.0, "mute": false, "color": i})
	patterns.append(new_pattern("Pattern 1", 0))
	dirty = false


func new_mixer_track(i: int) -> Dictionary:
	var sends := []
	for s in range(4):
		sends.append({"dest": -1, "amount": 0.0, "pre": false, "sidechain": false})
	return {
		"name": "Master" if i == 0 else "Insert %d" % i,
		"vol": 1.0 if i > 0 else 0.85,
		"pan": 0.0,
		"mute": false,
		"solo": false,
		"route": 0 if i > 0 else -1,
		"color": i,
		"sends": sends,
		"inserts": [null, null, null, null, null, null, null, null],
		# True on the one strip that is listening to the machine's audio input.
		"input": false,
	}


func new_pattern(pname: String, color: int) -> Dictionary:
	return {"name": pname, "color": color, "length": 16.0, "notes": []}


func new_channel(cname: String, plugin: Dictionary, mixer_track: int) -> Dictionary:
	return {
		"name": cname,
		"color": channels.size(),
		"plugin": plugin,
		"mixer": mixer_track,
		"vol": 0.8,
		"pan": 0.0,
		"mute": false,
		"solo": false,
		"transpose": 0,
		"root": 60,
		# Other channels this one also plays: [{channel, transpose, gain}].
		"layers": [],
		# A pure layer channel is silent itself and only drives its layers.
		"layer_only": false,
	}


func add_channel(cname: String, plugin: Dictionary, mixer_track: int = -1) -> int:
	var t := mixer_track
	if t < 0:
		t = _first_free_mixer()
	channels.append(new_channel(cname, plugin, t))
	dirty = true
	return channels.size() - 1


func _first_free_mixer() -> int:
	var used := {}
	for c in channels:
		used[int(c.mixer)] = true
	for i in range(1, mixer.size()):
		if not used.has(i):
			return i
	return 1


func remove_channel(index: int) -> void:
	if index < 0 or index >= channels.size():
		return
	channels.remove_at(index)
	# Layer references are channel indices, so they shift along with the notes.
	for c in channels:
		var layers: Array = c.get("layers", [])
		var kept := []
		for l in layers:
			var target := int(l.get("channel", -1))
			if target == index:
				continue
			if target > index:
				l["channel"] = target - 1
			kept.append(l)
		c["layers"] = kept
	for p in patterns:
		var keep := []
		for n in p.notes:
			if int(n.ch) == index:
				continue
			if int(n.ch) > index:
				n.ch = int(n.ch) - 1
			keep.append(n)
		p.notes = keep
	dirty = true


func add_pattern(pname: String = "") -> int:
	var n := pname
	if n.is_empty():
		n = "Pattern %d" % (patterns.size() + 1)
	patterns.append(new_pattern(n, patterns.size()))
	dirty = true
	return patterns.size() - 1


func pattern_notes(pattern: int, channel: int = -1) -> Array:
	if pattern < 0 or pattern >= patterns.size():
		return []
	if channel < 0:
		return patterns[pattern].notes
	var out := []
	for n in patterns[pattern].notes:
		if int(n.ch) == channel:
			out.append(n)
	return out


## The last beat anything happens on, used to size the playlist and the export.
func length_beats() -> float:
	var end := 0.0
	for c in clips:
		end = maxf(end, float(c.start) + float(c.length))
	return maxf(end, 16.0)


func used_pattern_length(pattern: int) -> float:
	var end := 0.0
	for n in pattern_notes(pattern):
		end = maxf(end, float(n.beat) + float(n.len))
	return end


# ---------------------------------------------------------------------------
# Serialisation
# ---------------------------------------------------------------------------
func to_dict() -> Dictionary:
	return {
		"format": FORMAT,
		"app": "Cadmium",
		"name": name,
		"author": author,
		"bpm": bpm,
		"sig_num": sig_num,
		"sig_den": sig_den,
		"ppq": ppq,
		"channels": channels.duplicate(true),
		"patterns": patterns.duplicate(true),
		"clips": clips.duplicate(true),
		"tracks": tracks.duplicate(true),
		"mixer": mixer.duplicate(true),
		"automations": automations.duplicate(true),
		"assets": assets.duplicate(true),
		"mark": [mark_a, mark_b],
	}


func from_dict(d: Dictionary) -> void:
	name = String(d.get("name", "Untitled"))
	author = String(d.get("author", ""))
	bpm = float(d.get("bpm", 140.0))
	sig_num = int(d.get("sig_num", 4))
	sig_den = int(d.get("sig_den", 4))
	ppq = maxi(1, int(d.get("ppq", 480)))
	channels = (d.get("channels", []) as Array).duplicate(true)
	patterns = (d.get("patterns", []) as Array).duplicate(true)
	clips = (d.get("clips", []) as Array).duplicate(true)
	tracks = (d.get("tracks", []) as Array).duplicate(true)
	mixer = (d.get("mixer", []) as Array).duplicate(true)
	automations = (d.get("automations", []) as Array).duplicate(true)
	assets = (d.get("assets", []) as Array).duplicate(true)
	var m: Array = d.get("mark", [])
	mark_a = float(m[0]) if m.size() > 1 else 0.0
	mark_b = float(m[1]) if m.size() > 1 else 0.0
	if patterns.is_empty():
		patterns.append(new_pattern("Pattern 1", 0))
	if mixer.is_empty():
		for i in range(17):
			mixer.append(new_mixer_track(i))
	if tracks.is_empty():
		for i in range(12):
			tracks.append({"name": "Track %d" % (i + 1), "height": 46.0, "mute": false, "color": i})
	dirty = false


func save(file_path: String) -> Error:
	var f := FileAccess.open(file_path, FileAccess.WRITE)
	if f == null:
		return FileAccess.get_open_error()
	f.store_string(JSON.stringify(to_dict(), "\t"))
	f.close()
	path = file_path
	name = file_path.get_file().get_basename()
	dirty = false
	return OK


func load_from(file_path: String) -> Error:
	var f := FileAccess.open(file_path, FileAccess.READ)
	if f == null:
		return FileAccess.get_open_error()
	var text := f.get_as_text()
	f.close()
	var parsed = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		return ERR_FILE_CORRUPT
	from_dict(parsed)
	path = file_path
	if name.is_empty() or name == "Untitled":
		name = file_path.get_file().get_basename()
	return OK
