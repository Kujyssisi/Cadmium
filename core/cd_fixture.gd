## A scene for the test hooks to photograph and measure: four channels, three
## patterns, an arrangement and a mixer with real effects on it, built from
## nothing so that a check has the same thing in front of it every time.
##
## This is scaffolding, not a feature. Cadmium used to offer it as Help > Load
## Demo Song and that is exactly what it should not be -- a new project is an
## empty one, and somebody else's idea of a tune is not a starting point. Only
## the --cd-* hooks reach it; nothing in the interface does.
class_name CdFixture
extends RefCounted


static func build(app) -> void:
	var p: CdProject = app.project
	app.new_project()
	p = app.project
	p.channels.clear()
	p.patterns.clear()
	p.clips.clear()
	p.bpm = 128.0

	var kick := _channel(p, "Kick", "cd.pulse", 1, {"mode": 0.0, "tune": 33.0, "body_dec": 0.42, "click": 0.3})
	var snare := _channel(p, "Snare", "cd.pulse", 2, {"mode": 1.0, "tune": 52.0, "noise_level": 0.85,
			"noise_dec": 0.18, "body_dec": 0.16})
	var hat := _channel(p, "Hat", "cd.pulse", 3, {"mode": 3.0, "tune": 74.0, "noise_level": 0.9,
			"noise_dec": 0.05, "body_dec": 0.04, "noise_tone": 9000.0})
	var bass := _channel(p, "Bass", "cd.ember", 4, {"o1_shape": 2.0, "o2_level": 0.0, "sub_level": 0.6,
			"flt_cut": 700.0, "flt_env": 26.0, "mod_d": 0.22, "amp_d": 0.5, "amp_s": 0.3,
			"voices": 1.0, "mono": 1.0, "glide": 0.02})
	var lead := _channel(p, "Keys", "cd.vector", 5, {"a_bank": 2.0, "a_unison": 3.0, "b_level": 0.5,
			"flt_cut": 3800.0, "amp_a": 0.02, "amp_r": 0.7})

	# --- patterns
	var beat := p.new_pattern("Beat", 0)
	beat.length = 16.0
	for bar in 4:
		var b := float(bar) * 4.0
		for step in [0.0, 1.0, 2.0, 2.75, 3.5]:
			beat.notes.append(_note(kick, b + step, 0.25, 60, 0.95 if step == 0.0 else 0.8))
		beat.notes.append(_note(snare, b + 1.0, 0.25, 60, 0.9))
		beat.notes.append(_note(snare, b + 3.0, 0.25, 60, 0.9))
		for i in 8:
			beat.notes.append(_note(hat, b + float(i) * 0.5, 0.2, 60, 0.55 if i % 2 else 0.8))
	p.patterns.append(beat)

	var bassline := p.new_pattern("Bass", 1)
	bassline.length = 16.0
	var seq := [36, 36, 43, 36, 41, 41, 48, 39]
	for bar in 4:
		for i in 8:
			var k: int = seq[i] + (0 if bar < 2 else (0 if bar == 2 else 3))
			bassline.notes.append(_note(bass, float(bar) * 4.0 + float(i) * 0.5, 0.42, k, 0.85))
	p.patterns.append(bassline)

	var chords := p.new_pattern("Chords", 2)
	chords.length = 16.0
	var voicings := [[60, 63, 67, 70], [58, 62, 65, 70], [63, 67, 70, 75], [56, 60, 63, 67]]
	for bar in 4:
		for k in voicings[bar]:
			chords.notes.append(_note(lead, float(bar) * 4.0, 3.6, int(k), 0.62))
	p.patterns.append(chords)

	# --- arrangement
	p.clips.append(_clip(Cd.ClipType.PATTERN, 0, 0, 0.0, 32.0))
	p.clips.append(_clip(Cd.ClipType.PATTERN, 1, 1, 8.0, 24.0))
	p.clips.append(_clip(Cd.ClipType.PATTERN, 2, 2, 16.0, 16.0))
	p.clips.append(_clip(Cd.ClipType.PATTERN, 0, 0, 32.0, 32.0))
	p.clips.append(_clip(Cd.ClipType.PATTERN, 1, 1, 32.0, 32.0))
	p.clips.append(_clip(Cd.ClipType.PATTERN, 2, 2, 32.0, 32.0))

	# --- mixer: a reverb bus, sidechained master compression, a master limiter
	p.mixer[8].name = "Reverb Bus"
	p.mixer[8].inserts[0] = _fx("cd.reverb", {"mix": 0.55, "size": 1.35, "decay": 0.5})
	p.mixer[5].sends[0] = {"dest": 8, "amount": 0.3, "pre": false, "sidechain": false}
	p.mixer[4].inserts[0] = _fx("cd.sat", {"drive": 8.0, "mode": 5.0})
	p.mixer[3].inserts[0] = _fx("cd.eq8", {})
	p.mixer[0].inserts[0] = _fx("cd.comp", {"thresh": -14.0, "ratio": 3.0, "attack": 6.0,
			"release": 90.0, "sc_ext": 1.0})
	p.mixer[0].inserts[1] = _fx("cd.limiter", {"ceiling": -0.5})
	p.mixer[1].sends[0] = {"dest": 0, "amount": 1.0, "pre": true, "sidechain": true}

	p.tracks[0].name = "Drums"
	p.tracks[1].name = "Bass"
	p.tracks[2].name = "Keys"
	p.name = "Cadmium Demo"
	p.dirty = true

	app.sync_all()
	app.select_pattern(0)
	app.set_mode(Cd.Mode.SONG)
	app.project_loaded.emit()
	app.channels_changed.emit()
	app.patterns_changed.emit()
	app.playlist_changed.emit()
	app.mixer_changed.emit()


static func _channel(p: CdProject, name: String, id: String, mixer: int, params: Dictionary) -> int:
	var plug := CdProject.plugin_dict("stock", id, "", name)
	plug["pending_named"] = params
	return p.add_channel(name, plug, mixer)


static func _fx(id: String, params: Dictionary) -> Dictionary:
	var plug := CdProject.plugin_dict("stock", id, "", id.substr(3).capitalize())
	plug["pending_named"] = params
	return plug


static func _note(ch: int, beat: float, length: float, key: int, vel: float) -> Dictionary:
	return {"ch": ch, "beat": beat, "len": length, "key": key, "vel": vel, "pan": 0.0}


static func _clip(type: int, index: int, track: int, start: float, length: float) -> Dictionary:
	return {"type": type, "index": index, "track": track, "start": start, "length": length,
			"offset": 0.0, "gain": 1.0, "mute": false, "pitch": 0.0}
