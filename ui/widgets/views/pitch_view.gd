class_name CdPitchView
extends Control
## What the shifter is actually doing: the spectrum going in, the spectrum
## coming out, and the interval between them shown on a keyboard.
##
## The two spectra are drawn over one another on purpose -- the whole point of
## the plugin is that the second is the first moved sideways, and seeing them
## together is what makes a wrong setting obvious.

var ref := {}
var params: Array = []

const BANDS := 64

var _in := PackedFloat32Array()
var _out := PackedFloat32Array()
var _index := {}


func _ready() -> void:
	custom_minimum_size.y = 168
	set_process(true)


func _process(_dt: float) -> void:
	if not is_visible_in_tree():
		return
	var h: int = App.handle_for(ref)
	if h >= 0:
		var a: PackedFloat32Array = App.engine().plugin_aux(h, 0, BANDS * 2)
		if a.size() >= BANDS * 2:
			_in = a.slice(0, BANDS)
			_out = a.slice(BANDS, BANDS * 2)
	queue_redraw()


func _draw() -> void:
	var font := get_theme_default_font()
	draw_rect(Rect2(Vector2.ZERO, size), CdPalette.WELL)

	var spec := Rect2(10, 16, size.x - 20.0, size.y - 82.0)
	draw_rect(spec, CdPalette.PANEL)
	draw_string(font, Vector2(spec.position.x, spec.position.y - 4.0), "IN / OUT",
			HORIZONTAL_ALIGNMENT_LEFT, spec.size.x, 8, CdPalette.TEXT_MUTE)
	_octave_marks(spec)
	if _in.size() == BANDS:
		_spectrum(spec, _in, Color(0.62, 0.66, 0.72, 0.42), true)
	if _out.size() == BANDS:
		_spectrum(spec, _out, CdPalette.ACCENT, false)
	if _in.size() != BANDS:
		draw_string(font, Vector2(0, spec.get_center().y), "play something through it",
				HORIZONTAL_ALIGNMENT_CENTER, size.x, 9, CdPalette.TEXT_MUTE)

	# The interval, on a keyboard an octave either side of the note going in.
	var keys := Rect2(10, size.y - 58.0, size.x - 20.0, 30.0)
	const RANGE := 12
	var n := RANGE * 2 + 1
	var kw: float = keys.size.x / float(n)
	for i in n:
		draw_rect(Rect2(keys.position.x + float(i) * kw + 0.5, keys.position.y,
				kw - 1.0, keys.size.y),
				Color(0.17, 0.17, 0.18) if _is_black(i - RANGE) else Color(0.74, 0.74, 0.75))
	var semis: float = _p("semi", 0.0) + _p("cent", 0.0) / 100.0
	var from_x: float = keys.position.x + (float(RANGE) + 0.5) * kw
	var to_x: float = clampf(keys.position.x + (semis + float(RANGE) + 0.5) * kw,
			keys.position.x, keys.end.x)
	draw_rect(Rect2(from_x - kw * 0.5 + 0.5, keys.position.y, kw - 1.0, keys.size.y),
			Color(0.42, 0.42, 0.44))
	draw_rect(Rect2(to_x - kw * 0.5 + 0.5, keys.position.y, kw - 1.0, keys.size.y),
			CdPalette.ACCENT)
	draw_line(Vector2(from_x, keys.end.y + 5.0), Vector2(to_x, keys.end.y + 5.0),
			CdPalette.ACCENT, 1.6)

	var formant: float = _p("formant", 0.0)
	var note := "%+.2f semitones" % semis
	if absf(formant) > 0.01:
		note += "   formants %+.1f" % formant
	note += "   latency %d samples" % 2048
	draw_string(font, Vector2(keys.position.x, size.y - 8.0), note,
			HORIZONTAL_ALIGNMENT_LEFT, keys.size.x, 9, CdPalette.TEXT_DIM)


## The same octave gridlines the analyser draws, so the two read alike. The
## engine's bands are logarithmic from bin 1 to the Nyquist bin.
func _octave_marks(r: Rect2) -> void:
	var font := get_theme_default_font()
	for hz in [100, 1000, 10000]:
		var t := _hz_to_t(float(hz))
		if t <= 0.0 or t >= 1.0:
			continue
		var x: float = r.position.x + r.size.x * t
		draw_line(Vector2(x, r.position.y), Vector2(x, r.end.y), Color(1, 1, 1, 0.06), 1.0)
		draw_string(font, Vector2(x + 2.0, r.end.y - 3.0),
				"%dk" % (hz / 1000) if hz >= 1000 else str(hz),
				HORIZONTAL_ALIGNMENT_LEFT, 40.0, 8, CdPalette.TEXT_MUTE)


func _hz_to_t(hz: float) -> float:
	var bins := 1024.0
	var rate: float = float(AudioServer.get_mix_rate())
	var bin: float = hz / maxf(1.0, rate) * 2048.0
	if bin < 1.0:
		return 0.0
	return log(bin) / log(bins)


func _spectrum(r: Rect2, v: PackedFloat32Array, col: Color, fill: bool) -> void:
	var pts := PackedVector2Array()
	for i in v.size():
		var x: float = r.position.x + r.size.x * (float(i) + 0.5) / float(v.size())
		pts.append(Vector2(x, r.end.y - r.size.y * clampf(v[i], 0.0, 1.0)))
	if pts.size() < 2:
		return
	if fill:
		# Column by column rather than as one polygon: a filled spectrum with a
		# notch in it is not convex, and the triangulator says so.
		for i in pts.size():
			var w: float = r.size.x / float(pts.size())
			draw_rect(Rect2(pts[i].x - w * 0.5, pts[i].y, w, r.end.y - pts[i].y), col)
	draw_polyline(pts, col, 1.4, true)


const WHITE := [0, 2, 4, 5, 7, 9, 11]


func _is_black(semi: int) -> bool:
	return not (((semi % 12) + 12) % 12) in WHITE


func _p(id: String, fallback: float) -> float:
	if _index.is_empty():
		for k in params.size():
			_index[String(params[k].id)] = int(params[k].index)
	if _index.has(id):
		return App.get_plugin_param(ref, int(_index[id]))
	return fallback
