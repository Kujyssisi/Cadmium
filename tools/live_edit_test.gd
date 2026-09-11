extends SceneTree
## Does an edit made while the transport is running take effect at the playhead,
## or only when the playhead next comes round? Run with
##   godot-beta --headless --path ~/Cadmium --script res://tools/live_edit_test.gd

var eng
var fails := 0


func _initialize() -> void:
	eng = ClassDB.instantiate("CdEngine")
	get_root().add_child(eng)

	eng.set_bpm(120.0)
	eng.set_mixer_count(4)
	var ch: int = eng.add_channel("Lead")
	var h: int = eng.create_plugin("cd.pulse")
	eng.set_channel_instrument(ch, h)
	eng.set_channel(ch, 1.0, 0.0, false, false, 1, 0)

	# One long note, so the playhead is inside it wherever we stop.
	var notes := PackedFloat32Array([0.0, 0.0, 8.0, 60.0, 1.0, 0.0, 0.0])
	eng.set_pattern(0, notes, 16.0)

	_song_clip_added_under_playhead()
	_notes_drawn_under_playhead()
	_pattern_switched_while_playing()
	_instrument_added_while_playing()
	_mode_switched_while_playing()

	print("\n%s" % ("FAILED %d check(s)" % fails if fails > 0 else "all checks passed"))
	quit(1 if fails > 0 else 0)


func _check(what: String, ok: bool) -> void:
	if not ok:
		fails += 1
	print("  %s %s" % ["PASS" if ok else "FAIL", what])


func _sounding(channel: int) -> int:
	return (eng.active_notes(channel) as PackedInt32Array).size()


func _reset() -> void:
	eng.stop()
	eng.set_playlist(PackedFloat32Array())
	eng.set_mode(1)
	eng.set_current_pattern(0)
	eng.set_loop(0.0, 16.0, true)


func _clip(type: int, index: int, track: int, start: float, length: float) -> PackedFloat32Array:
	return PackedFloat32Array([float(type), float(index), float(track), start, length,
			0.0, 1.0, 0.0, 0.0])


func _song_clip_added_under_playhead() -> void:
	print("a pattern clip dropped over the playhead, song mode")
	_reset()
	eng.play(true)
	eng.set_position(2.0)
	_check("silent before the clip exists", _sounding(0) == 0)
	eng.set_playlist(_clip(0, 0, 0, 0.0, 16.0))
	_check("playing as soon as the clip is there", _sounding(0) > 0)


func _notes_drawn_under_playhead() -> void:
	print("notes drawn into the pattern that is playing, pattern mode")
	_reset()
	eng.set_mode(0)
	eng.clear_pattern(1)
	eng.set_current_pattern(1)
	eng.play(true)
	eng.set_position(2.0)
	_check("silent while the pattern is empty", _sounding(0) == 0)
	eng.set_pattern(1, PackedFloat32Array([0.0, 0.0, 8.0, 62.0, 1.0, 0.0, 0.0]), 16.0)
	_check("playing as soon as the note is drawn", _sounding(0) > 0)
	# And the same note pushed again must not double up.
	var before := _sounding(0)
	eng.set_pattern(1, PackedFloat32Array([0.0, 0.0, 8.0, 62.0, 1.0, 0.0, 0.0]), 16.0)
	_check("pushing the same pattern again does not double it", _sounding(0) == before)


func _pattern_switched_while_playing() -> void:
	print("switching pattern while playing, pattern mode")
	_reset()
	eng.set_mode(0)
	eng.clear_pattern(2)
	eng.set_current_pattern(2)
	eng.play(true)
	eng.set_position(2.0)
	_check("the empty pattern is silent", _sounding(0) == 0)
	eng.set_current_pattern(0)
	_check("the pattern switched to is heard now", _sounding(0) > 0)


func _instrument_added_while_playing() -> void:
	print("an instrument put on a channel mid-note")
	_reset()
	eng.set_mode(0)
	eng.set_current_pattern(0)
	eng.set_channel_instrument(0, -1)
	eng.play(true)
	eng.set_position(2.0)
	# Swapping the instrument drops what the old one was holding, keys and all,
	# so anything showing afterwards was started by the swap.
	eng.set_channel_instrument(0, eng.create_plugin("cd.pulse"))
	_check("sounds as soon as the instrument is there", _sounding(0) > 0)


func _mode_switched_while_playing() -> void:
	print("switching from pattern to song while playing")
	_reset()
	eng.set_mode(0)
	eng.clear_pattern(3)
	eng.set_current_pattern(3)
	eng.set_playlist(_clip(0, 0, 0, 0.0, 16.0))
	eng.play(true)
	eng.set_position(2.0)
	_check("the empty pattern is silent", _sounding(0) == 0)
	eng.set_mode(1)
	_check("the arrangement is heard on the switch", _sounding(0) > 0)
