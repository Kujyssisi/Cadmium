class_name CdAcidView
extends Control
## The one thing an acid line is: a filter being swept by an envelope. The
## corner is drawn where it actually is, moment to moment, read back from the
## running voice, with the range the envelope can take it over shaded behind.

var ref := {}
var params: Array = []

var _env := 0.0
var _cut := 400.0
var _trail := PackedFloat32Array()
var _index := {}

const TRAIL := 180


func _ready() -> void:
	custom_minimum_size.y = 140
	_trail.resize(TRAIL)
	_trail.fill(0.0)
	set_process(true)


func _process(_dt: float) -> void:
	if not is_visible_in_tree():
		return
	var h: int = App.handle_for(ref)
	if h < 0:
		return
	var a: PackedFloat32Array = App.engine().plugin_aux(h, 0, 2)
	if a.size() == 2:
		_env = a[0]
		_cut = a[1]
		for i in TRAIL - 1:
			_trail[i] = _trail[i + 1]
		_trail[TRAIL - 1] = _cut
	queue_redraw()


func _draw() -> void:
	var font := get_theme_default_font()
	draw_rect(Rect2(Vector2.ZERO, size), CdPalette.WELL)
	var r := Rect2(10, 16, size.x - 20.0, size.y - 40.0)
	draw_rect(r, CdPalette.PANEL)
	draw_string(font, Vector2(r.position.x, r.position.y - 4.0), "CUTOFF",
			HORIZONTAL_ALIGNMENT_LEFT, r.size.x, 8, CdPalette.TEXT_MUTE)
	for hz in [200.0, 1000.0, 5000.0]:
		var t: float = _to_t(hz)
		var y: float = r.end.y - r.size.y * t
		draw_line(Vector2(r.position.x, y), Vector2(r.end.x, y), Color(1, 1, 1, 0.05), 1.0)
		draw_string(font, Vector2(r.position.x + 2.0, y - 2.0),
				Cd.format_param(hz, Cd.ParamKind.HZ), HORIZONTAL_ALIGNMENT_LEFT,
				-1, 8, Color(1, 1, 1, 0.20))

	# Where the envelope can take it: base up to base plus the modulation.
	var base: float = _p("cut", 400.0)
	var top: float = clampf(base * pow(2.0, _p("envmod", 0.0) * 6.0), 20.0, 20000.0)
	draw_rect(Rect2(r.position.x, r.end.y - r.size.y * _to_t(top), r.size.x,
			r.size.y * (_to_t(top) - _to_t(base))),
			Color(CdPalette.ACCENT.r, CdPalette.ACCENT.g, CdPalette.ACCENT.b, 0.10))

	var pts := PackedVector2Array()
	for i in TRAIL:
		var hz: float = maxf(20.0, _trail[i])
		pts.append(Vector2(r.position.x + r.size.x * float(i) / float(TRAIL - 1),
				r.end.y - r.size.y * _to_t(hz)))
	draw_polyline(pts, CdPalette.ACCENT, 1.6, true)

	draw_string(font, Vector2(r.position.x, r.end.y + 13.0),
			"%s   reso %d%%   env %d%%   %s" % [
			Cd.format_param(_cut, Cd.ParamKind.HZ),
			int(round(_p("res", 0.0) * 100.0)),
			int(round(_p("envmod", 0.0) * 100.0)),
			"accent" if _env > 0.8 else "  "],
			HORIZONTAL_ALIGNMENT_LEFT, r.size.x, 9, CdPalette.TEXT_DIM)


func _to_t(hz: float) -> float:
	return clampf(log(clampf(hz, 20.0, 20000.0) / 20.0) / log(1000.0), 0.0, 1.0)


func _p(id: String, fallback: float) -> float:
	if _index.is_empty():
		for k in params.size():
			_index[String(params[k].id)] = int(params[k].index)
	if _index.has(id):
		return App.get_plugin_param(ref, int(_index[id]))
	return fallback
