extends Node
## Global keys, plus the typing keyboard as a piano.
##
## Everything runs in _input(): _shortcut_input and _unhandled_key_input both
## fire *after* GUI input, so a focused Button would eat Space before a play
## shortcut ever saw it.

signal command(name: String)

## Two rows of a piano, laid out by where the keys sit on the keyboard rather
## than by what is printed on them. The codes below name the US positions,
## which is how Godot reports a physical key whatever the layout is -- so the
## bottom row plays the white notes on QWERTZ, AZERTY, Dvorak and the rest,
## and the note under your finger is the note you expect from the picture of a
## keyboard rather than from its letters.
const KEYS := {
	KEY_Z: 0, KEY_S: 1, KEY_X: 2, KEY_D: 3, KEY_C: 4, KEY_V: 5, KEY_G: 6, KEY_B: 7,
	KEY_H: 8, KEY_N: 9, KEY_J: 10, KEY_M: 11, KEY_COMMA: 12, KEY_L: 13, KEY_PERIOD: 14,
	KEY_Q: 12, KEY_2: 13, KEY_W: 14, KEY_3: 15, KEY_E: 16, KEY_R: 17, KEY_5: 18, KEY_T: 19,
	KEY_6: 20, KEY_Y: 21, KEY_7: 22, KEY_U: 23, KEY_I: 24, KEY_9: 25, KEY_O: 26,
}

## Names this keyboard to App's live-note book-keeping.
const SOURCE := "typing"

## Whether the piano follows the key positions or the printed letters. Position
## is right for nearly everyone; the other way suits someone who has learnt the
## letters on a layout of their own and wants those.
func _by_position() -> bool:
	return bool(Settings.get_value("piano_by_position", true))


## The code this key plays under: where the key sits, or what it prints.
func _piano_code(k: InputEventKey) -> int:
	if _by_position() and k.physical_keycode != 0:
		return int(k.physical_keycode)
	return int(k.keycode)

var octave := 4
var _down := {}
## Frames each held key has looked released for; see MISSING_FRAMES.
var _missing := {}
var typing_piano := true
## The viewport the event being handled came from.
var _vp: Viewport = null


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	octave = int(Settings.get_value("keyboard_octave", 4))
	Audio.midi_note.connect(_on_midi)
	set_process(true)


func _release(keycode: int) -> void:
	_missing.erase(keycode)
	if not _down.has(keycode):
		return
	App.live_note_off(int(_down[keycode]), SOURCE)
	_down.erase(keycode)


## Whether the typing keyboard is holding anything down. Asked by App's
## watchdog: a key that is still down is somebody still playing, whatever the
## window manager has to say about focus.
func holding() -> bool:
	return not _down.is_empty()


func release_all() -> void:
	for keycode in _down.keys():
		_release(int(keycode))


## Every key let go of the moment the keyboard stops being ours.
##
## The sweeper below cannot help here: it asks Godot whether a key is still
## down, and Godot only knows what it was told. Once another window has the
## keyboard -- a plugin's own interface, which takes it the moment it is
## clicked -- the key-up is delivered there and Godot goes on believing the key
## is held for ever. That is a note that sounds until the program is closed,
## and it is why letting go of a key inside Vital left it playing.
func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_WINDOW_FOCUS_OUT or what == NOTIFICATION_APPLICATION_FOCUS_OUT:
		release_all()


## Some key-ups never arrive: a window opens under the finger and takes the
## keyboard, or the compositor grabs it. Asking the input state directly each
## frame catches every one of those without waiting for an event.
##
## Not on the first frame that disagrees, though. The key state and the event
## stream do not always line up straight away -- a note played into a plugin's
## own window arrives as an event before the state catches up -- and a note cut
## off after one frame is worse than a stuck one.
const MISSING_FRAMES := 10

## Frames in a row the keyboard has been completely idle while Cadmium still
## thinks something is held. Two, so that a single frame landing between the
## key-down event and the window system agreeing about it cannot cut a note off
## the instant it is played.
const IDLE_FRAMES := 2

var _idle_frames := 0

func _process(_dt: float) -> void:
	if _down.is_empty():
		_missing.clear()
		_idle_frames = 0
		return
	# The keyboard itself, rather than what Godot believes about it.
	#
	# The sweep below asks Godot whether a key is still down, and Godot only
	# knows what it was told. Once another window has the keyboard -- a
	# plugin's own interface takes it the moment it is clicked -- the key-up is
	# delivered there, Godot is never told, and it goes on believing the key is
	# held for ever. That is the note that keeps playing until Cadmium is
	# closed, and no amount of asking Godot will ever catch it.
	#
	# Asked only while something is held, which is a few frames now and then
	# rather than every frame of every session, and it can only ever fire when
	# nothing at all is down -- so a key somebody is still holding is never cut
	# off. If it cannot find out, it says the key is held and nothing changes.
	if Audio.engine != null and not Audio.engine.any_key_held():
		_idle_frames += 1
		if _idle_frames >= IDLE_FRAMES:
			_idle_frames = 0
			release_all()
			return
	else:
		_idle_frames = 0
	for keycode in _down.keys():
		var code := int(keycode)
		if (Input.is_physical_key_pressed(code) if _by_position() else Input.is_key_pressed(code)):
			_missing.erase(code)
			continue
		var n: int = int(_missing.get(code, 0)) + 1
		_missing[code] = n
		if n >= MISSING_FRAMES:
			_release(code)


func _on_midi(key: int, vel: float, on: bool) -> void:
	if App.project.channels.is_empty():
		return
	if on:
		App.live_note_on(key, vel, App.LIVE_MIDI)
	else:
		App.live_note_off(key, App.LIVE_MIDI)


## Godot leaves focus on a LineEdit when the next click lands on something that
## does not take focus -- which here is every canvas. Without this, Space types
## a space into an invisible field forever.
func _drop_stale_text_focus(event: InputEvent) -> void:
	if not (event is InputEventMouseButton) or not event.pressed:
		return
	var vp := _viewport()
	if vp == null:
		return
	var f := vp.gui_get_focus_owner()
	if f == null or not (f is LineEdit or f is TextEdit or f is SpinBox):
		return
	if not f.get_global_rect().has_point(vp.get_mouse_position()):
		f.release_focus()


func _typing() -> bool:
	var f := _viewport().gui_get_focus_owner()
	return f is LineEdit or f is TextEdit or f is SpinBox or (f != null and f.get_parent() is SpinBox)


func _input(event: InputEvent) -> void:
	feed(event, get_viewport())


func _viewport() -> Viewport:
	return _vp if _vp != null and is_instance_valid(_vp) else get_viewport()


## The same handling, for events that arrived in another window. Each Godot
## window has its own viewport and its own input tree, so a key pressed while a
## plugin's window is focused never reaches this autoload on its own -- and the
## typing keyboard has to keep playing wherever you are.
func feed(event: InputEvent, vp: Viewport) -> void:
	_vp = vp
	_drop_stale_text_focus(event)
	if not (event is InputEventKey):
		return
	var k := event as InputEventKey
	if k.echo:
		return
	# A key that is playing a note gets its release handled before anything
	# else can return early on it. Holding a note and then pressing ctrl, or
	# clicking into a text field, or switching the typing keyboard off used to
	# swallow the key-up and leave the note sounding.
	# Released under the code it was pressed under -- and the other one too, in
	# case the setting changed while a key was held.
	for code in [_piano_code(k), int(k.keycode), int(k.physical_keycode)]:
		if not k.pressed and _down.has(code):
			_release(code)
			_viewport().set_input_as_handled()
			return
	if _typing():
		if k.pressed and k.keycode == KEY_ESCAPE:
			_viewport().gui_get_focus_owner().release_focus()
			_viewport().set_input_as_handled()
		return

	if k.pressed:
		var ctrl := k.ctrl_pressed
		var shift := k.shift_pressed
		match k.keycode:
			KEY_SPACE:
				if ctrl:
					Audio.play(true)
				else:
					Audio.toggle()
				_viewport().set_input_as_handled()
				return
			KEY_ENTER, KEY_KP_ENTER:
				Audio.stop()
				_viewport().set_input_as_handled()
				return
			KEY_S:
				if ctrl:
					command.emit("save_as" if shift else "save")
					_viewport().set_input_as_handled()
					return
			KEY_O:
				if ctrl:
					command.emit("open")
					_viewport().set_input_as_handled()
					return
			KEY_N:
				if ctrl:
					command.emit("new_pattern" if shift else "new")
					_viewport().set_input_as_handled()
					return
			KEY_E:
				if ctrl:
					command.emit("export")
					_viewport().set_input_as_handled()
					return
			KEY_Z:
				if ctrl:
					if shift:
						App.redo()
					else:
						App.undo()
					_viewport().set_input_as_handled()
					return
			KEY_Y:
				if ctrl:
					App.redo()
					_viewport().set_input_as_handled()
					return
			KEY_C:
				if ctrl:
					command.emit("copy")
					_viewport().set_input_as_handled()
					return
			KEY_X:
				if ctrl:
					command.emit("cut")
					_viewport().set_input_as_handled()
					return
			KEY_V:
				if ctrl:
					command.emit("paste")
					_viewport().set_input_as_handled()
					return
			KEY_Q:
				if ctrl:
					command.emit("quantize")
					_viewport().set_input_as_handled()
					return
			KEY_HOME:
				Audio.seek(0.0)
				_viewport().set_input_as_handled()
				return
			KEY_END:
				Audio.seek(maxf(0.0, App.project.length_beats() - 4.0))
				_viewport().set_input_as_handled()
				return
			KEY_R:
				if ctrl:
					command.emit("record")
					_viewport().set_input_as_handled()
					return
			KEY_M:
				if ctrl:
					command.emit("metronome")
					_viewport().set_input_as_handled()
					return
			KEY_L:
				# Ctrl+L is legato, the way it is in FL. The loop toggle it
				# used to be moved along to Ctrl+Shift+L rather than sitting
				# on top of it -- a match takes its first branch, so the two
				# of them here meant the second never ran at all.
				if ctrl and shift:
					command.emit("loop")
					_viewport().set_input_as_handled()
					return
				if ctrl:
					command.emit("legato")
					_viewport().set_input_as_handled()
					return
				App.set_mode(Cd.Mode.SONG if App.mode() == Cd.Mode.PATTERN else Cd.Mode.PATTERN)
				_viewport().set_input_as_handled()
				return
			KEY_T:
				if ctrl:
					command.emit("tap")
					_viewport().set_input_as_handled()
					return
			KEY_D:
				if ctrl:
					command.emit("duplicate_pattern" if shift else "duplicate")
					_viewport().set_input_as_handled()
					return
			KEY_F:
				if ctrl:
					command.emit("add_effect")
					_viewport().set_input_as_handled()
					return
			KEY_1, KEY_2, KEY_3, KEY_4:
				if not ctrl and not shift and not typing_piano:
					command.emit(["tool_draw", "tool_select", "tool_slice", "tool_mute"][k.keycode - KEY_1])
					_viewport().set_input_as_handled()
					return
			KEY_EQUAL, KEY_KP_ADD:
				if ctrl:
					command.emit("zoom_in")
					_viewport().set_input_as_handled()
					return
			KEY_MINUS, KEY_KP_SUBTRACT:
				if ctrl:
					command.emit("zoom_out")
					_viewport().set_input_as_handled()
					return
			KEY_F5:
				command.emit("view_playlist")
				return
			KEY_F6:
				command.emit("view_rack")
				return
			KEY_F7:
				command.emit("view_piano")
				return
			KEY_F9:
				command.emit("view_mixer")
				return
			KEY_F1:
				command.emit("help")
				return
			KEY_F11:
				command.emit("fullscreen")
				return
			KEY_BRACKETLEFT:
				octave = clampi(octave - 1, 0, 8)
				Settings.set_value("keyboard_octave", octave)
				return
			KEY_BRACKETRIGHT:
				octave = clampi(octave + 1, 0, 8)
				Settings.set_value("keyboard_octave", octave)
				return
			KEY_B:
				if not ctrl and not shift:
					command.emit("tool_draw")
					return
			KEY_C:
				if not ctrl:
					command.emit("tool_slice")
					return
			KEY_M:
				if not ctrl:
					command.emit("tool_mute")
					return
			KEY_ESCAPE:
				release_all()
				App.live_all_off()
				return

	if k.pressed and k.alt_pressed and k.keycode == KEY_E:
		command.emit("tool_select")
		return
	if not typing_piano or k.ctrl_pressed or k.alt_pressed:
		return
	var code := _piano_code(k)
	if not KEYS.has(code):
		return
	var note: int = clampi(octave * 12 + int(KEYS[code]), 0, 127)
	if k.pressed and not _down.has(code):
		_down[code] = note
		App.live_note_on(note, float(Settings.get_value("velocity", 0.78)), SOURCE)
		_viewport().set_input_as_handled()
