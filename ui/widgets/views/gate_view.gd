class_name CdGateView
extends Control
## Sixteen steps you can draw on, with the one currently playing lit.

signal param_changed()

var ref := {}
var params: Array = []
var _cur := 0
var _level := 1.0
var _paint := -1.0

func _ready() -> void:
	custom_minimum_size.y = 118
	mouse_filter = Control.MOUSE_FILTER_STOP
	set_process(true)

func _process(_dt: float) -> void:
	if not is_visible_in_tree():
		return
	var h: int = App.handle_for(ref)
	if h < 0:
		return
	var a: PackedFloat32Array = App.engine().plugin_aux(h, 0, 2)
	if a.size() >= 2:
		_cur = int(a[0])
		_level = a[1]
		queue_redraw()

func _step_index(i: int) -> int:
	for k in params.size():
		if String(params[k].id) == "s%d" % (i + 1):
			return int(params[k].index)
	return -1

func _length() -> int:
	for k in params.size():
		if String(params[k].id) == "length":
			return int(round(App.get_plugin_param(ref, int(params[k].index))))
	return 16

func _gui_input(event: InputEvent) -> void:
	var steps := _length()
	if event is InputEventMouseButton and event.pressed \
			and event.button_index in [MOUSE_BUTTON_LEFT, MOUSE_BUTTON_RIGHT]:
		# Left draws the level under the pointer, right clears the step.
		_paint = 0.0 if event.button_index == MOUSE_BUTTON_RIGHT else -1.0
		_set_at(event.position, steps)
		accept_event()
	elif event is InputEventMouseButton and not event.pressed:
		_paint = -1.0
	elif event is InputEventMouseMotion and Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		_set_at(event.position, steps)
		accept_event()
	elif event is InputEventMouseMotion and Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT):
		_paint = 0.0
		_set_at(event.position, steps)
		accept_event()

func _set_at(pos: Vector2, steps: int) -> void:
	var w := size.x / float(steps)
	var i := clampi(int(pos.x / w), 0, steps - 1)
	var idx := _step_index(i)
	if idx < 0:
		return
	var v: float = _paint if _paint >= 0.0 else clampf(1.0 - pos.y / maxf(1.0, size.y - 14.0), 0.0, 1.0)
	App.set_plugin_param(ref, idx, v)
	param_changed.emit()
	queue_redraw()

func _draw() -> void:
	var font := get_theme_default_font()
	draw_rect(Rect2(Vector2.ZERO, size), CdPalette.WELL)
	var steps := _length()
	var w := size.x / float(steps)
	var h := size.y - 14.0
	for i in steps:
		var idx := _step_index(i)
		var v: float = App.get_plugin_param(ref, idx) if idx >= 0 else 0.0
		var r := Rect2(i * w + 1.0, h - h * v, w - 2.0, h * v)
		var lit := i == _cur
		draw_rect(Rect2(i * w + 1.0, 0, w - 2.0, h),
				CdPalette.PANEL if not lit else CdPalette.RAISED)
		if v > 0.001:
			draw_rect(r, CdPalette.ACCENT if lit else CdPalette.ACCENT.darkened(0.28))
		# A beat marker every fourth step, so the bar is countable.
		if i % 4 == 0:
			draw_line(Vector2(i * w, 0), Vector2(i * w, h), CdPalette.RULE_LIGHT, 1.0)
		draw_string(font, Vector2(i * w + 2.0, size.y - 3.0), str(i + 1),
				HORIZONTAL_ALIGNMENT_LEFT, w, 8,
				CdPalette.TEXT if lit else CdPalette.TEXT_DIM)
	# The gate's own level, as a line across the steps.
	var y := h - h * _level
	draw_line(Vector2(0, y), Vector2(size.x, y), CdPalette.GOOD, 1.0)
