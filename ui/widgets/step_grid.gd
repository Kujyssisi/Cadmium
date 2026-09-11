extends Control
## One channel's row of sixteenth-note steps. Left click toggles, left drag
## paints, right drag erases, and dragging up or down on a lit step sets its
## velocity -- the same gestures a hardware sequencer would give you.

const STEP_W := 22.0

var channel := 0
var steps := 16

var _paint := 0        # 0 none, 1 draw, -1 erase
var _vel_step := -1
var _vel_start := 0.0
var _vel_origin := 0.0


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	focus_mode = Control.FOCUS_NONE
	set_process(true)


func _process(_dt: float) -> void:
	if (_paint != 0 or _vel_step >= 0) and not Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT) \
			and not Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT):
		if _vel_step >= 0:
			App.note_edit_done(App.current_pattern)
		_paint = 0
		_vel_step = -1
	tooltip_text = "Click a step to place a note; drag up or down on one to set velocity"


func _step_at(x: float) -> int:
	return clampi(int(x / STEP_W), 0, steps - 1)


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		var s := _step_at(mb.position.x)
		if mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed:
				App.select_channel(channel)
				var existing := App.step_state(App.current_pattern, channel, s)
				if existing.is_empty():
					App.toggle_step(App.current_pattern, channel, s)
					_paint = 1
				else:
					_vel_step = s
					_vel_start = mb.position.y
					_vel_origin = float(existing.vel)
					_paint = 0
			else:
				if _vel_step >= 0:
					App.note_edit_done(App.current_pattern)
				_paint = 0
				_vel_step = -1
			queue_redraw()
			accept_event()
		elif mb.button_index == MOUSE_BUTTON_RIGHT:
			if mb.pressed:
				_paint = -1
				if not App.step_state(App.current_pattern, channel, s).is_empty():
					App.toggle_step(App.current_pattern, channel, s)
			else:
				_paint = 0
			queue_redraw()
			accept_event()
	elif event is InputEventMouseMotion:
		var mm := event as InputEventMouseMotion
		if _vel_step >= 0:
			var v := clampf(_vel_origin - (mm.position.y - _vel_start) / 60.0, 0.05, 1.0)
			_set_velocity(_vel_step, v)
			queue_redraw()
			accept_event()
			return
		if _paint == 0:
			return
		var s := _step_at(mm.position.x)
		var on := not App.step_state(App.current_pattern, channel, s).is_empty()
		if _paint == 1 and not on:
			App.toggle_step(App.current_pattern, channel, s)
		elif _paint == -1 and on:
			App.toggle_step(App.current_pattern, channel, s)
		queue_redraw()
		accept_event()


func _set_velocity(step: int, v: float) -> void:
	var notes: Array = App.project.patterns[App.current_pattern].notes
	var beat := float(step) * Cd.STEP
	for i in notes.size():
		var n: Dictionary = notes[i]
		if int(n.ch) == channel and absf(float(n.beat) - beat) < 0.001:
			App.update_note(App.current_pattern, i, {"vel": v})
			return


func _draw() -> void:
	var h := size.y
	var playing_step := -1
	if Audio.playing() and App.mode() == Cd.Mode.PATTERN:
		playing_step = int(Audio.position() / Cd.STEP) % maxi(1, steps)
	for s in steps:
		var x := s * STEP_W
		var beat_start := (s % 4) == 0
		var bar_start := (s % 16) == 0
		var bg := CdPalette.SUNKEN if not beat_start else CdPalette.WELL.lightened(0.03)
		if bar_start:
			bg = CdPalette.WELL
		if s == playing_step:
			bg = bg.lightened(0.14)
		draw_rect(Rect2(x + 1, 1, STEP_W - 2, h - 2), bg)
		var state := App.step_state(App.current_pattern, channel, s)
		if not state.is_empty():
			var vel := float(state.vel)
			var col := CdPalette.ACCENT.lerp(Color("#ffd9d2"), vel * 0.4)
			var pad := 2.0
			var lit := Rect2(x + pad, 2.0 + (h - 4.0) * (1.0 - vel), STEP_W - pad * 2.0, (h - 4.0) * vel)
			draw_rect(Rect2(x + pad, 2, STEP_W - pad * 2.0, h - 4), CdPalette.ACCENT_DARK.darkened(0.25))
			draw_rect(lit, col)
		if bar_start and s > 0:
			draw_line(Vector2(x, 0), Vector2(x, h), CdPalette.RULE_LIGHT, 1.0)
