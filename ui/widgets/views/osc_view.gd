class_name CdOscView
extends Control
## The waveform itself, held still by the trigger so a steady note stands still
## on the screen instead of sliding across it.

var ref := {}
var params: Array = []

var _pts := PackedFloat32Array()
var _points := 0
var _per := 1.0
var _index := {}


func _ready() -> void:
	custom_minimum_size.y = 210
	set_process(true)


func _process(_dt: float) -> void:
	if not is_visible_in_tree():
		return
	var h: int = App.handle_for(ref)
	if h < 0:
		return
	var meta: PackedFloat32Array = App.engine().plugin_aux(h, 1, 2)
	if meta.size() == 2:
		_points = int(meta[0])
		_per = meta[1]
	if _points > 1:
		_pts = App.engine().plugin_aux(h, 0, _points * 2)
	queue_redraw()


func _draw() -> void:
	var font := get_theme_default_font()
	draw_rect(Rect2(Vector2.ZERO, size), CdPalette.WELL)
	var r := Rect2(8, 8, size.x - 16.0, size.y - 26.0)
	draw_rect(r, CdPalette.PANEL)
	var mid := r.get_center().y
	# A ten by eight grid, the way an oscilloscope has always been divided.
	for i in range(1, 10):
		var x: float = r.position.x + r.size.x * float(i) / 10.0
		draw_line(Vector2(x, r.position.y), Vector2(x, r.end.y), Color(1, 1, 1, 0.05), 1.0)
	for i in range(1, 8):
		var y: float = r.position.y + r.size.y * float(i) / 8.0
		draw_line(Vector2(r.position.x, y), Vector2(r.end.x, y),
				Color(1, 1, 1, 0.10 if i == 4 else 0.05), 1.0)

	var trig: float = _p("trig", 0.0)
	var ty: float = mid - trig * r.size.y * 0.46
	draw_line(Vector2(r.position.x, ty), Vector2(r.end.x, ty), Color(1, 1, 1, 0.14), 1.0)

	var n: int = _pts.size() / 2
	if n > 2:
		var left := PackedVector2Array()
		var right := PackedVector2Array()
		for i in n:
			var x: float = r.position.x + r.size.x * float(i) / float(n - 1)
			left.append(Vector2(x, mid - clampf(_pts[i * 2], -1.2, 1.2) * r.size.y * 0.46))
			right.append(Vector2(x, mid - clampf(_pts[i * 2 + 1], -1.2, 1.2) * r.size.y * 0.46))
		draw_polyline(right, Color(CdPalette.GOOD.r, CdPalette.GOOD.g,
				CdPalette.GOOD.b, 0.55), 1.0, true)
		draw_polyline(left, CdPalette.ACCENT, 1.4, true)
	else:
		draw_string(font, Vector2(0, mid), "no signal", HORIZONTAL_ALIGNMENT_CENTER,
				size.x, 10, CdPalette.TEXT_MUTE)

	var ms: float = _p("time", 20.0)
	draw_string(font, Vector2(r.position.x, r.end.y + 13.0),
			"%s across   %s per division   %s" % [
			Cd.format_param(ms, Cd.ParamKind.MS),
			Cd.format_param(ms / 10.0, Cd.ParamKind.MS),
			"free running" if _p("freeze", 0.0) > 0.5 else "triggered"],
			HORIZONTAL_ALIGNMENT_LEFT, r.size.x, 9, CdPalette.TEXT_DIM)


func _p(id: String, fallback: float) -> float:
	if _index.is_empty():
		for k in params.size():
			_index[String(params[k].id)] = int(params[k].index)
	if _index.has(id):
		return App.get_plugin_param(ref, int(_index[id]))
	return fallback
