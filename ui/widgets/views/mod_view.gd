class_name CdModView
extends Control
## What the modulation is doing: the shape it is sweeping, at the rate it is
## sweeping it, with the dot showing where it has got to. Chorus, flanger,
## phaser, auto pan and ring modulator all move something with an oscillator,
## so they all get this.

var ref := {}
var params: Array = []

var _phase := 0.0
var _index := {}


func _ready() -> void:
	custom_minimum_size.y = 118
	set_process(true)


func _process(dt: float) -> void:
	if not is_visible_in_tree():
		return
	# Free-running here rather than read from the processor: it is showing the
	# rate, and a rate is the one thing the panel can work out for itself.
	_phase = fposmod(_phase + dt * _rate(), 1.0)
	queue_redraw()


func _rate() -> float:
	var hz := _p(["rate", "lfo_rate"], 0.0)
	if hz > 0.0:
		return hz
	# Ring modulation has no LFO; its frequency is the thing being drawn, and
	# at a few kilohertz nothing useful moves, so it is shown standing still.
	return 0.0


func _draw() -> void:
	var font := get_theme_default_font()
	draw_rect(Rect2(Vector2.ZERO, size), CdPalette.WELL)
	var r := Rect2(8, 16, size.x - 16.0, size.y - 40.0)
	draw_rect(r, CdPalette.PANEL)
	draw_string(font, Vector2(r.position.x, r.position.y - 4.0), "MOTION",
			HORIZONTAL_ALIGNMENT_LEFT, r.size.x, 8, CdPalette.TEXT_MUTE)
	var mid := r.get_center().y
	draw_line(Vector2(r.position.x, mid), Vector2(r.end.x, mid), CdPalette.RULE_DARK, 1.0)

	var depth: float = _norm(["depth", "lfo_amt", "mix"], 0.5)
	var shape := int(_p(["shape", "lfo_shape"], 0.0))
	# Two cycles across, so the shape is readable rather than a single hump.
	var pts := PackedVector2Array()
	const N := 128
	for i in N + 1:
		var t := float(i) / float(N)
		var v := _wave(fposmod(t * 2.0, 1.0), shape)
		pts.append(Vector2(r.position.x + r.size.x * t, mid - v * r.size.y * 0.46 * depth))
	draw_polyline(pts, CdPalette.ACCENT, 1.6, true)

	if _rate() > 0.0:
		var t2 := fposmod(_phase, 0.5) * 2.0
		var x: float = r.position.x + r.size.x * (t2 * 0.5)
		var y: float = mid - _wave(fposmod(t2, 1.0), shape) * r.size.y * 0.46 * depth
		draw_line(Vector2(x, r.position.y), Vector2(x, r.end.y), Color(1, 1, 1, 0.14), 1.0)
		draw_circle(Vector2(x, y), 3.0, CdPalette.TEXT)

	var bits := PackedStringArray()
	if _rate() > 0.0:
		bits.append("%s" % Cd.format_param(_rate(), Cd.ParamKind.HZ))
	if _has(["depth"]):
		bits.append("depth %s" % _text("depth"))
	if _has(["feedback"]):
		bits.append("feedback %s" % _text("feedback"))
	if _has(["freq"]):
		bits.append("carrier %s" % _text("freq"))
	draw_string(font, Vector2(r.position.x, r.end.y + 13.0), "   ".join(bits),
			HORIZONTAL_ALIGNMENT_LEFT, r.size.x, 9, CdPalette.TEXT_DIM)


## The named shapes, in the order the plugins list them.
func _wave(t: float, shape: int) -> float:
	match shape:
		1:   # triangle
			return 1.0 - 4.0 * absf(t - 0.5)
		2:   # saw
			return 1.0 - 2.0 * t
		3:   # square
			return 1.0 if t < 0.5 else -1.0
		_:
			return sin(t * TAU)


func _fill_index() -> void:
	if not _index.is_empty():
		return
	for k in params.size():
		_index[String(params[k].id)] = int(params[k].index)


func _has(names: Array) -> bool:
	_fill_index()
	for n in names:
		if _index.has(n):
			return true
	return false


## Where a parameter sits in its own range, 0 to 1 -- depth is milliseconds on
## a chorus and a fraction on a phaser, and the picture wants neither.
func _norm(names: Array, fallback: float) -> float:
	_fill_index()
	for n in names:
		if not _index.has(n):
			continue
		for pm in params:
			if String(pm.id) != n:
				continue
			var v: float = App.get_plugin_param(ref, int(pm.index))
			var lo: float = float(pm.min)
			var hi: float = float(pm.max)
			return clampf((v - lo) / maxf(0.0001, hi - lo), 0.0, 1.0)
	return fallback


## A parameter written the way its own descriptor says it should be.
func _text(id: String) -> String:
	for pm in params:
		if String(pm.id) == id:
			return Cd.format_param(App.get_plugin_param(ref, int(pm.index)),
					int(pm.kind), String(pm.get("choices", "")))
	return ""


func _p(names: Array, fallback: float) -> float:
	_fill_index()
	for n in names:
		if _index.has(n):
			return App.get_plugin_param(ref, int(_index[n]))
	return fallback
