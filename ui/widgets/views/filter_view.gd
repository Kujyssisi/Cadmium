class_name CdFilterView
extends Control
## The filter's response, where its corner is, and how far the envelope and the
## LFO are moving it. The band between the two extremes is shaded, so what the
## modulation is going to do is visible before it does it.

var ref := {}
var params: Array = []

var _index := {}


func _ready() -> void:
	custom_minimum_size.y = 158
	set_process(true)


func _process(_dt: float) -> void:
	if is_visible_in_tree():
		queue_redraw()


func _draw() -> void:
	var font := get_theme_default_font()
	draw_rect(Rect2(Vector2.ZERO, size), CdPalette.WELL)
	var r := Rect2(10, 16, size.x - 20.0, size.y - 40.0)
	draw_rect(r, CdPalette.PANEL)
	draw_string(font, Vector2(r.position.x, r.position.y - 4.0), "RESPONSE",
			HORIZONTAL_ALIGNMENT_LEFT, r.size.x, 8, CdPalette.TEXT_MUTE)
	for hz in [100.0, 1000.0, 10000.0]:
		var t: float = log(hz / 20.0) / log(1000.0)
		var x: float = r.position.x + r.size.x * t
		draw_line(Vector2(x, r.position.y), Vector2(x, r.end.y), Color(1, 1, 1, 0.05), 1.0)
		draw_string(font, Vector2(x + 2.0, r.end.y - 3.0),
				"%dk" % int(hz / 1000.0) if hz >= 1000.0 else "%d" % int(hz),
				HORIZONTAL_ALIGNMENT_LEFT, -1, 8, Color(1, 1, 1, 0.20))

	var cut: float = _p("cut", 1000.0)
	var res: float = _p("res", 0.3)
	var type := int(_p("type", 0.0))
	var sweep: float = absf(_p("lfo_amt", 0.0)) + absf(_p("env_amt", 0.0))
	if sweep > 0.01:
		# Where the corner can get to, shaded: the sweep is in octaves.
		var lo: float = clampf(log(maxf(20.0, cut * pow(2.0, -sweep * 3.0)) / 20.0) / log(1000.0), 0.0, 1.0)
		var hi: float = clampf(log(minf(20000.0, cut * pow(2.0, sweep * 3.0)) / 20.0) / log(1000.0), 0.0, 1.0)
		draw_rect(Rect2(r.position.x + r.size.x * lo, r.position.y,
				r.size.x * (hi - lo), r.size.y),
				Color(CdPalette.ACCENT.r, CdPalette.ACCENT.g, CdPalette.ACCENT.b, 0.08))

	var pts := PackedVector2Array()
	for i in 129:
		var t := float(i) / 128.0
		var hz: float = 20.0 * pow(1000.0, t)
		var g := _response(hz, cut, res, type)
		pts.append(Vector2(r.position.x + r.size.x * t,
				r.end.y - r.size.y * clampf(0.5 + g * 0.5, 0.0, 1.0)))
	draw_polyline(pts, CdPalette.ACCENT, 1.6, true)

	var ct: float = clampf(log(maxf(20.0, cut) / 20.0) / log(1000.0), 0.0, 1.0)
	var cx: float = r.position.x + r.size.x * ct
	draw_line(Vector2(cx, r.position.y), Vector2(cx, r.end.y), Color(1, 1, 1, 0.20), 1.0)
	draw_string(font, Vector2(r.position.x, r.end.y + 13.0),
			"%s   reso %d%%   drive %d%%" % [Cd.format_param(cut, Cd.ParamKind.HZ),
			int(round(res * 100.0)), int(round(_p("drive", 0.0) * 100.0))],
			HORIZONTAL_ALIGNMENT_LEFT, r.size.x, 9, CdPalette.TEXT_DIM)


## Rough enough to read the shape: -1 is well down, +1 is a resonant peak.
func _response(hz: float, cut: float, res: float, type: int) -> float:
	var w: float = hz / maxf(20.0, cut)
	var peak: float = res * 1.6 * exp(-pow(log(maxf(0.01, w)) * 2.2, 2.0))
	match type:
		1:      # high pass
			return clampf(-1.0 / (1.0 + w * w * 4.0) * 2.0 + 1.0 + peak, -1.0, 1.0)
		2:      # band pass
			return clampf(peak + 1.0 / (1.0 + pow(log(maxf(0.01, w)) * 1.6, 2.0)) - 0.5, -1.0, 1.0)
		3:      # notch
			return clampf(1.0 - 1.6 / (1.0 + pow(log(maxf(0.01, w)) * 3.0, 2.0)), -1.0, 1.0)
		_:      # low pass
			return clampf(1.0 - w * w / (1.0 + w * w) * 2.0 + peak, -1.0, 1.0)


func _p(id: String, fallback: float) -> float:
	if _index.is_empty():
		for k in params.size():
			_index[String(params[k].id)] = int(params[k].index)
	if _index.has(id):
		return App.get_plugin_param(ref, int(_index[id]))
	return fallback
