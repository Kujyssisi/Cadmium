class_name CdVoxView
extends Control
## The three formants that make the vowel, where they are sitting right now.
## Moving the vowel round moves these, which is the whole trick, so it is worth
## being able to watch.

var ref := {}
var params: Array = []

var _f := PackedFloat32Array([700.0, 1200.0, 2600.0])
var _index := {}

const VOWELS := ["A", "E", "I", "O", "U"]


func _ready() -> void:
	custom_minimum_size.y = 128
	set_process(true)


func _process(_dt: float) -> void:
	if not is_visible_in_tree():
		return
	var h: int = App.handle_for(ref)
	if h < 0:
		return
	var a: PackedFloat32Array = App.engine().plugin_aux(h, 0, 3)
	if a.size() == 3:
		_f = a
	queue_redraw()


func _draw() -> void:
	var font := get_theme_default_font()
	draw_rect(Rect2(Vector2.ZERO, size), CdPalette.WELL)
	var r := Rect2(10, 16, size.x - 20.0, size.y - 46.0)
	draw_rect(r, CdPalette.PANEL)
	draw_string(font, Vector2(r.position.x, r.position.y - 4.0), "FORMANTS",
			HORIZONTAL_ALIGNMENT_LEFT, r.size.x, 8, CdPalette.TEXT_MUTE)
	for hz in [500.0, 1000.0, 2000.0, 4000.0]:
		var t: float = _to_t(hz)
		var x: float = r.position.x + r.size.x * t
		draw_line(Vector2(x, r.position.y), Vector2(x, r.end.y), Color(1, 1, 1, 0.05), 1.0)
		draw_string(font, Vector2(x + 2.0, r.end.y - 3.0),
				"%dk" % int(hz / 1000.0) if hz >= 1000.0 else "%d" % int(hz),
				HORIZONTAL_ALIGNMENT_LEFT, -1, 8, Color(1, 1, 1, 0.20))
	# Each formant as a hump: the first is the loudest, as it is in a voice.
	for i in _f.size():
		var t := _to_t(_f[i])
		var x: float = r.position.x + r.size.x * t
		var h: float = r.size.y * (0.9 - float(i) * 0.22)
		var pts := PackedVector2Array()
		for k in 33:
			var u := float(k) / 32.0
			var dx: float = (u - 0.5) * r.size.x * 0.16
			var g: float = exp(-pow((u - 0.5) * 6.0, 2.0))
			pts.append(Vector2(x + dx, r.end.y - h * g))
		draw_polyline(pts, CdPalette.ACCENT if i == 0 else Color(CdPalette.ACCENT.r,
				CdPalette.ACCENT.g, CdPalette.ACCENT.b, 0.55), 1.4, true)
		draw_string(font, Vector2(x - 10.0, r.end.y - h - 4.0), "F%d" % (i + 1),
				HORIZONTAL_ALIGNMENT_CENTER, 20.0, 8, CdPalette.TEXT_MUTE)

	var pos: float = clampf(_p("vowel", 0.0) + _p("morph", 0.0), 0.0, 4.0)
	var vowel := String(VOWELS[clampi(int(round(pos)), 0, 4)])
	draw_string(font, Vector2(r.position.x, r.end.y + 15.0),
			"vowel %s   %s / %s / %s" % [vowel,
			Cd.format_param(_f[0], Cd.ParamKind.HZ),
			Cd.format_param(_f[1], Cd.ParamKind.HZ),
			Cd.format_param(_f[2], Cd.ParamKind.HZ)],
			HORIZONTAL_ALIGNMENT_LEFT, r.size.x, 9, CdPalette.TEXT_DIM)


func _to_t(hz: float) -> float:
	return clampf(log(clampf(hz, 200.0, 6000.0) / 200.0) / log(30.0), 0.0, 1.0)


func _p(id: String, fallback: float) -> float:
	if _index.is_empty():
		for k in params.size():
			_index[String(params[k].id)] = int(params[k].index)
	if _index.has(id):
		return App.get_plugin_param(ref, int(_index[id]))
	return fallback
