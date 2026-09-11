## Standard MIDI File reading and writing.
##
## The reader hands back *parts* and touches nothing, so the same code serves the
## piano roll -- notes into the pattern you are looking at -- and the File menu,
## which builds a whole project out of one. What counts as a part is the thing
## that used to be wrong: a Type 1 file usually gives each instrument a track of
## its own and leaves every one of them on MIDI channel 1, so splitting by
## channel alone collapsed a sixteen-instrument arrangement into a single pile of
## notes. Parts are split by track *and* channel.
class_name CdMidi
extends RefCounted

## The resolution a file is written at when the project does not name one, and
## the one assumed for a file that arrives without a sensible division.
const PPQ := 480

## Shorter than this is not a note. Plenty of files put a note-off on the same
## tick as its note-on to mean "as short as you can", and a zero-length note is
## one that never sounds.
const MIN_LEN := 0.03125

## MIDI's drum channel, counted from zero.
const DRUM_CHANNEL := 9


# ---------------------------------------------------------------------------
# Read
# ---------------------------------------------------------------------------
## Everything in a MIDI file, as data. Returns {} for anything that is not one.
##
##   ppq, bpm, sig_num, sig_den, format, tracks, length, notes
##   parts: [{name, channel, drums, notes: [{beat, len, key, vel, pan, fine}]}]
static func read(data: PackedByteArray) -> Dictionary:
	if data.size() < 14 or data.slice(0, 4).get_string_from_ascii() != "MThd":
		return {}
	var head_len := _u32(data, 4)
	var format := _u16(data, 8)
	var ntrks := _u16(data, 10)
	var division := _u16(data, 12)
	var pos := 8 + maxi(6, head_len)

	var ticks := float(division if division > 0 else PPQ)
	if division & 0x8000:
		# SMPTE division: frames a second times ticks a frame.
		var fps := float(256 - ((division >> 8) & 0xFF))
		ticks = maxf(1.0, fps * float(division & 0xFF))

	# The *first* tempo and signature in the file, not the last one. A file that
	# changes tempo part way through is still a file whose tempo is the one it
	# starts at, and reading the whole track before keeping one meant a project
	# that opened at whatever the piece happened to end on.
	var tempo_us := 0.0
	var sig_num := 0
	var sig_den := 0

	var parts := []
	var tracks := 0
	var length := 0.0
	var total := 0

	for t in ntrks:
		if pos + 8 > data.size():
			break
		if data.slice(pos, pos + 4).get_string_from_ascii() != "MTrk":
			break
		var body_len := _u32(data, pos + 4)
		var end: int = mini(data.size(), pos + 8 + body_len)
		var p := pos + 8
		var tick := 0
		var running := 0
		var name := ""
		# channel -> key -> [{beat, vel}], a stack so that the same key struck
		# again before the first one is released does not lose the first.
		var open := {}
		var by_channel := {}

		while p < end:
			var dt := _varlen(data, p, end)
			p = dt.pos
			tick += dt.value
			if p >= end:
				break
			var status: int = data[p]
			if status < 0x80:
				status = running          # running status: the byte is data
			else:
				p += 1
			if status < 0x80:
				break                     # data with nothing to run from
			if status < 0xF0:
				running = status
			var kind := status & 0xF0
			var chan := status & 0x0F

			match kind:
				0x90, 0x80:
					if p + 1 >= end:
						p = end
						break
					var key: int = data[p]
					var vel: int = data[p + 1]
					p += 2
					var beat := float(tick) / ticks
					if kind == 0x90 and vel > 0:
						_hold(open, chan, key, beat, float(vel) / 127.0)
					else:
						var note := _release(open, chan, key, beat)
						if not note.is_empty():
							if not by_channel.has(chan):
								by_channel[chan] = []
							by_channel[chan].append(note)
							length = maxf(length, float(note.beat) + float(note.len))
							total += 1
				0xA0, 0xB0, 0xE0:
					p += 2
				0xC0, 0xD0:
					p += 1
				0xF0:
					if status == 0xFF:
						if p >= end:
							break
						var meta: int = data[p]
						p += 1
						var ml := _varlen(data, p, end)
						p = ml.pos
						var stop: int = mini(end, p + ml.value)
						if meta == 0x51 and ml.value >= 3 and tempo_us <= 0.0 and p + 2 < end:
							tempo_us = float((data[p] << 16) | (data[p + 1] << 8) | data[p + 2])
						elif meta == 0x58 and ml.value >= 2 and sig_num <= 0 and p + 1 < end:
							sig_num = maxi(1, data[p])
							sig_den = 1 << clampi(data[p + 1], 0, 7)
						elif meta == 0x03 and name.is_empty():
							name = data.slice(p, stop).get_string_from_utf8().strip_edges()
						p = stop
					else:
						# SysEx, and anything else with a length in front of it.
						var sl := _varlen(data, p, end)
						p = mini(end, sl.pos + sl.value)
				_:
					p += 1

		# Anything still held when the track runs out ends where the track does.
		var tail := float(tick) / ticks
		for c in open.keys():
			for key in (open[c] as Dictionary).keys():
				while true:
					var note := _release(open, c, key, tail)
					if note.is_empty():
						break
					if not by_channel.has(c):
						by_channel[c] = []
					by_channel[c].append(note)
					length = maxf(length, float(note.beat) + float(note.len))
					total += 1

		var channels: Array = by_channel.keys()
		channels.sort()
		for c in channels:
			var notes: Array = by_channel[c]
			if notes.is_empty():
				continue
			notes.sort_custom(func(a, b): return float(a.beat) < float(b.beat))
			parts.append({
				"name": _part_name(name, t, int(c), channels.size() > 1),
				"channel": int(c),
				"drums": int(c) == DRUM_CHANNEL,
				"notes": notes,
			})
		pos = pos + 8 + body_len
		tracks += 1

	if parts.is_empty():
		return {}
	return {
		"format": format,
		"ppq": int(round(ticks)),
		"tracks": tracks,
		"bpm": clampf(60000000.0 / maxf(1.0, tempo_us if tempo_us > 0.0 else 500000.0), 10.0, 999.0),
		"has_tempo": tempo_us > 0.0,
		"sig_num": sig_num if sig_num > 0 else 4,
		"sig_den": sig_den if sig_den > 0 else 4,
		"parts": parts,
		"length": length,
		"notes": total,
	}


## The same, from a file.
static func read_file(path: String) -> Dictionary:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var data := f.get_buffer(f.get_length())
	f.close()
	return read(data)


## What to call a part. The track's own name if it has one -- and the channel
## with it when one track carries several, because "Piano" twice over tells you
## nothing about which is which.
static func _part_name(track_name: String, track: int, channel: int, split: bool) -> String:
	var base := track_name
	if base.is_empty():
		base = "Drums" if channel == DRUM_CHANNEL else "Track %d" % (track + 1)
	if split:
		return "%s (ch %d)" % [base, channel + 1]
	return base


static func _hold(open: Dictionary, chan: int, key: int, beat: float, vel: float) -> void:
	if not open.has(chan):
		open[chan] = {}
	if not open[chan].has(key):
		open[chan][key] = []
	open[chan][key].append({"beat": beat, "vel": vel})


## The oldest sounding copy of this key, finished at `beat`. Oldest rather than
## newest so that two overlapping notes come out as the two notes that were
## played rather than as one long one and one stub.
static func _release(open: Dictionary, chan: int, key: int, beat: float) -> Dictionary:
	if not open.has(chan) or not open[chan].has(key):
		return {}
	var stack: Array = open[chan][key]
	if stack.is_empty():
		return {}
	var start: Dictionary = stack.pop_front()
	if stack.is_empty():
		(open[chan] as Dictionary).erase(key)
	return {
		"beat": float(start.beat),
		"len": maxf(MIN_LEN, beat - float(start.beat)),
		"key": clampi(key, 0, 127),
		"vel": clampf(float(start.vel), 0.0, 1.0),
		"pan": 0.0,
		"fine": 0.0,
	}


static func _u16(d: PackedByteArray, p: int) -> int:
	if p + 1 >= d.size():
		return 0
	return (d[p] << 8) | d[p + 1]


static func _u32(d: PackedByteArray, p: int) -> int:
	if p + 3 >= d.size():
		return 0
	return (d[p] << 24) | (d[p + 1] << 16) | (d[p + 2] << 8) | d[p + 3]


static func _varlen(d: PackedByteArray, p: int, end: int = -1) -> Dictionary:
	var stop: int = d.size() if end < 0 else mini(end, d.size())
	var v := 0
	var read_bytes := 0
	while p < stop and read_bytes < 4:
		var b := d[p]
		p += 1
		read_bytes += 1
		v = (v << 7) | (b & 0x7F)
		if b < 0x80:
			break
	return {"value": v, "pos": p}


# ---------------------------------------------------------------------------
# Write
# ---------------------------------------------------------------------------
## A Type 1 file: a tempo track, then one track per part. `parts` is
## [{name, notes: [{beat, len, key, vel}], channel (optional)}].
static func write(parts: Array, bpm: float, sig_num: int, sig_den: int, ppq: int,
		title: String) -> PackedByteArray:
	var res := clampi(ppq, 24, 960)
	var out := PackedByteArray()
	out.append_array("MThd".to_ascii_buffer())
	_be32_into(out, 6)
	_be16_into(out, 1)
	_be16_into(out, parts.size() + 1)
	_be16_into(out, res)

	# Track 0 carries the name, the tempo and the signature, as convention
	# expects. A file without a signature is read as 4/4, which puts the bar
	# lines somewhere else in whatever opens it next.
	var head := PackedByteArray()
	_varint(head, 0)
	head.append_array([0xFF, 0x03])
	var nm := title.to_utf8_buffer()
	_varint(head, nm.size())
	head.append_array(nm)
	_varint(head, 0)
	var us := int(60000000.0 / maxf(1.0, bpm))
	head.append_array([0xFF, 0x51, 0x03, (us >> 16) & 0xFF, (us >> 8) & 0xFF, us & 0xFF])
	_varint(head, 0)
	head.append_array([0xFF, 0x58, 0x04, clampi(sig_num, 1, 255), _log2_den(sig_den), 24, 8])
	_varint(head, 0)
	head.append_array([0xFF, 0x2F, 0x00])
	_track_into(out, head)

	for i in parts.size():
		var part: Dictionary = parts[i]
		var midi_ch := int(part.get("channel", -1))
		if midi_ch < 0 or midi_ch > 15:
			midi_ch = mini(15, i)
		var body := PackedByteArray()
		_varint(body, 0)
		body.append_array([0xFF, 0x03])
		var nb := String(part.get("name", "Part %d" % (i + 1))).to_utf8_buffer()
		_varint(body, nb.size())
		body.append_array(nb)

		var timeline := []
		for n in part.get("notes", []):
			var at := int(round(float(n.beat) * res))
			var off := maxi(at + 1, int(round((float(n.beat) + float(n.len)) * res)))
			timeline.append({"tick": at, "on": true, "key": int(n.key), "vel": float(n.vel)})
			timeline.append({"tick": off, "on": false, "key": int(n.key), "vel": 0.0})
		# Ends before beginnings on the same tick, so two notes that touch do
		# not stop each other in whatever reads the file next.
		timeline.sort_custom(func(a, b):
			if int(a.tick) == int(b.tick):
				return not bool(a.on) and bool(b.on)
			return int(a.tick) < int(b.tick))
		var last := 0
		for e in timeline:
			_varint(body, maxi(0, int(e.tick) - last))
			last = int(e.tick)
			body.append((0x90 if bool(e.on) else 0x80) | midi_ch)
			body.append(clampi(int(e.key), 0, 127))
			body.append(clampi(int(round(float(e.vel) * 127.0)), 0, 127))
		_varint(body, 0)
		body.append_array([0xFF, 0x2F, 0x00])
		_track_into(out, body)
	return out


## A MIDI signature says its denominator as a power of two: 4/4 writes a 2, 6/8
## writes a 3. Anything that is not a power of two is rounded down to one.
static func _log2_den(den: int) -> int:
	return clampi(int(floor(log(maxf(1.0, float(den))) / log(2.0))), 0, 7)


static func _track_into(out: PackedByteArray, body: PackedByteArray) -> void:
	out.append_array("MTrk".to_ascii_buffer())
	_be32_into(out, body.size())
	out.append_array(body)


static func _be16_into(out: PackedByteArray, v: int) -> void:
	out.append((v >> 8) & 0xFF)
	out.append(v & 0xFF)


static func _be32_into(out: PackedByteArray, v: int) -> void:
	out.append((v >> 24) & 0xFF)
	out.append((v >> 16) & 0xFF)
	out.append((v >> 8) & 0xFF)
	out.append(v & 0xFF)


static func _varint(buf: PackedByteArray, value: int) -> void:
	var v := maxi(0, value)
	var stack := [v & 0x7F]
	v >>= 7
	while v > 0:
		stack.append((v & 0x7F) | 0x80)
		v >>= 7
	stack.reverse()
	for b in stack:
		buf.append(b)


# ---------------------------------------------------------------------------
# Whole projects
# ---------------------------------------------------------------------------
## What the project asks to be written at, kept inside what a MIDI file can say.
static func _ppq_of(project: CdProject) -> int:
	return clampi(project.ppq, 24, 960)


## A file into the project as a new pattern with a channel per part, placed on
## the timeline. For putting one into the pattern you are already editing, see
## CdScore.midi_into_pattern.
static func import_file(path: String, project: CdProject) -> Dictionary:
	var midi := read_file(path)
	if midi.is_empty():
		return {}
	if bool(midi.has_tempo):
		project.bpm = float(midi.bpm)
	project.sig_num = int(midi.sig_num)
	project.sig_den = int(midi.sig_den)

	var pattern := project.new_pattern(path.get_file().get_basename(), project.patterns.size())
	var end_beat := 4.0
	for part in midi.parts:
		var label := String(part.name)
		var plug := CdProject.plugin_dict("stock",
				"cd.pulse" if bool(part.drums) else "cd.ember", "", label)
		var ci := project.add_channel(label, plug)
		for n in part.notes:
			var note: Dictionary = (n as Dictionary).duplicate()
			note["ch"] = ci
			pattern.notes.append(note)
			end_beat = maxf(end_beat, float(note.beat) + float(note.len))
	pattern.length = ceilf(end_beat / 4.0) * 4.0
	project.patterns.append(pattern)
	project.clips.append({
		"type": Cd.ClipType.PATTERN, "index": project.patterns.size() - 1, "track": 0,
		"start": 0.0, "length": pattern.length, "offset": 0.0, "gain": 1.0, "mute": false,
		"pitch": 0.0,
	})
	project.dirty = true
	return {"tracks": int(midi.tracks), "channels": (midi.parts as Array).size(),
			"notes": int(midi.notes), "bpm": float(midi.bpm),
			"pattern": project.patterns.size() - 1}


## The arrangement as a MIDI file: one track per channel, at absolute beats.
static func export_file(path: String, project: CdProject) -> Error:
	var per_channel := {}
	for e in _flatten(project):
		var ch := int(e.ch)
		if not per_channel.has(ch):
			per_channel[ch] = []
		per_channel[ch].append(e)
	var chans: Array = per_channel.keys()
	chans.sort()
	var parts := []
	for i in chans.size():
		var ch: int = chans[i]
		parts.append({
			"name": String(project.channels[ch].name) if ch < project.channels.size() \
					else "Channel %d" % ch,
			"notes": per_channel[ch],
		})
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return FileAccess.get_open_error()
	f.store_buffer(write(parts, project.bpm, project.sig_num, project.sig_den,
			_ppq_of(project), project.name))
	f.close()
	return OK


## Playlist clips expanded to absolute beats; the current pattern alone if the
## playlist is empty, because that is what the user is looking at.
static func _flatten(project: CdProject) -> Array:
	var out := []
	var pattern_clips := []
	for c in project.clips:
		if int(c.type) == Cd.ClipType.PATTERN and not bool(c.get("mute", false)):
			pattern_clips.append(c)
	if pattern_clips.is_empty():
		for p in project.patterns:
			for n in p.notes:
				out.append(n)
			break
		return out
	for c in pattern_clips:
		var pi := int(c.index)
		if pi >= project.patterns.size():
			continue
		var plen: float = maxf(0.25, float(project.patterns[pi].length))
		var reps := int(ceil(float(c.length) / plen))
		for rep in maxi(1, reps):
			for n in project.patterns[pi].notes:
				var beat := float(c.start) + float(rep) * plen + float(n.beat) \
						- float(c.get("offset", 0.0))
				if beat < float(c.start) or beat >= float(c.start) + float(c.length):
					continue
				var copy: Dictionary = n.duplicate()
				copy["beat"] = beat
				out.append(copy)
	return out
