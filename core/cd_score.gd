## A score: everything in one pattern, as the piano roll is editing it.
##
## The piano roll works on a pattern, and a pattern is the thing worth keeping on
## its own -- a riff, a drum part, a chord progression -- separately from the
## song it was written for. This is that file. It is Cadmium's own format rather
## than MIDI because MIDI cannot carry what the piano roll actually edits: a
## note's pan and its fine pitch, which channel of the rack it belongs to, and
## what instrument that channel was, so that a score opened into an empty project
## still plays.
##
## MIDI is the other half of the same job and lives beside it here: reading one
## *into the pattern being edited* rather than into a project of its own, which
## is what the File menu's import does and what makes dropping a riff into a
## song useful instead of destructive.
class_name CdScore
extends RefCounted

const EXT := "cdscore"
const FILTER := "*.cdscore ; Cadmium score"
const FORMAT := 1


# ---------------------------------------------------------------------------
# The pattern as a score
# ---------------------------------------------------------------------------
## `only_channel` >= 0 keeps just that channel's notes; `indices` limits it to a
## selection within the pattern. Both off means the whole pattern.
static func from_pattern(project: CdProject, pattern: int, only_channel: int = -1,
		indices: Array = []) -> Dictionary:
	if pattern < 0 or pattern >= project.patterns.size():
		return {}
	var p: Dictionary = project.patterns[pattern]
	var wanted := {}
	for i in indices:
		wanted[int(i)] = true
	var parts := {}
	var order := []
	var notes: Array = p.notes
	for i in notes.size():
		if not wanted.is_empty() and not wanted.has(i):
			continue
		var n: Dictionary = notes[i]
		var ch := int(n.ch)
		if only_channel >= 0 and ch != only_channel:
			continue
		if not parts.has(ch):
			parts[ch] = []
			order.append(ch)
		var copy := {"beat": float(n.beat), "len": float(n.len), "key": int(n.key),
				"vel": float(n.vel), "pan": float(n.get("pan", 0.0)),
				"fine": float(n.get("fine", 0.0))}
		if bool(n.get("mute", false)):
			copy["mute"] = true
		parts[ch].append(copy)
	order.sort()

	var out_parts := []
	for ch in order:
		var entry := {"channel": String(project.channels[ch].name) if ch < project.channels.size() \
				else "Channel %d" % (ch + 1), "notes": parts[ch]}
		# The instrument goes with it, so a score opened into an empty project
		# makes a sound instead of landing on nothing.
		if ch < project.channels.size():
			var plug = project.channels[ch].get("plugin", null)
			if plug != null:
				entry["plugin"] = {"kind": String(plug.get("kind", "stock")),
						"id": String(plug.get("id", "")), "path": String(plug.get("path", "")),
						"name": String(plug.get("name", ""))}
		out_parts.append(entry)

	return {
		"format": FORMAT,
		"app": "Cadmium",
		"kind": "score",
		"name": String(p.get("name", "Score")),
		"bpm": float(project.bpm),
		"sig_num": int(project.sig_num),
		"sig_den": int(project.sig_den),
		"ppq": int(project.ppq),
		"length": float(p.length),
		"parts": out_parts,
	}


static func save(path: String, project: CdProject, pattern: int, only_channel: int = -1,
		indices: Array = []) -> Error:
	var score := from_pattern(project, pattern, only_channel, indices)
	if score.is_empty():
		return ERR_INVALID_DATA
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return FileAccess.get_open_error()
	f.store_string(JSON.stringify(score, "\t"))
	f.close()
	return OK


## Reads one back. {} for anything that is not a Cadmium score.
static func load_file(path: String) -> Dictionary:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var text := f.get_as_text()
	f.close()
	var parsed = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		return {}
	var d: Dictionary = parsed
	if String(d.get("kind", "")) != "score" or not d.has("parts"):
		return {}
	return d


## A score into a pattern. Channels are matched by name and made when they are
## missing, so a score written in one project opens in another and lands on the
## instruments it was written for rather than on whatever happens to be first.
##
## `replace` empties the pattern first; without it the score is laid on top of
## what is already there, which is how a part gets built out of several.
static func apply(project: CdProject, pattern: int, score: Dictionary, replace: bool,
		at_beat: float = 0.0) -> Dictionary:
	if pattern < 0 or pattern >= project.patterns.size() or not score.has("parts"):
		return {}
	var p: Dictionary = project.patterns[pattern]
	if replace:
		(p.notes as Array).clear()
	var added := 0
	var made := 0
	var end_beat := 0.0
	for part in score.parts:
		var name := String((part as Dictionary).get("channel", "Channel"))
		var before := project.channels.size()
		var ch := channel_named(project, name, (part as Dictionary).get("plugin", null))
		if project.channels.size() > before:
			made += 1
		for n in (part as Dictionary).get("notes", []):
			var note := {
				"ch": ch,
				"beat": maxf(0.0, at_beat + float(n.get("beat", 0.0))),
				"len": maxf(0.03125, float(n.get("len", 0.25))),
				"key": clampi(int(n.get("key", 60)), 0, 127),
				"vel": clampf(float(n.get("vel", 0.78)), 0.0, 1.0),
				"pan": clampf(float(n.get("pan", 0.0)), -1.0, 1.0),
				"fine": clampf(float(n.get("fine", 0.0)), -2.0, 2.0),
			}
			if bool(n.get("mute", false)):
				note["mute"] = true
			(p.notes as Array).append(note)
			end_beat = maxf(end_beat, float(note.beat) + float(note.len))
			added += 1
	# The pattern grows to hold what arrived, and a replaced one takes the
	# score's own length so the loop is the loop the score was written with.
	if replace and float(score.get("length", 0.0)) > 0.25:
		p.length = maxf(float(score.length), _bar_ceil(end_beat, project.sig_num))
	else:
		p.length = maxf(float(p.length), _bar_ceil(end_beat, project.sig_num))
	project.dirty = true
	return {"notes": added, "parts": (score.parts as Array).size(), "channels_made": made,
			"length": float(p.length)}


## The channel called this, or a new one carrying the instrument the score asked
## for. Matched without regard to case or surrounding space, because a name that
## has been through a file and back is still the same name.
static func channel_named(project: CdProject, name: String, plugin = null) -> int:
	var want := name.strip_edges().to_lower()
	for i in project.channels.size():
		if String(project.channels[i].name).strip_edges().to_lower() == want:
			return i
	var plug: Dictionary
	if typeof(plugin) == TYPE_DICTIONARY and not String((plugin as Dictionary).get("id", "")).is_empty():
		plug = CdProject.plugin_dict(String(plugin.get("kind", "stock")), String(plugin.get("id", "")),
				String(plugin.get("path", "")), String(plugin.get("name", name)))
	else:
		plug = CdProject.plugin_dict("stock", "cd.ember", "", name)
	return project.add_channel(name, plug)


static func _bar_ceil(beats: float, sig_num: int) -> float:
	var bar := maxf(1.0, float(sig_num))
	return maxf(bar, ceilf(maxf(0.0, beats) / bar) * bar)


# ---------------------------------------------------------------------------
# MIDI, at the piano roll's level
# ---------------------------------------------------------------------------
## A MIDI file into the pattern being edited.
##
## One part in the file goes onto the channel you are pointing at, which is what
## dropping a riff onto an instrument should do. Several parts get a channel
## each, matched by name to what the project already has. Either way the project
## is not rebuilt, its tempo is not changed behind your back, and nothing lands
## on the playlist: this is the piano roll's import, not the File menu's.
static func midi_into_pattern(midi: Dictionary, project: CdProject, pattern: int,
		target_channel: int, replace: bool, at_beat: float = 0.0) -> Dictionary:
	if midi.is_empty() or pattern < 0 or pattern >= project.patterns.size():
		return {}
	var parts: Array = midi.parts
	var score_parts := []
	if parts.size() == 1 and target_channel >= 0 and target_channel < project.channels.size():
		score_parts.append({"channel": String(project.channels[target_channel].name),
				"notes": (parts[0] as Dictionary).notes})
	else:
		for part in parts:
			score_parts.append({
				"channel": String((part as Dictionary).name),
				"plugin": {"kind": "stock",
						"id": "cd.pulse" if bool((part as Dictionary).drums) else "cd.ember",
						"path": "", "name": String((part as Dictionary).name)},
				"notes": (part as Dictionary).notes,
			})
	var score := {
		"kind": "score", "parts": score_parts,
		"length": _bar_ceil(float(midi.get("length", 4.0)), project.sig_num),
	}
	var res := apply(project, pattern, score, replace, at_beat)
	res["bpm"] = float(midi.get("bpm", project.bpm))
	res["has_tempo"] = bool(midi.get("has_tempo", false))
	res["tracks"] = int(midi.get("tracks", 0))
	return res


## One pattern as a MIDI file: a track per channel that has anything in it.
static func export_midi(path: String, project: CdProject, pattern: int,
		only_channel: int = -1, indices: Array = []) -> Error:
	var score := from_pattern(project, pattern, only_channel, indices)
	if score.is_empty():
		return ERR_INVALID_DATA
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return FileAccess.get_open_error()
	f.store_buffer(midi_bytes(score))
	f.close()
	return OK


## A score as the bytes of a MIDI file, for writing or for the clipboard.
static func midi_bytes(score: Dictionary) -> PackedByteArray:
	var parts := []
	for i in (score.get("parts", []) as Array).size():
		var part: Dictionary = score.parts[i]
		parts.append({"name": String(part.get("channel", "Part")), "notes": part.get("notes", [])})
	return CdMidi.write(parts, float(score.get("bpm", 140.0)), int(score.get("sig_num", 4)),
			int(score.get("sig_den", 4)), int(score.get("ppq", CdMidi.PPQ)),
			String(score.get("name", "Score")))


# ---------------------------------------------------------------------------
# Score sheet
# ---------------------------------------------------------------------------
## The score written out to read, rather than to play: every note by bar, beat
## and name, a part at a time. Not engraved notation -- this is a listing, and
## what it is for is checking a part over and quoting it somewhere that is not a
## sequencer.
static func score_sheet(score: Dictionary) -> String:
	if score.is_empty():
		return ""
	var sig: int = maxi(1, int(score.get("sig_num", 4)))
	var out := "%s\n" % String(score.get("name", "Score"))
	out += "%s\n\n" % "=".repeat(maxi(4, String(score.get("name", "Score")).length()))
	out += "%.2f BPM   %d/%d   %.2f beats\n" % [float(score.get("bpm", 140.0)), sig,
			int(score.get("sig_den", 4)), float(score.get("length", 0.0))]
	for part in score.get("parts", []):
		var notes: Array = (part as Dictionary).get("notes", [])
		out += "\n%s  (%d note%s)\n" % [String((part as Dictionary).get("channel", "Part")),
				notes.size(), "" if notes.size() == 1 else "s"]
		out += "%-12s %-6s %-8s %s\n" % ["position", "note", "length", "velocity"]
		var sorted := notes.duplicate()
		sorted.sort_custom(func(a, b): return float(a.beat) < float(b.beat))
		for n in sorted:
			var beat := float(n.get("beat", 0.0))
			var bar := int(beat / float(sig)) + 1
			var within := beat - float(bar - 1) * float(sig)
			out += "%-12s %-6s %-8s %d%%\n" % [
				"%d:%.3f" % [bar, within + 1.0],
				Cd.note_name(int(n.get("key", 60))),
				"%.3f" % float(n.get("len", 0.25)),
				int(round(clampf(float(n.get("vel", 0.78)), 0.0, 1.0) * 100.0)),
			]
	return out


static func save_sheet(path: String, score: Dictionary) -> Error:
	var text := score_sheet(score)
	if text.is_empty():
		return ERR_INVALID_DATA
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return FileAccess.get_open_error()
	f.store_string(text)
	f.close()
	return OK
