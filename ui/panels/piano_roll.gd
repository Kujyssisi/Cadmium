extends Control
## Piano Roll: notes for one channel of the current pattern.
##
## Drawn as a single canvas rather than a scene tree of note widgets -- a busy
## pattern is thousands of notes and a Control each would crawl. Scrolling and
## zooming are internal offsets, so the keyboard, ruler and velocity lane stay
## locked to the grid by construction.

const KEY_W := 58.0

## The scales the key picker offers, as semitones above the root. The names are
## the ones people ask for them by rather than the theoretically tidy ones.
const SCALES := {
	"Off": [],
	"Major": [0, 2, 4, 5, 7, 9, 11],
	"Minor": [0, 2, 3, 5, 7, 8, 10],
	"Harmonic minor": [0, 2, 3, 5, 7, 8, 11],
	"Melodic minor": [0, 2, 3, 5, 7, 9, 11],
	"Pentatonic major": [0, 2, 4, 7, 9],
	"Pentatonic minor": [0, 3, 5, 7, 10],
	"Blues": [0, 3, 5, 6, 7, 10],
	"Dorian": [0, 2, 3, 5, 7, 9, 10],
	"Phrygian": [0, 1, 3, 5, 7, 8, 10],
	"Lydian": [0, 2, 4, 6, 7, 9, 11],
	"Mixolydian": [0, 2, 4, 5, 7, 9, 10],
	"Locrian": [0, 1, 3, 5, 6, 8, 10],
	"Whole tone": [0, 2, 4, 6, 8, 10],
	"Chromatic": [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11],
}
const NOTE_NAMES := ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
const RULER_H := 22.0
## The strip along the very top that the choosers live in. They used to sit on
## top of the ruler, over the first two or three bars of it, so those bars could
## not be clicked to move the marker and their numbers were hidden behind a
## drop-down. The ruler is nothing but ruler now.
const HEAD_H := 24.0
## How near the end-of-pattern marker counts as grabbing it.
const END_GRAB := 9.0
const VEL_H := 74.0
const MIN_ROW := 5.0
const MAX_ROW := 34.0

var px_per_beat := 72.0
var row_h := 13.0
var scroll_beat := 0.0
var scroll_key := 48.0          ## bottom-most visible key

var _drag_mode := ""            ## "", "move", "resize", "select", "draw", "vel", "scroll", "loop"
var _preview_key := -1          ## the note being auditioned by a drag, if any
## The key the piece is in, for the row highlighting: the root as 0-11 and the
## scale by name. Remembered between sessions, the way FL remembers it.
var scale_root := 0
var scale_name := "Off"
var _pan_from := Vector2.ZERO   ## scroll position when a middle-button pan began
var _drag_note := -1
var _drag_from := Vector2.ZERO
var _drag_origin := {}
var _drag_offsets := {}
var _band := Rect2()
var _last_len := 1.0
var _hover_note := -1
## Rubbing notes out with the right button held: whether this gesture has taken
## its undo step yet, and where the pointer was when it was last sampled.
var _erased := false
var _erase_last := Vector2.ZERO
var _ghost_key := -1
var _lit := {}          ## keys the engine says are sounding right now
## Where a scrub wants the playhead, applied once a frame. Moving it silences
## and retriggers everything behind the audio thread's lock, and a mouse that
## reports a thousand times a second asked for all of that a thousand times.
var _scrub_to := -1.0

## What the lane along the bottom edits. Every entry is a field on the note, a
## range, and where the bar is drawn from -- pan and detune are drawn from the
## middle because that is where their zero is.
const CONTROLS := [
	{"id": "vel", "name": "Note velocity", "lo": 0.0, "hi": 1.0, "default": 0.78, "centred": false},
	{"id": "pan", "name": "Note pan", "lo": -1.0, "hi": 1.0, "default": 0.0, "centred": true},
	{"id": "fine", "name": "Note fine pitch", "lo": -2.0, "hi": 2.0, "default": 0.0, "centred": true},
]
var control := 0                ## index into CONTROLS


@onready var _channel_btn: OptionButton = $Channel
@onready var _menu_btn: MenuButton = $Menu

## Anything the menu asks for that needs a file dialog or another panel. The
## piano roll does what it can itself and hands the rest up.
signal menu_command(cmd: String)

## The menu along the top. Each entry is a submenu: its name, then its items as
## [label, command] -- an empty entry is a separator, and a third field marks an
## item that shows a tick. Three of them are filled in when the menu opens
## because what is in them depends on the project: see _refresh_menu.
const MENU := [
	["File", [
		["Open score...", "score_open"],
		["Browse scores...", "score_browse"],
		["Save score as...", "score_save"],
		[],
		["Import MIDI file...", "score_midi_import"],
		["Export as MIDI file...", "score_midi_export"],
		[],
		["Copy to MIDI clipboard", "score_midi_copy"],
		["Paste from MIDI clipboard", "score_midi_paste"],
		[],
		["Export as score sheet...", "score_sheet"],
	]],
	["Edit", [
		["Undo", "undo"],
		["Redo", "redo"],
		[],
		["Cut", "cut"],
		["Copy", "copy"],
		["Paste", "paste"],
		["Delete", "delete"],
		["Duplicate", "duplicate"],
		[],
		["Quantize", "quantize"],
		["Quantize start only", "quantize_start"],
		[],
		["Transpose up an octave", "octave_up"],
		["Transpose down an octave", "octave_down"],
	]],
	["Tools", [
		["Legato", "legato"],
		["Reverse", "reverse"],
		["Flip pitch", "flip"],
		[],
		["Strum", "strum"],
		["Arpeggiate", "arpeggiate"],
		[],
		["Randomise velocity", "randomise_vel"],
		["Humanise timing", "humanise"],
	]],
	["Select", [
		["All", "select_all"],
		["None", "select_none"],
		["Invert", "select_invert"],
		[],
		["This channel only", "select_channel"],
	]],
	["Snap", []],
	["Zoom", [
		["In", "zoom_in"],
		["Out", "zoom_out"],
		[],
		["Fit pattern", "zoom_fit"],
		["Fit selection", "zoom_selection"],
	]],
	["View", [
		["Centre on the marker", "centre"],
		[],
		["Follow the playhead", "toggle_follow", true],
		["Preview notes while playing", "toggle_preview", true],
	]],
	["Target channel", []],
	["Target control", []],
]

## Command per menu id, since a PopupMenu deals in numbers.
var _cmds: Array[String] = []
var _menus := {}
## What each entry in the chooser stands for: a channel, or a sample.
var _chooser: Array = []


func _ready() -> void:
	theme_type_variation = "Dock"
	focus_mode = Control.FOCUS_CLICK
	mouse_filter = Control.MOUSE_FILTER_STOP
	clip_contents = true
	scroll_key = float(Settings.get_value("piano_roll_scroll", 48))
	scale_root = int(Settings.get_value("scale_root", 0))
	scale_name = String(Settings.get_value("scale_name", "Off"))
	if not SCALES.has(scale_name):
		scale_name = "Off"
	App.patterns_changed.connect(queue_redraw)
	App.pattern_selected.connect(func(_i): queue_redraw())
	App.selection_changed.connect(queue_redraw)
	App.project_loaded.connect(queue_redraw)
	Cd.compact(_channel_btn, "OptionButton", 4.0)
	_channel_btn.item_selected.connect(_choose)
	_build_menu()
	App.channels_changed.connect(_fill_chooser)
	App.playlist_changed.connect(_fill_chooser)
	App.project_loaded.connect(_fill_chooser)
	App.selection_changed.connect(_mark_chooser)
	_fill_chooser()
	set_process(true)


func _process(_dt: float) -> void:
	_guard_drag()
	if _scrub_to >= 0.0:
		Audio.seek(_scrub_to)
		_scrub_to = -1.0
		queue_redraw()
	# Keys light from the engine's own voice state, so a note triggered by the
	# sequencer, the typing keyboard or a MIDI keyboard all look the same.
	var lit := {}
	if Audio.engine != null:
		for k in Audio.engine.active_notes(App.current_channel):
			lit[int(k)] = true
	if lit != _lit:
		_lit = lit
		queue_redraw()
	if not Audio.playing():
		return
	if bool(Settings.get_value("follow_playhead", true)) and App.mode() == Cd.Mode.SONG:
		var beat := playhead_beat()
		var visible_beats := (size.x - KEY_W) / px_per_beat
		if beat >= 0.0 and (beat < scroll_beat or beat > scroll_beat + visible_beats * 0.92):
			scroll_beat = maxf(0.0, beat - visible_beats * 0.15)
	queue_redraw()


## A drag that leaves the window never gets its release event, and the editor
## would keep dragging until the next click. Watch the real button state.
func _guard_drag() -> void:
	var left := Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT)
	var right := Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT)
	# The keyboard down the side auditions without starting a drag, so its note
	# is checked whether or not one is running.
	if _ghost_key >= 0 and not left:
		App.live_note_off(_ghost_key, _source())
		_ghost_key = -1
		queue_redraw()
	if _drag_mode.is_empty():
		if _preview_key >= 0 and not left:
			_preview(-1)
		return
	if left or right:
		return
	if _drag_mode == "select":
		_finish_band(false)
	elif _drag_mode in ["move", "resize", "draw"]:
		App.note_edit_done(App.current_pattern)
	elif _drag_mode in ["vel", "vel_zero"]:
		App.note_edit_done(App.current_pattern)
	_preview(-1)
	_drag_mode = ""
	_band = Rect2()
	queue_redraw()


func focus_channel(index: int) -> void:
	App.select_channel(index)
	# Centre on whatever this channel actually plays.
	var notes := App.project.pattern_notes(App.current_pattern, index)
	if not notes.is_empty():
		var lo := 127
		var hi := 0
		for n in notes:
			lo = mini(lo, int(n.key))
			hi = maxi(hi, int(n.key))
		var rows := int((size.y - HEAD_H - RULER_H - VEL_H) / row_h)
		scroll_key = clampf(float(lo) - maxf(2.0, (rows - (hi - lo)) * 0.5), 0.0, 127.0)
	queue_redraw()


# ---------------------------------------------------------------------------
# Geometry
# ---------------------------------------------------------------------------
func _grid_rect() -> Rect2:
	return Rect2(KEY_W, HEAD_H + RULER_H, maxf(0.0, size.x - KEY_W),
			maxf(0.0, size.y - HEAD_H - RULER_H - VEL_H))


## The timeline strip, under the toolbar and above the grid.
func _ruler_rect() -> Rect2:
	return Rect2(0.0, HEAD_H, size.x, RULER_H)


## Where the choosers along the top go, and how much room is left for anything
## else put up there.
func _head_rect() -> Rect2:
	return Rect2(0.0, 0.0, size.x, HEAD_H)


func _vel_rect() -> Rect2:
	return Rect2(KEY_W, size.y - VEL_H, maxf(0.0, size.x - KEY_W), VEL_H)


func _beat_to_x(beat: float) -> float:
	return KEY_W + (beat - scroll_beat) * px_per_beat


func _x_to_beat(x: float) -> float:
	return scroll_beat + (x - KEY_W) / px_per_beat


func _key_to_y(key: float) -> float:
	var g := _grid_rect()
	return g.end.y - (key - scroll_key + 1.0) * row_h


func _y_to_key(y: float) -> int:
	var g := _grid_rect()
	return int(floor(scroll_key + (g.end.y - y) / row_h))


func _notes() -> Array:
	return App.project.patterns[App.current_pattern].notes if App.current_pattern < App.project.patterns.size() else []


func _note_rect(n: Dictionary) -> Rect2:
	var x := _beat_to_x(float(n.beat))
	var w := maxf(3.0, float(n.len) * px_per_beat)
	var y := _key_to_y(float(int(n.key)))
	return Rect2(x, y, w, row_h - 1.0)


## How wide the "drag me longer" strip at the end of a note is. Six pixels was
## a sliver you had to hunt for; this grows with the note and still leaves most
## of a short one grabbable for moving.
func _edge_zone(r: Rect2) -> float:
	return clampf(r.size.x * 0.3, 5.0, 12.0)


## Every note between where the pointer was last sampled and where it is now.
## A mouse moving quickly jumps tens of pixels between events, and a note that
## fell in the gap would survive being dragged straight through.
func _erase_along(to: Vector2) -> void:
	var steps := maxi(1, int(_erase_last.distance_to(to) / 4.0))
	for s in steps + 1:
		var p := _erase_last.lerp(to, float(s) / float(steps))
		# Notes overlap, so take everything under the pointer -- but never loop
		# on a removal that did not happen.
		for _n in 16:
			var hit := _note_at(p)
			if hit < 0:
				break
			if not _erased:
				_erased = true
				App.snapshot("Erase notes")
			App.remove_notes(App.current_pattern, [hit])
	_erase_last = to
	if _erased:
		App.selected_notes.clear()
		queue_redraw()


func _note_at(pos: Vector2) -> int:
	var notes := _notes()
	for i in range(notes.size() - 1, -1, -1):
		var n: Dictionary = notes[i]
		if int(n.ch) != App.current_channel:
			continue
		if _note_rect(n).has_point(pos):
			return i
	return -1


# ---------------------------------------------------------------------------
# Input
# ---------------------------------------------------------------------------
func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		_button(event as InputEventMouseButton)
	elif event is InputEventMouseMotion:
		_motion(event as InputEventMouseMotion)
	elif event is InputEventKey and event.pressed:
		_key(event as InputEventKey)


func _button(mb: InputEventMouseButton) -> void:
	var pos := mb.position
	var grid := _grid_rect()
	var snap := App.snap_beats()

	if mb.button_index == MOUSE_BUTTON_WHEEL_UP or mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
		if not mb.pressed:
			return
		var dir := 1.0 if mb.button_index == MOUSE_BUTTON_WHEEL_UP else -1.0
		if mb.ctrl_pressed:
			var anchor := _x_to_beat(pos.x)
			px_per_beat = clampf(px_per_beat * (1.12 if dir > 0 else 1.0 / 1.12), 8.0, 600.0)
			scroll_beat = maxf(0.0, anchor - (pos.x - KEY_W) / px_per_beat)
		elif mb.alt_pressed:
			var anchor_key := float(_y_to_key(pos.y))
			row_h = clampf(row_h * (1.12 if dir > 0 else 1.0 / 1.12), MIN_ROW, MAX_ROW)
			scroll_key = clampf(anchor_key - (grid.end.y - pos.y) / row_h, 0.0, 110.0)
		elif mb.shift_pressed:
			scroll_beat = maxf(0.0, scroll_beat - dir * 4.0 * 60.0 / px_per_beat)
		else:
			scroll_key = clampf(scroll_key + dir * 3.0, 0.0, 110.0)
			Settings.data["piano_roll_scroll"] = int(scroll_key)
		accept_event()
		queue_redraw()
		return

	# Middle button pans, from anywhere: the way every other editor does it.
	if mb.button_index == MOUSE_BUTTON_MIDDLE:
		if mb.pressed:
			_drag_mode = "pan"
			_drag_from = pos
			_pan_from = Vector2(scroll_beat, scroll_key)
		else:
			_drag_mode = ""
		accept_event()
		return

	# The toolbar along the top is not part of the editor. What is in it are
	# controls of their own, and they have already had their say.
	if pos.y < HEAD_H:
		return

	if pos.x < KEY_W and pos.y > grid.position.y and pos.y < grid.end.y:
		# The keyboard previews notes on the current channel.
		if mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT:
			var key := _y_to_key(pos.y)
			App.live_note_on(key, 0.8, _source())
			_ghost_key = key
		elif _ghost_key >= 0:
			App.live_note_off(_ghost_key, _source())
			_ghost_key = -1
		accept_event()
		return

	if pos.y < grid.position.y and pos.x < KEY_W:
		if mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT and _scale_button().has_point(pos):
			_scale_menu()
		accept_event()
		return

	if pos.y < grid.position.y:
		if mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT:
			# The marker at the end of the pattern is a handle: drag it to make
			# the pattern longer or shorter.
			var end_x := _beat_to_x(float(App.project.patterns[App.current_pattern].length))
			if absf(pos.x - end_x) <= END_GRAB:
				_drag_mode = "length"
				App.snapshot("Pattern length")
			else:
				_scrub_to = _song_beat_for(Cd.snap_beat(_x_to_beat(pos.x), snap))
				_drag_mode = "scrub"
			accept_event()
		elif not mb.pressed:
			_drag_mode = ""
		return

	if _vel_rect().has_point(pos):
		# The chooser first: it sits inside the lane, over the keyboard's column.
		if mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT and _control_button().has_point(pos):
			_control_menu()
			accept_event()
			return
		if mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT:
			_drag_mode = "vel"
			_set_velocity_at(pos)
			accept_event()
		elif mb.pressed and mb.button_index == MOUSE_BUTTON_RIGHT:
			# Right button puts a note back to the default. Dragging across the
			# lane with it held resets a run of them, the same way the left
			# button paints one.
			_drag_mode = "vel_zero"
			_set_velocity_at(pos, 0.0)
			accept_event()
		elif not mb.pressed:
			if _drag_mode in ["vel", "vel_zero"]:
				App.note_edit_done(App.current_pattern)
			_drag_mode = ""
		return

	if not grid.has_point(pos):
		return

	if mb.button_index == MOUSE_BUTTON_RIGHT:
		if mb.pressed:
			# Held down, the right button rubs out every note it is dragged
			# over, starting with the one it landed on. One gesture, one undo
			# step, however many notes go.
			_drag_mode = "erase"
			_erased = false
			_erase_last = pos
			_erase_along(pos)
			accept_event()
		else:
			_drag_mode = ""
		return

	if mb.button_index != MOUSE_BUTTON_LEFT:
		return

	if not mb.pressed:
		if _drag_mode == "select":
			_finish_band(mb.shift_pressed)
		elif _drag_mode in ["move", "resize", "draw"]:
			App.note_edit_done(App.current_pattern)
		_preview(-1)
		_drag_mode = ""
		_band = Rect2()
		queue_redraw()
		return

	var hit := _note_at(pos)
	if App.tool == Cd.Tool.SLICE:
		if hit >= 0:
			_slice_note(hit, _x_to_beat(pos.x))
		accept_event()
		queue_redraw()
		return
	if App.tool == Cd.Tool.MUTE:
		if hit >= 0:
			App.snapshot("Mute note")
			var nn: Dictionary = _notes()[hit]
			App.update_note(App.current_pattern, hit, {"mute": not bool(nn.get("mute", false))})
			App.note_edit_done(App.current_pattern)
		accept_event()
		queue_redraw()
		return
	if hit >= 0:
		var n: Dictionary = _notes()[hit]
		var r := _note_rect(n)
		if not App.selected_notes.has(hit):
			if not mb.shift_pressed:
				App.selected_notes.clear()
			App.selected_notes.append(hit)
		elif mb.shift_pressed:
			App.selected_notes.erase(hit)
		if pos.x > r.end.x - _edge_zone(r):
			_drag_mode = "resize"
		else:
			_drag_mode = "move"
			_preview(int(n.key))
		_drag_note = hit
		_drag_from = pos
		_drag_origin = n.duplicate()
		_drag_offsets.clear()
		for i in App.selected_notes:
			var nn: Dictionary = _notes()[i]
			_drag_offsets[i] = {"beat": float(nn.beat), "key": int(nn.key), "len": float(nn.len)}
		App.snapshot("Move notes" if _drag_mode == "move" else "Resize notes")
	elif App.tool == Cd.Tool.SELECT or mb.shift_pressed:
		_drag_mode = "select"
		_drag_from = pos
		_band = Rect2(pos, Vector2.ZERO)
	else:
		App.snapshot("Draw note")
		var beat := maxf(0.0, Cd.floor_snap(_x_to_beat(pos.x), snap))
		var key := _y_to_key(pos.y)
		var idx := App.add_note(App.current_pattern, App.current_channel, beat,
				maxf(snap, _last_len), key, float(Settings.get_value("velocity", 0.78)))
		App.selected_notes = [idx]
		_drag_note = idx
		_drag_mode = "draw"
		_drag_from = pos
		_drag_origin = _notes()[idx].duplicate()
		_drag_offsets = {idx: {"beat": beat, "key": key, "len": maxf(snap, _last_len)}}
		_preview(key)
	accept_event()
	queue_redraw()


## Quick legato, the way FL Studio does it: every selected note is stretched --
## or trimmed -- to end exactly where the next one starts, so a run of notes
## joins up with nothing between them. With nothing selected it applies to the
## whole pattern. The last note keeps the length it has: there is nothing after
## it to reach.
func quick_legato() -> void:
	var notes: Array = _notes()
	if notes.is_empty():
		return
	var order := []
	for i in notes.size():
		order.append(i)
	order.sort_custom(func(a, b): return float(notes[a].beat) < float(notes[b].beat))
	var wanted := {}
	if App.selected_notes.is_empty():
		for i in notes.size():
			wanted[i] = true
	else:
		for i in App.selected_notes:
			wanted[int(i)] = true
	App.snapshot("Legato")
	var changed := 0
	for pos in order.size():
		var i: int = order[pos]
		if not wanted.has(i):
			continue
		var start := float(notes[i].beat)
		# The next note that begins after this one does, whatever its pitch --
		# a run of chords closes up to the next chord, not to its own notes.
		var next := -1.0
		for q in range(pos + 1, order.size()):
			var b := float(notes[order[q]].beat)
			if b > start + 0.0001:
				next = b
				break
		if next < 0.0:
			continue
		var want_len: float = maxf(0.03125, next - start)
		if absf(want_len - float(notes[i].len)) < 0.0001:
			continue
		App.update_note(App.current_pattern, i, {"len": want_len})
		changed += 1
	App.note_edit_done(App.current_pattern)
	queue_redraw()
	App.status.emit("Legato: %d note%s reach the next one" % [changed, "" if changed == 1 else "s"])


# ---------------------------------------------------------------------------
# The menu
# ---------------------------------------------------------------------------
func _build_menu() -> void:
	if _menu_btn == null:
		return
	_menu_btn.text = "Piano roll"
	Cd.compact(_menu_btn, "MenuButton", 4.0)
	var root := _menu_btn.get_popup()
	root.clear()
	for kid in root.get_children():
		root.remove_child(kid)
		kid.queue_free()
	_cmds.clear()
	_menus.clear()
	for entry in MENU:
		var title := String(entry[0])
		var sub := PopupMenu.new()
		sub.name = title.replace(" ", "_")
		sub.id_pressed.connect(_on_menu_id)
		root.add_child(sub)
		root.add_submenu_node_item(title, sub)
		_menus[title] = sub
		_fill_menu(sub, entry[1])
	root.about_to_popup.connect(_refresh_menu)


func _fill_menu(into: PopupMenu, items: Array) -> void:
	for item in items:
		if (item as Array).is_empty():
			into.add_separator()
			continue
		var id := _cmds.size()
		_cmds.append(String(item[1]))
		if (item as Array).size() > 2 and bool(item[2]):
			into.add_check_item(String(item[0]), id)
		else:
			into.add_item(String(item[0]), id)


## What the menu cannot know until it is opened: the snap values, the channels
## in the rack, the lane's controls, and which of the ticked items are on.
func _refresh_menu() -> void:
	var snap_menu: PopupMenu = _menus.get("Snap")
	if snap_menu != null:
		snap_menu.clear()
		for key in Cd.SNAPS.keys():
			var id := _cmds.size()
			_cmds.append("snap:%s" % String(key))
			snap_menu.add_check_item(String(key), id)
			snap_menu.set_item_checked(snap_menu.get_item_index(id), App.snap == String(key))

	var chan_menu: PopupMenu = _menus.get("Target channel")
	if chan_menu != null:
		chan_menu.clear()
		for i in App.project.channels.size():
			var id := _cmds.size()
			_cmds.append("target:%d" % i)
			chan_menu.add_check_item(String(App.project.channels[i].name), id)
			chan_menu.set_item_checked(chan_menu.get_item_index(id), i == App.current_channel)
		if App.project.channels.is_empty():
			chan_menu.add_item("no channels yet", -1)
			chan_menu.set_item_disabled(0, true)

	var ctl_menu: PopupMenu = _menus.get("Target control")
	if ctl_menu != null:
		ctl_menu.clear()
		for i in CONTROLS.size():
			var id := _cmds.size()
			_cmds.append("control:%d" % i)
			ctl_menu.add_check_item(String(CONTROLS[i].name), id)
			ctl_menu.set_item_checked(ctl_menu.get_item_index(id), i == control)

	var view: PopupMenu = _menus.get("View")
	if view != null:
		_tick(view, "toggle_follow", bool(Settings.get_value("follow_playhead", true)))
		_tick(view, "toggle_preview", bool(Settings.get_value("preview_while_playing", false)))


func _tick(menu: PopupMenu, cmd: String, on: bool) -> void:
	for i in menu.item_count:
		var id := menu.get_item_id(i)
		if id >= 0 and id < _cmds.size() and _cmds[id] == cmd:
			menu.set_item_checked(i, on)
			return


func _on_menu_id(id: int) -> void:
	if id < 0 or id >= _cmds.size():
		return
	_run(_cmds[id])


## Everything the piano roll can do without help. What it cannot -- anything
## that needs a file chooser -- goes up to the window, which owns the dialogs.
func _run(cmd: String) -> void:
	if cmd.begins_with("snap:"):
		App.set_snap(cmd.substr(5))
		App.status.emit("Snap %s" % App.snap)
		queue_redraw()
		return
	if cmd.begins_with("target:"):
		focus_channel(int(cmd.substr(7)))
		_mark_chooser()
		return
	if cmd.begins_with("control:"):
		control = clampi(int(cmd.substr(8)), 0, CONTROLS.size() - 1)
		queue_redraw()
		return
	match cmd:
		"select_all":
			select_all()
		"select_none":
			App.selected_notes.clear()
			App.selection_changed.emit()
			queue_redraw()
		"select_invert":
			var was := {}
			for i in App.selected_notes:
				was[int(i)] = true
			App.selected_notes.clear()
			var all := _notes()
			for i in all.size():
				if int(all[i].ch) == App.current_channel and not was.has(i):
					App.selected_notes.append(i)
			App.selection_changed.emit()
			queue_redraw()
		"select_channel":
			select_all()
		"delete":
			delete_selection()
		"duplicate":
			_duplicate_selection()
		"octave_up":
			_select_if_empty()
			_transpose(12)
		"octave_down":
			_select_if_empty()
			_transpose(-12)
		"quantize", "quantize_start":
			_select_if_empty()
			var n := App.quantize_notes(App.selected_notes, 1.0, cmd == "quantize")
			App.status.emit("Quantized %d note%s to %s" % [n, "" if n == 1 else "s", App.snap])
			queue_redraw()
		"legato":
			quick_legato()
		"reverse":
			_reverse()
		"flip":
			_flip_pitch()
		"strum":
			_spread(0.0)
		"arpeggiate":
			_spread(1.0)
		"randomise_vel":
			_randomise_velocity()
		"humanise":
			_humanise()
		"zoom_fit":
			_zoom_to(0.0, _pattern_length())
		"zoom_selection":
			var span := _selection_span()
			if span == Vector2.ZERO:
				App.status.emit("Nothing selected to zoom to")
			else:
				_zoom_to(span.x, span.y)
		"centre":
			_centre_view()
		"toggle_follow":
			var on := not bool(Settings.get_value("follow_playhead", true))
			Settings.set_value("follow_playhead", on)
			App.status.emit("Following the playhead" if on else "Not following the playhead")
		"toggle_preview":
			var on := not bool(Settings.get_value("preview_while_playing", false))
			Settings.set_value("preview_while_playing", on)
			App.status.emit("Notes preview while the song plays" if on
					else "Notes do not preview while the song plays")
		_:
			menu_command.emit(cmd)


## Most of the tools work on what is selected, and "nothing selected" almost
## always means "all of it" rather than "do nothing".
func _select_if_empty() -> void:
	if App.selected_notes.is_empty():
		select_all()


## The notes a tool should work on, as indices, already in time order.
func _tool_targets() -> Array:
	_select_if_empty()
	var notes := _notes()
	var out := []
	for i in App.selected_notes:
		if int(i) >= 0 and int(i) < notes.size():
			out.append(int(i))
	out.sort_custom(func(a, b): return float(notes[a].beat) < float(notes[b].beat))
	return out


func _selection_span() -> Vector2:
	var notes := _notes()
	var lo := INF
	var hi := -INF
	for i in App.selected_notes:
		if int(i) < 0 or int(i) >= notes.size():
			continue
		lo = minf(lo, float(notes[int(i)].beat))
		hi = maxf(hi, float(notes[int(i)].beat) + float(notes[int(i)].len))
	if lo > hi:
		return Vector2.ZERO
	return Vector2(lo, hi)


## Back to front in time, inside the stretch the notes already occupy, so the
## phrase plays backwards without moving anywhere.
func _reverse() -> void:
	var targets := _tool_targets()
	if targets.size() < 2:
		App.status.emit("Reverse needs more than one note")
		return
	var notes := _notes()
	var span := Vector2(INF, -INF)
	for i in targets:
		span.x = minf(span.x, float(notes[i].beat))
		span.y = maxf(span.y, float(notes[i].beat) + float(notes[i].len))
	App.snapshot("Reverse")
	for i in targets:
		var n: Dictionary = notes[i]
		var mirrored: float = span.x + span.y - float(n.beat) - float(n.len)
		App.update_note(App.current_pattern, i, {"beat": maxf(0.0, mirrored)})
	App.note_edit_done(App.current_pattern)
	queue_redraw()
	App.status.emit("Reversed %d notes" % targets.size())


## Turned upside down about the middle of its own range, so the shape of the
## phrase is kept and its direction is not.
func _flip_pitch() -> void:
	var targets := _tool_targets()
	if targets.size() < 2:
		App.status.emit("Flip needs more than one note")
		return
	var notes := _notes()
	var lo := 127
	var hi := 0
	for i in targets:
		lo = mini(lo, int(notes[i].key))
		hi = maxi(hi, int(notes[i].key))
	App.snapshot("Flip pitch")
	for i in targets:
		App.update_note(App.current_pattern, i, {"key": clampi(lo + hi - int(notes[i].key), 0, 127)})
	App.note_edit_done(App.current_pattern)
	queue_redraw()
	App.status.emit("Flipped %d notes about %s" % [targets.size(),
			Cd.note_name(int(round((lo + hi) * 0.5)))])


## Notes that start together, staggered. A small spread is a strum; a spread of
## a whole snap step each is an arpeggio. `reach` at zero keeps the ends where
## they are, so a strummed chord still finishes together.
func _spread(reach: float) -> void:
	var targets := _tool_targets()
	if targets.is_empty():
		return
	var notes := _notes()
	var snap: float = maxf(App.snap_beats(), 0.0625)
	var step: float = snap if reach > 0.0 else minf(snap * 0.25, 0.0625)
	# Grouped by where they start: a chord is the notes that begin together.
	var groups := {}
	for i in targets:
		var key := int(round(float(notes[i].beat) / 0.001))
		if not groups.has(key):
			groups[key] = []
		groups[key].append(i)
	var moved := 0
	App.snapshot("Arpeggiate" if reach > 0.0 else "Strum")
	for key in groups.keys():
		var group: Array = groups[key]
		if group.size() < 2:
			continue
		group.sort_custom(func(a, b): return int(notes[a].key) < int(notes[b].key))
		for pos in group.size():
			var i: int = group[pos]
			var shift := float(pos) * step
			var fields := {"beat": float(notes[i].beat) + shift}
			if reach > 0.0:
				fields["len"] = maxf(0.03125, step)
			else:
				fields["len"] = maxf(0.03125, float(notes[i].len) - shift)
			App.update_note(App.current_pattern, i, fields)
			moved += 1
	App.note_edit_done(App.current_pattern)
	queue_redraw()
	if moved == 0:
		App.status.emit("Nothing stacked up to spread out")
	else:
		App.status.emit("%s %d notes" % ["Arpeggiated" if reach > 0.0 else "Strummed", moved])


func _randomise_velocity() -> void:
	var targets := _tool_targets()
	if targets.is_empty():
		return
	var notes := _notes()
	App.snapshot("Randomise velocity")
	for i in targets:
		var v: float = clampf(float(notes[i].vel) + randf_range(-0.18, 0.18), 0.05, 1.0)
		App.update_note(App.current_pattern, i, {"vel": v})
	App.note_edit_done(App.current_pattern)
	queue_redraw()
	App.status.emit("Randomised %d velocities" % targets.size())


## A few milliseconds either way, so a part stops sounding typed in. Bounded by
## the snap, because a sixteenth-note hi-hat humanised by an eighth is a mistake
## rather than a performance.
func _humanise() -> void:
	var targets := _tool_targets()
	if targets.is_empty():
		return
	var notes := _notes()
	var reach: float = minf(maxf(App.snap_beats(), 0.0625) * 0.18, 0.04)
	App.snapshot("Humanise")
	for i in targets:
		App.update_note(App.current_pattern, i,
				{"beat": maxf(0.0, float(notes[i].beat) + randf_range(-reach, reach))})
	App.note_edit_done(App.current_pattern)
	queue_redraw()
	App.status.emit("Humanised %d notes" % targets.size())


## Fits a stretch of beats across the grid, with a little room either side.
func _zoom_to(from_beat: float, to_beat: float) -> void:
	var span: float = maxf(0.25, to_beat - from_beat)
	var width: float = maxf(80.0, size.x - KEY_W)
	px_per_beat = clampf(width / (span * 1.06), 8.0, 600.0)
	scroll_beat = maxf(0.0, from_beat - span * 0.03)
	queue_redraw()


## The marker in the middle, with the notes around it in view.
func _centre_view() -> void:
	var beat := playhead_beat()
	if beat < 0.0:
		beat = scroll_beat
	scroll_beat = maxf(0.0, beat - (size.x - KEY_W) / px_per_beat * 0.5)
	var grid := _grid_rect()
	var rows := maxf(1.0, grid.size.y / row_h)
	var lo := 127
	var hi := 0
	var any := false
	for n in _notes():
		if int(n.ch) != App.current_channel:
			continue
		lo = mini(lo, int(n.key))
		hi = maxi(hi, int(n.key))
		any = true
	if any:
		scroll_key = clampf(float(lo + hi) * 0.5 - rows * 0.5, 0.0, 127.0)
	queue_redraw()


## Everything the piano roll can be pointed at: the instruments in the rack and
## the samples in the song, the way FL lists both. Picking a sample puts it on a
## sampler channel of its own, which is what makes it playable at all.
func _fill_chooser() -> void:
	if _channel_btn == null:
		return
	_chooser.clear()
	_channel_btn.clear()
	for i in App.project.channels.size():
		_chooser.append({"kind": "channel", "index": i})
		_channel_btn.add_item(String(App.project.channels[i].name))
	if not App.project.assets.is_empty():
		_channel_btn.add_separator("Samples")
		for i in App.project.assets.size():
			_chooser.append({"kind": "sample", "index": i})
			_channel_btn.add_item(String(App.project.assets[i].get("name", "sample")))
	_mark_chooser()


## The entry for the channel being edited, ticked. Separators take up a place
## in the list and none in ours, so the two are matched by what they stand for
## rather than by counting.
func _mark_chooser() -> void:
	if _channel_btn == null:
		return
	for i in _channel_btn.item_count:
		var at := _entry_at(i)
		if at.get("kind", "") == "channel" and int(at.get("index", -1)) == App.current_channel:
			_channel_btn.select(i)
			return
	_channel_btn.select(-1)


func _entry_at(item: int) -> Dictionary:
	var seen := 0
	for i in _channel_btn.item_count:
		if _channel_btn.is_item_separator(i):
			continue
		if i == item:
			return _chooser[seen] if seen < _chooser.size() else {}
		seen += 1
	return {}


func _choose(item: int) -> void:
	var entry := _entry_at(item)
	if entry.is_empty():
		return
	if String(entry.kind) == "channel":
		App.select_channel(int(entry.index))
	else:
		App.select_channel(App.channel_for_asset(int(entry.index)))
	queue_redraw()


## Names this editor in App's live-note book-keeping, which remembers the
## channel each note started on: selecting another channel mid-drag used to
## send the note-off to the wrong one and leave the first sounding.
func _source() -> String:
	return "roll%d" % get_instance_id()


## Auditions `key`, replacing whatever was sounding. Passing -1 just stops.
func _preview(key: int) -> void:
	# Not while the song is playing, unless it has been asked for: drawing a note
	# in over a part that is already sounding should put the note in, not play it
	# at you as well. View > Preview notes while playing turns it back on.
	if key >= 0 and Audio.playing() and not bool(Settings.get_value("preview_while_playing", false)):
		key = -1
	if key == _preview_key:
		return
	if _preview_key >= 0:
		App.live_note_off(_preview_key, _source())
	_preview_key = key
	if key >= 0:
		App.live_note_on(key, float(Settings.get_value("velocity", 0.78)), _source())


func _motion(mm: InputEventMouseMotion) -> void:
	var pos := mm.position
	var snap := App.snap_beats()
	match _drag_mode:
		"pan":
			scroll_beat = maxf(0.0, _pan_from.x - (pos.x - _drag_from.x) / px_per_beat)
			scroll_key = clampf(_pan_from.y + (pos.y - _drag_from.y) / row_h, 0.0, 110.0)
			queue_redraw()
		"length":
			var want := maxf(float(App.project.sig_num) * 0.5,
					Cd.snap_beat(_x_to_beat(pos.x), maxf(snap, 0.25)))
			if absf(want - float(App.project.patterns[App.current_pattern].length)) > 0.01:
				App.set_pattern_prop(App.current_pattern, "length", want)
			queue_redraw()
		"scrub":
			_scrub_to = _song_beat_for(Cd.snap_beat(_x_to_beat(pos.x), snap))
		"select":
			_band = Rect2(_drag_from, pos - _drag_from).abs()
		"erase":
			_erase_along(pos)
		"vel":
			_set_velocity_at(pos)
		"vel_zero":
			_set_velocity_at(pos, 0.0)
		"move":
			var dbeat := Cd.snap_beat(_x_to_beat(pos.x) - _x_to_beat(_drag_from.x), snap)
			var dkey := _y_to_key(pos.y) - _y_to_key(_drag_from.y)
			for i in _drag_offsets.keys():
				var o: Dictionary = _drag_offsets[i]
				App.update_note(App.current_pattern, int(i), {
					"beat": maxf(0.0, float(o.beat) + dbeat),
					"key": clampi(int(o.key) + dkey, 0, 127),
				})
			# The note you hear should be the note you are pointing at, not the
			# one you picked up.
			if _drag_offsets.has(_drag_note):
				var od: Dictionary = _drag_offsets[_drag_note]
				_preview(clampi(int(od.key) + dkey, 0, 127))
		"draw":
			# The note just drawn is carried by the pointer until the button
			# comes up -- any direction, pitch and time both, keeping the length
			# it was drawn with. Dragging used to stretch it instead, which made
			# a note put down on the wrong row a job for a second gesture and
			# left dragging backwards doing nothing at all.
			if not _drag_offsets.has(_drag_note):
				return
			var key := clampi(_y_to_key(pos.y), 0, 127)
			var beat := maxf(0.0, Cd.floor_snap(_x_to_beat(pos.x), maxf(snap, 0.0625)))
			App.update_note(App.current_pattern, _drag_note, {"key": key, "beat": beat})
			_preview(key)
		"resize":
			var target := _x_to_beat(pos.x)
			for i in _drag_offsets.keys():
				var o: Dictionary = _drag_offsets[i]
				var want := Cd.snap_beat(target - float(o.beat), snap)
				if i == _drag_note:
					_last_len = maxf(snap if snap > 0.0 else 0.125, want)
				App.update_note(App.current_pattern, int(i), {"len": maxf(snap if snap > 0.0 else 0.0625, want)})
		_:
			if _ruler_rect().has_point(pos):
				var end_x := _beat_to_x(float(App.project.patterns[App.current_pattern].length))
				mouse_default_cursor_shape = Control.CURSOR_HSIZE if absf(pos.x - end_x) <= END_GRAB \
						else Control.CURSOR_ARROW
				return
			var hit := _note_at(pos)
			# The pointer says what a click will do, which is the only way the
			# resize strip is discoverable.
			var over_edge := false
			if hit >= 0:
				var hr := _note_rect(_notes()[hit])
				over_edge = pos.x > hr.end.x - _edge_zone(hr)
			var want := Control.CURSOR_HSIZE if over_edge else Control.CURSOR_ARROW
			if mouse_default_cursor_shape != want:
				mouse_default_cursor_shape = want
			if hit != _hover_note:
				_hover_note = hit
				queue_redraw()
			return
	queue_redraw()


func _key(k: InputEventKey) -> void:
	match k.keycode:
		KEY_DELETE, KEY_BACKSPACE:
			delete_selection()
		KEY_A:
			if k.ctrl_pressed:
				select_all()
		KEY_D, KEY_B:
			# Ctrl+B is the one everybody's fingers already know, and holding
			# it lays down copy after copy: the key repeat is the repeat.
			if k.ctrl_pressed:
				_duplicate_selection()
		KEY_UP, KEY_DOWN:
			var d := 1 if k.keycode == KEY_UP else -1
			if k.ctrl_pressed:
				d *= 12
			_transpose(d)
		KEY_LEFT, KEY_RIGHT:
			var snap := maxf(App.snap_beats(), 0.0625)
			_nudge((snap if k.keycode == KEY_RIGHT else -snap))


## Cut a note in two at the pointer, snapped. The right-hand half keeps the
## velocity; both halves stay selected so a second cut is one click away.
func _slice_note(index: int, at_beat: float) -> void:
	var notes := _notes()
	if index < 0 or index >= notes.size():
		return
	var n: Dictionary = notes[index]
	var cut := Cd.snap_beat(at_beat, App.snap_beats())
	var start := float(n.beat)
	var end := start + float(n.len)
	if cut <= start + 0.01 or cut >= end - 0.01:
		return
	App.snapshot("Slice note")
	App.update_note(App.current_pattern, index, {"len": cut - start})
	var idx := App.add_note(App.current_pattern, int(n.ch), cut, end - cut, int(n.key), float(n.vel))
	App.selected_notes = [index, idx]
	App.note_edit_done(App.current_pattern)


## The list of everything the lane can edit, at the pointer.
func _control_menu() -> void:
	var pm := PopupMenu.new()
	add_child(pm)
	pm.add_separator("Note properties")
	for i in CONTROLS.size():
		pm.add_radio_check_item(String(CONTROLS[i].name), i)
		pm.set_item_checked(pm.item_count - 1, i == control)
	pm.id_pressed.connect(func(id):
		control = clampi(id, 0, CONTROLS.size() - 1)
		queue_redraw())
	pm.popup_hide.connect(func(): pm.queue_free(), CONNECT_DEFERRED)
	pm.popup(Rect2i(DisplayServer.mouse_get_position(), Vector2i(0, 0)))


## Sets the chosen control on the note nearest the pointer. `forced` is used by
## the right button to put a note back to nothing without aiming.
func _set_velocity_at(pos: Vector2, forced: float = -1.0) -> void:
	var r := _vel_rect()
	var c := _control()
	var beat := _x_to_beat(pos.x)
	var field := String(c.id)
	var t := clampf(1.0 - (pos.y - r.position.y) / r.size.y, 0.0, 1.0)
	var v := float(c.lo) + t * (float(c.hi) - float(c.lo))
	if field == "vel":
		v = maxf(v, 0.02)
	if forced >= 0.0:
		# Right button resets rather than empties: back to the default this
		# control is drawn from -- the middle for pan and detune, and the
		# velocity the tool is set to write for velocity. A note silenced by a
		# stray right-click is not what anybody meant by "reset".
		v = float(c.default)
		if field == "vel":
			v = clampf(float(Settings.get_value("velocity", float(c.default))), 0.02, 1.0)
	var notes := _notes()
	var best := -1
	# Half a bar of reach was too little on a zoomed-out pattern and too much
	# on a zoomed-in one, so the reach is measured in pixels instead.
	var best_d := 14.0 / maxf(1.0, px_per_beat)
	for i in notes.size():
		var n: Dictionary = notes[i]
		if int(n.ch) != App.current_channel:
			continue
		# The bar is drawn at the note's start, but the whole note is a target:
		# anywhere along it counts, which is what made short notes so hard to
		# hit that they looked unselectable.
		var d: float = absf(float(n.beat) - beat)
		if beat >= float(n.beat) and beat <= float(n.beat) + float(n.len):
			d = 0.0
		if d < best_d:
			best_d = d
			best = i
	if best < 0:
		return
	# What is being edited is shown as selected, so there is never a doubt
	# about which note the lane is talking about.
	if not App.selected_notes.has(best):
		App.selected_notes = [best]
		App.selection_changed.emit()
	if App.selected_notes.size() > 1 and App.selected_notes.has(best):
		for i in App.selected_notes:
			App.update_note(App.current_pattern, int(i), {field: v})
	else:
		App.update_note(App.current_pattern, best, {field: v})
	if forced < 0.0 and field == "vel":
		Settings.data["velocity"] = v


func _finish_band(add: bool) -> void:
	if not add:
		App.selected_notes.clear()
	var notes := _notes()
	for i in notes.size():
		var n: Dictionary = notes[i]
		if int(n.ch) != App.current_channel:
			continue
		if _band.intersects(_note_rect(n)) and not App.selected_notes.has(i):
			App.selected_notes.append(i)
	App.selection_changed.emit()


## Where the playhead is inside this pattern, or -1 when the pattern is not
## being played at all.
##
## A pattern is edited on its own timeline, starting at its own beat zero. In
## song mode it is played by its clips, and a clip at bar 33 plays the
## pattern's first bar there -- so the playhead belongs where those notes are,
## not a hundred and twenty-eight beats off to the right of them.
func playhead_beat() -> float:
	var beat := Audio.position()
	var length := _pattern_length()
	if App.mode() == Cd.Mode.PATTERN:
		return fmod(beat, length)
	for c in App.project.clips:
		if int(c.type) != Cd.ClipType.PATTERN or int(c.index) != App.current_pattern:
			continue
		if bool(c.get("mute", false)):
			continue
		var start := float(c.start)
		if beat < start or beat >= start + float(c.length):
			continue
		return fmod(maxf(0.0, beat - start + float(c.get("offset", 0.0))), length)
	return -1.0


## The pattern's own length, which is the timeline the piano roll draws.
func _pattern_length() -> float:
	if App.current_pattern >= App.project.patterns.size():
		return 4.0
	return maxf(0.25, float(App.project.patterns[App.current_pattern].length))


## Where in the song one clip of this pattern plays the pattern's beat `local`.
## A clip longer than its pattern repeats it, so the repetition wanted is the
## one around `near` -- dragging the marker across the ruler should walk along
## the bar you are looking at, not jump to the clip's first time round.
func _clip_beat(c: Dictionary, local: float, near: float, length: float) -> float:
	var start := float(c.start)
	var end: float = start + float(c.length)
	var base: float = start - float(c.get("offset", 0.0))
	var want: float = base + floorf((near - base) / length) * length + local
	while want < start - 0.0001:
		want += length
	while want >= end - 0.0001 and want - length >= start - 0.0001:
		want -= length
	return clampf(want, start, maxf(start, end - 0.0001))


## The song position that lines up with a beat on this pattern's own timeline --
## the inverse of playhead_beat().
##
## Without this, dragging the marker along the piano roll's ruler in song mode
## sent the arrangement to that many beats from the start of the song: click at
## bar two of a pattern that is played by a clip at bar thirty-three and the
## whole thing jumped to bar two, where this pattern is not playing at all, so
## the piano roll's own marker vanished. The ruler here moves the marker to
## where you pointed *in the pattern*, and the arrangement follows to wherever
## that is.
func _song_beat_for(local: float) -> float:
	local = maxf(0.0, local)
	if App.mode() == Cd.Mode.PATTERN:
		return local
	var length := _pattern_length()
	var here := Audio.position()
	var holding := {}
	var earliest := {}
	for c in App.project.clips:
		if int(c.type) != Cd.ClipType.PATTERN or int(c.index) != App.current_pattern:
			continue
		if bool(c.get("mute", false)):
			continue
		if earliest.is_empty() or float(c.start) < float(earliest.start):
			earliest = c
		if here >= float(c.start) and here < float(c.start) + float(c.length):
			holding = c
	# The clip being played wins, so scrubbing stays inside the bar you can
	# hear; failing that, the first place this pattern appears at all.
	if not holding.is_empty():
		return _clip_beat(holding, local, here, length)
	if not earliest.is_empty():
		return _clip_beat(earliest, local, float(earliest.start), length)
	# The pattern is not in the arrangement anywhere, so there is nothing to
	# line up with and the beat stands for itself.
	return local


## Paste lands at the playhead when it is in view, otherwise at the left edge:
## whichever the eye is on.
func paste_anchor() -> float:
	var beat := playhead_beat()
	if beat < 0.0:
		beat = scroll_beat
	var visible := (size.x - KEY_W) / px_per_beat
	if beat < scroll_beat or beat > scroll_beat + visible:
		beat = scroll_beat
	return Cd.snap_beat(maxf(0.0, beat), App.snap_beats())


func select_all() -> void:
	App.selected_notes.clear()
	var notes := _notes()
	for i in notes.size():
		if int(notes[i].ch) == App.current_channel:
			App.selected_notes.append(i)
	queue_redraw()


func delete_selection() -> void:
	if App.selected_notes.is_empty():
		return
	App.snapshot("Delete notes")
	App.remove_notes(App.current_pattern, App.selected_notes)
	App.selected_notes.clear()
	queue_redraw()


func _duplicate_selection() -> void:
	if App.selected_notes.is_empty():
		return
	App.snapshot("Duplicate notes")
	var notes := _notes()
	var span := 0.0
	var start := INF
	for i in App.selected_notes:
		var n: Dictionary = notes[int(i)]
		start = minf(start, float(n.beat))
		span = maxf(span, float(n.beat) + float(n.len))
	# Rounded up to the snap, so a copy of one bar lands on the next bar rather
	# than a thirty-second early because the last note ended short.
	var snap := App.snap_beats()
	var shift := span - start
	if snap > 0.0:
		shift = ceilf(shift / snap - 0.001) * snap
	shift = maxf(shift, snap if snap > 0.0 else 0.0625)
	var added := []
	for i in App.selected_notes:
		var n: Dictionary = notes[int(i)]
		added.append(App.add_note(App.current_pattern, int(n.get("ch", App.current_channel)),
				float(n.beat) + shift, float(n.len), int(n.key), float(n.vel)))
	App.selected_notes = added
	App.note_edit_done(App.current_pattern)
	queue_redraw()


func _transpose(semitones: int) -> void:
	if App.selected_notes.is_empty():
		return
	App.snapshot("Transpose")
	var notes := _notes()
	for i in App.selected_notes:
		var n: Dictionary = notes[int(i)]
		App.update_note(App.current_pattern, int(i), {"key": clampi(int(n.key) + semitones, 0, 127)})
	App.note_edit_done(App.current_pattern)
	queue_redraw()


func _nudge(beats: float) -> void:
	if App.selected_notes.is_empty():
		return
	App.snapshot("Nudge")
	var notes := _notes()
	for i in App.selected_notes:
		var n: Dictionary = notes[int(i)]
		App.update_note(App.current_pattern, int(i), {"beat": maxf(0.0, float(n.beat) + beats)})
	App.note_edit_done(App.current_pattern)
	queue_redraw()


# ---------------------------------------------------------------------------
# Drawing
# ---------------------------------------------------------------------------
func _draw() -> void:
	var grid := _grid_rect()
	var font := get_theme_default_font()
	draw_rect(Rect2(Vector2.ZERO, size), CdPalette.VIEWPORT)
	if App.project.patterns.is_empty():
		return
	var pattern: Dictionary = App.project.patterns[App.current_pattern]
	var length := float(pattern.length)

	_draw_rows(grid)
	_draw_grid_lines(grid, length)
	_draw_notes(grid)
	_draw_velocity(font)
	_draw_keyboard(grid, font)
	_draw_ruler(font, length)
	_draw_scale_button(font)
	_draw_head(font, pattern)

	if _drag_mode == "select" and _band.size.length() > 2.0:
		draw_rect(_band, Color(CdPalette.ACCENT.r, CdPalette.ACCENT.g, CdPalette.ACCENT.b, 0.15))
		draw_rect(_band, CdPalette.ACCENT, false, 1.0)

	# Playhead over everything but the keyboard, at the point of the pattern
	# being played -- wherever in the song the clip playing it happens to sit.
	var beat := playhead_beat()
	if beat >= 0.0:
		var px := _beat_to_x(beat)
		if px >= KEY_W and px < size.x:
			_draw_playhead(px, _ruler_rect().position.y, grid.end.y)


## The strip along the top: which channel is being written, and which pattern it
## is being written into. The chooser is a real control and only needs putting
## in the right place; the pattern's name is drawn beside it, where there is room
## for it -- it used to be squeezed into the fifty pixels above the velocity lane
## along with the channel name, which fitted neither.
func _draw_head(font: Font, pattern: Dictionary) -> void:
	var r := _head_rect()
	draw_rect(r, CdPalette.PANEL)
	draw_line(Vector2(0, r.end.y), Vector2(size.x, r.end.y), CdPalette.RULE_DARK, 1.0)
	var left := 6.0
	# Their own heights, centred: a button is not free to be shorter than its
	# text and its arrow, and one asked to be shorter overhangs the strip and
	# lands back on the ruler, which is the whole thing being fixed.
	if _menu_btn != null:
		var mh: float = maxf(_menu_btn.get_combined_minimum_size().y, HEAD_H - 8.0)
		_menu_btn.size = Vector2(_menu_btn.get_combined_minimum_size().x, mh)
		_menu_btn.position = Vector2(left, maxf(0.0, (HEAD_H - mh) * 0.5))
		left += _menu_btn.size.x + 8.0
	if _channel_btn != null:
		var h: float = maxf(_channel_btn.get_combined_minimum_size().y, HEAD_H - 8.0)
		_channel_btn.size = Vector2(minf(220.0, maxf(120.0, size.x * 0.22)), h)
		_channel_btn.position = Vector2(left, maxf(0.0, (HEAD_H - h) * 0.5))
		left += _channel_btn.size.x + 10.0
	draw_string(font, Vector2(left, HEAD_H - 7.0), String(pattern.name),
			HORIZONTAL_ALIGNMENT_LEFT, maxf(0.0, size.x - left - 6.0), 10, CdPalette.TEXT_MUTE)


## The key picker, drawn like the control chooser under the keyboard so the two
## read as the same kind of thing.
func _draw_scale_button(font: Font) -> void:
	var r := _scale_button()
	var on: bool = scale_name != "Off"
	draw_rect(r, CdPalette.RAISED if on else CdPalette.PANEL)
	draw_rect(r, CdPalette.BEVEL_LO, false, 1.0)
	draw_string(font, Vector2(r.position.x + 5.0, r.position.y + r.size.y - 5.0),
			_scale_label(), HORIZONTAL_ALIGNMENT_LEFT, r.size.x - 8.0, 9,
			CdPalette.ACCENT if on else CdPalette.TEXT_MUTE)


## The marker: a flag in the ruler, a bright line under it, and a dark edge so
## it stays visible over a light clip as well as a dark grid.
func _draw_playhead(x: float, top: float, bottom: float) -> void:
	var c := CdPalette.PLAYHEAD
	draw_line(Vector2(x + 1.0, top), Vector2(x + 1.0, bottom), Color(0, 0, 0, 0.55), 3.0)
	draw_line(Vector2(x, top), Vector2(x, bottom), c, 1.6)
	var head := PackedVector2Array([
		Vector2(x - 6.0, top), Vector2(x + 6.0, top), Vector2(x, top + 9.0)])
	draw_colored_polygon(head, c)
	draw_polyline(PackedVector2Array([head[0], head[1], head[2], head[0]]),
			Color(0, 0, 0, 0.5), 1.0, true)


func _draw_rows(grid: Rect2) -> void:
	var first := int(scroll_key)
	var rows := int(grid.size.y / row_h) + 2
	var steps: Array = SCALES.get(scale_name, [])
	var lit := scale_root >= 0 and not steps.is_empty()
	for i in rows:
		var key := first + i
		if key > 127:
			break
		var y := _key_to_y(float(key))
		if y > grid.end.y or y + row_h < grid.position.y:
			continue
		var c := CdPalette.ROW_BLACK if Cd.is_black_key(key) else CdPalette.ROW_WHITE
		if key % 12 == 0:
			c = CdPalette.ROW_ROOT
		var r := Rect2(grid.position.x, maxf(y, grid.position.y), grid.size.x,
				minf(row_h, grid.end.y - y))
		draw_rect(r, c)
		if not lit:
			continue
		# In the key: lifted a shade, and the root of the scale more than the
		# rest. Out of it: darkened, so a run drawn by ear lands where it
		# should without having to count semitones.
		var step: int = posmod(key - scale_root, 12)
		if step == 0:
			draw_rect(r, Color(CdPalette.ACCENT.r, CdPalette.ACCENT.g, CdPalette.ACCENT.b, 0.13))
		elif steps.has(step):
			draw_rect(r, Color(1, 1, 1, 0.045))
		else:
			draw_rect(r, Color(0, 0, 0, 0.28))


func _draw_grid_lines(grid: Rect2, length: float) -> void:
	var snap := App.snap_beats()
	var fine := snap if snap > 0.0 else 0.25
	if fine * px_per_beat < 6.0:
		fine = 0.25
	while fine * px_per_beat < 6.0:
		fine *= 2.0
	var b := floorf(scroll_beat / fine) * fine
	while true:
		var x := _beat_to_x(b)
		if x > size.x:
			break
		if x >= grid.position.x:
			var col := CdPalette.GRID_FINE
			if is_equal_approx(fmod(b, 1.0), 0.0):
				col = CdPalette.GRID_BEAT
			if is_equal_approx(fmod(b, float(App.project.sig_num)), 0.0):
				col = CdPalette.GRID_BAR
			draw_line(Vector2(x, grid.position.y), Vector2(x, grid.end.y), col, 1.0)
		b += fine
	# Anything past the pattern's length is shaded: it will not sound.
	var end_x := _beat_to_x(length)
	if end_x < size.x:
		draw_rect(Rect2(maxf(end_x, grid.position.x), grid.position.y,
				size.x - maxf(end_x, grid.position.x), grid.size.y), Color(0, 0, 0, 0.35))


func _draw_notes(grid: Rect2) -> void:
	var notes := _notes()
	# Selection lookup built once: asking an Array whether it holds each index
	# is a scan per note, which is a scan per note per frame.
	var selected := {}
	for i in App.selected_notes:
		selected[int(i)] = true
	var channel := App.current_channel
	# Other channels first, dimmed, so context is visible but not distracting.
	for i in notes.size():
		var n: Dictionary = notes[i]
		if int(n.ch) == channel:
			continue
		var r := _note_rect(n)
		if r.end.x < grid.position.x or r.position.x > size.x or r.end.y < grid.position.y or r.position.y > grid.end.y:
			continue
		var c := CdPalette.track_color(int(n.ch))
		draw_rect(r, Color(c.r, c.g, c.b, 0.22))
	for i in notes.size():
		var n: Dictionary = notes[i]
		if int(n.ch) != channel:
			continue
		var r := _note_rect(n)
		if r.end.x < grid.position.x or r.position.x > size.x or r.end.y < grid.position.y or r.position.y > grid.end.y:
			continue
		var sel: bool = selected.has(i)
		var muted := bool(n.get("mute", false))
		var c := CdPalette.note_color(float(n.vel), sel)
		if muted:
			draw_rect(r, Color(c.r, c.g, c.b, 0.18))
			draw_rect(r, c.darkened(0.3), false, 1.0)
		else:
			draw_rect(r, c)
			draw_rect(r, CdPalette.WELL if not sel else CdPalette.TEXT, false, 1.0)
		if _lit.has(int(n.key)) and not muted:
			# Sounding right now: outline it.
			draw_rect(r.grow(1.0), CdPalette.PLAYHEAD, false, 1.0)
		if r.size.x > 26.0 and row_h >= 11.0:
			draw_string(get_theme_default_font(), r.position + Vector2(3, row_h - 4.0),
					Cd.note_name(int(n.key)), HORIZONTAL_ALIGNMENT_LEFT, r.size.x - 5, 8,
					Color(0, 0, 0, 0.65))
		if i == _hover_note:
			draw_rect(Rect2(r.end.x - _edge_zone(r), r.position.y, _edge_zone(r), r.size.y),
					CdPalette.TEXT_DIM)


## The control the lane is showing.
func _control() -> Dictionary:
	return CONTROLS[clampi(control, 0, CONTROLS.size() - 1)]


## A note's value for it, and the same value back as a height up the lane.
func _control_value(n: Dictionary) -> float:
	var c := _control()
	return float(n.get(String(c.id), float(c.default)))


func _control_t(v: float) -> float:
	var c := _control()
	return clampf((v - float(c.lo)) / maxf(0.0001, float(c.hi) - float(c.lo)), 0.0, 1.0)


## The button that opens the list of controls, at the left of the lane.
func _control_button() -> Rect2:
	return Rect2(2.0, size.y - VEL_H + 2.0, KEY_W - 4.0, 15.0)


## The key picker sits in the corner above the keyboard, where the ruler and
## the key column meet: the one piece of the editor that is not the grid.
func _scale_button() -> Rect2:
	return Rect2(2.0, HEAD_H + 2.0, KEY_W - 4.0, RULER_H - 4.0)


## What the key picker says: "C Minor", or "Key" when nothing is chosen.
func _scale_label() -> String:
	if scale_name == "Off" or not SCALES.has(scale_name):
		return "Key"
	return "%s %s" % [NOTE_NAMES[posmod(scale_root, 12)], scale_name]


## Root notes and scales, the way FL offers them: pick a key and the rows that
## belong to it light up.
func _scale_menu() -> void:
	var pm := PopupMenu.new()
	add_child(pm)
	pm.add_separator("Key")
	for i in NOTE_NAMES.size():
		pm.add_radio_check_item(NOTE_NAMES[i], i)
		pm.set_item_checked(pm.item_count - 1, i == posmod(scale_root, 12))
	pm.add_separator("Scale")
	var names: Array = SCALES.keys()
	for i in names.size():
		pm.add_radio_check_item(String(names[i]), 100 + i)
		pm.set_item_checked(pm.item_count - 1, String(names[i]) == scale_name)
	pm.id_pressed.connect(func(id):
		if int(id) >= 100:
			scale_name = String(names[int(id) - 100])
			Settings.set_value("scale_name", scale_name)
		else:
			scale_root = int(id)
			Settings.set_value("scale_root", scale_root)
		App.status.emit("Piano roll key: %s" % _scale_label())
		queue_redraw())
	pm.popup_hide.connect(func(): pm.queue_free(), CONNECT_DEFERRED)
	pm.popup(Rect2i(DisplayServer.mouse_get_position(), Vector2i(1, 1)))


func _draw_velocity(font: Font) -> void:
	var r := _vel_rect()
	var c := _control()
	draw_rect(r, CdPalette.WELL)
	draw_line(r.position, Vector2(size.x, r.position.y), CdPalette.RULE_DARK, 1.0)

	# The chooser. It looks like a button because it is one: clicking it opens
	# the list of everything the lane can edit.
	var btn := _control_button()
	draw_rect(btn, CdPalette.RAISED)
	draw_rect(btn, CdPalette.BEVEL_LO, false, 1.0)
	draw_string(font, Vector2(btn.position.x + 4.0, btn.end.y - 4.0),
			String(c.name).replace("Note ", ""), HORIZONTAL_ALIGNMENT_LEFT,
			btn.size.x - 14.0, 8, CdPalette.TEXT_DIM)
	var ax: float = btn.end.x - 8.0
	var ay: float = btn.get_center().y - 1.0
	draw_colored_polygon(PackedVector2Array([Vector2(ax - 3.0, ay), Vector2(ax + 3.0, ay),
			Vector2(ax, ay + 3.5)]), CdPalette.TEXT_MUTE)

	var zero := r.end.y - r.size.y * _control_t(0.0 if bool(c.centred) else float(c.lo))
	for level: float in [0.25, 0.5, 0.75]:
		var y := r.end.y - r.size.y * level
		draw_line(Vector2(r.position.x, y), Vector2(size.x, y), CdPalette.GRID_FINE, 1.0)
	if bool(c.centred):
		draw_line(Vector2(r.position.x, zero), Vector2(size.x, zero), CdPalette.RULE_DARK, 1.0)

	var notes := _notes()
	for i in notes.size():
		var n: Dictionary = notes[i]
		if int(n.ch) != App.current_channel:
			continue
		var x := _beat_to_x(float(n.beat))
		if x < r.position.x - 4.0 or x > size.x:
			continue
		var v := _control_value(n)
		var y := r.end.y - r.size.y * _control_t(v)
		var col := CdPalette.note_color(float(n.vel), App.selected_notes.has(i))
		# From the middle for the ones that have a middle, from the floor for
		# the ones that do not.
		var top: float = minf(y, zero)
		var h: float = maxf(1.0, absf(y - zero))
		draw_rect(Rect2(x, top, 3.0, h), col)
		draw_circle(Vector2(x + 1.5, y), 3.0, col)


func _draw_keyboard(grid: Rect2, font: Font) -> void:
	draw_rect(Rect2(0, grid.position.y, KEY_W, grid.size.y), CdPalette.PANEL)
	var first := int(scroll_key)
	var rows := int(grid.size.y / row_h) + 2
	for i in rows:
		var key := first + i
		if key > 127:
			break
		var y := _key_to_y(float(key))
		if y > grid.end.y or y + row_h < grid.position.y:
			continue
		var black := Cd.is_black_key(key)
		# White keys butt against each other -- a gap between every row makes a
		# keyboard read as a stack of bars. Only the B/C and E/F joins are drawn.
		var r := Rect2(0, maxf(y, grid.position.y), KEY_W - (16.0 if black else 0.0),
				minf(row_h - (1.0 if black else 0.0), grid.end.y - y))
		var lit: bool = _lit.has(key)
		draw_rect(r, CdPalette.KEY_BLACK if black else CdPalette.KEY_WHITE)
		if lit:
			draw_rect(r, CdPalette.ACCENT)
			# A wash across the row makes it obvious which line is sounding.
			draw_rect(Rect2(KEY_W, r.position.y, size.x - KEY_W, r.size.y),
					Color(CdPalette.ACCENT.r, CdPalette.ACCENT.g, CdPalette.ACCENT.b, 0.10))
		if not black and (key % 12 == 0 or key % 12 == 5):
			draw_line(Vector2(0, r.position.y), Vector2(KEY_W, r.position.y), CdPalette.WELL, 1.0)
		if key == _ghost_key:
			draw_rect(r, CdPalette.ACCENT)
		if not black and key % 12 == 0 and row_h >= 8.0:
			draw_string(font, Vector2(4, r.position.y + r.size.y - 2.0), Cd.note_name(key),
					HORIZONTAL_ALIGNMENT_LEFT, KEY_W - 6, 8, CdPalette.WELL)
	draw_line(Vector2(KEY_W, grid.position.y), Vector2(KEY_W, grid.end.y), CdPalette.RULE_DARK, 1.0)


func _draw_ruler(font: Font, length: float) -> void:
	var strip := _ruler_rect()
	var top := strip.position.y
	var bot := strip.end.y
	draw_rect(strip, CdPalette.CAPTION)
	draw_line(Vector2(0, bot), Vector2(size.x, bot), CdPalette.RULE_DARK, 1.0)
	var sig := float(App.project.sig_num)
	# Numbers every few bars once they would otherwise run into each other.
	var step := Cd.ruler_step(px_per_beat, int(sig))
	var per_bar := px_per_beat * sig
	var bar := floorf(scroll_beat / sig) * sig
	while true:
		var x := _beat_to_x(bar)
		if x > size.x:
			break
		if x >= KEY_W:
			var number := int(bar / sig) + 1
			if Cd.ruler_labels(number, step):
				draw_line(Vector2(x, top + 4), Vector2(x, bot), CdPalette.TEXT_MUTE, 1.0)
				draw_string(font, Vector2(x + 3, top + 13), str(number),
						HORIZONTAL_ALIGNMENT_LEFT, -1, 9, CdPalette.TEXT_DIM)
			elif per_bar >= 14.0:
				draw_line(Vector2(x, bot - 5), Vector2(x, bot), CdPalette.RULE_LIGHT, 1.0)
		if px_per_beat > 40.0:
			for b in range(1, int(sig)):
				var bx := _beat_to_x(bar + float(b))
				if bx >= KEY_W and bx < size.x:
					draw_line(Vector2(bx, bot - 6), Vector2(bx, bot), CdPalette.RULE_LIGHT, 1.0)
		bar += sig
	var ex := _beat_to_x(length)
	if ex >= KEY_W and ex < size.x:
		draw_line(Vector2(ex, top), Vector2(ex, bot), CdPalette.ACCENT, 2.0)
		# A grab tab, so the end of the pattern reads as a handle.
		var tab := PackedVector2Array([
			Vector2(ex, bot - 10.0), Vector2(ex + 8.0, bot - 6.0), Vector2(ex, bot - 2.0)])
		draw_colored_polygon(tab, CdPalette.ACCENT)
