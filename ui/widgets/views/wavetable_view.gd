class_name CdWavetableView
extends Control
## The two waves the synth is actually reading, as the morph knob picks them
## out of their tables, with the envelope and filter under them. A wavetable
## synth with no picture of its wave is a wall of knobs; this is the picture.

var ref := {}
var params: Array = []

var _waves := PackedFloat32Array()
var _index := {}


func _ready() -> void:
	custom_minimum_size.y = 130
	set_process(true)


func _process(_dt: float) -> void:
	if not is_visible_in_tree():
		return
	var h: int = App.handle_for(ref)
	if h < 0:
		return
	var a: PackedFloat32Array = App.engine().plugin_aux(h, 0, 256)
	if a.size() == 256:
		_waves = a
	queue_redraw()


func _draw() -> void:
	var font := get_theme_default_font()
	draw_rect(Rect2(Vector2.ZERO, size), CdPalette.WELL)
	var half := size.x * 0.5
	_osc(Rect2(8, 16, half - 12.0, size.y - 34.0), 0, "OSC A", font)
	_osc(Rect2(half + 4.0, 16, half - 12.0, size.y - 34.0), 1, "OSC B", font)


func _osc(r: Rect2, which: int, label: String, font: Font) -> void:
	draw_rect(r, CdPalette.PANEL)
	draw_string(font, Vector2(r.position.x, r.position.y - 4.0), label,
			HORIZONTAL_ALIGNMENT_LEFT, r.size.x, 8, CdPalette.TEXT_MUTE)
	var mid := r.get_center().y
	draw_line(Vector2(r.position.x, mid), Vector2(r.end.x, mid), CdPalette.RULE_DARK, 1.0)
	if _waves.size() != 256:
		return
	var pts := PackedVector2Array()
	for i in 128:
		var v: float = _waves[which * 128 + i]
		pts.append(Vector2(r.position.x + r.size.x * float(i) / 127.0,
				mid - clampf(v, -1.2, 1.2) * r.size.y * 0.42))
	var level: float = _p("a_level" if which == 0 else "b_level", 1.0)
	var col := CdPalette.ACCENT
	draw_polyline(pts, Color(col.r, col.g, col.b, 0.35 + 0.65 * clampf(level, 0.0, 1.0)),
			1.6, true)
	draw_string(font, Vector2(r.position.x + 3.0, r.end.y - 3.0),
			"morph %d%%   level %d%%" % [
			int(round(_p("a_morph" if which == 0 else "b_morph", 0.0) * 100.0)),
			int(round(level * 100.0))],
			HORIZONTAL_ALIGNMENT_LEFT, r.size.x, 8, CdPalette.TEXT_DIM)


func _p(id: String, fallback: float) -> float:
	if _index.is_empty():
		for k in params.size():
			_index[String(params[k].id)] = int(params[k].index)
	if _index.has(id):
		return App.get_plugin_param(ref, int(_index[id]))
	return fallback
