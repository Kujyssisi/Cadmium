class_name CdDragField
extends LineEdit
## A numeric field you can drag as well as type into: press and pull up or down
## to change the value, or click without moving to edit the text.
##
## Shift is fine, Ctrl is coarse. The drag is abandoned if the button is
## released outside the window so nothing can get stuck holding it.

signal dragged(value: float)

@export var minimum := 0.0
@export var maximum := 1.0
@export var step := 0.01
## Value change for a full window's worth of vertical travel.
@export var sensitivity := 0.35

var _dragging := false
var _moved := false
var _accum := 0.0


func _ready() -> void:
	mouse_default_cursor_shape = Control.CURSOR_VSIZE
	set_process(false)


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			_dragging = true
			_moved = false
			_accum = text.to_float()
			set_process(true)
			accept_event()
		elif _dragging:
			_dragging = false
			set_process(false)
			if not _moved:
				# A plain click still means "let me type in here".
				grab_focus()
				select_all()
			accept_event()
	elif event is InputEventMouseMotion and _dragging:
		var e := event as InputEventMouseMotion
		if absf(e.relative.y) < 0.01:
			return
		_moved = true
		release_focus()
		var span := maximum - minimum
		var scale := sensitivity
		if Input.is_key_pressed(KEY_SHIFT):
			scale *= 0.15
		_accum = clampf(_accum - e.relative.y * span * scale * 0.01, minimum, maximum)
		var v := _accum
		if Input.is_key_pressed(KEY_CTRL):
			v = snappedf(v, maxf(step, 1.0))
		else:
			v = snappedf(v, step)
		dragged.emit(v)
		accept_event()
	elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_WHEEL_UP and event.pressed:
		dragged.emit(clampf(text.to_float() + step, minimum, maximum))
		accept_event()
	elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_WHEEL_DOWN and event.pressed:
		dragged.emit(clampf(text.to_float() - step, minimum, maximum))
		accept_event()


## Dragging past the edge of the window stops sending motion, so the release is
## never seen; give up on the drag as soon as the button is no longer down.
func _process(_dt: float) -> void:
	if _dragging and not Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		_dragging = false
		set_process(false)
