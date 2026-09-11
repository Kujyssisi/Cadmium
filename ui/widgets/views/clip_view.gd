class_name CdClipView
extends Control
## The clipper's transfer curve -- what goes in against what comes out -- with
## the ceiling drawn across it and a count of how much of the signal is hitting
## it. The curve is the plugin's own, read back from the processor, so it is
## the shape being applied rather than a drawing of one.

var ref := {}
var params: Array = []

var _curve := PackedFloat32Array()
var _gr := 0.0
var _hit := 0.0


func _ready() -> void:
	custom_minimum_size.y = 150
	set_process(true)


func _process(_dt: float) -> void:
	if not is_visible_in_tree():
		return
	var h: int = App.handle_for(ref)
	if h < 0:
		return
	_curve = App.engine().plugin_aux(h, 0, 65)
	var m: PackedFloat32Array = App.engine().plugin_aux(h, 1, 2)
	if m.size() == 2:
		_gr = m[0]
		_hit = m[1]
	queue_redraw()


func _draw() -> void:
	var font := get_theme_default_font()
	draw_rect(Rect2(Vector2.ZERO, size), CdPalette.WELL)
	var pad := 10.0
	var side: float = minf(size.x * 0.55, size.y - pad * 2.0)
	var box := Rect2(pad, pad, side, side)
	_draw_curve(box, font)
	_draw_meters(Rect2(box.end.x + 16.0, pad, size.x - box.end.x - 16.0 - pad,
			side), font)


func _draw_curve(r: Rect2, font: Font) -> void:
	draw_rect(r, CdPalette.PANEL)
	# The diagonal is "nothing happening": every point on it means out equals in.
	draw_line(r.position + Vector2(0, r.size.y), r.position + Vector2(r.size.x, 0),
			Color(1, 1, 1, 0.10), 1.0)
	draw_line(Vector2(r.position.x, r.get_center().y),
			Vector2(r.end.x, r.get_center().y), CdPalette.RULE_DARK, 1.0)
	draw_line(Vector2(r.get_center().x, r.position.y),
			Vector2(r.get_center().x, r.end.y), CdPalette.RULE_DARK, 1.0)
	if _curve.size() < 2:
		return
	var pts := PackedVector2Array()
	for i in _curve.size():
		var x: float = r.position.x + r.size.x * float(i) / float(_curve.size() - 1)
		var y: float = r.get_center().y - clampf(_curve[i], -1.0, 1.0) * r.size.y * 0.5
		pts.append(Vector2(x, y))
	draw_polyline(pts, CdPalette.ACCENT, 1.6, true)
	draw_string(font, Vector2(r.position.x + 3.0, r.position.y + 11.0), "TRANSFER",
			HORIZONTAL_ALIGNMENT_LEFT, r.size.x, 8, CdPalette.TEXT_MUTE)


func _draw_meters(r: Rect2, font: Font) -> void:
	if r.size.x < 40.0:
		return
	# How far the loudest sample was pushed back, and how much of the signal
	# reached the ceiling at all. The second is what tells you whether you are
	# shaving peaks or squashing the whole thing.
	var rows := [
		{"label": "REDUCTION", "text": "%.1f dB" % _gr, "fill": clampf(-_gr / 12.0, 0.0, 1.0)},
		{"label": "CLIPPING", "text": "%.1f %%" % (_hit * 100.0), "fill": clampf(_hit * 6.0, 0.0, 1.0)},
	]
	var y := r.position.y
	for row in rows:
		draw_string(font, Vector2(r.position.x, y + 10.0), String(row.label),
				HORIZONTAL_ALIGNMENT_LEFT, r.size.x, 8, CdPalette.TEXT_MUTE)
		var bar := Rect2(r.position.x, y + 16.0, r.size.x, 14.0)
		draw_rect(bar, CdPalette.PANEL)
		var f: float = float(row.fill)
		if f > 0.001:
			draw_rect(Rect2(bar.position, Vector2(bar.size.x * f, bar.size.y)),
					CdPalette.BAD if f > 0.75 else CdPalette.ACCENT)
		draw_string(font, Vector2(bar.position.x + 4.0, bar.end.y - 3.0), String(row.text),
				HORIZONTAL_ALIGNMENT_LEFT, bar.size.x, 9, CdPalette.TEXT)
		y += 42.0
	var ceil_db := _param("ceil", -0.3)
	draw_string(font, Vector2(r.position.x, r.end.y - 2.0),
			"ceiling %s" % Cd.format_param(ceil_db, Cd.ParamKind.DB),
			HORIZONTAL_ALIGNMENT_LEFT, r.size.x, 9, CdPalette.TEXT_DIM)


func _param(id: String, fallback: float) -> float:
	for i in params.size():
		if String(params[i].id) == id:
			return App.get_plugin_param(ref, int(params[i].index))
	return fallback
