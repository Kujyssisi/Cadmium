class_name CdTapeView
extends Control
## What the tape is doing to the timing: the wow and flutter drawn as the trace
## it actually is, read from the running machine, with the tone controls shown
## as the curve they make.

var ref := {}
var params: Array = []

var _trail := PackedFloat32Array()
var _index := {}

const TRAIL := 220


func _ready() -> void:
	custom_minimum_size.y = 132
	_trail.resize(TRAIL)
	_trail.fill(0.0)
	set_process(true)


func _process(_dt: float) -> void:
	if not is_visible_in_tree():
		return
	var h: int = App.handle_for(ref)
	if h < 0:
		return
	var a: PackedFloat32Array = App.engine().plugin_aux(h, 0, 1)
	if a.size() >= 1:
		for i in TRAIL - 1:
			_trail[i] = _trail[i + 1]
		_trail[TRAIL - 1] = a[0]
	queue_redraw()


func _draw() -> void:
	var font := get_theme_default_font()
	draw_rect(Rect2(Vector2.ZERO, size), CdPalette.WELL)
	var half := size.x * 0.55
	_motion(Rect2(10, 16, half - 16.0, size.y - 36.0), font)
	_tone(Rect2(half + 4.0, 16, size.x - half - 14.0, size.y - 36.0), font)


func _motion(r: Rect2, font: Font) -> void:
	draw_rect(r, CdPalette.PANEL)
	draw_string(font, Vector2(r.position.x, r.position.y - 4.0), "WOW & FLUTTER",
			HORIZONTAL_ALIGNMENT_LEFT, r.size.x, 8, CdPalette.TEXT_MUTE)
	var mid := r.get_center().y
	draw_line(Vector2(r.position.x, mid), Vector2(r.end.x, mid), CdPalette.RULE_DARK, 1.0)
	var top := 0.0001
	for v in _trail:
		top = maxf(top, absf(v))
	var scale: float = r.size.y * 0.42 / maxf(top, 0.002)
	var pts := PackedVector2Array()
	for i in TRAIL:
		pts.append(Vector2(r.position.x + r.size.x * float(i) / float(TRAIL - 1),
				mid - _trail[i] * scale))
	draw_polyline(pts, CdPalette.ACCENT, 1.4, true)
	# The trace comes back as a fraction of the six milliseconds of travel the
	# transport has, so it is turned back into a time to be written down.
	draw_string(font, Vector2(r.position.x + 3.0, r.end.y - 3.0),
			"%.2f ms drift" % (top * 6.0), HORIZONTAL_ALIGNMENT_LEFT,
			r.size.x, 9, CdPalette.TEXT_DIM)


func _tone(r: Rect2, font: Font) -> void:
	draw_rect(r, CdPalette.PANEL)
	draw_string(font, Vector2(r.position.x, r.position.y - 4.0), "TONE",
			HORIZONTAL_ALIGNMENT_LEFT, r.size.x, 8, CdPalette.TEXT_MUTE)
	var mid := r.get_center().y
	draw_line(Vector2(r.position.x, mid), Vector2(r.end.x, mid), Color(1, 1, 1, 0.10), 1.0)
	# The head bump down low and the roll off up top, which is the tape sound
	# as much as the saturation is.
	var bump: float = _p("bump", 0.0)
	var hf: float = _p("hf", 12000.0)
	var pts := PackedVector2Array()
	for i in 65:
		var t := float(i) / 64.0
		var hz: float = 20.0 * pow(1000.0, t)
		var db: float = bump * exp(-pow(log(hz / 60.0), 2.0) * 1.4)
		db += -12.0 / (1.0 + pow(hf / maxf(hz, 20.0), 2.0))
		pts.append(Vector2(r.position.x + r.size.x * t,
				mid - clampf(db / 12.0, -1.0, 1.0) * r.size.y * 0.42))
	draw_polyline(pts, CdPalette.ACCENT, 1.4, true)
	draw_string(font, Vector2(r.position.x + 3.0, r.end.y - 3.0),
			"bump %s   roll %s" % [Cd.format_param(bump, Cd.ParamKind.DB),
			Cd.format_param(hf, Cd.ParamKind.HZ)],
			HORIZONTAL_ALIGNMENT_LEFT, r.size.x, 9, CdPalette.TEXT_DIM)


func _p(id: String, fallback: float) -> float:
	if _index.is_empty():
		for k in params.size():
			_index[String(params[k].id)] = int(params[k].index)
	if _index.has(id):
		return App.get_plugin_param(ref, int(_index[id]))
	return fallback
