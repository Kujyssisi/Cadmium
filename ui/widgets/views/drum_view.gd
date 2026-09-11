class_name CdDrumView
extends Control
## The hit, drawn as it is built: the pitch sweeping down at the front, and the
## body and the noise falling away underneath at their own rates. A drum synth
## is those three shapes and nothing else, so those three shapes are the panel.

var ref := {}
var params: Array = []

var _index := {}


func _ready() -> void:
	custom_minimum_size.y = 140
	set_process(true)


func _process(_dt: float) -> void:
	if is_visible_in_tree():
		queue_redraw()


func _draw() -> void:
	var font := get_theme_default_font()
	draw_rect(Rect2(Vector2.ZERO, size), CdPalette.WELL)
	var top := Rect2(10, 16, size.x - 20.0, (size.y - 46.0) * 0.42)
	var bot := Rect2(10, top.end.y + 8.0, size.x - 20.0, (size.y - 46.0) * 0.58)
	_pitch(top, font)
	_amp(bot, font)


## How far the pitch envelope throws the note, and how quickly it lands.
func _pitch(r: Rect2, font: Font) -> void:
	draw_rect(r, CdPalette.PANEL)
	draw_string(font, Vector2(r.position.x, r.position.y - 4.0), "PITCH",
			HORIZONTAL_ALIGNMENT_LEFT, r.size.x, 8, CdPalette.TEXT_MUTE)
	var amount: float = _p("pitch_env", 2.2)
	var dec: float = maxf(0.002, _p("pitch_dec", 0.045))
	var span := _span()
	var pts := PackedVector2Array()
	for i in 97:
		var t: float = float(i) / 96.0 * span
		var v: float = exp(-t / dec) * amount / 8.0
		pts.append(Vector2(r.position.x + r.size.x * (t / span),
				r.end.y - r.size.y * clampf(v, 0.0, 1.0)))
	draw_polyline(pts, CdPalette.ACCENT, 1.6, true)
	draw_string(font, Vector2(r.position.x + 3.0, r.end.y - 3.0),
			"drop over %s" % Cd.format_param(dec * 1000.0, Cd.ParamKind.MS),
			HORIZONTAL_ALIGNMENT_LEFT, r.size.x, 8, CdPalette.TEXT_DIM)


## Body and noise, each falling at its own rate, and the two added.
func _amp(r: Rect2, font: Font) -> void:
	draw_rect(r, CdPalette.PANEL)
	draw_string(font, Vector2(r.position.x, r.position.y - 4.0), "SHAPE",
			HORIZONTAL_ALIGNMENT_LEFT, r.size.x, 8, CdPalette.TEXT_MUTE)
	var span := _span()
	for ms in [0.1, 0.25, 0.5, 1.0]:
		if ms >= span:
			break
		var x: float = r.position.x + r.size.x * (ms / span)
		draw_line(Vector2(x, r.position.y), Vector2(x, r.end.y), Color(1, 1, 1, 0.05), 1.0)
		draw_string(font, Vector2(x + 2.0, r.end.y - 3.0), "%d ms" % int(ms * 1000.0),
				HORIZONTAL_ALIGNMENT_LEFT, -1, 8, Color(1, 1, 1, 0.20))

	var body_d: float = maxf(0.005, _p("body_dec", 0.42))
	var body_l: float = _p("body_level", 1.0)
	var noise_d: float = maxf(0.002, _p("noise_dec", 0.08))
	var noise_l: float = _p("noise_level", 0.12)
	var sum := PackedVector2Array()
	var body := PackedVector2Array()
	var noise := PackedVector2Array()
	for i in 129:
		var t: float = float(i) / 128.0 * span
		var b: float = exp(-t / body_d) * body_l
		var n: float = exp(-t / noise_d) * noise_l
		var x: float = r.position.x + r.size.x * (t / span)
		body.append(Vector2(x, r.end.y - r.size.y * clampf(b, 0.0, 1.0)))
		noise.append(Vector2(x, r.end.y - r.size.y * clampf(n, 0.0, 1.0)))
		sum.append(Vector2(x, r.end.y - r.size.y * clampf(b + n, 0.0, 1.0)))
	var fill := PackedVector2Array(sum)
	fill.append(Vector2(r.end.x, r.end.y))
	fill.append(Vector2(r.position.x, r.end.y))
	if Cd.has_area(fill):
		draw_colored_polygon(fill, Color(CdPalette.ACCENT.r, CdPalette.ACCENT.g,
				CdPalette.ACCENT.b, 0.14))
	draw_polyline(body, Color(CdPalette.ACCENT.r, CdPalette.ACCENT.g,
			CdPalette.ACCENT.b, 0.55), 1.0, true)
	draw_polyline(noise, CdPalette.TEXT_DIM, 1.0, true)
	draw_polyline(sum, CdPalette.ACCENT, 1.6, true)
	draw_string(font, Vector2(r.position.x, r.end.y + 13.0),
			"body %s   noise %s   click %d%%" % [
			Cd.format_param(body_d * 1000.0, Cd.ParamKind.MS),
			Cd.format_param(noise_d * 1000.0, Cd.ParamKind.MS),
			int(round(_p("click", 0.0) * 100.0))],
			HORIZONTAL_ALIGNMENT_LEFT, r.size.x, 9, CdPalette.TEXT_DIM)


## Enough of the hit to see all of it, whatever it is set to.
func _span() -> float:
	return clampf(maxf(_p("body_dec", 0.42), _p("noise_dec", 0.08)) * 3.5, 0.12, 4.0)


func _p(id: String, fallback: float) -> float:
	if _index.is_empty():
		for k in params.size():
			_index[String(params[k].id)] = int(params[k].index)
	if _index.has(id):
		return App.get_plugin_param(ref, int(_index[id]))
	return fallback
