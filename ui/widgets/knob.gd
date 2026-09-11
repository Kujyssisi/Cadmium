class_name CdKnob
extends Control
## A rotary control. Drag anywhere on it to turn: the pointer stays where it is
## and stays visible, so the knob behaves like every other draggable thing.
##
## Shift is fine, Ctrl is coarse (snaps to steps), double-click resets, and a
## right click offers the parameter menu the panels fill in.

signal value_changed(value: float)
signal edit_finished()
signal menu_requested(position: Vector2)

@export var label := ""
@export var minimum := 0.0
@export var maximum := 1.0
@export var default_value := 0.0
@export var skew := 1.0
@export var kind := Cd.ParamKind.FLOAT
@export var choices := ""
@export var show_label := true
@export var knob_size := 34.0
## How many steps the value has between minimum and maximum, 0 for continuous.
## A hosted plugin snaps a stepped parameter to its nearest step, so a knob
## that turns smoothly through one looks like a knob that does nothing: you
## move it a quarter of the way and the plugin is still on the same setting.
@export var steps := 0
## The plugin reports this value but will not be told it -- a latency readout,
## a meter. Shown, not turned.
@export var readonly := false

var value := 0.0:
	set(v):
		var c := clampf(v, minf(minimum, maximum), maxf(minimum, maximum))
		if is_equal_approx(c, value):
			return
		value = c
		queue_redraw()

## When set, this supplies the readout instead of Cd.format_param -- a hosted
## plugin knows how to spell its own values and we should not guess.
var value_text_fn: Callable = Callable()

var _dragging := false
var _press_pos := Vector2.ZERO
var _accum := 0.0
var _hover := false

## What this knob is, for automation: {target, ref, a, b}. Setting it is what
## makes the knob light up when a lane is driving it and move on its own while
## the song plays. Empty means it is not something that can be automated.
var auto_ref := {}:
	set(v):
		auto_ref = v
		if not auto_ref.is_empty() and not App.automation_changed.is_connected(_check_automated):
			App.automation_changed.connect(_check_automated)
			App.project_loaded.connect(_check_automated)
			App.automation_tick.connect(_follow_automation)
		_check_automated()

## Something is driving this control. Drawn lighter so you can see it at a
## glance, without a label or a badge taking up room in a rack of them.
var automated := false:
	set(v):
		if automated == v:
			return
		automated = v
		queue_redraw()

## Where the lane driving this control stands, when that is not the same thing
## as the knob's own value -- the sampler's stretching knobs, which are
## automated as playback speed. Drawn as a light mark riding the rim so it can
## be watched moving without the knob itself telling a lie about what it is
## set to. NAN means there is nothing to draw.
var overlay := NAN:
	set(v):
		if is_nan(v) and is_nan(overlay):
			return
		if not is_nan(v) and not is_nan(overlay) and is_equal_approx(v, overlay):
			return
		overlay = v
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


## Only what can be seen, and never the one being held: following a lane while
## somebody is turning the knob would fight their hand.
func _follow_automation() -> void:
	# A control can be worth lighting up without being worth moving: the
	# sampler's stretching knobs are automated as playback speed, which is not
	# the number written on them. Those get the mark on the rim instead.
	if not automated or not is_visible_in_tree() or not Audio.playing():
		overlay = NAN
		return
	if _dragging:
		return
	# The curve where the engine keeps its own copy of the value -- a mixer
	# fader, a channel, a sample -- and the plugin itself where the engine
	# writes into the plugin, which is the value anyone would read back.
	var v := App.live_automation_value(_auto_lane)
	if is_nan(v):
		v = App.control_value(int(auto_ref.get("target", 0)), auto_ref.get("ref", {}),
				int(auto_ref.get("a", 0)), int(auto_ref.get("b", 0)))
	if not bool(auto_ref.get("follow", true)):
		# The knob keeps saying what it is set to; the lane rides the rim.
		overlay = v
		return
	if is_equal_approx(v, value):
		return
	set_value_silent(v)


func _ready() -> void:
	focus_mode = Control.FOCUS_NONE
	mouse_filter = Control.MOUSE_FILTER_STOP
	# Only while dragging: see _process.
	set_process(false)
	# Only when the scene did not say: a knob in a rack row is given a box to
	# sit in, and asking for a bigger one pushes the row apart.
	if custom_minimum_size == Vector2.ZERO:
		custom_minimum_size = Vector2(knob_size + 8.0,
				knob_size + (18.0 if show_label else 4.0) + 12.0)


## Sets the value without telling anyone, for when the model changed underneath.
func set_value_silent(v: float) -> void:
	value = v


func setup(p: Dictionary, v: float) -> void:
	label = String(p.get("name", ""))
	minimum = float(p.get("min", 0.0))
	maximum = float(p.get("max", 1.0))
	default_value = float(p.get("default", 0.0))
	skew = float(p.get("skew", 1.0))
	kind = int(p.get("kind", Cd.ParamKind.FLOAT))
	choices = String(p.get("choices", ""))
	steps = int(p.get("steps", 0))
	readonly = bool(p.get("readonly", false))
	value = v
	tooltip_text = "%s\n%s" % [label, text_value()]
	queue_redraw()


func text_value() -> String:
	if value_text_fn.is_valid():
		var t: String = value_text_fn.call(value)
		if not t.is_empty():
			return t
	return Cd.format_param(value, kind, choices)


func _norm() -> float:
	return Cd.to_norm(value, minimum, maximum, skew)


func _set_norm(n: float) -> void:
	if steps > 0:
		n = roundf(clampf(n, 0.0, 1.0) * float(steps)) / float(steps)
	var v := Cd.from_norm(n, minimum, maximum, skew)
	if kind == Cd.ParamKind.CHOICE or kind == Cd.ParamKind.BOOL or kind == Cd.ParamKind.SEMI:
		v = roundf(v)
	if steps > 0 and is_equal_approx(v, value):
		# Still on the same step: nothing to tell anyone, and telling them
		# anyway floods a hosted plugin with changes it did not make.
		return
	value = v
	tooltip_text = "%s\n%s" % [label, text_value()]
	value_changed.emit(value)


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


func _gui_input(event: InputEvent) -> void:
	if readonly:
		# Still offers its menu, so the value can be read and copied; just not
		# turned, because the plugin would put it straight back.
		if event is InputEventMouseButton and event.pressed \
				and event.button_index == MOUSE_BUTTON_RIGHT:
			if menu_requested.get_connections().is_empty():
				_default_menu()
			else:
				menu_requested.emit(get_global_mouse_position())
			accept_event()
		return
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed:
				if mb.double_click:
					value = default_value
					_set_norm(_norm())
					edit_finished.emit()
					return
				_dragging = true
				set_process(true)
				_press_pos = get_viewport().get_mouse_position()
				_accum = _norm()
			elif _dragging:
				_dragging = false
				edit_finished.emit()
			accept_event()
		elif mb.button_index == MOUSE_BUTTON_RIGHT and mb.pressed:
			# Panels that offer more than a reset -- automation, say -- take the
			# menu over. Everywhere else gets the built-in one, so every knob in
			# the program can be put back where it started.
			if menu_requested.get_connections().is_empty():
				_default_menu()
			else:
				menu_requested.emit(get_global_mouse_position())
			accept_event()
		elif mb.pressed and (mb.button_index == MOUSE_BUTTON_WHEEL_UP or mb.button_index == MOUSE_BUTTON_WHEEL_DOWN):
			var step := 0.02 if not mb.shift_pressed else 0.005
			if steps > 0:
				step = 1.0 / float(steps)
			elif kind == Cd.ParamKind.CHOICE or kind == Cd.ParamKind.BOOL or kind == Cd.ParamKind.SEMI:
				step = 1.0 / maxf(1.0, absf(maximum - minimum))
			_set_norm(clampf(_norm() + (step if mb.button_index == MOUSE_BUTTON_WHEEL_UP else -step), 0.0, 1.0))
			edit_finished.emit()
			accept_event()
	elif event is InputEventMouseMotion and _dragging:
		var mm := event as InputEventMouseMotion
		# Plain relative motion, pointer left where it is. Holding it in place
		# needs a pointer warp, which does not survive this desktop, so the
		# answer is a short throw instead: about eighty pixels covers the whole
		# range, and shift is a tenth of that for fine work.
		var speed := 0.0012 if mm.shift_pressed else 0.012
		_accum = clampf(_accum - mm.relative.y * speed, 0.0, 1.0)
		_set_norm(_accum)
		accept_event()


## Reset, and the finer steps that are awkward to reach by dragging.
func _default_menu() -> void:
	var pm := PopupMenu.new()
	pm.add_item("Reset to %s" % Cd.format_param(default_value, kind, choices), 0)
	pm.add_separator()
	pm.add_item("Minimum  (%s)" % Cd.format_param(minimum, kind, choices), 1)
	pm.add_item("Middle" if kind != Cd.ParamKind.PCT else "Half", 2)
	pm.add_item("Maximum  (%s)" % Cd.format_param(maximum, kind, choices), 3)
	add_child(pm)
	pm.id_pressed.connect(func(id):
		match id:
			0: value = default_value
			1: value = minimum
			2: value = (minimum + maximum) * 0.5
			3: value = maximum
		value_changed.emit(value)
		edit_finished.emit()
		pm.queue_free())
	pm.popup_hide.connect(func(): pm.queue_free())
	pm.popup(Rect2i(DisplayServer.mouse_get_position(), Vector2i(1, 1)))


func _notification(what: int) -> void:
	if what == NOTIFICATION_MOUSE_ENTER:
		_hover = true
		queue_redraw()
	elif what == NOTIFICATION_MOUSE_EXIT:
		_hover = false
		queue_redraw()


func _draw() -> void:
	var font := get_theme_default_font()
	var fs := 9
	# Fitted to the box it was actually given rather than to what it asked for,
	# and centred in it: a knob squeezed into a rack row would otherwise draw
	# over the row above and the row below.
	var label_h := 13.0 if show_label else 0.0
	# The rim is drawn four pixels wide on the radius, so the box has to hold
	# the circle and that stroke, not just the circle.
	var r: float = maxf(5.0, minf(knob_size, minf(size.x - 6.0, size.y - label_h - 6.0)) * 0.5)
	var centre := Vector2(size.x * 0.5, (size.y - label_h) * 0.5)
	var n := _norm()
	# 270 degrees of travel, gap at the bottom.
	var a0 := deg_to_rad(135.0)
	var a1 := deg_to_rad(405.0)
	var a := lerpf(a0, a1, n)

	# An automated knob wears a lighter version of the same colour, and a faint
	# halo outside its rim: it reads as "something else is holding this" from
	# across a rack without anything being written on it.
	var arc := CdPalette.ACCENT.lightened(0.45) if automated else CdPalette.ACCENT
	draw_arc(centre, r, a0, a1, 40, CdPalette.SUNKEN, 4.0, true)
	if automated:
		draw_arc(centre, r + 2.5, a0, a1, 40, Color(arc.r, arc.g, arc.b, 0.22), 2.0, true)
	draw_circle(centre, r - 3.0, CdPalette.RAISED_HI if (_hover or automated) else CdPalette.RAISED)
	draw_arc(centre, r - 3.0, 0.0, TAU, 32, CdPalette.BEVEL_LO, 1.0, true)
	if kind == Cd.ParamKind.FLOAT and minimum < 0.0 and maximum > 0.0:
		# Bipolar: fill out from the centre detent.
		var mid := lerpf(a0, a1, Cd.to_norm(0.0, minimum, maximum, skew))
		draw_arc(centre, r, minf(mid, a), maxf(mid, a), 32, arc, 4.0, true)
	else:
		draw_arc(centre, r, a0, a, 32, arc, 4.0, true)
	if not is_nan(overlay):
		# The lane, riding the rim: a lighter arc to where it stands and a mark
		# on it, so it can be watched moving while the pointer stays put.
		var oa := lerpf(a0, a1, clampf(Cd.to_norm(overlay, minimum, maximum, skew), 0.0, 1.0))
		var light := CdPalette.ACCENT.lightened(0.6)
		draw_arc(centre, r + 2.5, a0, oa, 32, Color(light.r, light.g, light.b, 0.75), 2.0, true)
		draw_circle(centre + Vector2(cos(oa), sin(oa)) * (r + 2.5), 2.2, light)
	var dir := Vector2(cos(a), sin(a))
	draw_line(centre + dir * (r * 0.35), centre + dir * (r - 4.0), CdPalette.TEXT, 2.0, true)

	if show_label:
		var txt := label if not _hover and not _dragging else text_value()
		# Width-limited: draw_string clips at its width, which is what keeps a
		# hosted plugin's "Chorus Filter Cutoff" out of its neighbour's cell.
		draw_string(font, Vector2(1.0, size.y - 2.0), txt,
				HORIZONTAL_ALIGNMENT_CENTER, size.x - 2.0, fs,
				CdPalette.ACCENT if (_hover or _dragging) else CdPalette.TEXT_DIM)
