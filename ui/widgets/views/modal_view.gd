class_name CdModalView
extends Control
## The eight resonators, each as loud as it is ringing. Struck material sounds
## the way it does because of which of these are up and how fast they fall, and
## this is that, live.

var ref := {}
var params: Array = []

var _levels := PackedFloat32Array()
var _peak := PackedFloat32Array()
var _index := {}


func _ready() -> void:
	custom_minimum_size.y = 132
	set_process(true)


func _process(_dt: float) -> void:
	if not is_visible_in_tree():
		return
	var h: int = App.handle_for(ref)
	if h < 0:
		return
	var a: PackedFloat32Array = App.engine().plugin_aux(h, 0, 8)
	if a.size() > 0:
		_levels = a
		if _peak.size() != a.size():
			_peak = a.duplicate()
		for i in a.size():
			_peak[i] = maxf(a[i], _peak[i] - 0.012)
	queue_redraw()


func _draw() -> void:
	var font := get_theme_default_font()
	draw_rect(Rect2(Vector2.ZERO, size), CdPalette.WELL)
	var r := Rect2(10, 16, size.x - 20.0, size.y - 40.0)
	draw_rect(r, CdPalette.PANEL)
	draw_string(font, Vector2(r.position.x, r.position.y - 4.0), "RESONATORS",
			HORIZONTAL_ALIGNMENT_LEFT, r.size.x, 8, CdPalette.TEXT_MUTE)
	if _levels.is_empty():
		return
	var n := _levels.size()
	var bw: float = r.size.x / float(n)
	for i in n:
		var v: float = clampf(_levels[i] * 2.0, 0.0, 1.0)
		draw_rect(Rect2(r.position.x + float(i) * bw + 2.0, r.end.y - r.size.y * v,
				bw - 4.0, r.size.y * v), CdPalette.ACCENT)
		if _peak.size() == n:
			var pv: float = clampf(_peak[i] * 2.0, 0.0, 1.0)
			var y: float = r.end.y - r.size.y * pv
			draw_line(Vector2(r.position.x + float(i) * bw + 2.0, y),
					Vector2(r.position.x + float(i + 1) * bw - 2.0, y),
					CdPalette.TEXT_DIM, 1.0)
		draw_string(font, Vector2(r.position.x + float(i) * bw, r.end.y + 11.0),
				"%d" % (i + 1), HORIZONTAL_ALIGNMENT_CENTER, bw, 8, CdPalette.TEXT_MUTE)
	draw_string(font, Vector2(r.position.x, r.end.y + 22.0),
			"decay %d%%   inharmonic %d%%" % [
			int(round(_p("decay", 0.0) * 100.0)), int(round(_p("inharm", 0.0) * 100.0))],
			HORIZONTAL_ALIGNMENT_LEFT, r.size.x, 9, CdPalette.TEXT_DIM)


func _p(id: String, fallback: float) -> float:
	if _index.is_empty():
		for k in params.size():
			_index[String(params[k].id)] = int(params[k].index)
	if _index.has(id):
		return App.get_plugin_param(ref, int(_index[id]))
	return fallback
