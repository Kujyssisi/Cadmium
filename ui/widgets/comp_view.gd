class_name CdCompView
extends Control
## Compressor display: the transfer curve on the left, live gain reduction on
## the right. The reduction number is read from the running plugin.

var ref := {}
var params: Array = []
var _idx := {}
var _gr := 0.0


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	for p in params:
		_idx[String(p.id)] = int(p.index)
	set_process(true)


func _process(_dt: float) -> void:
	var h := App.handle_for(ref)
	if h >= 0:
		var a: PackedFloat32Array = App.engine().plugin_aux(h, 0, 1)
		if a.size() > 0:
			# Attack on the display is instant, release is eased: the number
			# jumps to the reduction and settles back, like a needle.
			_gr = minf(a[0], _gr + 1.4) if a[0] < _gr else lerpf(_gr, a[0], 0.25)
	queue_redraw()


func _pget(id: String) -> float:
	return App.get_plugin_param(ref, int(_idx.get(id, 0))) if _idx.has(id) else 0.0


func _draw() -> void:
	var font := get_theme_default_font()
	var pad := 6.0
	var graph := Rect2(pad, pad, size.y - pad * 2.0, size.y - pad * 2.0)
	draw_rect(graph, CdPalette.WELL)
	for i in range(1, 4):
		var t := float(i) / 4.0
		draw_line(graph.position + Vector2(graph.size.x * t, 0), graph.position + Vector2(graph.size.x * t, graph.size.y), CdPalette.GRID_FINE)
		draw_line(graph.position + Vector2(0, graph.size.y * t), graph.position + Vector2(graph.size.x, graph.size.y * t), CdPalette.GRID_FINE)
	draw_line(graph.position + Vector2(0, graph.size.y), graph.position + Vector2(graph.size.x, 0), CdPalette.RULE_LIGHT, 1.0)

	var thr := _pget("thresh")
	var ratio := maxf(1.0, _pget("ratio"))
	var knee := _pget("knee")
	var pts := PackedVector2Array()
	for i in 65:
		var in_db := lerpf(-60.0, 0.0, float(i) / 64.0)
		var over := in_db - thr
		var out_db := in_db
		if knee > 0.01 and over > -knee * 0.5 and over < knee * 0.5:
			var x := over + knee * 0.5
			out_db = in_db + (1.0 / ratio - 1.0) * x * x / (2.0 * knee)
		elif over > 0.0:
			out_db = in_db + over * (1.0 / ratio - 1.0)
		pts.append(Vector2(
			graph.position.x + graph.size.x * (in_db + 60.0) / 60.0,
			graph.end.y - graph.size.y * (out_db + 60.0) / 60.0))
	draw_polyline(pts, CdPalette.ACCENT, 2.0, true)
	var tx := graph.position.x + graph.size.x * (thr + 60.0) / 60.0
	draw_line(Vector2(tx, graph.position.y), Vector2(tx, graph.end.y), CdPalette.WARN, 1.0)

	# Gain reduction, drawn downward from the top like an outboard meter.
	var mx := graph.end.x + 16.0
	var mw := 22.0
	var mrect := Rect2(mx, pad, mw, size.y - pad * 2.0)
	draw_rect(mrect, CdPalette.WELL)
	var amount := clampf(-_gr / 24.0, 0.0, 1.0)
	draw_rect(Rect2(mrect.position, Vector2(mw, mrect.size.y * amount)), CdPalette.ACCENT)
	draw_rect(mrect, CdPalette.BEVEL_LO, false, 1.0)
	draw_string(font, Vector2(mx + mw + 8.0, pad + 12.0), "GAIN REDUCTION",
			HORIZONTAL_ALIGNMENT_LEFT, -1, 9, CdPalette.TEXT_MUTE)
	draw_string(font, Vector2(mx + mw + 8.0, pad + 34.0), "%.1f dB" % _gr,
			HORIZONTAL_ALIGNMENT_LEFT, -1, 16, CdPalette.ACCENT)
	draw_string(font, Vector2(mx + mw + 8.0, pad + 54.0),
			"%.0f:1  at  %.1f dB" % [_pget("ratio"), _pget("thresh")],
			HORIZONTAL_ALIGNMENT_LEFT, -1, 9, CdPalette.TEXT_DIM)
