class_name CdShapeView
extends Control
## The curve the distortion is applying, read back from the processor itself:
## what goes in along the bottom, what comes out up the side. A bit crusher's
## staircase and a saturator's knee are the same picture drawn from the same
## place, so both use this.

var ref := {}
var params: Array = []

var _curve := PackedFloat32Array()
var _points := 65


func _ready() -> void:
	custom_minimum_size.y = 168
	set_process(true)


func _process(_dt: float) -> void:
	if not is_visible_in_tree():
		return
	var h: int = App.handle_for(ref)
	if h < 0:
		return
	# A crusher answers with more points than a saturator: its steps need them.
	var got: PackedFloat32Array = App.engine().plugin_aux(h, 0, 129)
	if got.size() >= 33:
		_curve = got
		_points = got.size()
	queue_redraw()


func _draw() -> void:
	var font := get_theme_default_font()
	draw_rect(Rect2(Vector2.ZERO, size), CdPalette.WELL)
	var side: float = minf(size.y - 20.0, size.x - 20.0)
	var box := Rect2((size.x - side) * 0.5, 12.0, side, side - 4.0)
	draw_rect(box, CdPalette.PANEL)
	draw_string(font, Vector2(box.position.x + 3.0, box.position.y + 11.0), "CURVE",
			HORIZONTAL_ALIGNMENT_LEFT, box.size.x, 8, CdPalette.TEXT_MUTE)
	# The diagonal is the signal untouched; anything off it is the effect.
	draw_line(Vector2(box.position.x, box.end.y), Vector2(box.end.x, box.position.y),
			Color(1, 1, 1, 0.10), 1.0)
	draw_line(Vector2(box.position.x, box.get_center().y),
			Vector2(box.end.x, box.get_center().y), CdPalette.RULE_DARK, 1.0)
	draw_line(Vector2(box.get_center().x, box.position.y),
			Vector2(box.get_center().x, box.end.y), CdPalette.RULE_DARK, 1.0)
	if _curve.size() < 2:
		return
	var pts := PackedVector2Array()
	for i in _curve.size():
		var x: float = box.position.x + box.size.x * float(i) / float(_curve.size() - 1)
		var y: float = box.get_center().y - clampf(_curve[i], -1.2, 1.2) * box.size.y * 0.5
		pts.append(Vector2(x, y))
	draw_polyline(pts, CdPalette.ACCENT, 1.6, true)
