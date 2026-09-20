## Drives the editing gestures the way a mouse would, so that "you cannot drag
## a note's length" is a thing a test can catch rather than a thing you have to
## notice. Run with --cd-uitest.
class_name CdUiTest
extends RefCounted

var main
var tree
var pass_count := 0
var fail_count := 0


static func run(m, t) -> int:
	var u := CdUiTest.new()
	u.main = m
	u.tree = t
	return await u._run()


func _check(name: String, ok: bool, detail: String = "") -> void:
	if ok:
		pass_count += 1
		print("  ok    %s%s" % [name, ("  " + detail) if not detail.is_empty() else ""])
	else:
		fail_count += 1
		print("  FAIL  %s%s" % [name, ("  " + detail) if not detail.is_empty() else ""])


func _press(node, at: Vector2, button := MOUSE_BUTTON_LEFT, shift := false) -> void:
	var e := InputEventMouseButton.new()
	e.button_index = button
	e.pressed = true
	e.position = at
	e.shift_pressed = shift
	node._gui_input(e)


func _release(node, at: Vector2, button := MOUSE_BUTTON_LEFT) -> void:
	var e := InputEventMouseButton.new()
	e.button_index = button
	e.pressed = false
	e.position = at
	node._gui_input(e)


func _move(node, from: Vector2, to: Vector2, steps := 6) -> void:
	for i in range(1, steps + 1):
		var e := InputEventMouseMotion.new()
		e.position = from.lerp(to, float(i) / float(steps))
		e.relative = (to - from) / float(steps)
		node._gui_input(e)


func _frames(n: int) -> void:
	for i in n:
		await tree.process_frame


func _run() -> int:
	print("Cadmium interface test")
	await _piano_roll()
	await _playlist()
	await _controls()
	await _keys()
	await _closing()
	await _media()
	await _audio_clips()
	await _ruler()
	await _icons()
	await _panels()
	await _drops()
	await _automation()
	await _tweaked()
	await _windows()
	await _plugin_removal()
	await _mixer_routing()
	await _picker_panel()
	await _tracks()
	await _held_notes()
	await _transport_marker()
	await _layouts()
	await _legato()
	await _key_picking()
	await _sampler()
	await _stuck_keys()
	await _piano_ruler()
	await _piano_menu()
	await _erase_drag()
	await _live_edits()
	_dialogs()
	await _preferences()
	_versions()
	await _update_window()
	await _bad_plugins()
	await _crash_reports()
	await _addons()
	await _theme_colours()
	await _picker()
	await _perf(main)
	print("")
	print("%d passed, %d failed" % [pass_count, fail_count])
	return fail_count


## A key held down while something else takes the keyboard -- a menu opening
## under the pointer, a click into another window -- and then released where
## Cadmium cannot see it. The note has to stop anyway.
func _stuck_keys() -> void:
	print("--- a key released out of sight")
	App.new_project()
	await _frames(2)
	App.add_stock_channel("cd.ember")
	await _frames(3)
	Shortcuts.release_all()
	App.live_all_off()

	var down := InputEventKey.new()
	down.keycode = KEY_Z
	down.physical_keycode = KEY_Z
	down.pressed = true
	Input.parse_input_event(down)
	await _frames(1)
	Shortcuts.feed(down, main.get_viewport())
	var lit: Array = await _sounding(true)
	_check("holding a key plays a note", not lit.is_empty(), "%d sounding" % lit.size())

	# The release goes somewhere else entirely -- a popup, another window --
	# so Cadmium is never told about it. All it can see is the key state.
	var up := InputEventKey.new()
	up.keycode = KEY_Z
	up.physical_keycode = KEY_Z
	up.pressed = false
	Input.parse_input_event(up)
	var gone: Array = await _sounding(false, 60)
	_check("and it stops even though the release went elsewhere", gone.is_empty(),
			"%d still sounding" % gone.size())
	Shortcuts.release_all()
	App.live_all_off()
	await _frames(2)


## Every sample in the song is a sampler of its own, and the piano roll can be
## pointed at one.
func _sampler() -> void:
	print("--- samplers")
	App.new_project()
	await _frames(2)
	var wav := _test_wav()
	if wav.is_empty():
		_check("a sample to test with", false)
		return
	var ai: int = App.add_audio_asset(wav)
	await _frames(3)
	_check("a sample arrives with settings of its own",
			App.project.assets[ai].has("sampler"), str(App.project.assets[ai].keys()))
	var win = CdSampleWindow.open(main, ai)
	await _frames(4)
	_check("its sampler opens", is_instance_valid(win) and win.visible)
	_check("with the stretching modes", win._mode.item_count == CdSampleWindow.MODES.size(),
			"%d modes" % win._mode.item_count)
	_check("and no playback section, which belongs to the instrument",
			not win.has_node("Root/Col/Playback") or not win.get_node("Root/Col/Playback").visible)
	# Which mixer track it plays through, so a filter can be put on it. A
	# sample used to go wherever its clip's playlist track pointed, and the
	# only way to put an effect on one was to move the clip.
	_check("the sampler offers every mixer track to play through",
			win._mixer.item_count == App.project.mixer.size() + 1,
			"%d entries for %d tracks" % [win._mixer.item_count, App.project.mixer.size()])
	_check("and starts on the one the clip's own track says",
			int(App.sample_settings(ai).get("mixer", -1)) == -1)
	win._change("mixer", 3)
	await _frames(2)
	_check("choosing one is remembered", int(App.sample_settings(ai).get("mixer", -1)) == 3,
			str(App.sample_settings(ai).get("mixer", -1)))
	# And the sound really arrives there: a clip on a playlist track that feeds
	# a different mixer track still comes out of the one that was chosen.
	Audio.stop()
	App.set_mode(Cd.Mode.SONG)
	var mix_clip: int = App.add_clip(Cd.ClipType.AUDIO, ai, 0, 0.0,
			App.asset_length_beats_by_index(ai), {"name": "routed"})
	App.clip_edit_done()
	Audio.seek(0.0)
	Audio.play(true)
	var heard := 0.0
	var elsewhere := 0.0
	for _i in 90:
		await _frames(1)
		var m: PackedFloat32Array = Audio.engine.meters()
		if m.size() > 4 * 4 + 1:
			heard = maxf(heard, maxf(m[3 * 4], m[3 * 4 + 1]))
			elsewhere = maxf(elsewhere, maxf(m[1 * 4], m[1 * 4 + 1]))
		if heard > 0.001:
			break
	Audio.stop()
	_check("and the sample is heard on the track it was sent to", heard > 0.001,
			"%.4f on track 3, %.4f on track 1" % [heard, elsewhere])
	App.remove_clips([mix_clip])
	win._change("mixer", -1)
	await _frames(2)

	# A knob in the window is the setting in the project is the setting in the
	# engine: three places, one value.
	win._change("gain", 0.5)
	await _frames(2)
	_check("moving a control changes the sample",
			absf(float(App.sample_settings(ai).gain) - 0.5) < 0.001,
			"%.2f" % float(App.sample_settings(ai).gain))
	_check("and the engine agrees",
			absf(float(Audio.engine.sample_settings(ai).gain) - 0.5) < 0.001,
			"%.2f" % float(Audio.engine.sample_settings(ai).gain))
	# Turning a sampler's knobs while the song is playing is heard at once:
	# what is sounding carries on sounding, with the change in it.
	App.set_mode(Cd.Mode.SONG)
	var live_clip: int = App.add_clip(Cd.ClipType.AUDIO, ai, 0, 0.0,
			App.asset_length_beats_by_index(ai), {"name": "live"})
	App.clip_edit_done()
	Audio.seek(0.0)
	Audio.play(true)
	# Waited for rather than counted out in frames: the sample is a couple of
	# seconds long and then it is over, so a fixed count of frames is a check
	# that passes on an idle machine and fails on a busy one.
	var sounding := 0
	for _i in 90:
		await _frames(1)
		sounding = Audio.engine.sample_voices()
		if sounding > 0:
			break
	win._change("gain", 0.5)
	await _frames(2)
	_check("changing a sample while it plays does not stop it",
			sounding > 0 and Audio.engine.sample_voices() >= sounding,
			"%d sounding, was %d" % [Audio.engine.sample_voices(), sounding])
	Audio.stop()
	App.remove_clips([live_clip])
	await _frames(2)

	# A sampler knob that cannot follow its lane -- the stretching pair, which
	# are automated as playback speed -- shows where the lane is with a mark on
	# the rim instead, and puts it away when the song stops.
	var pitch_knob = win._knobs["pitch"]
	var pitch_lane: int = App.automate(Cd.AutoTarget.SAMPLE_PITCH, {}, ai)
	# A long lane on purpose. The mark is read while the song is playing, and
	# the song does not stop for a machine that is busy: a short lane means a
	# check that passes on an idle machine and fails on a loaded one, which is
	# a check that says nothing. Eight bars gives it seconds of room either way.
	App.project.automations[pitch_lane].points = [
		{"beat": 0.0, "value": -12.0, "curve": 0.0},
		{"beat": 32.0, "value": 12.0, "curve": 0.0},
	]
	for c in App.project.clips:
		if int(c.type) == Cd.ClipType.AUTOMATION and int(c.index) == pitch_lane:
			c["length"] = 32.0
	App.clip_edit_done()
	App.push_automation()
	App.set_mode(Cd.Mode.SONG)
	await _frames(3)
	_check("an automated sampler knob lights up", pitch_knob.automated)
	Audio.seek(24.0)
	Audio.play(false)
	await _frames(20)
	_check("and shows where the lane is while it plays",
			not is_nan(pitch_knob.overlay) and pitch_knob.overlay > 0.0,
			"%.2f" % pitch_knob.overlay)
	var pointer: float = pitch_knob.value
	_check("without moving the knob itself off what it is set to",
			absf(pointer - float(App.sample_settings(ai).get("pitch", 0.0))) < 0.01,
			"%.2f" % pointer)
	Audio.stop()
	await _frames(6)
	_check("and puts the mark away when the song stops", is_nan(pitch_knob.overlay))
	App.remove_automation(pitch_lane)
	await _frames(2)

	# A stretched sample is a longer sample, and a clip of it is as long as
	# what it plays. And its picture has to change with it.
	main.tabs.current_tab = 0
	var pl = main.playlist
	pl.scroll_beat = 0.0
	await _frames(2)
	var beats := App.asset_length_beats_by_index(ai)
	var ci: int = App.add_clip(Cd.ClipType.AUDIO, ai, 0, 0.0, beats, {"name": "tone"})
	App.clip_edit_done()
	await _frames(3)
	var shape_before: PackedVector2Array = pl._wave_shape(ai, 0.0, 1.0, 128, beats)
	win._change("mode", 1)
	win._change("stretch", 2.0)
	await _frames(3)
	var longer := App.asset_length_beats_by_index(ai)
	_check("stretching a sample makes it longer", longer > beats * 1.5,
			"%.2f beats, was %.2f" % [longer, beats])
	_check("and its clip is stretched with it",
			absf(float(App.project.clips[ci].length) - longer) < 0.01,
			"clip %.2f, sample %.2f" % [float(App.project.clips[ci].length), longer])
	var shape_after: PackedVector2Array = pl._wave_shape(ai, 0.0, 1.0, 128, longer)
	var different := shape_before.size() != shape_after.size()
	for i in mini(shape_before.size(), shape_after.size()):
		if absf(shape_before[i].y - shape_after[i].y) > 0.01:
			different = true
	_check("and the drawing is not the one from before", different)
	win._change("mode", 3)
	win._change("stretch", 1.0)
	await _frames(2)

	win.queue_free()
	await _frames(2)

	# The piano roll can be pointed at any instrument or any sample.
	main.tabs.current_tab = 1
	App.add_stock_channel("cd.pluck")
	await _frames(3)
	var piano = main.piano
	var entries: int = piano._chooser.size()
	_check("the piano roll lists instruments and samples",
			entries == App.project.channels.size() + App.project.assets.size(),
			"%d entries for %d channels and %d samples" % [entries,
			App.project.channels.size(), App.project.assets.size()])
	var channels_before := App.project.channels.size()
	var ch: int = App.channel_for_asset(ai)
	await _frames(3)
	_check("picking a sample gives it a channel to be played from",
			App.project.channels.size() == channels_before + 1
			and int(App.project.channels[ch].get("asset", -1)) == ai,
			"channel %d" % ch)
	_check("and asking again gives the same one", App.channel_for_asset(ai) == ch)
	App.new_project()
	await _frames(2)


## A second of a tone, written once, for the tests that need a sample.
func _test_wav() -> String:
	var path := OS.get_user_data_dir().path_join("uitest_tone.wav")
	if FileAccess.file_exists(path):
		return path
	var rate := 48000
	var frames := rate
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return ""
	f.store_buffer("RIFF".to_ascii_buffer())
	f.store_32(36 + frames * 4)
	f.store_buffer("WAVEfmt ".to_ascii_buffer())
	f.store_32(16)
	f.store_16(1)
	f.store_16(2)
	f.store_32(rate)
	f.store_32(rate * 4)
	f.store_16(4)
	f.store_16(16)
	f.store_buffer("data".to_ascii_buffer())
	f.store_32(frames * 4)
	for i in frames:
		var env: float = 1.0 - float(i) / float(frames)
		var v := int(clampf(sin(TAU * 220.0 * float(i) / float(rate)) * env * 0.6, -1.0, 1.0) * 24000.0)
		f.store_16(v & 0xFFFF)
		f.store_16(v & 0xFFFF)
	f.close()
	return path


## Picking the key the piece is in, the way FL does it: the rows that belong to
## the scale are lit and the rest are dimmed.
func _key_picking() -> void:
	print("--- key picking")
	App.new_project()
	await _frames(2)
	App.add_stock_channel("cd.pluck")
	main.tabs.current_tab = 1
	await _frames(3)
	var piano = main.piano
	piano.scale_root = 2
	piano.scale_name = "Minor"
	piano.queue_redraw()
	await _frames(2)
	_check("the picker says which key it is in", piano._scale_label() == "D Minor",
			piano._scale_label())
	_check("a minor scale has the notes a minor scale has",
			piano.SCALES["Minor"] == [0, 2, 3, 5, 7, 8, 10], str(piano.SCALES["Minor"]))
	piano.scale_name = "Off"
	await _frames(2)
	_check("and says nothing in particular when it is off", piano._scale_label() == "Key",
			piano._scale_label())

	# The picker sits in the corner over the keyboard, and clicking it must not
	# be taken for a click on the ruler next to it.
	var strip: Rect2 = piano._ruler_rect()
	var r: Rect2 = piano._scale_button()
	_check("the picker is in the corner above the keys",
			r.position.x < piano.KEY_W and strip.encloses(r) and r.size.x > 8.0, str(r))
	piano._drag_mode = ""
	_press(piano, r.get_center())
	_release(piano, r.get_center())
	await _frames(2)
	_check("clicking it does not drag the playhead", piano._drag_mode != "scrub",
			"drag mode \"%s\"" % piano._drag_mode)
	# And a click on the ruler proper still scrubs.
	var on_ruler := Vector2(piano.KEY_W + 60.0, strip.position.y + strip.size.y * 0.5)
	_press(piano, on_ruler)
	_check("but the ruler beside it still does", piano._drag_mode == "scrub",
			"drag mode \"%s\"" % piano._drag_mode)
	_release(piano, on_ruler)
	await _frames(2)

	# The choosers live in a strip of their own above the ruler. They used to
	# sit on top of it, so the first two or three bars could not be clicked at
	# all and their numbers were hidden behind a drop-down.
	var head: Rect2 = piano._head_rect()
	_check("the ruler starts below the toolbar, not under it",
			strip.position.y >= head.end.y and head.size.y > 8.0,
			"toolbar %s, ruler %s" % [str(head), str(strip)])
	var chooser := Rect2(piano._channel_btn.position, piano._channel_btn.size) \
			if piano._channel_btn != null else Rect2()
	_check("and the chooser is wholly inside it, off the ruler",
			head.encloses(chooser), "chooser %s, toolbar %s" % [str(chooser), str(head)])
	piano._drag_mode = ""
	_press(piano, Vector2(piano.KEY_W + 300.0, head.size.y * 0.5))
	_release(piano, Vector2(piano.KEY_W + 300.0, head.size.y * 0.5))
	await _frames(2)
	_check("and clicking the toolbar does not move the marker", piano._drag_mode != "scrub",
			"drag mode \"%s\"" % piano._drag_mode)


## Quick legato: a run of notes closed up so each one reaches the next.
func _legato() -> void:
	print("--- legato")
	App.new_project()
	await _frames(2)
	App.add_stock_channel("cd.pluck")
	main.tabs.current_tab = 1
	await _frames(3)
	# Four notes a beat apart, all far too short to touch.
	for i in 4:
		App.add_note(App.current_pattern, 0, float(i), 0.1, 60 + i, 0.8)
	App.note_edit_done(App.current_pattern)
	App.selected_notes.clear()
	await _frames(2)
	# Driven by the key itself, not by the command behind it: the binding is
	# the half that was broken, and a test of the command alone said nothing.
	var ctrl_l := InputEventKey.new()
	ctrl_l.keycode = KEY_L
	ctrl_l.physical_keycode = KEY_L
	ctrl_l.ctrl_pressed = true
	ctrl_l.pressed = true
	Shortcuts.feed(ctrl_l, main.get_viewport())
	await _frames(2)
	var notes: Array = App.project.patterns[App.current_pattern].notes
	var joined := 0
	for i in 3:
		if absf(float(notes[i].len) - 1.0) < 0.001:
			joined += 1
	_check("every note reaches the next one", joined == 3,
			"%d of 3 closed up" % joined)
	_check("the last note is left alone", absf(float(notes[3].len) - 0.1) < 0.001,
			"%.2f beats" % float(notes[3].len))

	# With a selection it only touches what is selected, and it shortens as
	# well as stretches.
	App.update_note(App.current_pattern, 0, {"len": 4.0})
	App.selected_notes = [0]
	await _frames(2)
	Shortcuts.feed(ctrl_l, main.get_viewport())
	await _frames(2)
	notes = App.project.patterns[App.current_pattern].notes
	_check("a note that overshoots is pulled back", absf(float(notes[0].len) - 1.0) < 0.001,
			"%.2f beats" % float(notes[0].len))
	_check("and the rest are left as they were", absf(float(notes[3].len) - 0.1) < 0.001)

	# The loop toggle it used to share the shortcut with still has one.
	var was_loop := App.loop_enabled
	var ctrl_shift_l := InputEventKey.new()
	ctrl_shift_l.keycode = KEY_L
	ctrl_shift_l.physical_keycode = KEY_L
	ctrl_shift_l.ctrl_pressed = true
	ctrl_shift_l.shift_pressed = true
	ctrl_shift_l.pressed = true
	Shortcuts.feed(ctrl_shift_l, main.get_viewport())
	await _frames(2)
	_check("and ctrl-shift-L still works the loop", App.loop_enabled != was_loop,
			"loop %s, was %s" % [App.loop_enabled, was_loop])
	Shortcuts.feed(ctrl_shift_l, main.get_viewport())
	await _frames(2)


## The typing keyboard on a keyboard that is not American. Godot reports both
## what a key prints and where it sits; the piano follows where it sits, so the
## same physical key plays the same note on QWERTY, QWERTZ and AZERTY.
func _layouts() -> void:
	print("--- keyboard layouts")
	App.new_project()
	await _frames(2)
	App.add_stock_channel("cd.ember")
	await _frames(3)
	Shortcuts.release_all()
	Settings.set_value("piano_by_position", true)

	# The key an American keyboard calls Z. On AZERTY that same key prints W,
	# and on QWERTZ the one next to it prints Y -- the note must not move.
	var layouts := [
		{"name": "QWERTY", "prints": KEY_Z},
		{"name": "AZERTY", "prints": KEY_W},
		{"name": "QWERTZ", "prints": KEY_Y},
		{"name": "Dvorak", "prints": KEY_SEMICOLON},
	]
	var notes := []
	for l in layouts:
		var down := InputEventKey.new()
		down.physical_keycode = KEY_Z
		down.keycode = int(l.prints)
		down.pressed = true
		Shortcuts.feed(down, main.get_viewport())
		var lit: Array = await _sounding(true)
		notes.append(lit[0] if not lit.is_empty() else -1)
		var up := InputEventKey.new()
		up.physical_keycode = KEY_Z
		up.keycode = int(l.prints)
		up.pressed = false
		Shortcuts.feed(up, main.get_viewport())
		await _sounding(false)
	var same := true
	for n in notes:
		if n != notes[0] or n < 0:
			same = false
	_check("the same key plays the same note on every layout", same,
			", ".join(layouts.map(func(l): return String(l.name)))
			+ " -> " + ", ".join(notes.map(func(n): return str(n))))

	# And the other way round for anyone who would rather have the letters.
	Settings.set_value("piano_by_position", false)
	var d2 := InputEventKey.new()
	d2.physical_keycode = KEY_Z
	d2.keycode = KEY_W        # an AZERTY keyboard's Z key, printing W
	d2.pressed = true
	Shortcuts.feed(d2, main.get_viewport())
	var lit2: Array = await _sounding(true)
	_check("with the setting off it follows the printed letter",
			not lit2.is_empty() and int(lit2[0]) != int(notes[0]),
			"%d against %d" % [int(lit2[0]) if not lit2.is_empty() else -1, int(notes[0])])
	var u2 := InputEventKey.new()
	u2.physical_keycode = KEY_Z
	u2.keycode = KEY_W
	u2.pressed = false
	Shortcuts.feed(u2, main.get_viewport())
	await _sounding(false)
	Settings.set_value("piano_by_position", true)
	Shortcuts.release_all()
	App.live_all_off()

	# A plugin is only ever refused on the strength of a crash report written
	# at about the moment it was being opened. Cadmium being killed -- a task
	# manager, a force quit, the machine going down -- leaves the same marker
	# behind and is nobody's fault, and refusing a working synth for ever on
	# that basis is exactly what happened to Vital.
	var was_broken := Plugins._broken()
	Plugins._set_broken({})
	Plugins._mark_probing("/nowhere/Innocent.vst3")
	await Plugins._ready()
	_check("a plugin is not written off just because Cadmium stopped",
			not Plugins.is_broken("/nowhere/Innocent.vst3"))
	_check("and the marker is cleared either way", Plugins._crashed_on().is_empty())
	# And one that really did take it down is still remembered.
	Plugins._mark_probing("/nowhere/Guilty.vst3")
	_check("a crash from around then is what makes it count",
			Plugins._crash_around(Plugins._probing_time() + 100000) == false)
	Plugins._clear_probing()
	Plugins._set_broken(was_broken)

	# Taking the keyboard back off a plugin is right on X11 and wrong on
	# Windows, where the plugin's canvas is a window of its own: doing it there
	# takes the focus off a plugin while it is being used, and a JUCE plugin
	# ends a drag when it loses the focus. Vital's wavetable could not be
	# dragged at all.
	var pw := load("res://ui/panels/plugin_window.gd")
	_check("the keyboard is taken back from a plugin on X11", pw._reclaims_keyboard("Linux"))
	_check("and never on Windows, where it would cancel what you are doing",
			not pw._reclaims_keyboard("Windows"))

	# A key whose release never arrives. This is what happens for real every
	# time somebody plays a note and then clicks into a plugin's own interface:
	# the plugin takes the keyboard, the key-up is delivered there, and Godot
	# goes on believing the key is held. Asking Godot is no use -- it is the
	# thing that is wrong -- so the keyboard itself is asked, and a note is let
	# go of once nothing at all is down.
	_check("the keyboard can be asked what is really held",
			not Audio.engine.any_key_held(),
			"something is being held down on this machine" if Audio.engine.any_key_held()
			else "nothing held, as expected")
	var stuck := InputEventKey.new()
	stuck.physical_keycode = KEY_Z
	stuck.keycode = KEY_Z
	stuck.pressed = true
	Shortcuts.feed(stuck, main.get_viewport())
	var held: Array = await _sounding(true)
	_check("a key that is never released plays", not held.is_empty())
	# No key-up fed at all: exactly what a plugin taking the keyboard does.
	var gone := false
	for _i in 30:
		await _frames(1)
		if not Shortcuts.holding():
			gone = true
			break
	_check("and is let go of anyway once the keyboard is idle", gone)
	await _sounding(false)
	_check("with nothing left sounding", App.live_notes_held() == 0,
			"%d still held" % App.live_notes_held())
	Shortcuts.release_all()
	App.live_all_off()


## The marker: playing from where you put it, and coming back there when you
## stop. And drawing a note while the song plays should not play it at you.
func _transport_marker() -> void:
	print("--- the marker")
	App.new_project()
	await _frames(2)
	App.add_stock_channel("cd.pluck")
	main.tabs.current_tab = 0
	# Stopped first: this is a test about where the marker goes, and it starts
	# by saying what the transport is doing rather than hoping.
	Audio.stop()
	await _frames(3)
	Audio.seek(8.0)
	await _frames(2)
	_check("the marker goes where it is put", absf(Audio.position() - 8.0) < 0.001,
			"%.2f" % Audio.position())
	Audio.play(false)
	await _frames(6)
	_check("and playing starts from there", Audio.position() > 8.0, "%.2f" % Audio.position())
	Audio.toggle()
	await _frames(3)
	_check("stopping comes back to it", absf(Audio.position() - 8.0) < 0.001,
			"%.2f" % Audio.position())
	Audio.stop()
	await _frames(2)
	_check("and stopping again goes to the beginning", Audio.position() < 0.001,
			"%.2f" % Audio.position())

	# A note drawn while the song is playing is put in, not auditioned.
	main.tabs.current_tab = 1
	App.tool = Cd.Tool.DRAW
	await _frames(3)
	var piano = main.piano
	var g: Rect2 = piano._grid_rect()
	Audio.play(true)
	await _frames(4)
	# Read straight after the press, with no frame in between: the editor lets
	# go of an audition as soon as it notices the button is not really down,
	# and a synthetic press never was.
	var at := Vector2(g.position.x + 60.0, g.position.y + g.size.y * 0.5)
	_press(piano, at)
	var while_playing: int = piano._preview_key
	_release(piano, at)
	_check("drawing a note while it plays does not audition it", while_playing < 0,
			"preview %d" % while_playing)
	Audio.stop()
	await _frames(3)
	var at2 := Vector2(g.position.x + 260.0, g.position.y + g.size.y * 0.5)
	_press(piano, at2)
	var while_stopped: int = piano._preview_key
	_release(piano, at2)
	_check("and with it stopped it still does", while_stopped >= 0,
			"preview %d" % while_stopped)
	await _frames(2)
	App.live_all_off()


## Press and hold on a key -- the keyboard down the side of the piano roll, or
## the one under a plugin -- and the note has to keep sounding until the button
## comes back up.
func _held_notes() -> void:
	print("--- holding a key")
	App.new_project()
	await _frames(2)
	App.add_stock_channel("cd.ember")
	main.tabs.current_tab = 1
	await _frames(4)
	var piano = main.piano
	var grid: Rect2 = piano._grid_rect()
	var at := Vector2(piano.KEY_W * 0.5, grid.position.y + grid.size.y * 0.5)

	# Fed through Input as well as to the control: the editor asks the input
	# system whether the button is still down, because a release outside the
	# window never arrives as an event.
	var down := InputEventMouseButton.new()
	down.button_index = MOUSE_BUTTON_LEFT
	down.pressed = true
	down.position = at
	Input.parse_input_event(down)
	await _frames(1)
	piano._gui_input(down)
	var lit: Array = await _sounding(true)
	_check("pressing a key on the piano roll's keyboard plays a note", not lit.is_empty(),
			"%d sounding" % lit.size())
	# Held: still sounding several frames later, with nothing else touched.
	await _frames(12)
	_check("holding it keeps the note sounding",
			not Audio.engine.active_notes(App.current_channel).is_empty(),
			"%d sounding" % Audio.engine.active_notes(App.current_channel).size())
	var up := InputEventMouseButton.new()
	up.button_index = MOUSE_BUTTON_LEFT
	up.pressed = false
	up.position = at
	Input.parse_input_event(up)
	await _frames(1)
	piano._gui_input(up)
	var gone: Array = await _sounding(false)
	_check("letting go stops it", gone.is_empty(), "%d still sounding" % gone.size())

	# The same thing on a note in the grid: pressing one auditions it, and the
	# audition lasts as long as the button is down.
	var key: int = piano._y_to_key(grid.position.y + grid.size.y * 0.5)
	var beat: float = maxf(0.0, snappedf(piano._x_to_beat(grid.position.x + 80.0), 0.25))
	var ni: int = App.add_note(App.current_pattern, 0, beat, 2.0, key, 0.8)
	App.note_edit_done(App.current_pattern)
	await _frames(2)
	var r: Rect2 = piano._note_rect(piano._notes()[ni])
	var on_note := Vector2(r.position.x + 6.0, r.position.y + r.size.y * 0.5)
	var d2 := InputEventMouseButton.new()
	d2.button_index = MOUSE_BUTTON_LEFT
	d2.pressed = true
	d2.position = on_note
	Input.parse_input_event(d2)
	await _frames(1)
	piano._gui_input(d2)
	var lit2: Array = await _sounding(true)
	_check("pressing a note in the grid auditions it", not lit2.is_empty(),
			"%d sounding" % lit2.size())
	await _frames(12)
	_check("and holding it keeps that sounding too",
			not Audio.engine.active_notes(App.current_channel).is_empty(),
			"%d sounding" % Audio.engine.active_notes(App.current_channel).size())
	var u2 := InputEventMouseButton.new()
	u2.button_index = MOUSE_BUTTON_LEFT
	u2.pressed = false
	u2.position = on_note
	Input.parse_input_event(u2)
	await _frames(1)
	piano._gui_input(u2)
	await _sounding(false)

	# And the keyboard under a plugin's own window.
	main.open_plugin_window({"kind": "channel", "index": 0})
	await _frames(8)
	var win = null
	for w in main._plugin_windows.values():
		if is_instance_valid(w):
			win = w
	if win == null:
		_check("a plugin window opens for the keyboard", false)
		return
	var keys = win.get_node_or_null("Root/Col/Keys")
	if keys == null:
		_check("the plugin window has a keyboard", false)
		main._close_plugin_window({"kind": "channel", "index": 0})
		return
	keys.size = Vector2(300, 40)
	await _frames(2)
	var kat := Vector2(keys.size.x * 0.3, keys.size.y * 0.7)
	var d3 := InputEventMouseButton.new()
	d3.button_index = MOUSE_BUTTON_LEFT
	d3.pressed = true
	d3.position = kat
	Input.parse_input_event(d3)
	await _frames(1)
	keys._gui_input(d3)
	var lit3: Array = await _sounding(true)
	_check("pressing a key under a plugin plays a note", not lit3.is_empty(),
			"%d sounding" % lit3.size())
	await _frames(12)
	_check("and it holds", not Audio.engine.active_notes(App.current_channel).is_empty(),
			"%d sounding" % Audio.engine.active_notes(App.current_channel).size())
	var u3 := InputEventMouseButton.new()
	u3.button_index = MOUSE_BUTTON_LEFT
	u3.pressed = false
	u3.position = kat
	Input.parse_input_event(u3)
	await _frames(1)
	keys._gui_input(u3)
	await _sounding(false)
	main._close_plugin_window({"kind": "channel", "index": 0})
	await _frames(2)

	# And the rule that used to cut those notes off, put to it directly: a note
	# is only dropped once the application has been away for a while with
	# nothing held down. Alt-tab mid-chord still has to stop it.
	App.live_note_on(64, 0.8, "watchdog-test")
	await _frames(2)
	for i in 20:
		App._watchdog_tick(0.1, false, true)      # away, but still holding
	_check("a note held down survives the window losing focus", App.live_notes_held() > 0,
			"%d held" % App.live_notes_held())
	for i in 20:
		App._watchdog_tick(0.1, true, false)      # back, nothing held
	_check("and survives while the window has focus", App.live_notes_held() > 0,
			"%d held" % App.live_notes_held())
	for i in 3:
		App._watchdog_tick(0.2, false, false)     # away, nothing held: let go
	_check("but is let go of once the window has really gone away",
			App.live_notes_held() == 0, "%d held" % App.live_notes_held())
	App.live_all_off()


## The arrangement holds as many rows as the song wants, not the twelve it
## starts with.
func _tracks() -> void:
	print("--- arrangement tracks")
	App.new_project()
	await _frames(2)
	main.tabs.current_tab = 0
	var pl = main.playlist
	pl.scroll_y = 0.0
	await _frames(2)
	var before := App.project.tracks.size()
	var i := App.add_track()
	await _frames(2)
	_check("a track can be added", App.project.tracks.size() == before + 1 and i == before,
			"%d tracks, was %d" % [App.project.tracks.size(), before])
	# The one that matters: it is somewhere you can put a clip.
	var ci: int = App.add_clip(Cd.ClipType.PATTERN, 0, i, 0.0, 4.0)
	App.clip_edit_done()
	await _frames(2)
	_check("and a clip can go on it", ci >= 0 and int(App.project.clips[ci].track) == i,
			"clip on track %d" % int(App.project.clips[ci].track))
	var r: Rect2 = pl._clip_rect(App.project.clips[ci])
	_check("where the arrangement actually draws it", r.size.x > 4.0 and r.size.y > 4.0,
			str(r))

	# Marking a stretch out: shift and drag along the ruler, which is what
	# loops and what the export window offers as "Marked region".
	App.clear_mark()
	var ruler_y: float = pl.MAP_H + pl.RULER_H * 0.5
	var from_x: float = pl._beat_to_x(4.0)
	var to_x: float = pl._beat_to_x(12.0)
	_press(pl, Vector2(from_x, ruler_y), MOUSE_BUTTON_LEFT, true)
	_move(pl, Vector2(from_x, ruler_y), Vector2(to_x, ruler_y))
	_release(pl, Vector2(to_x, ruler_y))
	await _frames(2)
	var span: Vector2 = App.mark_span()
	_check("shift and drag along the ruler marks a stretch out", App.has_mark()
			and absf(span.x - 4.0) < 0.51 and absf(span.y - 12.0) < 0.51, str(span))
	_check("and the transport loops over exactly that",
			absf(Audio.engine.loop_start() - span.x) < 0.001
			and absf(Audio.engine.loop_end() - span.y) < 0.001,
			"%.2f..%.2f" % [Audio.engine.loop_start(), Audio.engine.loop_end()])
	# It survives being saved and opened again, the way a loop marker should.
	var mark_file := OS.get_user_data_dir().path_join("uitest_mark.cad")
	App.project.save(mark_file)
	App.new_project()
	await _frames(2)
	_check("a new project has nothing marked", not App.has_mark())
	App.load_project(mark_file)
	await _frames(2)
	_check("and the mark comes back with the project it was saved in",
			App.has_mark() and absf(App.mark_span().x - span.x) < 0.001, str(App.mark_span()))
	# Double-clicking the ruler takes it away again.
	var dbl := InputEventMouseButton.new()
	dbl.button_index = MOUSE_BUTTON_LEFT
	dbl.pressed = true
	dbl.double_click = true
	dbl.position = Vector2(to_x, ruler_y)
	pl._gui_input(dbl)
	await _frames(2)
	_check("and double-clicking the ruler takes the mark away", not App.has_mark())
	_check("which puts the loop back over the whole song",
			Audio.engine.loop_end() > 0.0 and absf(Audio.engine.loop_start()) < 0.001,
			"%.2f..%.2f" % [Audio.engine.loop_start(), Audio.engine.loop_end()])
	# Put back what the round trip replaced, so what follows starts where it
	# expects to: one added track, with one clip on it.
	App.new_project()
	await _frames(2)
	main.tabs.current_tab = 0
	pl.scroll_y = 0.0
	i = App.add_track()
	ci = App.add_clip(Cd.ClipType.PATTERN, 0, i, 0.0, 4.0)
	App.clip_edit_done()
	await _frames(2)
	# Twenty more, by the strip under the headers.
	for n in 20:
		var add: Rect2 = pl._add_track_rect()
		_press(pl, add.get_center())
		_release(pl, add.get_center())
		await tree.process_frame
	_check("the strip under the headers adds them", App.project.tracks.size() == before + 21,
			"%d tracks" % App.project.tracks.size())
	_check("and it moves down as they are added",
			pl._add_track_rect().position.y > pl._track_y(before),
			"at y %.0f" % pl._add_track_rect().position.y)
	# And back off again, taking what was on it.
	var clips_before := App.project.clips.size()
	App.project.clips.append({"type": Cd.ClipType.PATTERN, "index": 0,
			"track": App.project.tracks.size() - 1, "start": 0.0, "length": 4.0})
	App.clip_edit_done()
	await _frames(2)
	_check("removing the last track takes its clips with it", App.remove_track()
			and App.project.clips.size() == clips_before,
			"%d clips, was %d" % [App.project.clips.size(), clips_before])


## The picker down the left of the arrangement: everything the song is made of,
## where you can see it, instead of a drop-down at the top of the window.
func _picker_panel() -> void:
	print("--- playlist picker")
	App.new_project()
	await _frames(3)
	main.tabs.current_tab = 0
	var pick = main.picker
	await _frames(2)
	_check("the picker lists the song's patterns", pick._rows.size() == App.project.patterns.size(),
			"%d rows for %d patterns" % [pick._rows.size(), App.project.patterns.size()])
	var added: int = App.add_pattern("Second")
	await _frames(3)
	_check("a new pattern appears in it", pick._rows.size() == App.project.patterns.size(),
			"%d rows for %d patterns" % [pick._rows.size(), App.project.patterns.size()])
	# Clicking one is how you choose what the piano roll is editing.
	pick._on_picked("pattern", added)
	await _frames(2)
	_check("clicking one selects it", App.current_pattern == added,
			"pattern %d" % App.current_pattern)
	var marked := 0
	for row in pick._rows:
		if row.current:
			marked += 1
	_check("and only that one is marked", marked == 1, "%d marked" % marked)

	# Each row draws what the thing actually is, which is how you tell six
	# patterns called "Pattern 4" apart.
	App.add_stock_channel("cd.ember")
	App.add_note(added, 0, 0.0, 1.0, 60, 0.9)
	App.add_note(added, 0, 1.0, 1.0, 67, 0.9)
	App.note_edit_done(added)
	pick.rebuild()
	await _frames(2)
	var with_notes = null
	var without = null
	for row in pick._rows:
		if int(row.index) == added:
			with_notes = row
		else:
			without = row
	_check("a pattern with notes in it draws a preview",
			with_notes != null and with_notes._preview.size() >= 4,
			"%d points" % (with_notes._preview.size() if with_notes != null else -1))
	_check("an empty one draws nothing",
			without != null and without._preview.is_empty(),
			"%d points" % (without._preview.size() if without != null else -1))

	# Dragging a row onto the arrangement puts it down, so the payload the row
	# offers has to be one the arrangement takes.
	var before := App.project.clips.size()
	var row0 = pick._rows[0]
	var payload: Variant = row0._get_drag_data(Vector2.ZERO)
	_check("the arrangement accepts what a row offers",
			main.playlist._can_drop_data(Vector2(200, 40), payload))
	main.playlist._drop_data(Vector2(200, 40), payload)
	await _frames(2)
	_check("dropping one puts a clip down", App.project.clips.size() == before + 1,
			"%d clips, was %d" % [App.project.clips.size(), before])

	# The other two sections list the rest of what a song is made of.
	var ai: int = App.add_automation("test lane", Cd.AutoTarget.MIXER_VOL, {}, 1, 0, 0.0, 1.0)
	await _frames(2)
	pick._select_section("automation")
	await _frames(2)
	_check("the automation section lists the lanes",
			pick._rows.size() == App.project.automations.size(),
			"%d rows for %d lanes" % [pick._rows.size(), App.project.automations.size()])
	var before2 := App.project.clips.size()
	pick.place("automation", ai, 0, 0.0)
	await _frames(2)
	_check("an automation clip can be placed from it",
			App.project.clips.size() == before2 + 1)
	pick._select_section("sample")
	await _frames(2)
	_check("the audio section lists the files the song uses",
			pick._rows.size() == App.project.assets.size(),
			"%d rows for %d files" % [pick._rows.size(), App.project.assets.size()])
	pick._select_section("pattern")
	await _frames(2)


## Whether one mixer strip is drawing the selection outline.
func mixer_selected(track: int) -> bool:
	var nodes: Dictionary = main.mixer._strip_nodes
	return nodes.has(track) and is_instance_valid(nodes[track]) and bool(nodes[track]._selected)


## Taking a plugin away has to take its window with it. A window left behind is
## pointing at a plugin that is not there any more, or at whichever one moved up
## into the slot.
func _plugin_removal() -> void:
	print("--- removing a plugin")
	App.new_project()
	await _frames(2)
	App.set_insert(1, 0, CdProject.plugin_dict("stock", "cd.reverb", "", "Reverb"))
	App.set_insert(1, 1, CdProject.plugin_dict("stock", "cd.delay", "", "Delay"))
	await _frames(3)
	var top := {"kind": "insert", "track": 1, "slot": 0}
	var below := {"kind": "insert", "track": 1, "slot": 1}
	main.open_plugin_window(top)
	main.open_plugin_window(below)
	await _frames(4)
	_check("two effects, two windows", main._plugin_windows.size() == 2,
			"%d open" % main._plugin_windows.size())
	var kept = main._plugin_windows.get(JSON.stringify(below))
	var kept_handle: int = int(kept.handle) if kept != null else -1

	App.remove_insert(1, 0)
	await _frames(4)
	_check("removing one closes its window", main._plugin_windows.size() == 1,
			"%d open" % main._plugin_windows.size())
	# The one that is left has to be the plugin it was opened on, not whatever
	# slid up into slot zero.
	var still = null
	for w in main._plugin_windows.values():
		if is_instance_valid(w):
			still = w
	_check("and leaves the other one alone", still != null and int(still.handle) == kept_handle,
			"handle %d, was %d" % [int(still.handle) if still else -1, kept_handle])
	if still != null:
		main._close_plugin_window(still.ref)
	await _frames(2)

	# The same for an instrument: replacing one closes the window that was
	# showing the old plugin.
	App.add_stock_channel("cd.ember")
	await _frames(3)
	var chan := {"kind": "channel", "index": 0}
	main.open_plugin_window(chan)
	await _frames(4)
	_check("a channel's plugin has a window", main._plugin_windows.size() == 1)
	App.replace_channel_plugin(0, CdProject.plugin_dict("stock", "cd.pluck", "", "Pluck"))
	await _frames(4)
	_check("replacing the instrument closes it", main._plugin_windows.is_empty(),
			"%d open" % main._plugin_windows.size())

	# And removing the channel entirely.
	main.open_plugin_window(chan)
	await _frames(4)
	App.remove_channel(0)
	await _frames(4)
	_check("removing the channel closes it too", main._plugin_windows.is_empty(),
			"%d open" % main._plugin_windows.size())


## The mixer: as many tracks as you want, and the routing band under them.
func _mixer_routing() -> void:
	print("--- mixer routing")
	var mx = main.mixer
	App.new_project()
	await _frames(2)
	main.tabs.current_tab = 2
	await _frames(3)
	var before := App.project.mixer.size()
	var strips_before: int = mx._strip_nodes.size()
	var added := App.add_mixer_track()
	await _frames(3)
	_check("a track can be added", App.project.mixer.size() == before + 1 and added == before,
			"%d tracks, was %d" % [App.project.mixer.size(), before])
	_check("the engine has it too", Audio.engine.mixer_count() == App.project.mixer.size(),
			"engine %d" % Audio.engine.mixer_count())
	# The one that matters: a strip you can actually see and click.
	_check("and a strip appears for it", mx._strip_nodes.size() == strips_before + 1
			and mx._strip_nodes.has(added) and is_instance_valid(mx._strip_nodes[added]),
			"%d strips, was %d" % [mx._strip_nodes.size(), strips_before])
	_check("with the +/- still at the end of the row",
			mx._strips.get_child(mx._strips.get_child_count() - 1).has_node("Add"))
	# There is no ceiling: a hundred more is fine.
	for i in 100:
		App.add_mixer_track()
	await _frames(3)
	_check("and a hundred more", App.project.mixer.size() == before + 101
			and Audio.engine.mixer_count() == App.project.mixer.size(),
			"%d tracks" % App.project.mixer.size())
	_check("with a strip each", mx._strip_nodes.size() == App.project.mixer.size(),
			"%d strips for %d tracks" % [mx._strip_nodes.size(), App.project.mixer.size()])

	# Only one strip wears the selection outline: the one that just lost it has
	# to take it off, which it can only do if it is told.
	App.select_mixer(2)
	await _frames(2)
	App.select_mixer(4)
	await _frames(2)
	var outlined := []
	for t in App.project.mixer.size():
		if mixer_selected(t):
			outlined.append(t)
	_check("only the selected strip is outlined", outlined == [4], str(outlined))

	# Routing, the way clicking a socket does it.
	App.select_mixer(1)
	await _frames(2)
	_check("a track starts out going to the master", App.routes_of(1) == [0],
			str(App.routes_of(1)))
	App.set_route(1, 3, true)
	await _frames(2)
	_check("routing into another track adds it", App.routes_of(1).has(3),
			str(App.routes_of(1)))
	App.set_route(1, 0, false)
	await _frames(2)
	_check("and the main output can be taken away", not App.routes_of(1).has(0),
			str(App.routes_of(1)))
	App.set_route(1, 3, false)
	await _frames(2)
	_check("as can the send", App.routes_of(1).is_empty(), str(App.routes_of(1)))
	App.set_route(1, 0, true)

	# The band draws a socket under every strip, and they are where the strips
	# are: clicking one has to land on the right track.
	var r1: Rect2 = mx._socket_rect(1)
	var r5: Rect2 = mx._socket_rect(5)
	_check("every strip has a socket under it", r1.size.x > 4.0 and r5.size.x > 4.0,
			"%s and %s" % [str(r1), str(r5)])
	_check("and they are in strip order", r5.position.x > r1.position.x)
	var click := InputEventMouseButton.new()
	click.button_index = MOUSE_BUTTON_LEFT
	click.pressed = true
	click.position = r5.get_center()
	mx._routing_input(click)
	await _frames(2)
	_check("clicking a socket routes into that strip", App.routes_of(1).has(5),
			str(App.routes_of(1)))
	mx._routing_input(click)
	await _frames(2)
	_check("and clicking it again stops", not App.routes_of(1).has(5),
			str(App.routes_of(1)))

	# A track something is using cannot be taken away.
	App.add_stock_channel("cd.ember")
	App.set_channel_prop(0, "mixer", App.project.mixer.size() - 1)
	await _frames(2)
	var kept := App.project.mixer.size()
	_check("a track in use is not removed", not App.remove_mixer_track()
			and App.project.mixer.size() == kept)
	App.set_channel_prop(0, "mixer", 1)
	await _frames(2)
	_check("and an unused one is", App.remove_mixer_track()
			and App.project.mixer.size() == kept - 1,
			"%d tracks" % App.project.mixer.size())
	await _frames(3)
	_check("and its strip goes with it", mx._strip_nodes.size() == App.project.mixer.size(),
			"%d strips for %d tracks" % [mx._strip_nodes.size(), App.project.mixer.size()])


## Clicking a plugin's name is a toggle: the second click puts the window away
## again, rather than raising the one that is already in front of you.
func _windows() -> void:
	print("--- plugin windows")
	App.new_project()
	await _frames(2)
	App.add_stock_channel("cd.ember")
	await _frames(3)
	var ref := {"kind": "channel", "index": 0}
	App.toggle_plugin_window(ref)
	await _frames(4)
	_check("clicking a channel's plugin opens its window", main._plugin_windows.size() == 1,
			"%d open" % main._plugin_windows.size())
	var win = main._plugin_windows.values()[0] if not main._plugin_windows.is_empty() else null
	if win != null:
		_check("one of Cadmium's own plugins is not kept waiting", not win._busy.visible)
	App.toggle_plugin_window(ref)
	await _frames(4)
	_check("clicking it again puts the window away", main._plugin_windows.is_empty(),
			"%d open" % main._plugin_windows.size())
	App.toggle_plugin_window(ref)
	await _frames(4)
	_check("and again brings it back", main._plugin_windows.size() == 1,
			"%d open" % main._plugin_windows.size())

	# Cadmium takes the keyboard back off a hosted plugin so the typing keys
	# keep playing -- but only once the pointer has left the plugin's own
	# canvas. Taking it while the pointer is still in there shuts the plugin's
	# right-click menus as they open and makes its text boxes untypeable.
	var w2 = main._plugin_windows.values()[0]
	_check("the keyboard is left alone while the pointer is on the plugin",
			not w2._away_check(true, 1000))
	_check("and still left alone the moment it leaves",
			not w2._away_check(false, 1000))
	_check("and taken back once it has been away for a moment",
			w2._away_check(false, 1000 + w2.AWAY_BEFORE_KEYS + 1))
	_check("going back in starts the wait again", not w2._away_check(true, 5000)
			and not w2._away_check(false, 5000))
	main._close_plugin_window(ref)
	await _frames(2)


## The toolbar's last-tweaked control: it has to follow whatever was moved and
## turn it into automation without the user having to find it again.
func _tweaked() -> void:
	print("--- last tweaked")
	App.new_project()
	await _frames(2)
	App.add_stock_channel("cd.ember")
	await _frames(2)
	App.last_tweaked.clear()
	var ref := {"kind": "channel", "index": 0}
	var params: Array = App.plugin_params(ref)
	if params.size() < 2:
		_check("the instrument has controls to move", false, "%d parameters" % params.size())
		return
	var first: Dictionary = params[0]
	var idx := int(first.index)
	App.set_plugin_param(ref, idx, lerpf(float(first.min), float(first.max), 0.5))
	await _frames(2)
	_check("moving a control remembers it",
			App.last_tweaked.size() == 1 and int(App.last_tweaked[0].b) == idx,
			"%d remembered" % App.last_tweaked.size())
	var d := App.tweak_describe(App.last_tweaked[0])
	_check("the remembered control knows what it is",
			not d.is_empty() and not String(d.get("name", "")).is_empty(),
			String(d.get("name", "(nothing)")))
	var bar = main.transport
	_check("the toolbar shows it", String(bar._tweak_name.text) == String(d.get("short", "")),
			"\"%s\"" % bar._tweak_name.text)

	var before := App.project.clips.size()
	bar._tweak_command(0)
	await _frames(2)
	_check("it makes an automation clip", App.project.clips.size() == before + 1,
			"%d clips, was %d" % [App.project.clips.size(), before])
	if App.project.clips.is_empty():
		return
	var clip: Dictionary = App.project.clips[App.project.clips.size() - 1]
	var lane: Dictionary = App.project.automations[int(clip.index)]
	_check("the clip drives the control that was moved",
			int(clip.type) == Cd.ClipType.AUTOMATION and int(lane.target) == Cd.AutoTarget.PLUGIN
			and int(lane.b) == idx, "target %d parameter %d" % [int(lane.target), int(lane.b)])

	# Several controls, then clips for all of them at once.
	App.set_plugin_param(ref, int(params[1].index), lerpf(float(params[1].min), float(params[1].max), 0.6))
	App.set_mixer_prop(1, "vol", 0.55)
	await _frames(2)
	_check("more than one is remembered", App.last_tweaked.size() >= 3,
			"%d remembered" % App.last_tweaked.size())
	var before2 := App.project.clips.size()
	var wanted: int = App.last_tweaked.size()
	bar._tweak_command(1)
	await _frames(2)
	_check("clips can be made for all of them at once",
			App.project.clips.size() == before2 + wanted,
			"%d clips, was %d, expected %d more" % [App.project.clips.size(), before2, wanted])
	# And the same control twice running does not fill the list with copies.
	App.set_plugin_param(ref, idx, lerpf(float(first.min), float(first.max), 0.7))
	App.set_plugin_param(ref, idx, lerpf(float(first.min), float(first.max), 0.8))
	await _frames(2)
	var keys := {}
	for e in App.last_tweaked:
		keys[String(e.key)] = true
	_check("the list holds each control once", keys.size() == App.last_tweaked.size(),
			"%d entries, %d distinct" % [App.last_tweaked.size(), keys.size()])


## Add-ons, and the FL importer that ships as one.
## A plugin that falls over the moment it is opened must not take Cadmium with
## it. The new ones are opened in a process of their own for exactly this, and
## the crashing probe next to the others is what proves it.
func _bad_plugins() -> void:
	print("--- plugins that will not open")
	var crash := Cd.home_dir().path_join(".vst3/CdProbeCrash.vst3")
	var good := Cd.home_dir().path_join(".vst3/CdProbe.vst3")
	if not DirAccess.dir_exists_absolute(crash) or not DirAccess.dir_exists_absolute(good):
		print("  --    no crashing probe installed to try it with")
		return
	var before: Dictionary = Plugins._broken()
	var broken := before.duplicate()
	var report: Dictionary = await Plugins._probe_apart([crash, good], broken)
	_check("Cadmium is still here after opening a plugin that crashes", true)
	# Dealt with, either way round: on a machine where that probe is not a
	# plugin at all it is refused rather than crashing, and either answer is
	# the program staying up and saying which one it was.
	var blamed := broken.has(crash)
	for e in report.trouble:
		if String(e.get("path", "")) == crash:
			blamed = true
	_check("the one that would not open is named", blamed,
			"%d known bad, %d refused" % [broken.size(), (report.trouble as Array).size()])
	var kept := false
	for e in report.found:
		if String(e.get("path", "")) == good:
			kept = true
	_check("and the ones after it are still read", kept,
			"%d read, %d refused" % [(report.found as Array).size(),
					(report.trouble as Array).size()])
	# And it is not offered to the program afterwards: a plugin that has taken
	# the program down once is refused rather than tried again.
	_check("and it is refused if something asks for it again", Plugins.is_broken(crash),
			Plugins.broken_reason(crash))
	var plug := CdProject.plugin_dict("vst3", "0000", crash, "Crashing probe")
	App.project.channels.clear()
	App.channel_handles.clear()
	App.project.add_channel("Crashing probe", plug, 1)
	App.sync_all()
	await _frames(3)
	_check("so a project that asks for it opens without it rather than not at all",
			App.handle_for({"kind": "channel", "index": 0}) < 0,
			"handle %d" % App.handle_for({"kind": "channel", "index": 0}))
	App.new_project()
	await _frames(2)
	# The list is the user's, not the test's.
	Plugins._set_broken(before)


## The report a crash leaves. Made to happen on purpose, in a process of its
## own, and then read back: a report that is never checked is a report that
## quietly stopped being written two months ago.
func _crash_reports() -> void:
	print("--- crash reports")
	var before: int = CdCrash.list().size()
	var exe := OS.get_executable_path()
	var args := PackedStringArray()
	if OS.has_feature("editor") or exe.get_file().to_lower().begins_with("godot"):
		args.append_array(["--path", ProjectSettings.globalize_path("res://")])
	args.append_array(["--headless", "--audio-driver", "Dummy", "--", "--cd-crashtest"])
	var pid := OS.create_process(exe, args)
	if pid <= 0:
		print("  --    nothing here can start a second copy to crash")
		return
	var deadline := Time.get_ticks_msec() + 60000
	while OS.is_process_running(pid) and Time.get_ticks_msec() < deadline:
		await _frames(4)
	await _frames(10)
	var reports := CdCrash.list()
	_check("a crash leaves a report behind", reports.size() > before,
			"%d reports, was %d" % [reports.size(), before])
	if reports.is_empty():
		return
	var text := CdCrash.read(String(reports[0].path))
	_check("which says what was being done at the time",
			text.contains("--cd-crashtest"), CdCrash.doing(String(reports[0].path)))
	_check("and how it stopped", text.contains("reason"))
	_check("and where it was", text.length() > 200, "%d bytes" % text.length())
	# Opened from the Help menu rather than from a folder nobody can find.
	var dlg = preload("res://ui/dialogs/crash_dialog.tscn").instantiate()
	main.add_child(dlg)
	await _frames(4)
	_check("the reports can be read from inside Cadmium", dlg._list.item_count == reports.size(),
			"%d listed" % dlg._list.item_count)
	_check("with the report itself shown", dlg._text.text.contains("stopped unexpectedly"))
	dlg.queue_free()
	CdCrash.remove(String(reports[0].path))
	await _frames(2)

	# A plugin that falls over while the scan is opening it takes a process
	# that exists to be taken down. The report is kept, because it says which
	# plugin and how far it got, but the next start must not announce it as
	# Cadmium having crashed: nothing of anybody's was lost.
	var scan_report := CdCrash.dir().path_join("%s-2999-01-01_00-00-00.log" % CdCrash.SCAN_PREFIX)
	var f := FileAccess.open(scan_report, FileAccess.WRITE)
	if f != null:
		f.store_string("Cadmium stopped unexpectedly\nversion   test\nreason    test\n"
				+ "doing     opening the plugin Nothing.vst3 -- creating it\n")
		f.close()
		Settings.set_value("last_run_unix", 0)
		var listed := CdCrash.list()
		var mine := listed.filter(func(r): return String(r.path) == scan_report)
		_check("a report from the scan is kept", mine.size() == 1)
		_check("and marked as the scan's", mine.size() == 1 and bool(mine[0].get("scan", false)))
		_check("but never announced as Cadmium falling over",
				CdCrash.since_last_run().filter(
						func(r): return String(r.path) == scan_report).is_empty())
		CdCrash.remove(scan_report)

	# The scan starts copies of Cadmium. A copy that scanned would start copies
	# that scanned, and each of those would start more -- a machine filling up
	# with Cadmium until it runs out of memory, which is exactly what happened.
	# Nothing started to do a job scans of its own accord, and the one whose job
	# is scanning never starts another copy at all.
	_check("a copy of Cadmium started to do a job knows it", Plugins._is_a_job())
	_check("and the one whose job is scanning knows that",
			Plugins._is_a_scan(PackedStringArray(["--cd-vstscan=in,out"])))
	_check("a test run is a job but not a scan",
			Plugins._is_a_job(PackedStringArray(["--cd-uitest"]))
			and not Plugins._is_a_scan(PackedStringArray(["--cd-uitest"])))
	_check("and being used normally is neither",
			not Plugins._is_a_job(PackedStringArray([])))

	# A library written down by a version that never opened anything is opened
	# again once, in a process of its own. Without this, a plugin that crashes
	# on the way up sat in the cache marked perfectly fine for ever.
	var kept: Array = Plugins.vst3.duplicate(true)
	Plugins.vst3 = [{"path": "/nowhere/Old.vst3", "cid": "0", "name": "Old", "stamp": "1"}]
	_check("a plugin nothing has ever opened is counted as unchecked",
			Plugins._unchecked() == 1, "%d unchecked" % Plugins._unchecked())
	Plugins.vst3[0]["probed"] = Plugins.PROBE_MARK
	_check("and is left alone once it has been", Plugins._unchecked() == 0)
	Plugins.vst3 = kept
	await _frames(2)

## The add-on system with nothing installed. Cadmium shipped an FL Studio
## importer once; it was not good enough to keep, and what is worth checking now
## is that taking the only add-on away leaves the machinery standing rather than
## a panel full of errors.
func _addons() -> void:
	print("--- add-ons")
	Addons.reload()
	await _frames(2)
	_check("the add-ons folder is read with none installed", Addons.list.is_empty(),
			"%d found" % Addons.list.size())
	_check("and nothing offers an action", Addons.actions().is_empty(),
			"%d actions" % Addons.actions().size())
	# Asking for one that is not there has to be a no-op rather than a crash:
	# a saved preference can still name an add-on that has since been removed.
	Addons.run("fl_import", "open", main)
	Addons.set_enabled("fl_import", false)
	await _frames(2)
	_check("and asking for one that is gone does nothing at all", Addons.list.is_empty())




## Changing the interface's colours has to change all of it, at once, and not
## cost a second of the program standing still while it happens.
func _theme_colours() -> void:
	print("--- colours")
	var theme: Theme = ThemeDB.get_project_theme()
	# A control given a tightened copy of a theme style is the case that used
	# to need a restart: its copy kept the colours it was made with.
	var probe := Button.new()
	probe.text = "probe"
	main.add_child(probe)
	await _frames(2)
	Cd.compact(probe, "Button", 4.0)
	await _frames(2)

	var t0 := Time.get_ticks_usec()
	Secondary.apply(Color("#3d444d"), false)
	var secs := float(Time.get_ticks_usec() - t0) / 1000.0
	_check("changing the secondary colour is quick", secs < 150.0, "%.1f ms" % secs)
	t0 = Time.get_ticks_usec()
	Accent.apply(Color("#4a90d9"), false)
	var acc := float(Time.get_ticks_usec() - t0) / 1000.0
	_check("and so is the primary", acc < 150.0, "%.1f ms" % acc)

	var worn: StyleBox = probe.get_theme_stylebox("normal")
	var wanted: StyleBox = theme.get_stylebox("normal", "Button")
	var same := true
	if worn is StyleBoxTexture and wanted is StyleBoxTexture:
		same = (worn as StyleBoxTexture).modulate_color.is_equal_approx(
				(wanted as StyleBoxTexture).modulate_color)
	elif worn is StyleBoxFlat and wanted is StyleBoxFlat:
		same = (worn as StyleBoxFlat).bg_color.is_equal_approx((wanted as StyleBoxFlat).bg_color)
	_check("a control with a tightened style follows the change", same,
			"worn %s, theme %s" % [str(worn.get_class()), str(wanted.get_class())])
	_check("the palette moved with it", not CdPalette.PANEL.is_equal_approx(CdPalette.PANEL_BASE),
			str(CdPalette.PANEL))
	_check("and the icons' neutral ink with it",
			not CdPalette.INK_MID.is_equal_approx(CdPalette.INK_MID_BASE), str(CdPalette.INK_MID))

	Accent.apply(CdPalette.ACCENT_DEFAULT, false)
	Secondary.apply(CdPalette.SECONDARY_DEFAULT, false)
	await _frames(2)
	_check("and back again", CdPalette.PANEL.is_equal_approx(CdPalette.PANEL_BASE),
			str(CdPalette.PANEL))
	probe.queue_free()
	await _frames(2)


## Every window of Cadmium's own has to have something between its content and
## its frame. They all used to use the docked-panel style, which has none,
## because a docked panel sits against its neighbours on purpose.
func _dialogs() -> void:
	print("--- dialogs")
	var theme: Theme = load("res://themes/cadmium_theme.tres")
	var sb: StyleBox = theme.get_stylebox("panel", "Dialog") if theme != null else null
	_check("the dialog panel style has room at the sides", sb != null
			and sb.content_margin_left >= 6.0 and sb.content_margin_right >= 6.0
			and sb.content_margin_top >= 6.0 and sb.content_margin_bottom >= 6.0,
			"margins %.0f/%.0f/%.0f/%.0f" % [sb.content_margin_left if sb else 0.0,
					sb.content_margin_right if sb else 0.0, sb.content_margin_top if sb else 0.0,
					sb.content_margin_bottom if sb else 0.0])
	var d := DirAccess.open("res://ui/dialogs")
	var checked := 0
	var flush: Array = []
	for name in (d.get_files() if d != null else []):
		if not name.ends_with(".tscn"):
			continue
		var text := FileAccess.get_file_as_string("res://ui/dialogs/" + name)
		if not text.contains("type=\"Window\""):
			continue
		checked += 1
		if not text.contains("theme_type_variation = &\"Dialog\""):
			flush.append(name)
	_check("every dialog uses it", checked > 0 and flush.is_empty(),
			"%d windows, flush: %s" % [checked, ", ".join(flush) if not flush.is_empty() else "none"])


## Comparing versions, which is the whole of whether an update is offered.
## Getting this wrong in either direction is bad: too eager and it offers a
## downgrade, too shy and nobody ever hears about a release.
func _versions() -> void:
	print("--- versions")
	var cases := [
		["2026.09.20", "2026.09.20", 0],
		["2026.09.12", "2026.09.20", -1],
		["2026.09.20", "2026.09.12", 1],
		# Date parts are numbers, not text: 9 is before 10, and 2 before 12.
		["2026.09.20", "2026.10.01", -1],
		["2026.09.02", "2026.09.12", -1],
		["1.2.0", "1.10.0", -1],
		# A leading v and a missing tail are both the same version.
		["v2026.09.20", "2026.09.20", 0],
		["2026.09", "2026.09.0", 0],
		# A release candidate is older than the release it is for.
		["2026.09.20-rc1", "2026.09.20", -1],
	]
	var bad := []
	for c in cases:
		var got: int = CdUpdate.compare(String(c[0]), String(c[1]))
		if got != int(c[2]):
			bad.append("%s vs %s gave %d, wanted %d" % [c[0], c[1], got, c[2]])
	_check("versions compare the way a person reads them", bad.is_empty(),
			"%d cases%s" % [cases.size(), "" if bad.is_empty() else ": " + ", ".join(bad)])
	# Running from source is not something to offer an update for.
	var where: Dictionary = CdUpdate.installation()
	_check("a source build knows it is one", int(where.kind) == CdUpdate.Kind.SOURCE,
			"kind %d" % int(where.kind))
	_check("and it reports the version the repository records",
			not CdUpdate.current().is_empty(), CdUpdate.current())


## Help ▸ Check for Updates opens, says what it is doing, and does not offer to
## replace a source build. It really does ask github.com -- there is no point
## testing a check against something that is not the thing being checked.
func _update_window() -> void:
	print("--- check for updates")
	main._on_command("updates")
	await _frames(10)
	var dlg: Window = null
	for c in main.get_children():
		if c is Window and c.get_node_or_null("Root/Col/State") != null:
			dlg = c
	_check("the update window opens", dlg != null)
	if dlg == null:
		return
	var state: Label = dlg.get_node("Root/Col/State")
	_check("and says it is asking", not state.text.is_empty(), state.text)
	# Up to twelve seconds for a round trip, then give up rather than hang the
	# suite on somebody else's network.
	var waited := 0
	while state.text.begins_with("Asking") and waited < 720:
		await _frames(1)
		waited += 1
	_check("and comes back with an answer", not state.text.begins_with("Asking"),
			state.text.left(70))
	var action: Button = dlg.get_node("Root/Col/Row/Action")
	_check("a source build is never offered a download",
			not action.visible or action.text != "Download and install",
			"button: %s" % ("hidden" if not action.visible else action.text))
	dlg.queue_free()
	await _frames(4)


## Every page of Preferences has to have something on it.
##
## A TabContainer stores every page but the open one hidden, and the dialog
## moves each page into a scroll container of its own after it is built -- so
## the page stops being the tab's own child and nothing turns it visible again.
## Four of the five pages came up as empty rectangles, and the one for choosing
## where VST3 plugins live was among them. Nothing about that looks like a
## fault from the code: the nodes are all there, correctly filled in, and off
## the screen.
func _preferences() -> void:
	print("--- preferences")
	main._on_command("settings")
	await _frames(12)
	var dlg: Window = null
	for w in tree.root.get_children():
		if w is Window and String(w.title).to_lower().contains("preference"):
			dlg = w
	if dlg == null:
		for c in main.get_children():
			if c is Window and c.get_node_or_null("Root/Tabs") != null:
				dlg = c
	_check("Preferences opens", dlg != null)
	if dlg == null:
		return
	var tabs: TabContainer = dlg.get_node("Root/Tabs")
	_check("it has the five pages", tabs.get_tab_count() == 5,
			"%d tabs" % tabs.get_tab_count())
	for i in tabs.get_tab_count():
		tabs.current_tab = i
		await _frames(4)
		var page: Control = tabs.get_tab_control(i)
		# Past the scroll the dialog wraps each page in, to the page itself.
		var body: Control = page
		if page is ScrollContainer and page.get_child_count() > 0:
			body = page.get_child(0)
		var shown := 0
		for c in body.get_children():
			if c is Control and (c as Control).visible:
				shown += 1
		_check("%s has something on it" % tabs.get_tab_title(i),
				body.visible and shown > 0 and body.size.y > 8.0,
				"%d visible rows, %.0f px tall" % [shown, body.size.y])
	# The Folders page is the only way to point Cadmium at a plugin folder it
	# does not search by itself, so it gets a second look -- with that page
	# open, since a page on a tab nobody is looking at is hidden on purpose.
	tabs.current_tab = 3
	await _frames(4)
	var folders: Control = tabs.get_tab_control(3)
	var vst3 = folders.find_child("Vst3", true, false)
	_check("the VST3 folder list is there and visible",
			vst3 != null and vst3.is_visible_in_tree())
	if vst3 != null:
		_check("with buttons to add and remove one",
				vst3.get_node_or_null("Col/Row/Add") != null
				and vst3.get_node_or_null("Col/Row/Remove") != null)
		# And adding one has to reach the scanner, not just the list.
		var was: Array = (vst3.folders() as Array).duplicate()
		var mine := "/tmp/cadmium-uitest-vst3"
		vst3.add_folder(mine)
		await _frames(2)
		_check("a folder added here is one the scan will look in",
				Array(Plugins.vst3_dirs()).has(mine),
				"%d folders" % Plugins.vst3_dirs().size())
		vst3.remove_folder(mine)
		await _frames(2)
		_check("and taking it off puts it back as it was",
				not Array(Plugins.vst3_dirs()).has(mine)
				and (vst3.folders() as Array).size() == was.size())
	dlg.queue_free()
	await _frames(4)


## "Search all plugins..." at the bottom of the effect drop-down has to bring
## up the big searchable panel. It is the way out of a menu that is the wrong
## shape for the question, so a menu entry that does nothing is worse than not
## having it.
func _picker() -> void:
	print("--- plugin picker")
	CdPluginMenu._pick(main, true, [], CdPluginMenu.SEARCH_ID, func(_p): pass)
	await _frames(10)
	var found: Window = null
	for w in tree.root.get_children():
		if w is CdPluginPicker:
			found = w
	_check("searching all plugins opens the panel", found != null)
	if found == null:
		return
	_check("and it is actually up", found.visible and found.size.x > 300 and found.size.y > 200,
			"%s at %s" % [str(found.size), str(found.position)])
	_check("with something in it to pick", found._list.item_count > 0,
			"%d listed" % found._list.item_count)
	found.queue_free()
	await _frames(2)

	# And through the drop-down itself, which is how anyone actually reaches
	# it: the menu is built, the entry is chosen, the menu closes underneath.
	var picked := []
	# No frame between building it and choosing from it: a popup with nobody
	# holding the mouse hides itself, and hiding is what frees it.
	var menu: PopupMenu = CdPluginMenu.open(main, true, func(p): picked.append(p))
	var search_at := -1
	for i in menu.item_count:
		if menu.get_item_id(i) == CdPluginMenu.SEARCH_ID:
			search_at = i
	_check("the drop-down offers searching all plugins", search_at >= 0)
	if search_at >= 0:
		menu.id_pressed.emit(CdPluginMenu.SEARCH_ID)
		menu.hide()
		await _frames(10)
		var panel: Window = null
		for w in tree.root.get_children():
			if w is CdPluginPicker:
				panel = w
		_check("choosing it from the drop-down opens the panel", panel != null)
		if panel != null:
			_check("in front, where it can be seen",
					panel.visible and panel._list.item_count > 0,
					"%d listed" % panel._list.item_count)
			# And on the screen. A panel is sized in scaled units and can come
			# out bigger than the display, and one placed half off the edge
			# reads as one that never opened.
			var usable := DisplayServer.screen_get_usable_rect(
					DisplayServer.window_get_current_screen(main.get_window().get_window_id()))
			var rect := Rect2i(panel.position, panel.size)
			_check("and inside the screen", usable.encloses(rect),
					"%s in %s" % [str(rect), str(usable)])
			panel.queue_free()
	if is_instance_valid(menu):
		menu.queue_free()
	await _frames(2)


func _piano_roll() -> void:
	print("--- piano roll")
	main.get_window().size = Vector2i(1600, 1000)
	App.new_project()
	await _frames(2)
	App.add_stock_channel("cd.ember")
	main.tabs.current_tab = 1
	App.snap = "1/16"
	await _frames(6)
	var piano = main.piano
	var g: Rect2 = piano._grid_rect()
	# Most of a piano roll is the part you edit in: the strips along the top and
	# the lane along the bottom must not crowd the grid out between them.
	_check("the piano roll has room to edit in",
			g.size.x > 200.0 and g.size.y > 60.0 and g.size.y > piano.size.y * 0.3,
			"grid %s of panel %s" % [str(g.size), str(piano.size)])

	# Place the note where the view already is, rather than moving the view to
	# the note: that keeps the test about editing and not about scrolling.
	var key: int = piano._y_to_key(g.position.y + g.size.y * 0.5)
	var beat: float = maxf(0.0, snappedf(piano._x_to_beat(g.position.x + 60.0), 0.25))
	var idx: int = App.add_note(App.current_pattern, 0, beat, 1.0, key, 0.8)
	App.note_edit_done(App.current_pattern)
	await _frames(2)

	var r: Rect2 = piano._note_rect(piano._notes()[idx])
	_check("the note is on screen", g.intersects(r), "note %s in grid %s" % [str(r), str(g)])

	# --- drag the right-hand edge to make it longer
	var edge := Vector2(r.end.x - 2.0, r.position.y + r.size.y * 0.5)
	_press(piano, edge)
	_check("pressing the right edge starts a resize", piano._drag_mode == "resize",
			"drag mode is \"%s\"" % piano._drag_mode)
	var target := Vector2(edge.x + 2.0 * piano.px_per_beat, edge.y)
	_move(piano, edge, target)
	_release(piano, target)
	var after: float = float(piano._notes()[idx].len)
	_check("dragging the edge changes the length", absf(after - 3.0) < 0.3,
			"length %.2f, expected about 3" % after)

	# --- and shorter again
	var r2: Rect2 = piano._note_rect(piano._notes()[idx])
	var edge2 := Vector2(r2.end.x - 2.0, r2.position.y + r2.size.y * 0.5)
	_press(piano, edge2)
	var target2 := Vector2(edge2.x - 1.5 * piano.px_per_beat, edge2.y)
	_move(piano, edge2, target2)
	_release(piano, target2)
	var after2: float = float(piano._notes()[idx].len)
	_check("dragging it back makes it shorter", after2 < after - 0.5,
			"length %.2f, was %.2f" % [after2, after])

	# --- the middle of a note moves it instead
	var r3: Rect2 = piano._note_rect(piano._notes()[idx])
	var mid := Vector2(r3.position.x + 4.0, r3.position.y + r3.size.y * 0.5)
	var beat_before: float = float(piano._notes()[idx].beat)
	_press(piano, mid)
	_check("pressing the middle starts a move", piano._drag_mode == "move",
			"drag mode is \"%s\"" % piano._drag_mode)
	var moved := Vector2(mid.x + piano.px_per_beat, mid.y)
	_move(piano, mid, moved)
	_release(piano, moved)
	_check("dragging the middle moves the note",
			absf(float(piano._notes()[idx].beat) - (beat_before + 1.0)) < 0.3,
			"beat %.2f, was %.2f" % [float(piano._notes()[idx].beat), beat_before])

	# --- drawing a new note and dragging its length out in one gesture
	var before_count: int = piano._notes().size()
	var blank := Vector2(g.position.x + g.size.x * 0.6, g.position.y + g.size.y * 0.25)
	_press(piano, blank)
	_check("drawing on empty grid adds a note", piano._notes().size() == before_count + 1,
			"%d notes" % piano._notes().size())
	_check("a freshly drawn note is still being drawn", piano._drag_mode == "draw",
			"drag mode is \"%s\"" % piano._drag_mode)
	# Down two rows as well as out two beats: the same gesture sets the pitch,
	# which is what stopped a note landing on the wrong key being a do-over.
	var drawn_key_before: int = int(piano._notes()[piano._notes().size() - 1].key)
	var drawn_beat_before: float = float(piano._notes()[piano._notes().size() - 1].beat)
	var drawn_len_before: float = float(piano._notes()[piano._notes().size() - 1].len)
	var drawn_to := Vector2(blank.x + 2.0 * piano.px_per_beat, blank.y + 2.0 * piano.row_h)
	_move(piano, blank, drawn_to)
	_check("dragging a drawn note down moves it down",
			int(piano._notes()[piano._notes().size() - 1].key) == drawn_key_before - 2,
			"key %d, was %d" % [int(piano._notes()[piano._notes().size() - 1].key), drawn_key_before])
	_check("dragging a drawn note along moves it along",
			float(piano._notes()[piano._notes().size() - 1].beat) > drawn_beat_before + 1.5,
			"beat %.2f, was %.2f" % [float(piano._notes()[piano._notes().size() - 1].beat), drawn_beat_before])
	# Backwards has to work as well as forwards, and neither may resize it.
	var back_to := Vector2(blank.x - 1.0 * piano.px_per_beat, blank.y)
	_move(piano, drawn_to, back_to)
	_check("dragging a drawn note backwards moves it back",
			float(piano._notes()[piano._notes().size() - 1].beat) < drawn_beat_before,
			"beat %.2f, was %.2f" % [float(piano._notes()[piano._notes().size() - 1].beat), drawn_beat_before])
	_release(piano, back_to)
	var drawn: Dictionary = piano._notes()[piano._notes().size() - 1]
	_check("dragging a drawn note leaves its length alone",
			absf(float(drawn.len) - drawn_len_before) < 0.001,
			"length %.3f, was %.3f" % [float(drawn.len), drawn_len_before])

	# --- the velocity lane
	var vr: Rect2 = piano._vel_rect()
	if vr.size.y > 8.0:
		var nx: float = piano._note_rect(piano._notes()[idx]).position.x + 3.0
		var vp := Vector2(nx, vr.position.y + vr.size.y * 0.25)
		var vel_before: float = float(piano._notes()[idx].vel)
		_press(piano, vp)
		_move(piano, vp, Vector2(nx, vr.position.y + vr.size.y * 0.9))
		_release(piano, Vector2(nx, vr.position.y + vr.size.y * 0.9))
		_check("dragging in the velocity lane changes velocity",
				absf(float(piano._notes()[idx].vel) - vel_before) > 0.05,
				"%.2f, was %.2f" % [float(piano._notes()[idx].vel), vel_before])
		# The right button resets rather than silences.
		var want_default: float = clampf(float(Settings.get_value("velocity", 0.78)), 0.02, 1.0)
		_press(piano, vp, MOUSE_BUTTON_RIGHT)
		_release(piano, vp, MOUSE_BUTTON_RIGHT)
		_check("right-clicking the lane resets the note to the default",
				absf(float(piano._notes()[idx].vel) - want_default) < 0.001,
				"%.3f, wanted %.3f" % [float(piano._notes()[idx].vel), want_default])

		# --- the lane's control chooser
		var pan_control := -1
		for ci in piano.CONTROLS.size():
			if String(piano.CONTROLS[ci].id) == "pan":
				pan_control = ci
		_check("the lane offers note pan", pan_control >= 0)
		if pan_control >= 0:
			piano.control = pan_control
			var vel_kept: float = float(piano._notes()[idx].vel)
			var pan_before: float = float(piano._notes()[idx].get("pan", 0.0))
			var pp := Vector2(nx, vr.position.y + vr.size.y * 0.15)
			_press(piano, pp)
			_release(piano, pp)
			_check("the lane writes pan once pan is chosen",
					absf(float(piano._notes()[idx].get("pan", 0.0)) - pan_before) > 0.2,
					"%.2f, was %.2f" % [float(piano._notes()[idx].get("pan", 0.0)), pan_before])
			_check("choosing pan leaves velocity alone",
					absf(float(piano._notes()[idx].vel) - vel_kept) < 0.001,
					"%.3f" % float(piano._notes()[idx].vel))
			piano.control = 0


func _playlist() -> void:
	print("--- playlist")
	main.tabs.current_tab = 0
	var pl = main.playlist
	pl.size = Vector2(1200, 500)
	await _frames(2)
	var clip: int = App.add_clip(Cd.ClipType.PATTERN, App.current_pattern, 0, 0.0, 4.0)
	App.clip_edit_done()
	pl.scroll_beat = 0.0
	await _frames(3)
	if not pl.has_method("_clip_rect"):
		print("  --    the playlist has no clip geometry to test")
		return
	var r: Rect2 = pl._clip_rect(App.project.clips[clip])
	var edge := Vector2(r.end.x - 2.0, r.position.y + r.size.y * 0.5)
	_press(pl, edge)
	var target := Vector2(edge.x + 2.0 * pl.px_per_beat, edge.y)
	_move(pl, edge, target)
	_release(pl, target)
	var len_after: float = float(App.project.clips[clip].length)
	_check("dragging a clip's edge resizes it", len_after > 5.0,
			"length %.2f, was 4" % len_after)

	# Either end of a clip resizes it. The near end trims the head and takes
	# what is played with it, so the part still showing does not slide about.
	var head_clip: int = App.add_clip(Cd.ClipType.PATTERN, App.current_pattern, 1, 4.0, 4.0)
	App.clip_edit_done()
	await _frames(3)
	var hr: Rect2 = pl._clip_rect(App.project.clips[head_clip])
	var grab := Vector2(hr.position.x + 2.0, hr.position.y + hr.size.y * 0.5)
	_press(pl, grab)
	var to := Vector2(grab.x + 2.0 * pl.px_per_beat, grab.y)
	_move(pl, grab, to)
	_release(pl, to)
	var moved: Dictionary = App.project.clips[head_clip]
	_check("dragging a clip's near edge moves its start",
			absf(float(moved.start) - 6.0) < 0.26, "%.2f, was 4" % float(moved.start))
	_check("and takes the length with it",
			absf(float(moved.length) - 2.0) < 0.26, "%.2f, was 4" % float(moved.length))
	_check("and what it plays moves into it",
			absf(float(moved.get("offset", 0.0)) - 2.0) < 0.26,
			"%.2f" % float(moved.get("offset", 0.0)))
	App.remove_clips([head_clip])
	await _frames(2)

	# Whole patterns up or down.
	App.select_pattern(App.current_pattern)
	var keys_before := []
	for n in App.project.patterns[App.current_pattern].notes:
		keys_before.append(int(n.key))
	if keys_before.is_empty():
		App.add_note(App.current_pattern, 0, 0.0, 1.0, 60, 0.8)
		App.note_edit_done(App.current_pattern)
		keys_before = [60]
	var shifted: int = App.transpose_patterns([App.current_pattern], -2)
	await _frames(2)
	var keys_after := []
	for n in App.project.patterns[App.current_pattern].notes:
		keys_after.append(int(n.key))
	_check("a pattern can be moved by a number of semitones",
			shifted > 0 and keys_after[0] == keys_before[0] - 2,
			"%d -> %d" % [int(keys_before[0]), int(keys_after[0])])
	App.transpose_patterns([App.current_pattern], 2)
	await _frames(2)
	# And what "the ones I picked" means when the picking was done with clips.
	App.selected_clips = [clip]
	_check("and the arrangement's selection says which patterns those are",
			App.selected_pattern_indices() == [int(App.project.clips[clip].index)],
			str(App.selected_pattern_indices()))
	App.selected_clips = []
	# Notes at the very edge of the keyboard stay put rather than piling up.
	App.add_note(App.current_pattern, 0, 2.0, 1.0, 125, 0.8)
	App.note_edit_done(App.current_pattern)
	App.transpose_patterns([App.current_pattern], 12)
	await _frames(2)
	var top := 0
	for n in App.project.patterns[App.current_pattern].notes:
		top = maxi(top, int(n.key))
	_check("and a note that would fall off the end stays where it is", top == 125,
			"highest %d" % top)
	App.transpose_patterns([App.current_pattern], -12)
	await _frames(2)

	# The lane on its own, with room to draw in.
	var edit_lane: int = App.automate(Cd.AutoTarget.MIXER_PAN, {}, 2)
	var aw = CdAutomationWindow.open(main, edit_lane)
	await _frames(4)
	_check("an automation lane opens in an editor of its own", aw != null and aw.visible)
	var pts_before: int = App.project.automations[edit_lane].points.size()
	var body: Rect2 = aw._body()
	var spot := Vector2(body.position.x + body.size.x * 0.6, body.position.y + body.size.y * 0.3)
	var down := InputEventMouseButton.new()
	down.button_index = MOUSE_BUTTON_LEFT
	down.pressed = true
	down.position = spot
	aw._editor_input(down)
	var up := InputEventMouseButton.new()
	up.button_index = MOUSE_BUTTON_LEFT
	up.position = spot
	aw._editor_input(up)
	await _frames(2)
	_check("clicking the graph adds a point",
			App.project.automations[edit_lane].points.size() == pts_before + 1,
			"%d points, was %d" % [App.project.automations[edit_lane].points.size(), pts_before])
	# The graph can be got closer to: a lane is as long as the clips that play
	# it, which can be the whole song, while the shape in it is four bars.
	var whole: float = aw._span()
	var wheel := InputEventMouseButton.new()
	wheel.button_index = MOUSE_BUTTON_WHEEL_UP
	wheel.pressed = true
	wheel.position = Vector2(aw._body().position.x + aw._body().size.x * 0.5,
			aw._body().position.y + 10.0)
	aw._editor_input(wheel)
	aw._editor_input(wheel)
	await _frames(2)
	_check("the graph zooms in", aw._span() < whole * 0.8,
			"%.1f beats, was %.1f" % [aw._span(), whole])
	aw._bars = 0.0
	aw._from = 0.0

	# A lane can drive more than one control: one shape, one clip, several
	# things moving together.
	_check("a new lane drives one control", App.automation_links(edit_lane).size() == 1)
	var added: bool = App.add_automation_link(edit_lane, Cd.AutoTarget.MIXER_PAN, {}, 3, 0)
	await _frames(3)
	_check("and another can be added", added and App.automation_links(edit_lane).size() == 2,
			"%d links" % App.automation_links(edit_lane).size())
	_check("which the editor lists", aw._links.get_child_count() == 2,
			"%d rows" % aw._links.get_child_count())
	_check("and the same one twice is refused",
			not App.add_automation_link(edit_lane, Cd.AutoTarget.MIXER_PAN, {}, 3, 0))
	App.remove_automation_link(edit_lane, 1)
	await _frames(3)
	_check("and it can be taken off again", App.automation_links(edit_lane).size() == 1)
	App.add_automation_link(edit_lane, Cd.AutoTarget.MIXER_PAN, {}, 3, 0)
	await _frames(2)

	aw._mode.item_selected.emit(Cd.AutoMode.ADDITIVE)
	await _frames(2)
	_check("and a lane can add to what its control is set to instead of forcing it",
			int(App.project.automations[edit_lane].get("mode", 0)) == Cd.AutoMode.ADDITIVE
			and App.project.automations[edit_lane].has("base"),
			"mode %d" % int(App.project.automations[edit_lane].get("mode", 0)))
	aw._on.toggled.emit(false)
	await _frames(2)
	_check("and switched off it leaves its control alone",
			not bool(App.project.automations[edit_lane].get("on", true)))
	aw.queue_free()
	App.remove_automation(edit_lane)
	await _frames(2)

	# The piano roll edits a pattern on the pattern's own timeline, and in song
	# mode the playhead has to be mapped back onto it: a clip at bar nine plays
	# the pattern's first bar there.
	App.set_mode(Cd.Mode.SONG)
	Audio.stop()
	var far: int = App.add_clip(Cd.ClipType.PATTERN, App.current_pattern, 0, 32.0, 4.0)
	App.clip_edit_done()
	Audio.seek(33.0)
	await _frames(2)
	var roll = main.piano
	_check("the piano roll puts the playhead inside the pattern being played",
			absf(roll.playhead_beat() - 1.0) < 0.35,
			"%.2f, song beat %.2f" % [roll.playhead_beat(), Audio.position()])
	Audio.seek(20.0)
	await _frames(2)
	_check("and shows none while no clip of it is playing", roll.playhead_beat() < 0.0,
			"%.2f" % roll.playhead_beat())
	App.remove_clips([far])
	Audio.seek(0.0)
	await _frames(2)

	# An automated control says so, and follows what is driving it while the
	# song plays.
	main.tabs.current_tab = 2
	await _frames(3)
	var strip = main.mixer._strip_nodes.get(1)
	if strip != null:
		var fader = strip._fader
		_check("a control with nothing driving it is drawn plainly", not fader.automated)
		var vol_lane: int = App.automate(Cd.AutoTarget.MIXER_VOL, {}, 1)
		await _frames(3)
		_check("and lights up once something does", fader.automated, "lane %d" % vol_lane)
		App.project.automations[vol_lane].points = [
			{"beat": 0.0, "value": 0.2, "curve": 0.0},
			{"beat": 8.0, "value": 1.1, "curve": 0.0},
		]
		for c in App.project.clips:
			if int(c.type) == Cd.ClipType.AUTOMATION and int(c.index) == vol_lane:
				c["length"] = 8.0
		App.clip_edit_done()
		App.push_automation()
		App.set_mixer_prop(1, "vol", 0.2)
		App.set_mode(Cd.Mode.SONG)
		await _frames(2)
		var held: float = fader.gain
		Audio.seek(6.0)
		Audio.play(false)
		await _frames(20)
		_check("and follows it while the song plays", fader.gain > held + 0.1,
				"%.2f, was %.2f" % [fader.gain, held])
		Audio.stop()
		App.remove_automation(vol_lane)
		await _frames(3)
		_check("and goes back to plain when the lane is gone", not fader.automated)
	main.tabs.current_tab = 0
	await _frames(2)

	# A mixer control can be automated from anywhere it appears, and what comes
	# back is a lane and a clip of it on a track with room for it.
	var autos_before: int = App.project.automations.size()
	var lane: int = App.automate(Cd.AutoTarget.MIXER_PAN, {}, 1)
	_check("a mixer control can be automated", lane >= 0
			and App.project.automations.size() == autos_before + 1,
			"lane %d" % lane)
	var made := -1
	for i in App.project.clips.size():
		var c: Dictionary = App.project.clips[i]
		if int(c.type) == Cd.ClipType.AUTOMATION and int(c.index) == lane:
			made = i
	_check("and it arrives on the timeline", made >= 0)
	await _frames(3)

	# Clicking a clip picks up what it plays, and the next thing drawn is
	# another one of the same -- FL's way round.
	if made >= 0:
		var ar: Rect2 = pl._clip_rect(App.project.clips[made])
		var mid := ar.position + ar.size * 0.5
		_press(pl, mid)
		_release(pl, mid)
		_check("clicking a clip picks up what it plays",
				String(App.current_paint_item().kind) == "automation",
				String(App.current_paint_item().kind))
		var count := App.project.clips.size()
		var below := Vector2(ar.position.x + 20.0, ar.position.y + ar.size.y * 1.5)
		if pl._track_at(below.y) >= 0:
			_press(pl, below)
			_release(pl, below)
			var drawn := App.project.clips.size() > count
			_check("and drawing puts another one of those down", drawn
					and int(App.project.clips[App.project.clips.size() - 1].type)
						== Cd.ClipType.AUTOMATION,
					"%d clips, was %d" % [App.project.clips.size(), count])
		# Its near edge resizes rather than adding a point: the curve owns the
		# middle of an automation clip, but not its ends.
		var ar2: Rect2 = pl._clip_rect(App.project.clips[made])
		var start_was: float = float(App.project.clips[made].start)
		var near := Vector2(ar2.position.x + 2.0, ar2.position.y + ar2.size.y * 0.6)
		_press(pl, near)
		var near_to := Vector2(near.x + 2.0 * pl.px_per_beat, near.y)
		_move(pl, near, near_to)
		_release(pl, near_to)
		_check("an automation clip resizes from its near edge too",
				float(App.project.clips[made].start) > start_was + 0.5,
				"%.2f, was %.2f" % [float(App.project.clips[made].start), start_was])

		_press(pl, Vector2(pl._clip_rect(App.project.clips[clip]).position.x + 4.0,
				pl._clip_rect(App.project.clips[clip]).position.y + 6.0))
		_release(pl, Vector2(0, 0))
		_check("clicking a pattern clip goes back to painting patterns",
				String(App.current_paint_item().kind) == "pattern",
				String(App.current_paint_item().kind))


## Knobs and faders only tick while they are being dragged; that saves a lot of
## work in a panel with a hundred of them, and it must not cost a stuck drag.
func _controls() -> void:
	print("--- knobs and faders")
	var k := CdKnob.new()
	k.minimum = 0.0
	k.maximum = 1.0
	k.value = 0.5
	main.add_child(k)
	await _frames(2)
	_check("an idle knob does not tick", not k.is_processing())

	_press(k, Vector2(10, 10))
	_check("a knob being dragged does tick", k.is_processing())
	var before: float = k.value
	var m := InputEventMouseMotion.new()
	m.position = Vector2(10, -40)
	m.relative = Vector2(0, -50)
	k._gui_input(m)
	_check("dragging a knob changes its value", k.value > before + 0.02,
			"%.3f, was %.3f" % [k.value, before])
	_release(k, Vector2(10, -40))
	await _frames(2)
	_check("a released knob stops ticking", not k.is_processing())

	# A drag that ends outside the window never delivers its release.
	_press(k, Vector2(10, 10))
	k._dragging = true
	await _frames(3)
	_check("a drag abandoned outside the window is let go of", not k.is_processing())
	k.queue_free()

	# A fader is positional: the cap goes where you put the pointer, rather
	# than travelling by however far the mouse moved.
	var f := CdFader.new()
	f.gain = 1.0
	f.size = Vector2(22, 120)
	main.add_child(f)
	await _frames(2)
	var track: Rect2 = f._track()
	# Well away from the cap, which for unity gain sits near the top.
	var at := Vector2(11, track.position.y + track.size.y * 0.6)
	_press(f, at)
	_check("clicking the track puts the fader there",
			absf(Cd.gain_to_fader(f.gain) - 0.4) < 0.03,
			"travel %.3f, expected 0.40" % Cd.gain_to_fader(f.gain))
	var low := Vector2(11, track.position.y + track.size.y * 0.9)
	var m2 := InputEventMouseMotion.new()
	m2.position = low
	m2.relative = low - at
	f._gui_input(m2)
	_check("dragging the fader follows the pointer",
			absf(Cd.gain_to_fader(f.gain) - 0.1) < 0.03,
			"travel %.3f, expected 0.10" % Cd.gain_to_fader(f.gain))
	_release(f, low)
	f.queue_free()


## The typing keyboard has to keep playing when a window other than the main one
## is in front, which is what a plugin's own window is.
func _keys() -> void:
	print("--- typing keyboard from another window")
	App.new_project()
	await _frames(2)
	App.add_stock_channel("cd.ember")
	await _frames(3)
	var sub := Window.new()
	main.add_child(sub)
	sub.size = Vector2i(320, 200)
	sub.show()
	await _frames(3)

	var down := InputEventKey.new()
	down.keycode = KEY_Z
	down.physical_keycode = KEY_Z
	down.pressed = true
	Shortcuts.feed(down, sub.get_viewport())
	var lit: Array = await _sounding(true)
	_check("a key pressed in another window plays a note", not lit.is_empty(),
			"%d sounding" % lit.size())

	var up := InputEventKey.new()
	up.keycode = KEY_Z
	up.physical_keycode = KEY_Z
	up.pressed = false
	Shortcuts.feed(up, sub.get_viewport())
	var quiet: Array = await _sounding(false)
	_check("releasing it stops the note", quiet.is_empty(), "%d still sounding" % quiet.size())
	sub.queue_free()

	# The same thing through a plugin's own window, pushed in the way the
	# window system does it and with one of the plugin's own controls holding
	# the keyboard. This is the case that used to go quiet: the window only
	# looked at keys nothing else had wanted, and a focused button wants Space.
	main.open_plugin_window({"kind": "channel", "index": 0})
	await _frames(8)
	var win = null
	for w in main._plugin_windows.values():
		if is_instance_valid(w):
			win = w
	if win == null:
		_check("a plugin window opens", false)
		return
	# Something in the window holding the keyboard is the case that broke: a
	# focused button is offered every key before anything unhandled is, and it
	# takes Space for itself.
	var probe := Button.new()
	probe.text = "focus"
	probe.focus_mode = Control.FOCUS_ALL
	win.add_child(probe)
	await _frames(2)
	probe.grab_focus()
	await _frames(2)
	_check("a control in the plugin window has the keyboard", probe.has_focus())
	win.push_input(down)
	var held: Array = await _sounding(true)
	_check("a note key still plays with a plugin window in front", not held.is_empty(),
			"%d sounding" % held.size())
	win.push_input(up)
	var gone: Array = await _sounding(false)
	_check("and releasing it there stops the note", gone.is_empty(),
			"%d still sounding" % gone.size())

	var was_playing := Audio.playing()
	var space := InputEventKey.new()
	space.keycode = KEY_SPACE
	space.physical_keycode = KEY_SPACE
	space.pressed = true
	win.push_input(space)
	await _frames(3)
	_check("space starts and stops the transport from a plugin window",
			Audio.playing() != was_playing, "playing %s, was %s" % [Audio.playing(), was_playing])
	Audio.engine.stop()
	await _frames(2)

	# A text box in the window is allowed to swallow what is typed into it --
	# that is what it is for -- but clicking away from it has to give the
	# keyboard back, or the notes stay dead for as long as the window is open.
	var field: LineEdit = win._filter_field
	if field != null and field.is_visible_in_tree():
		field.grab_focus()
		win.push_input(down)
		await _frames(4)
		_check("a focused text box keeps what is typed into it",
				Audio.engine.active_notes(App.current_channel).is_empty())
		var click := InputEventMouseButton.new()
		click.button_index = MOUSE_BUTTON_LEFT
		click.pressed = true
		click.position = Vector2(win.size.x * 0.5, win.size.y - 6.0)
		win.push_input(click)
		await _frames(2)
		_check("clicking away from it gives the keyboard back",
				win.get_viewport().gui_get_focus_owner() != field)
		win.push_input(down)
		var again: Array = await _sounding(true)
		_check("and the note keys play again", not again.is_empty(), "%d sounding" % again.size())
		win.push_input(up)
		await _sounding(false)
	win.queue_free()
	await _frames(2)


## Waits for the engine to agree that something is or is not sounding. A note
## started this frame is not audible until the audio callback has run, and how
## long that takes is the device's business, not the test's.
func _sounding(want: bool, frames := 40) -> Array:
	var lit: Array = []
	for i in frames:
		lit = Audio.engine.active_notes(App.current_channel)
		if lit.is_empty() != want:
			return lit
		await tree.process_frame
	return lit


## The first thing inside a window that will take the keyboard, which is what
## clicking on a plugin's interface leaves behind. Text fields do not count:
## a focused box is meant to swallow what is typed into it.
func _focusable(node: Node) -> Control:
	for c in node.get_children():
		if c is Control and (c as Control).focus_mode != Control.FOCUS_NONE \
				and (c as Control).is_visible_in_tree() \
				and not (c is LineEdit or c is TextEdit or c is SpinBox):
			return c
		var deeper := _focusable(c)
		if deeper != null:
			return deeper
	return null


## Closing a project with unsaved work has to ask first, and a clean project has
## to close without a question nobody needs.
func _closing() -> void:
	print("--- closing a project")
	App.new_project()
	await _frames(2)
	App.project.dirty = false
	var went := [false]
	main._if_saved(func(): went[0] = true)
	await _frames(2)
	_check("a project with nothing to lose closes straight away", went[0])
	_check("and asks nothing", not main._asking)

	App.add_stock_channel("cd.ember")
	App.project.dirty = true
	var went2 := [false]
	main._if_saved(func(): went2[0] = true)
	await _frames(3)
	_check("a project with unsaved changes asks first", main._asking and not went2[0])

	# Discarding goes through with it; cancelling leaves everything alone.
	var dlg: ConfirmationDialog = null
	for c in main.get_children():
		if c is ConfirmationDialog:
			dlg = c
	_check("the question offers a way out", dlg != null and dlg.get_cancel_button() != null)
	if dlg != null:
		dlg.emit_signal("custom_action", "discard")
		await _frames(2)
		_check("discarding closes it", went2[0] and not main._asking)


## Formats, long files and the preview: the things that decide whether you can
## get your own audio into the program at all.
func _media() -> void:
	print("--- audio files")
	_check("the format list covers what people have",
			Cd.is_audio_file("x.mp3") and Cd.is_audio_file("x.flac") and Cd.is_audio_file("x.m4a")
			and Cd.is_audio_file("x.opus") and Cd.is_audio_file("x.wv") and Cd.is_audio_file("X.WAV"),
			"%d extensions" % Cd.AUDIO_EXTS.size())
	_check("and turns down what it cannot play", not Cd.is_audio_file("song.txt"))

	# A long file, written as a real WAV and loaded through the engine: this is
	# the path a full song takes, and the one that used to need the file twice
	# over in memory.
	var dir := OS.get_user_data_dir().path_join("uitest")
	DirAccess.make_dir_recursive_absolute(dir)
	var path := dir.path_join("long.wav")
	var rate := 48000
	var seconds := 120
	var frames := rate * seconds
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		print("  --    nowhere to write a test file")
		return
	var bytes := frames * 2 * 2
	f.store_buffer("RIFF".to_ascii_buffer())
	f.store_32(36 + bytes)
	f.store_buffer("WAVEfmt ".to_ascii_buffer())
	f.store_32(16)
	f.store_16(1)
	f.store_16(2)
	f.store_32(rate)
	f.store_32(rate * 4)
	f.store_16(4)
	f.store_16(16)
	f.store_buffer("data".to_ascii_buffer())
	f.store_32(bytes)
	# A slow sweep, so the overview has something to show.
	var chunk := PackedByteArray()
	chunk.resize(rate * 4)
	for s in frames:
		var v := int(sin(float(s) * 0.002) * 12000.0)
		var o := (s % rate) * 4
		chunk.encode_s16(o, v)
		chunk.encode_s16(o + 2, v)
		if (s % rate) == rate - 1:
			f.store_buffer(chunk)
	f.close()
	var size_mb := float(FileAccess.get_file_as_bytes(path).size()) / 1048576.0

	var idx: int = Audio.engine.register_audio(path)
	_check("a two-minute file loads", idx >= 0, "%.1f MB" % size_mb)

	App.new_project()
	await _frames(2)
	var ch: int = App.add_stock_channel("cd.sampler")
	await _frames(3)
	var ref := {"kind": "channel", "index": ch}
	App.set_plugin_string(ref, "sample", path)
	await _frames(3)
	var peaks: PackedFloat32Array = App.engine().plugin_aux(App.handle_for(ref), 0, 512)
	var ink := 0
	for i in peaks.size():
		if absf(peaks[i]) > 0.01:
			ink += 1
	_check("and draws an overview of the whole of it", peaks.size() == 512 and ink > 200,
			"%d of %d buckets have signal" % [ink, peaks.size()])
	_check("minutes and seconds read as minutes and seconds",
			Cd.format_seconds(222.4) == "3:42", Cd.format_seconds(222.4))


## An audio clip has to show its waveform, and playing from the middle of one
## has to play from there rather than waiting for the next clip.
func _audio_clips() -> void:
	print("--- audio clips")
	var dir := OS.get_user_data_dir().path_join("uitest")
	var path := dir.path_join("long.wav")
	if not FileAccess.file_exists(path):
		print("  --    no test file")
		return
	App.new_project()
	await _frames(2)
	var asset: int = App.add_audio_asset(path)
	_check("the file registers as an asset", asset >= 0)
	var peaks: PackedFloat32Array = App.engine().asset_peaks(asset, 256)
	var ink := 0
	for i in peaks.size():
		if absf(peaks[i]) > 0.01:
			ink += 1
	_check("a clip has a waveform to draw", peaks.size() == 512 and ink > 100,
			"%d of %d values carry signal" % [ink, peaks.size()])

	var length: float = App.asset_length_beats(path)
	App.add_clip(Cd.ClipType.AUDIO, asset, 0, 0.0, length, {"name": path.get_file()})
	App.clip_edit_done()
	App.set_mode(Cd.Mode.SONG)
	await _frames(2)
	# Half way in: silence here would mean the clip only starts if the playhead
	# rolls over its beginning.
	var mid := _render_song_at(length * 0.5)
	_check("playing from the middle of a clip plays from there", mid > 0.01,
			"peak %.3f at %.1f beats in" % [mid, length * 0.5])
	App.set_mode(Cd.Mode.PATTERN)

	# --- the waveform: built once per view, and rebuilt when the view changes.
	# It used to be one draw call per pixel of every clip, every frame, which is
	# what made a long .wav on the timeline drag the whole interface down.
	var pl = main.playlist
	main.tabs.current_tab = 0
	pl.size = Vector2(1200, 500)
	await _frames(3)
	var body := Rect2(Vector2(100, 40), Vector2(600, 60))
	var first: PackedVector2Array = pl._wave_lines(asset, 0.0, 1.0, body, 70.0)
	_check("the waveform builds line segments", first.size() >= 200,
			"%d points" % first.size())
	var t0 := Time.get_ticks_usec()
	for i in 30:
		pl._wave_lines(asset, 0.0, 1.0, body, 70.0)
	var cached_us := Time.get_ticks_usec() - t0
	_check("drawing it again costs almost nothing", cached_us < 30000,
			"%d us for thirty redraws" % cached_us)
	# How long the file is has to come from the engine, which is holding the
	# samples. It used to come from ffprobe -- a subprocess, per clip, per
	# frame -- and a timeline with a few long files on it ran at sixteen frames
	# a second because of it.
	var t1 := Time.get_ticks_usec()
	for i in 200:
		App.asset_length_beats_by_index(asset)
	var len_us := Time.get_ticks_usec() - t1
	_check("asking how long a clip is costs almost nothing", len_us < 20000,
			"%d us for two hundred asks" % len_us)
	# Zoomed into a twentieth of the file, the shape has to be a different one:
	# the same blocky overview stretched wider is what it used to show.
	var zoomed: PackedVector2Array = pl._wave_lines(asset, 0.30, 0.35, body, 70.0)
	var differs := zoomed.size() != first.size()
	if not differs:
		for i in mini(first.size(), zoomed.size()):
			if absf(first[i].y - zoomed[i].y) > 0.5:
				differs = true
				break
	_check("zooming in draws a different, closer waveform", differs,
			"%d points against %d" % [zoomed.size(), first.size()])

	# The waveform is read in tiles three screenfuls wide; drawing the whole
	# tile put it over the track headers and off the end of the panel. Checked
	# in pixels, because that is where it went wrong.
	main.tabs.current_tab = 0
	await _frames(3)
	pl.px_per_beat = 90.0
	pl.scroll_beat = maxf(0.0, length * 0.25)
	pl.queue_redraw()
	await _frames(4)
	var clip_i := -1
	for i in App.project.clips.size():
		if int(App.project.clips[i].type) == Cd.ClipType.AUDIO:
			clip_i = i
	if clip_i < 0:
		_check("there is an audio clip to look at", false)
		return
	var cr: Rect2 = pl._clip_rect(App.project.clips[clip_i])
	_check("the clip runs off the left of the view", cr.position.x < pl.HEAD_W,
			"clip starts at x %.0f, headers end at %.0f" % [cr.position.x, pl.HEAD_W])
	var shot: Image = pl.get_viewport().get_texture().get_image()
	var vp: Vector2 = Vector2(pl.get_viewport().size)
	var scale: float = float(shot.get_width()) / maxf(1.0, vp.x)
	var local_row: float = cr.position.y + cr.size.y * 0.5
	var at: Vector2 = pl.get_global_transform() * Vector2(0.0, local_row) * scale
	var row: int = clampi(int(at.y), 0, shot.get_height() - 1)
	var x0: int = clampi(int(at.x) + 6, 0, shot.get_width() - 1)
	var x1: int = clampi(int((pl.get_global_transform() * Vector2(pl.HEAD_W, local_row)).x * scale) - 3,
			x0, shot.get_width() - 1)
	var strays := 0
	for x in range(x0, x1):
		var col: Color = shot.get_pixel(x, row)
		# The waveform is nearly black; the header behind it is not.
		if col.r + col.g + col.b < 0.22:
			strays += 1
	_check("no waveform pixels land in the track headers", strays == 0,
			"%d dark pixels across %d of header on row %d" % [strays, x1 - x0, row])

	# And the same thing said in beats, which is the invariant the drawing has
	# to hold whatever the panel happens to look like: nothing outside the part
	# of the clip that is on screen.
	var vis_l: float = clampf((pl.HEAD_W - cr.position.x) / maxf(1.0, pl.px_per_beat),
			0.0, float(App.project.clips[clip_i].length))
	var span: Vector2 = pl.last_wave_span
	_check("the waveform is only drawn where the clip is visible",
			span.x >= vis_l - 0.001 and span.y > span.x,
			"drew %.2f..%.2f beats, visible from %.2f" % [span.x, span.y, vis_l])


## Renders a second of song from `beat` and returns the peak.
func _render_song_at(beat: float) -> float:
	var out := OS.get_user_data_dir().path_join("uitest").path_join("clipmid.wav")
	Audio.engine.set_mode(Cd.Mode.SONG)
	if not Audio.engine.render(out, beat, beat + 1.0, 0.1, 24, false):
		return 0.0
	var f := FileAccess.open(out, FileAccess.READ)
	if f == null:
		return 0.0
	var data := f.get_buffer(f.get_length())
	f.close()
	var peak := 0.0
	var i := 44
	while i + 2 < data.size():
		var v := data[i] | (data[i + 1] << 8) | (data[i + 2] << 16)
		if v & 0x800000:
			v -= 0x1000000
		peak = maxf(peak, absf(float(v) / 8388608.0))
		i += 3
	return peak


## Zoomed out, the ruler has to stop numbering every bar or it is a smear.
func _ruler() -> void:
	print("--- ruler")
	_check("close in, every bar is numbered", Cd.ruler_step(60.0, 4) == 1,
			"step %d at 60 px per beat" % Cd.ruler_step(60.0, 4))
	_check("further out it goes to twos and fives",
			Cd.ruler_step(12.0, 4) == 2 and Cd.ruler_step(4.0, 4) == 5,
			"%d then %d" % [Cd.ruler_step(12.0, 4), Cd.ruler_step(4.0, 4)])
	_check("right out, tens and hundreds",
			Cd.ruler_step(1.0, 4) == 20 and Cd.ruler_step(0.05, 4) == 500,
			"%d then %d" % [Cd.ruler_step(1.0, 4), Cd.ruler_step(0.05, 4)])
	_check("the first bar is always numbered",
			Cd.ruler_labels(1, 10) and Cd.ruler_labels(20, 10) and not Cd.ruler_labels(15, 10))
	# The labels have to stay far enough apart to read at every step on the
	# ladder, which is the whole point of choosing one.
	var worst := 999.0
	for ppb in [0.05, 0.2, 0.7, 2.5, 6.0, 15.0, 40.0, 120.0]:
		var step: int = Cd.ruler_step(ppb, 4)
		worst = minf(worst, float(step) * ppb * 4.0)
	_check("numbers never crowd each other", worst >= 50.0,
			"closest any two get is %.0f px" % worst)


## Every glyph has to sit in the middle of its own square. They are drawn by
## hand in a 24-unit box and several of them were well off -- undo and redo by
## a pixel and a half at the size they are actually used.
func _icons() -> void:
	print("--- icons")
	var worst_name := ""
	var worst := 0.0
	var checked := 0
	for name in CdIcons.names():
		var tex := CdIcons.render(String(name), CdPalette.ACCENT, 64)
		if tex == null:
			continue
		var img: Image = (tex as ImageTexture).get_image()
		var w := img.get_width()
		var h := img.get_height()
		var x0 := w
		var y0 := h
		var x1 := -1
		var y1 := -1
		for y in h:
			for x in w:
				if img.get_pixel(x, y).a > 0.06:
					x0 = mini(x0, x)
					x1 = maxi(x1, x)
					y0 = mini(y0, y)
					y1 = maxi(y1, y)
		if x1 < 0:
			continue
		checked += 1
		# Measured at 64 and reported at 16, the size they are drawn at.
		var dx: float = absf(float(w) * 0.5 - float(x0 + x1 + 1) * 0.5) / 4.0
		var dy: float = absf(float(h) * 0.5 - float(y0 + y1 + 1) * 0.5) / 4.0
		if dx + dy > worst:
			worst = dx + dy
			worst_name = String(name)
	_check("every icon is centred in its own square", checked > 40 and worst <= 0.5,
			"%d checked, worst is %s at %.2f px" % [checked, worst_name, worst])


## Every stock plugin gets a display of its own. A grid of knobs with nothing
## above it is the thing this is here to catch.
func _panels() -> void:
	print("--- plugin panels")
	var bare: Array = []
	var shown := 0
	for entry in Plugins.stock:
		var id := String(entry.id)
		var ref: Dictionary
		if bool(entry.get("instrument", false)):
			var ci: int = App.add_stock_channel(id)
			ref = {"kind": "channel", "index": ci}
		else:
			App.set_insert(1, 0, CdProject.plugin_dict("stock", id, "", id))
			App.mixer_changed.emit()
			ref = {"kind": "insert", "track": 1, "slot": 0}
		await _frames(2)
		main.open_plugin_window(ref)
		await _frames(3)
		var win = main._plugin_windows.get(JSON.stringify(ref))
		if win == null or not is_instance_valid(win):
			bare.append(id)
			continue
		# Either a panel built for this plugin, or -- for the plainest effects --
		# at least the display of its own output that every one of them gets.
		var has_custom: bool = win._custom != null
		var has_view := false
		for c in win._body.get_children():
			if c is CdScopeView or c is CdSynthView:
				has_view = true
		if has_custom or has_view:
			shown += 1
		else:
			bare.append(id)
		main._close_plugin_window(ref)
		await _frames(2)
	_check("every stock plugin has something to look at", bare.is_empty(),
			"%d plugins, missing: %s" % [shown, ", ".join(bare)] if not bare.is_empty()
			else "%d plugins" % shown)


## A file dragged from the desktop onto a loader lands in the plugin.
func _drops() -> void:
	print("--- dropping files in")
	var dir := OS.get_user_data_dir().path_join("uitest")
	DirAccess.make_dir_recursive_absolute(dir)

	# Something to drop: a short tone as a wav, and a small picture.
	var wav := dir.path_join("drop.wav")
	var f := FileAccess.open(wav, FileAccess.WRITE)
	if f == null:
		print("  --    nowhere to write a test file")
		return
	var frames := 4800
	var bytes := frames * 4
	f.store_buffer("RIFF".to_ascii_buffer())
	f.store_32(36 + bytes)
	f.store_buffer("WAVEfmt ".to_ascii_buffer())
	f.store_32(16)
	f.store_16(1)
	f.store_16(2)
	f.store_32(48000)
	f.store_32(48000 * 4)
	f.store_16(4)
	f.store_16(16)
	f.store_buffer("data".to_ascii_buffer())
	f.store_32(bytes)
	for i in frames:
		var v := int(sin(float(i) * 0.05) * 12000.0)
		f.store_16(v & 0xFFFF)
		f.store_16(v & 0xFFFF)
	f.close()

	var png := dir.path_join("drop.png")
	var img := Image.create(32, 32, false, Image.FORMAT_RGB8)
	img.fill(Color(0.8, 0.4, 0.2))
	img.save_png(png)

	for spec in [{"id": "cd.sampler", "file": wav, "key": "sample"},
			{"id": "cd.prism", "file": png, "key": "image"},
			{"id": "cd.space", "file": wav, "key": "ir"}]:
		var id := String(spec.id)
		var ref: Dictionary
		if id == "cd.space":
			App.set_insert(1, 0, CdProject.plugin_dict("stock", id, "", id))
			App.mixer_changed.emit()
			ref = {"kind": "insert", "track": 1, "slot": 0}
		else:
			var ci: int = App.add_stock_channel(id)
			ref = {"kind": "channel", "index": ci}
		await _frames(2)
		main.open_plugin_window(ref)
		await _frames(3)
		var win = main._plugin_windows.get(JSON.stringify(ref))
		var zone: CdDropZone = null
		for c in win._body.get_children():
			if c is CdDropZone:
				zone = c
		if zone == null:
			_check("%s takes a dropped file" % id, false, "no drop target on its panel")
			continue
		_check("%s says yes to the right kind of file" % id, zone.accepts(String(spec.file)))
		_check("%s turns down the wrong kind" % id, not zone.accepts("notes.txt"))
		# The window reports the drop; the panel works out it was over it. Here
		# the signal is raised directly, which is the same call the window makes.
		zone.dropped.emit(String(spec.file))
		await _frames(3)
		var plug = App.plugin_for(ref)
		var got := String(plug.get("strings", {}).get(String(spec.key), "")) if plug != null else ""
		_check("%s loaded what was dropped on it" % id, not got.is_empty(),
				got.get_file())
		main._close_plugin_window(ref)
		await _frames(2)


## The performance recorder: it has to write a file with the numbers in it,
## because the whole point is that somebody else can send that file back.
func _perf(m) -> void:
	m._on_command("perf_log")
	_check("the performance log starts", m._perf.running)
	for i in 12:
		await _frames(1)
	var path: String = m._perf.stop()
	_check("the performance log writes a file", FileAccess.file_exists(path), path.get_file())
	if not FileAccess.file_exists(path):
		return
	var f := FileAccess.open(path, FileAccess.READ)
	var parsed = JSON.parse_string(f.get_as_text())
	f.close()
	_check("the log is readable JSON", typeof(parsed) == TYPE_DICTIONARY)
	if typeof(parsed) != TYPE_DICTIONARY:
		return
	_check("the log names the machine", not String(parsed.get("machine", {}).get("cpu", "")).is_empty(),
			String(parsed.get("machine", {}).get("gpu", "")))
	_check("the log has frame samples", int((parsed.get("samples", []) as Array).size()) > 0,
			"%d samples" % (parsed.get("samples", []) as Array).size())
	_check("the log summarises the worst frame",
			parsed.get("summary", {}).has("worst_frame_ms"))


## Automation clips: the curve is edited on the clip itself, and a point cannot
## be dragged off into a part of the automation the clip is not showing -- which
## is where they used to disappear to.
func _automation() -> void:
	print("--- automation")
	main.tabs.current_tab = 0
	var pl = main.playlist
	pl.size = Vector2(1200, 500)
	pl.scroll_beat = 0.0
	await _frames(2)
	var ai: int = App.add_automation("test", Cd.AutoTarget.MIXER_VOL, {}, 1, 0, 0.0, 1.0)
	var ci: int = App.add_clip(Cd.ClipType.AUTOMATION, ai, 0, 0.0, 8.0)
	App.clip_edit_done()
	await _frames(3)
	var r: Rect2 = pl._clip_rect(App.project.clips[ci])
	if r.size.x < 40.0 or r.size.y < 30.0:
		_check("the automation clip has room to edit", false, str(r))
		return
	var body: Rect2 = pl._auto_body(r)
	var before: int = App.project.automations[ai].points.size()
	var at := Vector2(body.position.x + body.size.x * 0.4, body.get_center().y)
	_press(pl, at)
	_release(pl, at)
	var pts: Array = App.project.automations[ai].points
	_check("clicking an automation clip adds a point", pts.size() == before + 1,
			"%d points, was %d" % [pts.size(), before])
	if pts.is_empty():
		return

	# Dragged far past both ends: it has to stop at the edge of what is drawn.
	var far := Vector2(body.position.x - 900.0, body.position.y - 900.0)
	_press(pl, Vector2(pl._auto_point_pos(App.project.clips[ci], body, App.project.automations[ai].points[0])))
	_move(pl, at, far)
	_release(pl, far)
	var p0: Dictionary = App.project.automations[ai].points[0]
	var c0: Dictionary = App.project.clips[ci]
	var from := float(c0.get("offset", 0.0))
	_check("a point cannot be dragged off the front of the clip",
			float(p0.beat) >= from - 0.001 and float(p0.beat) <= from + float(c0.length) + 0.001,
			"beat %.3f in %.1f..%.1f" % [float(p0.beat), from, from + float(c0.length)])
	_check("a point cannot be dragged past the top of the lane",
			float(p0.value) <= 1.001 and float(p0.value) >= -0.001, "%.3f" % float(p0.value))
	var still: Vector2 = pl._auto_point_pos(c0, body, p0)
	_check("a dragged point is still somewhere the clip draws",
			body.grow(6.0).has_point(still), str(still))

	# And the right button takes it away again.
	var had: int = App.project.automations[ai].points.size()
	_press(pl, still, MOUSE_BUTTON_RIGHT)
	_release(pl, still, MOUSE_BUTTON_RIGHT)
	_check("right-clicking a point removes it",
			App.project.automations[ai].points.size() == had - 1,
			"%d points, was %d" % [App.project.automations[ai].points.size(), had])
	_check("the clip itself survives the point being removed",
			ci < App.project.clips.size() and int(App.project.clips[ci].type) == Cd.ClipType.AUTOMATION)


## Holding the right button down and dragging rubs out everything the pointer
## goes over -- notes, clips -- rather than only the one it landed on, and the
## whole sweep is one thing to undo.
func _erase_drag() -> void:
	print("--- rubbing out with the right button")
	App.new_project()
	await _frames(2)
	App.add_stock_channel("cd.ember")
	main.tabs.current_tab = 1
	await _frames(4)
	var piano = main.piano
	piano.size = Vector2(1200, 600)
	await _frames(2)
	var grid: Rect2 = piano._grid_rect()
	var key: int = piano._y_to_key(grid.position.y + grid.size.y * 0.5)
	for i in 5:
		App.add_note(App.current_pattern, App.current_channel, float(i), 0.9, key, 0.8)
	App.note_edit_done(App.current_pattern)
	piano.scroll_beat = 0.0
	await _frames(3)
	var made: int = (piano._notes() as Array).size()
	_check("five notes to rub out", made == 5, "%d notes" % made)

	var first: Rect2 = piano._note_rect(piano._notes()[0])
	var last: Rect2 = piano._note_rect(piano._notes()[4])
	var from := first.get_center()
	var to := last.get_center()
	_press(piano, from, MOUSE_BUTTON_RIGHT)
	_move(piano, from, to, 10)
	_release(piano, to, MOUSE_BUTTON_RIGHT)
	await _frames(2)
	var left: int = (piano._notes() as Array).size()
	_check("dragging the right button across them takes them all", left == 0,
			"%d left" % left)
	App.undo()
	await _frames(3)
	var back: int = (piano._notes() as Array).size()
	_check("and one undo brings the whole sweep back", back == 5, "%d back" % back)

	# The same gesture on the arrangement.
	main.tabs.current_tab = 0
	var pl = main.playlist
	pl.size = Vector2(1200, 500)
	pl.scroll_beat = 0.0
	await _frames(3)
	var clips := []
	for i in 4:
		clips.append(App.add_clip(Cd.ClipType.PATTERN, App.current_pattern, 0, float(i) * 4.0, 4.0))
	App.clip_edit_done()
	await _frames(3)
	var before: int = App.project.clips.size()
	var cfrom: Vector2 = pl._clip_rect(App.project.clips[clips[0]]).get_center()
	var cto: Vector2 = pl._clip_rect(App.project.clips[clips[3]]).get_center()
	_press(pl, cfrom, MOUSE_BUTTON_RIGHT)
	_move(pl, cfrom, cto, 10)
	_release(pl, cto, MOUSE_BUTTON_RIGHT)
	await _frames(2)
	_check("dragging it across the arrangement takes every clip it crosses",
			App.project.clips.is_empty(), "%d of %d left" % [App.project.clips.size(), before])
	App.undo()
	await _frames(3)
	_check("and one undo brings those back too", App.project.clips.size() == before,
			"%d back" % App.project.clips.size())


## An edit made while the transport runs is heard now, not on the next pass.
func _live_edits() -> void:
	print("--- editing while it plays")
	App.new_project()
	await _frames(2)
	App.add_stock_channel("cd.ember")
	await _frames(2)
	var ch: int = App.current_channel
	# A note long enough that the playhead is inside it wherever it stops.
	App.add_note(App.current_pattern, ch, 0.0, 8.0, 60, 0.8)
	App.note_edit_done(App.current_pattern)
	App.set_mode(Cd.Mode.SONG)
	await _frames(2)
	Audio.play(true)
	Audio.seek(2.0)
	await _frames(2)
	_check("nothing sounds with an empty arrangement",
			(Audio.engine.active_notes(ch) as Array).is_empty(),
			"%d sounding" % (Audio.engine.active_notes(ch) as Array).size())
	var clip: int = App.add_clip(Cd.ClipType.PATTERN, App.current_pattern, 0, 0.0, 16.0)
	App.clip_edit_done()
	await _frames(2)
	_check("a clip dropped over the playhead plays straight away",
			not (Audio.engine.active_notes(ch) as Array).is_empty(),
			"%d sounding" % (Audio.engine.active_notes(ch) as Array).size())

	# And the loop has to grow with the song, or nothing put past the old end
	# is ever reached.
	var end_before: float = Audio.engine.loop_end()
	App.add_clip(Cd.ClipType.PATTERN, App.current_pattern, 1, 32.0, 16.0)
	App.clip_edit_done()
	await _frames(2)
	_check("the loop grows with the arrangement", Audio.engine.loop_end() > end_before + 0.5,
			"%.1f, was %.1f" % [Audio.engine.loop_end(), end_before])
	Audio.stop()
	App.remove_clips([clip])
	await _frames(2)


## The piano roll draws a pattern on the pattern's own timeline, so the marker
## on its ruler belongs to the pattern -- not to the song. Dragging it used to
## send the arrangement to that many beats from the start, which for a pattern
## played by a clip at bar seventeen meant the marker you were dragging
## disappeared, because the pattern was no longer playing anywhere.
func _piano_ruler() -> void:
	print("--- the piano roll's ruler")
	App.new_project()
	await _frames(2)
	App.add_stock_channel("cd.ember")
	App.add_clip(Cd.ClipType.PATTERN, App.current_pattern, 0, 64.0, 16.0)
	App.clip_edit_done()
	App.set_mode(Cd.Mode.SONG)
	Audio.seek(66.0)
	main.tabs.current_tab = 1
	await _frames(4)
	var piano = main.piano
	piano.size = Vector2(1200, 600)
	piano.scroll_beat = 0.0
	await _frames(2)
	_check("the marker shows where the pattern is playing, not where the song is",
			absf(piano.playhead_beat() - 2.0) < 0.26, "%.2f" % piano.playhead_beat())
	var ruler_y: float = piano._ruler_rect().get_center().y
	var x: float = piano._beat_to_x(8.0)
	_press(piano, Vector2(x, ruler_y))
	_release(piano, Vector2(x, ruler_y))
	await _frames(4)
	_check("clicking its ruler moves the marker to where you pointed",
			absf(piano.playhead_beat() - 8.0) < 0.26, "%.2f" % piano.playhead_beat())
	_check("and the arrangement follows to where that is in the song",
			absf(Audio.position() - 72.0) < 0.26, "%.2f, expected 72" % Audio.position())

	# Dragging along the ruler keeps walking the same bar rather than jumping
	# back to the clip's first time round.
	var x2: float = piano._beat_to_x(12.0)
	_press(piano, Vector2(x, ruler_y))
	_move(piano, Vector2(x, ruler_y), Vector2(x2, ruler_y))
	_release(piano, Vector2(x2, ruler_y))
	await _frames(4)
	_check("dragging it stays inside the clip that is playing",
			absf(Audio.position() - 76.0) < 0.26, "%.2f, expected 76" % Audio.position())

	# And in pattern mode the ruler is simply the pattern's own beats.
	App.set_mode(Cd.Mode.PATTERN)
	await _frames(2)
	_press(piano, Vector2(x, ruler_y))
	_release(piano, Vector2(x, ruler_y))
	await _frames(4)
	_check("in pattern mode it is the pattern's own beat", absf(Audio.position() - 8.0) < 0.26,
			"%.2f, expected 8" % Audio.position())


## The piano roll's own menu: scores and MIDI in and out of the pattern being
## edited, and the things it can do to what is in it.
func _piano_menu() -> void:
	print("--- the piano roll's menu")
	App.new_project()
	await _frames(2)
	App.add_stock_channel("cd.ember")
	App.add_stock_channel("cd.pluck")
	App.project.channels[0]["name"] = "Pads"
	App.project.channels[1]["name"] = "Pluck"
	main.tabs.current_tab = 1
	await _frames(4)
	var piano = main.piano
	App.select_channel(0)
	App.add_note(App.current_pattern, 0, 0.0, 1.0, 60, 0.8)
	App.add_note(App.current_pattern, 0, 1.0, 1.0, 64, 0.7)
	App.add_note(App.current_pattern, 1, 2.0, 1.0, 72, 0.9)
	App.note_edit_done(App.current_pattern)
	await _frames(2)

	var root: PopupMenu = piano._menu_btn.get_popup()
	var titles := []
	for i in root.item_count:
		titles.append(root.get_item_text(i))
	_check("the menu is there, with a submenu each", titles.size() >= 8, str(titles))
	_check("and File is the first of them", titles.size() > 0 and String(titles[0]) == "File",
			str(titles.slice(0, 3)))
	var file_menu: PopupMenu = piano._menus.get("File")
	var items := []
	for i in file_menu.item_count:
		items.append(file_menu.get_item_text(i))
	var joined := " | ".join(items)
	_check("File offers scores and MIDI both ways",
			joined.contains("Open score") and joined.contains("Save score")
			and joined.contains("Import MIDI") and joined.contains("Export as MIDI")
			and joined.contains("MIDI clipboard"), joined)

	# What the menu fills in when it opens: the snap values, the rack, the lane.
	piano._refresh_menu()
	var chan_menu: PopupMenu = piano._menus.get("Target channel")
	_check("Target channel lists the rack",
			chan_menu.item_count == 2 and chan_menu.get_item_text(0) == "Pads",
			"%d item(s)" % chan_menu.item_count)
	piano._run("target:1")
	await _frames(2)
	_check("and picking one moves the piano roll to it", App.current_channel == 1,
			"channel %d" % App.current_channel)
	piano._run("snap:1/8")
	_check("Snap sets the snap", App.snap == "1/8", App.snap)
	App.select_channel(0)
	await _frames(2)

	# --- a score out to a file and back
	var dir := OS.get_user_data_dir().path_join("uitest")
	DirAccess.make_dir_recursive_absolute(dir)
	var score_file := dir.path_join("menu_score")
	main._save_score(score_file)
	await _frames(2)
	_check("Save score as writes a file",
			FileAccess.file_exists(score_file + "." + CdScore.EXT))
	var before: int = (App.project.patterns[App.current_pattern].notes as Array).size()
	App.remove_notes(App.current_pattern, [0, 1, 2])
	App.note_edit_done(App.current_pattern)
	await _frames(2)
	_check("the pattern can be emptied",
			(App.project.patterns[App.current_pattern].notes as Array).is_empty())
	main._open_score(score_file + "." + CdScore.EXT)
	await _frames(3)
	_check("Open score puts it back",
			(App.project.patterns[App.current_pattern].notes as Array).size() == before,
			"%d of %d notes" % [(App.project.patterns[App.current_pattern].notes as Array).size(), before])
	var chans := {}
	for n in App.project.patterns[App.current_pattern].notes:
		chans[int(n.ch)] = true
	_check("on the channels it was written from, not all on one",
			chans.size() == 2 and App.project.channels.size() == 2,
			"%d channel(s) used, %d in the rack" % [chans.size(), App.project.channels.size()])

	# --- MIDI out of the pattern and back into it
	var mid := dir.path_join("menu_score.mid")
	main._score_export_midi(mid)
	await _frames(2)
	_check("Export as MIDI file writes one", FileAccess.file_exists(mid))
	App.remove_notes(App.current_pattern, [0, 1, 2])
	App.note_edit_done(App.current_pattern)
	await _frames(2)
	main._score_import_midi(mid)
	await _frames(3)
	_check("Import MIDI file puts the notes into the pattern being edited",
			(App.project.patterns[App.current_pattern].notes as Array).size() == before,
			"%d note(s)" % (App.project.patterns[App.current_pattern].notes as Array).size())
	_check("without building a project around them",
			App.project.clips.is_empty() and App.project.patterns.size() == 1,
			"%d clip(s), %d pattern(s)" % [App.project.clips.size(), App.project.patterns.size()])
	_check("and without doubling the rack", App.project.channels.size() == 2,
			"%d channels" % App.project.channels.size())

	# --- the MIDI clipboard
	piano.select_all()
	await _frames(2)
	main._score_midi_copy()
	var clip := DisplayServer.clipboard_get()
	_check("Copy to MIDI clipboard puts a MIDI file on the clipboard",
			clip.begins_with(main.MIDI_CLIP_MARK) and clip.length() > 40,
			"%d characters" % clip.length())
	var was: int = (App.project.patterns[App.current_pattern].notes as Array).size()
	main._score_midi_paste()
	await _frames(3)
	_check("and pasting it brings the notes back in",
			(App.project.patterns[App.current_pattern].notes as Array).size() > was,
			"%d, was %d" % [(App.project.patterns[App.current_pattern].notes as Array).size(), was])

	# --- a tool
	App.select_channel(0)
	piano.select_all()
	await _frames(2)
	var span_before: Vector2 = piano._selection_span()
	var keys_before := _keys_in_time_order(piano)
	piano._run("reverse")
	await _frames(2)
	var span_after: Vector2 = piano._selection_span()
	var keys_after := _keys_in_time_order(piano)
	var wanted := keys_before.duplicate()
	wanted.reverse()
	_check("Reverse plays the phrase backwards", keys_after == wanted,
			"%s -> %s" % [str(keys_before), str(keys_after)])
	_check("without moving it off where it was",
			span_before.distance_to(span_after) < 0.01,
			"%s -> %s" % [str(span_before), str(span_after)])


## The selected notes' pitches, earliest first.
func _keys_in_time_order(piano) -> Array:
	var notes: Array = piano._notes()
	var picked := []
	for i in App.selected_notes:
		if int(i) >= 0 and int(i) < notes.size():
			picked.append(notes[int(i)])
	picked.sort_custom(func(a, b): return float(a.beat) < float(b.beat))
	var keys := []
	for n in picked:
		keys.append(int(n.key))
	return keys
