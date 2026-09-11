class_name CdSpanView
extends Control
## The spectrum, on the axes everyone reads a mix on: frequency by octave across
## and decibels down, with a peak trace that falls slowly behind the live one.

var ref := {}
var params: Array = []

var _bins := PackedFloat32Array()
var _hold := PackedFloat32Array()


func _ready() -> void:
	custom_minimum_size.y = 240
	set_process(true)


func _process(_dt: float) -> void:
	if not is_visible_in_tree():
		return
	var h: int = App.handle_for(ref)
	if h < 0:
		return
	_bins = App.engine().plugin_aux(h, 0, 160)
	_hold = App.engine().plugin_aux(h, 1, 160)
	queue_redraw()


func _draw() -> void:
	var font := get_theme_default_font()
	var r := Rect2(Vector2.ZERO, size)
	draw_rect(r, CdPalette.WELL)
	var floor_db: float = _param("floor", -96.0)
	var top_db := 6.0
	_grid(r, font, floor_db, top_db)
	if _hold.size() > 2:
		_trace(r, _hold, floor_db, top_db, Color(CdPalette.ACCENT.r,
				CdPalette.ACCENT.g, CdPalette.ACCENT.b, 0.45), 1.0, false)
	if _bins.size() > 2:
		_trace(r, _bins, floor_db, top_db, CdPalette.ACCENT, 1.4, true)


func _grid(r: Rect2, font: Font, floor_db: float, top_db: float) -> void:
	for hz in [50.0, 100.0, 200.0, 500.0, 1000.0, 2000.0, 5000.0, 10000.0]:
		var t: float = log(hz / 20.0) / log(1000.0)
		if t <= 0.0 or t >= 1.0:
			continue
		var x: float = r.size.x * t
		draw_line(Vector2(x, 0), Vector2(x, r.size.y), Color(1, 1, 1, 0.06), 1.0)
		var lbl: String = "%dk" % int(hz / 1000.0) if hz >= 1000.0 else "%d" % int(hz)
		draw_string(font, Vector2(x + 2.0, r.size.y - 3.0), lbl,
				HORIZONTAL_ALIGNMENT_LEFT, -1, 8, Color(1, 1, 1, 0.22))
	var db := top_db
	while db > floor_db:
		var y: float = r.size.y * (top_db - db) / (top_db - floor_db)
		draw_line(Vector2(0, y), Vector2(r.size.x, y), Color(1, 1, 1, 0.05), 1.0)
		draw_string(font, Vector2(3, y - 2.0), "%d" % int(db),
				HORIZONTAL_ALIGNMENT_LEFT, -1, 8, Color(1, 1, 1, 0.22))
		db -= 12.0


func _trace(r: Rect2, data: PackedFloat32Array, floor_db: float, top_db: float,
		col: Color, width: float, fill: bool) -> void:
	var n := data.size()
	var pts := PackedVector2Array()
	for i in n:
		var x: float = r.size.x * float(i) / float(n - 1)
		var t: float = clampf((top_db - data[i]) / (top_db - floor_db), 0.0, 1.0)
		pts.append(Vector2(x, r.size.y * t))
	if fill:
		var poly := PackedVector2Array(pts)
		poly.append(Vector2(r.size.x, r.size.y))
		poly.append(Vector2(0, r.size.y))
		if Cd.has_area(poly):
			draw_colored_polygon(poly, Color(col.r, col.g, col.b, 0.14))
	draw_polyline(pts, col, width, true)


func _param(id: String, fallback: float) -> float:
	for i in params.size():
		if String(params[i].id) == id:
			return App.get_plugin_param(ref, int(params[i].index))
	return fallback
