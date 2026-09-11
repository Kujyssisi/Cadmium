class_name CdOrganView
extends Control
## Nine drawbars, drawn as drawbars, plus the rotary horn going round.

signal param_changed()

var ref := {}
var params: Array = []
var _rot := 0.0
var _drag := -1

const LABELS := ["16'", "5⅓'", "8'", "4'", "2⅔'", "2'", "1⅗'", "1⅓'", "1'"]
# The colours a drawbar console uses: the mutation bars are the dark ones.
const DARK := [1, 4, 6, 7]

func _ready() -> void:
	custom_minimum_size.y = 150
	mouse_filter = Control.MOUSE_FILTER_STOP
	set_process(true)

func _process(_dt: float) -> void:
	if not is_visible_in_tree():
		return
	var h: int = App.handle_for(ref)
	if h < 0:
		return
	var a: PackedFloat32Array = App.engine().plugin_aux(h, 0, 10)
	if a.size() == 10:
		_rot = a[9]
		queue_redraw()

func _bar_index(i: int) -> int:
	for k in params.size():
		if String(params[k].id) == "d%d" % (i + 1):
			return int(params[k].index)
	return -1

func _gui_input(event: InputEvent) -> void:
	var w := (size.x - 60.0) / 9.0
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed and event.position.x < size.x - 58.0:
			_drag = clampi(int(event.position.x / w), 0, 8)
			_set_bar(event.position)
			accept_event()
		else:
			_drag = -1
	elif event is InputEventMouseMotion and _drag >= 0:
		if not Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
			_drag = -1
			return
		_set_bar(event.position)
		accept_event()

func _set_bar(pos: Vector2) -> void:
	var idx := _bar_index(_drag)
	if idx < 0:
		return
	# Eight notches, as on the instrument.
	var v := clampf(1.0 - (pos.y - 14.0) / maxf(1.0, size.y - 32.0), 0.0, 1.0)
	App.set_plugin_param(ref, idx, snappedf(v, 0.125))
	param_changed.emit()
	queue_redraw()

func _draw() -> void:
	var font := get_theme_default_font()
	draw_rect(Rect2(Vector2.ZERO, size), CdPalette.WELL)
	var w := (size.x - 60.0) / 9.0
	var top := 14.0
	var h := size.y - 32.0
	for i in 9:
		var idx := _bar_index(i)
		var v: float = App.get_plugin_param(ref, idx) if idx >= 0 else 0.0
		var x := i * w + 3.0
		draw_rect(Rect2(x, top, w - 6.0, h), CdPalette.PANEL)
		# The bar is pulled out towards you: the further out, the louder.
		var bh := 18.0
		var by := top + (h - bh) * (1.0 - v)
		var col: Color = Color("#3a3d42") if DARK.has(i) else Color("#d8d4cc")
		draw_rect(Rect2(x, by, w - 6.0, bh), col)
		draw_rect(Rect2(x, by, w - 6.0, bh), CdPalette.RULE_DARK, false, 1.0)
		draw_string(font, Vector2(x, top - 3.0), LABELS[i], HORIZONTAL_ALIGNMENT_CENTER,
				w - 6.0, 8, CdPalette.TEXT_MUTE)
		draw_string(font, Vector2(x, size.y - 5.0), "%d" % int(round(v * 8.0)),
				HORIZONTAL_ALIGNMENT_CENTER, w - 6.0, 8,
				Color("#e0e0e0") if DARK.has(i) else CdPalette.TEXT_DIM)
	# The rotary horn, going round at whatever speed the cabinet is set to.
	var c := Vector2(size.x - 30.0, size.y * 0.5)
	var r := minf(24.0, size.y * 0.3)
	draw_arc(c, r, 0.0, TAU, 32, CdPalette.RULE_DARK, 1.0)
	var a := _rot * TAU
	draw_line(c, c + Vector2(cos(a), sin(a)) * r, CdPalette.ACCENT, 2.0)
	draw_string(font, Vector2(c.x - r, size.y - 5.0), "rotary",
			HORIZONTAL_ALIGNMENT_CENTER, r * 2.0, 8, CdPalette.TEXT_DIM)
