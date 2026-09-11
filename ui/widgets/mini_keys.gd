extends Control
## A two-and-a-bit octave keyboard under an instrument, for auditioning without
## reaching for the piano roll. Follows the typing keyboard's octave.

var channel := 0
var _held := -1
const FIRST := 36
const KEYS := 37


var _lit := {}


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	focus_mode = Control.FOCUS_NONE
	tooltip_text = "Click to audition; the computer keyboard plays too"
	set_process(true)
	tree_exiting.connect(_let_go)


## Own name in App's live-note book, so this keyboard can let go of its note
## without disturbing one the typing keyboard or a MIDI device is holding.
func _source() -> String:
	return "keys%d" % get_instance_id()


func _let_go() -> void:
	if _held < 0:
		return
	App.live_note_off(_held, _source())
	_held = -1
	queue_redraw()


func _process(_dt: float) -> void:
	# A button-up that lands outside this control -- released over another
	# window, or after a dialog opened under the pointer -- never arrives as an
	# event, so the button state is what decides whether the note is still held.
	if _held >= 0 and not Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		_let_go()
	if Audio.engine == null:
		return
	var lit := {}
	for k in Audio.engine.active_notes(channel):
		lit[int(k)] = true
	if lit != _lit:
		_lit = lit
		queue_redraw()


func _white_count() -> int:
	var n := 0
	for i in KEYS:
		if not Cd.is_black_key(FIRST + i):
			n += 1
	return n


func _key_at(pos: Vector2) -> int:
	var ww := size.x / float(_white_count())
	# Black keys sit on top, so test them first.
	var wi := 0
	for i in KEYS:
		var key := FIRST + i
		if Cd.is_black_key(key):
			var x := wi * ww - ww * 0.3
			if Rect2(x, 0, ww * 0.6, size.y * 0.6).has_point(pos):
				return key
		else:
			wi += 1
	wi = 0
	for i in KEYS:
		var key := FIRST + i
		if not Cd.is_black_key(key):
			if Rect2(wi * ww, 0, ww, size.y).has_point(pos):
				return key
			wi += 1
	return -1


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			var k := _key_at(event.position)
			if k >= 0:
				_held = k
				App.live_note_on(k, 0.85, _source())
		elif _held >= 0:
			_let_go()
		queue_redraw()
		accept_event()
	elif event is InputEventMouseMotion and _held >= 0:
		var k := _key_at(event.position)
		if k >= 0 and k != _held:
			App.live_note_off(_held, _source())
			App.live_note_on(k, 0.85, _source())
			_held = k
			queue_redraw()


func _draw() -> void:
	var ww := size.x / float(_white_count())
	var wi := 0
	for i in KEYS:
		var key := FIRST + i
		if Cd.is_black_key(key):
			continue
		var r := Rect2(wi * ww + 0.5, 0, ww - 1.0, size.y)
		draw_rect(r, CdPalette.ACCENT if (key == _held or _lit.has(key)) else CdPalette.KEY_WHITE)
		draw_rect(r, CdPalette.BEVEL_LO, false, 1.0)
		if key % 12 == 0:
			draw_string(get_theme_default_font(), Vector2(r.position.x + 2, size.y - 3),
					Cd.note_name(key), HORIZONTAL_ALIGNMENT_LEFT, ww, 8, CdPalette.TEXT_MUTE)
		wi += 1
	wi = 0
	for i in KEYS:
		var key := FIRST + i
		if not Cd.is_black_key(key):
			wi += 1
			continue
		var r := Rect2(wi * ww - ww * 0.3, 0, ww * 0.6, size.y * 0.6)
		draw_rect(r, CdPalette.ACCENT if (key == _held or _lit.has(key)) else CdPalette.KEY_BLACK)
