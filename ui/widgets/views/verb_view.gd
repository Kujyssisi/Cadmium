class_name CdVerbView
extends Control
## How long the tail is and what happens to it on the way out: the decay drawn
## against time, with the pre-delay before it and the damping shown as the top
## end dying first.

var ref := {}
var params: Array = []

var _index := {}


func _ready() -> void:
	custom_minimum_size.y = 128
	set_process(true)


func _process(_dt: float) -> void:
	if is_visible_in_tree():
		queue_redraw()


func _draw() -> void:
	var font := get_theme_default_font()
	draw_rect(Rect2(Vector2.ZERO, size), CdPalette.WELL)
	var r := Rect2(10, 16, size.x - 20.0, size.y - 40.0)
	draw_rect(r, CdPalette.PANEL)
	draw_string(font, Vector2(r.position.x, r.position.y - 4.0), "TAIL",
			HORIZONTAL_ALIGNMENT_LEFT, r.size.x, 8, CdPalette.TEXT_MUTE)

	# Six seconds across, which covers everything short of a freeze.
	const SPAN := 6.0
	for sec in [1.0, 2.0, 3.0, 4.0, 5.0]:
		var x: float = r.position.x + r.size.x * (sec / SPAN)
		draw_line(Vector2(x, r.position.y), Vector2(x, r.end.y), Color(1, 1, 1, 0.05), 1.0)
		draw_string(font, Vector2(x + 2.0, r.end.y - 3.0), "%ds" % int(sec),
				HORIZONTAL_ALIGNMENT_LEFT, -1, 8, Color(1, 1, 1, 0.20))

	var pre_ms := _p("predelay", 0.0)
	var decay := _t60()
	var damp: float = clampf(_p("damp", 0.5), 0.0, 1.0)
	var pre_t: float = clampf(pre_ms / 1000.0 / SPAN, 0.0, 0.5)

	# Two traces: the whole tail, and the top end, which damping shortens.
	for pass_i in 2:
		var top := pass_i == 1
		var t60: float = decay * (1.0 - damp * 0.65) if top else decay
		var pts := PackedVector2Array()
		for i in 97:
			var t := float(i) / 96.0
			var sec: float = t * SPAN
			var v := 0.0
			if sec >= pre_ms / 1000.0:
				var age: float = sec - pre_ms / 1000.0
				v = pow(10.0, -3.0 * age / maxf(0.05, t60))
			pts.append(Vector2(r.position.x + r.size.x * t, r.end.y - r.size.y * v))
		if top:
			draw_polyline(pts, Color(CdPalette.ACCENT.r, CdPalette.ACCENT.g,
					CdPalette.ACCENT.b, 0.45), 1.0, true)
		else:
			var fill := PackedVector2Array(pts)
			fill.append(Vector2(r.end.x, r.end.y))
			fill.append(Vector2(r.position.x, r.end.y))
			if Cd.has_area(fill):
				draw_colored_polygon(fill, Color(CdPalette.ACCENT.r, CdPalette.ACCENT.g,
						CdPalette.ACCENT.b, 0.16))
			draw_polyline(pts, CdPalette.ACCENT, 1.6, true)

	if pre_t > 0.002:
		var px: float = r.position.x + r.size.x * pre_t
		draw_line(Vector2(px, r.position.y), Vector2(px, r.end.y), CdPalette.TEXT_DIM, 1.0)
		draw_string(font, Vector2(px + 3.0, r.position.y + 11.0),
				"pre %s" % Cd.format_param(pre_ms, Cd.ParamKind.MS),
				HORIZONTAL_ALIGNMENT_LEFT, -1, 8, CdPalette.TEXT_DIM)

	var bits := PackedStringArray(["%.1f s tail" % decay])
	if _has("size"):
		bits.append("size %d%%" % int(round(_p("size", 0.0) * 100.0)))
	if _has("damp"):
		bits.append("damping %d%%" % int(round(damp * 100.0)))
	if _has("width"):
		bits.append("width %d%%" % int(round(_p("width", 1.0) * 100.0)))
	draw_string(font, Vector2(r.position.x, r.end.y + 13.0), "   ".join(bits),
			HORIZONTAL_ALIGNMENT_LEFT, r.size.x, 9, CdPalette.TEXT_DIM)


## How long it takes to fall sixty decibels. The decay knob is a feedback
## amount rather than a time, so it is turned into one here the same way the
## tank does: more feedback and a bigger room both make it longer.
func _t60() -> float:
	if _has("decay"):
		return maxf(0.15, _p("size", 1.0) * (0.25 + pow(_p("decay", 0.45), 2.2) * 14.0))
	# The convolution reverb rings for as long as its impulse does; stretch is
	# the only thing that changes it.
	return maxf(0.2, _p("stretch", 1.0) * 2.0)


func _fill() -> void:
	if _index.is_empty():
		for k in params.size():
			_index[String(params[k].id)] = int(params[k].index)


func _has(id: String) -> bool:
	_fill()
	return _index.has(id)


func _p(id: String, fallback: float) -> float:
	_fill()
	if _index.has(id):
		return App.get_plugin_param(ref, int(_index[id]))
	return fallback
