class_name CdAmpView
extends Control
## What the amp is doing to the tone: the whole chain's response, tone stack and
## cabinet together, which is the thing you are actually setting when you turn
## those three knobs.

var ref := {}
var params: Array = []

var _curve := PackedFloat32Array()
var _index := {}


func _ready() -> void:
	custom_minimum_size.y = 150
	set_process(true)


func _process(_dt: float) -> void:
	if not is_visible_in_tree():
		return
	var h: int = App.handle_for(ref)
	if h < 0:
		return
	var a: PackedFloat32Array = App.engine().plugin_aux(h, 0, 65)
	if a.size() == 65:
		_curve = a
	queue_redraw()


func _draw() -> void:
	var font := get_theme_default_font()
	draw_rect(Rect2(Vector2.ZERO, size), CdPalette.WELL)
	var r := Rect2(10, 16, size.x - 20.0, size.y - 40.0)
	draw_rect(r, CdPalette.PANEL)
	draw_string(font, Vector2(r.position.x, r.position.y - 4.0), "TONE",
			HORIZONTAL_ALIGNMENT_LEFT, r.size.x, 8, CdPalette.TEXT_MUTE)
	for hz in [100.0, 1000.0, 10000.0]:
		var t: float = log(hz / 20.0) / log(1000.0)
		var x: float = r.position.x + r.size.x * t
		draw_line(Vector2(x, r.position.y), Vector2(x, r.end.y), Color(1, 1, 1, 0.05), 1.0)
		draw_string(font, Vector2(x + 2.0, r.end.y - 3.0),
				"%dk" % int(hz / 1000.0) if hz >= 1000.0 else "%d" % int(hz),
				HORIZONTAL_ALIGNMENT_LEFT, -1, 8, Color(1, 1, 1, 0.20))
	var mid := r.get_center().y
	draw_line(Vector2(r.position.x, mid), Vector2(r.end.x, mid), Color(1, 1, 1, 0.10), 1.0)
	if _curve.size() == 65:
		var pts := PackedVector2Array()
		for i in 65:
			# Thirty decibels of travel: a cabinet takes off more than an EQ.
			var y: float = mid - clampf(_curve[i] / 30.0, -1.0, 1.0) * r.size.y * 0.46
			pts.append(Vector2(r.position.x + r.size.x * float(i) / 64.0, y))
		# Filled column by column rather than as one shape: a response that
		# crosses the flat line would tie the outline into a bow, and that is
		# not something a triangulator can make sense of.
		var col := Color(CdPalette.ACCENT.r, CdPalette.ACCENT.g, CdPalette.ACCENT.b, 0.12)
		var step: float = r.size.x / 64.0
		for i in 64:
			var y0: float = pts[i].y
			draw_rect(Rect2(pts[i].x, minf(y0, mid), step + 1.0, absf(mid - y0)), col)
		draw_polyline(pts, CdPalette.ACCENT, 1.6, true)
	var models := ["clean", "crunch", "lead"]
	var cabs := ["4x12", "1x12", "2x12", "no cabinet"]
	draw_string(font, Vector2(r.position.x, r.end.y + 13.0),
			"%s   %s   gain %s" % [
			String(models[clampi(int(_p("model", 1.0)), 0, 2)]),
			String(cabs[clampi(int(_p("cab", 0.0)), 0, 3)]),
			Cd.format_param(_p("gain", 0.0), Cd.ParamKind.DB)],
			HORIZONTAL_ALIGNMENT_LEFT, r.size.x, 9, CdPalette.TEXT_DIM)


func _p(id: String, fallback: float) -> float:
	if _index.is_empty():
		for k in params.size():
			_index[String(params[k].id)] = int(params[k].index)
	if _index.has(id):
		return App.get_plugin_param(ref, int(_index[id]))
	return fallback
