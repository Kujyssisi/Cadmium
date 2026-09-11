class_name CdFader
extends Control
## The mixer's vertical fader: 0..1 of travel over -60..+6 dB, with the useful
## part of the range spread out where the hand expects it.

signal value_changed(value: float)
signal edit_finished()
## Panels that offer more than a reset -- automation, say -- take the menu
## over. Everywhere else gets the built-in one.
signal menu_requested(at: Vector2)

var gain := 1.0:
	set(v):
		gain = maxf(0.0, v)
		queue_redraw()

var _dragging := false
var _press_pos := Vector2.ZERO
var _accum := 0.0

## What this fader is, for automation -- see CdKnob.auto_ref.
var auto_ref := {}:
	set(v):
		auto_ref = v
		if not auto_ref.is_empty() and not App.automation_changed.is_connected(_check_automated):
			App.automation_changed.connect(_check_automated)
			App.project_loaded.connect(_check_automated)
			App.automation_tick.connect(_follow_automation)
		_check_automated()

var automated := false:
	set(v):
		if automated == v:
			return
		automated = v
		queue_redraw()


## Which lane is driving this control, so following it is a lookup rather than
## a search every thirtieth of a second.
var _auto_lane := -1


func _check_automated() -> void:
	if auto_ref.is_empty():
		_auto_lane = -1
		automated = false
		return
	_auto_lane = App.automated_lane(int(auto_ref.get("target", 0)), auto_ref.get("ref", {}),
			int(auto_ref.get("a", 0)), int(auto_ref.get("b", 0)))
	automated = _auto_lane >= 0


func _follow_automation() -> void:
	# A control can be worth lighting up without being worth moving: the
	# sampler's stretching knobs are automated as playback speed, which is not
	# the number written on them.
	if not automated or _dragging or not is_visible_in_tree():
		return
	if not bool(auto_ref.get("follow", true)):
		return
	# The curve where the engine keeps its own copy of the value -- a mixer
	# fader, a channel, a sample -- and the plugin itself where the engine
	# writes into the plugin, which is the value anyone would read back.
	var v := App.live_automation_value(_auto_lane)
	if is_nan(v):
		v = App.control_value(int(auto_ref.get("target", 0)), auto_ref.get("ref", {}),
				int(auto_ref.get("a", 0)), int(auto_ref.get("b", 0)))
	if is_equal_approx(v, gain):
		return
	gain = v
## Distance between the cap's centre and where it was grabbed, so picking the
## cap up by its edge does not jump it under the pointer.
var _grab_offset := 0.0


func _ready() -> void:
	focus_mode = Control.FOCUS_NONE
	custom_minimum_size = Vector2(22, 90)
	# Only while dragging: see _process.
	set_process(false)


## Runs only for the one control being dragged: a button released outside the
## window never comes back as an event, so the drag has to be ended by watching
## the real button state.
func _process(_dt: float) -> void:
	if not _dragging:
		set_process(false)
		return
	if not Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		_dragging = false
		set_process(false)
		edit_finished.emit()


func _travel() -> float:
	return Cd.gain_to_fader(gain)


## The track the cap slides along, matching what _draw puts on screen.
func _track() -> Rect2:
	return Rect2(size.x * 0.5 - 3.0, 6.0, 6.0, size.y - 12.0)


## Travel for a pointer at `y`. A fader is a thing you put where you want it,
## so this is the position on the track, not an accumulated distance.
func _travel_at(y: float) -> float:
	var t := _track()
	return clampf(1.0 - (y - _grab_offset - t.position.y) / maxf(1.0, t.size.y), 0.0, 1.0)


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed:
				if mb.double_click:
					gain = 1.0
					value_changed.emit(gain)
					edit_finished.emit()
					return
				_dragging = true
				set_process(true)
				_press_pos = get_viewport().get_mouse_position()
				var t := _track()
				var cap_y := t.position.y + t.size.y * (1.0 - _travel())
				# Grabbed the cap: keep the grip where it was taken. Clicked the
				# track somewhere else: the cap comes to the pointer.
				_grab_offset = mb.position.y - cap_y if absf(mb.position.y - cap_y) <= 8.0 else 0.0
				_accum = _travel_at(mb.position.y)
				if not is_equal_approx(_accum, _travel()):
					gain = Cd.fader_to_gain(_accum)
					value_changed.emit(gain)
			elif _dragging:
				_dragging = false
				edit_finished.emit()
			accept_event()
		elif mb.button_index == MOUSE_BUTTON_RIGHT and mb.pressed:
			if not menu_requested.get_connections().is_empty():
				menu_requested.emit(get_global_mouse_position())
				accept_event()
				return
			var pm := PopupMenu.new()
			pm.add_item("Reset to 0 dB", 0)
			pm.add_separator()
			pm.add_item("Silence", 1)
			add_child(pm)
			pm.id_pressed.connect(func(id):
				gain = 1.0 if id == 0 else 0.0
				value_changed.emit(gain)
				edit_finished.emit()
				pm.queue_free())
			pm.popup_hide.connect(func(): pm.queue_free())
			pm.popup(Rect2i(DisplayServer.mouse_get_position(), Vector2i(1, 1)))
			accept_event()
		elif mb.pressed and mb.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]:
			var step := 0.01 if mb.shift_pressed else 0.03
			gain = Cd.fader_to_gain(clampf(_travel() + (step if mb.button_index == MOUSE_BUTTON_WHEEL_UP else -step), 0.0, 1.0))
			value_changed.emit(gain)
			edit_finished.emit()
			accept_event()
	elif event is InputEventMouseMotion and _dragging:
		var mm := event as InputEventMouseMotion
		if mm.shift_pressed:
			# Fine: relative and slow, for the last half a decibel.
			_accum = clampf(_accum - mm.relative.y * 0.0012, 0.0, 1.0)
		else:
			# The cap follows the pointer, the way a fader does.
			_accum = _travel_at(mm.position.y)
		gain = Cd.fader_to_gain(_accum)
		value_changed.emit(gain)
		accept_event()


func _draw() -> void:
	var track := Rect2(size.x * 0.5 - 3.0, 6.0, 6.0, size.y - 12.0)
	draw_rect(track, CdPalette.WELL)
	draw_rect(track, CdPalette.BEVEL_LO, false, 1.0)
	# Unity mark, so 0 dB is findable without reading the number.
	var unity := 1.0 - Cd.gain_to_fader(1.0)
	var uy := track.position.y + track.size.y * unity
	draw_line(Vector2(2, uy), Vector2(size.x - 2, uy), CdPalette.RULE_LIGHT, 1.0)

	var t := _travel()
	var y := track.position.y + track.size.y * (1.0 - t)
	var fill := Rect2(track.position.x, y, track.size.x, track.position.y + track.size.y - y)
	# Lighter when something is driving it, the same as an automated knob.
	draw_rect(fill, CdPalette.ACCENT_DARK.lightened(0.35) if automated else CdPalette.ACCENT_DARK)

	var cap := Rect2(2.0, y - 6.0, size.x - 4.0, 12.0)
	draw_rect(cap, CdPalette.RAISED_HI if (_dragging or automated) else CdPalette.RAISED)
	draw_rect(cap, CdPalette.BEVEL_LO, false, 1.0)
	draw_line(Vector2(cap.position.x + 2, y), Vector2(cap.end.x - 2, y),
			CdPalette.ACCENT.lightened(0.45) if automated else CdPalette.ACCENT, 1.0)
