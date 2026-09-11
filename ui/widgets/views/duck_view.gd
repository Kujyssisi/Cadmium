class_name CdDuckView
extends Control
## The shape the ducker is applying, over one division, with a marker showing
## where in it the song currently is. The curve is read back from the processor,
## so what is drawn is the gain that is actually being applied.

var ref := {}
var params: Array = []

var _shape := PackedFloat32Array()
var _pos := 0.0


func _ready() -> void:
	custom_minimum_size.y = 132
	set_process(true)


func _process(_dt: float) -> void:
	if not is_visible_in_tree():
		return
	var h: int = App.handle_for(ref)
	if h < 0:
		return
	var a: PackedFloat32Array = App.engine().plugin_aux(h, 0, 65)
	if a.size() == 65:
		_shape = a
		_pos = a[64]
	queue_redraw()


func _draw() -> void:
	var font := get_theme_default_font()
	draw_rect(Rect2(Vector2.ZERO, size), CdPalette.WELL)
	var r := Rect2(10, 16, size.x - 20.0, size.y - 34.0)
	draw_rect(r, CdPalette.PANEL)
	draw_string(font, Vector2(r.position.x, r.position.y - 4.0), "SHAPE",
			HORIZONTAL_ALIGNMENT_LEFT, r.size.x, 8, CdPalette.TEXT_MUTE)
	# Unity across the top: anything below it is the ducking.
	draw_line(Vector2(r.position.x, r.position.y), Vector2(r.end.x, r.position.y),
			Color(1, 1, 1, 0.10), 1.0)
	if _shape.size() < 64:
		return
	var pts := PackedVector2Array()
	var fill := PackedVector2Array()
	fill.append(Vector2(r.position.x, r.end.y))
	for i in 64:
		var x: float = r.position.x + r.size.x * float(i) / 63.0
		var y: float = r.end.y - r.size.y * clampf(_shape[i], 0.0, 1.0)
		pts.append(Vector2(x, y))
		fill.append(Vector2(x, y))
	fill.append(Vector2(r.end.x, r.end.y))
	if Cd.has_area(fill):
		draw_colored_polygon(fill, Color(CdPalette.ACCENT.r, CdPalette.ACCENT.g,
				CdPalette.ACCENT.b, 0.16))
	draw_polyline(pts, CdPalette.ACCENT, 1.6, true)

	var px: float = r.position.x + r.size.x * clampf(_pos, 0.0, 1.0)
	draw_line(Vector2(px, r.position.y), Vector2(px, r.end.y), CdPalette.TEXT, 1.0)
	var idx: int = clampi(int(_pos * 63.0), 0, 63)
	var now: float = _shape[idx]
	draw_string(font, Vector2(r.position.x + 4.0, r.end.y - 4.0),
			"now %s" % Cd.format_param(Cd.gain_to_db(maxf(now, 0.0001)), Cd.ParamKind.DB),
			HORIZONTAL_ALIGNMENT_LEFT, r.size.x, 9, CdPalette.TEXT_DIM)
