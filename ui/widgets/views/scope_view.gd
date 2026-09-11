class_name CdScopeView
extends Control
## What the plugin is actually putting out: the wave along the top, the spectrum
## under it. Every stock panel gets one, so none of them is a bare grid of knobs
## -- you can see what a knob did as well as read its number.

var ref := {}
var params: Array = []
var _pts := PackedFloat32Array()
var _peak := 0.0
var _bins := PackedFloat32Array()
var _smooth := PackedFloat32Array()

var _coef := PackedFloat32Array()

const BINS := 56
const LO_HZ := 30.0
const HI_HZ := 18000.0
## How much of the height the wave takes; the spectrum has the rest.
const WAVE_SHARE := 0.38

func _ready() -> void:
	custom_minimum_size.y = 104
	set_process(true)

func _process(_dt: float) -> void:
	if not is_visible_in_tree():
		return
	var h: int = App.handle_for(ref)
	if h < 0:
		return
	_pts = App.engine().plugin_scope(h, 512)
	_peak = App.engine().plugin_peak(h)
	_analyse()
	queue_redraw()

## A real spectrum, by a Goertzel bank on log-spaced centres. Cheaper than
## a transform for a few dozen bins and it puts the bars where the eye
## expects them: an octave takes the same width everywhere.
func _analyse() -> void:
	var n: int = _pts.size() / 2
	if n < 32:
		return
	if _bins.size() != BINS:
		_bins.resize(BINS)
		_smooth.resize(BINS)
		_smooth.fill(0.0)
		_coef.resize(BINS)
		_recoef()
	if _coef.is_empty():
		_recoef()
	for b in BINS:
		var c: float = _coef[b]
		var s1 := 0.0
		var s2 := 0.0
		for i in n:
			# Mono sum: the picture is of the plugin, not of one side.
			var x: float = (_pts[i * 2] + _pts[i * 2 + 1]) * 0.5
			# Hann, so a tone lands in its own bin instead of smearing.
			x *= 0.5 - 0.5 * cos(TAU * float(i) / float(n - 1))
			var s0: float = x + c * s1 - s2
			s2 = s1
			s1 = s0
		var power: float = s1 * s1 + s2 * s2 - c * s1 * s2
		var mag: float = sqrt(maxf(0.0, power)) * (2.0 / float(n))
		# Decibels, floored where nothing is audible anyway.
		var db: float = 20.0 * log(maxf(mag, 1e-5)) / log(10.0)
		var v: float = clampf((db + 72.0) / 72.0, 0.0, 1.0)
		_bins[b] = v
		# Fall slowly, rise at once: the way a meter is read.
		_smooth[b] = maxf(v, _smooth[b] - 0.035)

func _recoef() -> void:
	var sr: float = 48000.0
	if App.engine() != null:
		sr = maxf(8000.0, float(App.engine().sample_rate()))
	var n: int = maxi(32, _pts.size() / 2)
	for b in BINS:
		var t: float = float(b) / float(BINS - 1)
		var hz: float = LO_HZ * pow(HI_HZ / LO_HZ, t)
		var k: float = float(n) * hz / sr
		_coef[b] = 2.0 * cos(TAU * k / float(n))

func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), CdPalette.WELL)
	var wave_h: float = maxf(24.0, size.y * WAVE_SHARE)
	_draw_wave(Rect2(0, 0, size.x, wave_h))
	draw_line(Vector2(0, wave_h), Vector2(size.x, wave_h), CdPalette.RULE_DARK, 1.0)
	_draw_spectrum(Rect2(0, wave_h + 1.0, size.x, size.y - wave_h - 1.0))

	var font := get_theme_default_font()
	var db: float = Cd.gain_to_db(maxf(_peak, 0.00001))
	draw_string(font, Vector2(6, 12), "out %.1f dB" % db, HORIZONTAL_ALIGNMENT_LEFT,
			-1, 9, CdPalette.TEXT_DIM if _peak < 1.0 else CdPalette.BAD)


## The last few milliseconds, lifted so a quiet signal is still a shape. The
## number above says how loud it really is, so the lift misleads no one.
func _draw_wave(r: Rect2) -> void:
	var mid: float = r.position.y + r.size.y * 0.5
	draw_line(Vector2(0, mid), Vector2(r.size.x, mid), CdPalette.RULE_DARK, 1.0)
	var n: int = _pts.size() / 2
	if n < 2:
		return
	var top: float = 0.0
	for i in n:
		top = maxf(top, maxf(absf(_pts[i * 2]), absf(_pts[i * 2 + 1])))
	if top < 0.00002:
		var font := get_theme_default_font()
		draw_string(font, Vector2(r.size.x * 0.5 - 14.0, mid + 4.0), "silent",
				HORIZONTAL_ALIGNMENT_LEFT, -1, 9, CdPalette.TEXT_DIM)
		return
	var scale: float = r.size.y * 0.46 / maxf(top, 0.05)
	var left := PackedVector2Array()
	var right := PackedVector2Array()
	for i in n:
		var x: float = r.size.x * float(i) / float(n - 1)
		left.append(Vector2(x, mid - _pts[i * 2] * scale))
		right.append(Vector2(x, mid - _pts[i * 2 + 1] * scale))
	# Right behind left: on a mono signal they sit on top of each other.
	draw_polyline(right, Color(CdPalette.ACCENT.r, CdPalette.ACCENT.g,
			CdPalette.ACCENT.b, 0.40), 1.0, true)
	draw_polyline(left, CdPalette.ACCENT, 1.2, true)


func _draw_spectrum(r: Rect2) -> void:
	var font := get_theme_default_font()
	# Octave marks, so a bump can be named without counting bars.
	for hz in [100.0, 1000.0, 10000.0]:
		var t: float = log(hz / LO_HZ) / log(HI_HZ / LO_HZ)
		if t <= 0.0 or t >= 1.0:
			continue
		var gx: float = r.size.x * t
		draw_line(Vector2(gx, r.position.y), Vector2(gx, r.end.y), Color(1, 1, 1, 0.06), 1.0)
		draw_string(font, Vector2(gx + 2.0, r.end.y - 2.0),
				"%dk" % int(hz / 1000.0) if hz >= 1000.0 else "%d" % int(hz),
				HORIZONTAL_ALIGNMENT_LEFT, -1, 8, Color(1, 1, 1, 0.18))
	if _smooth.size() != BINS:
		return
	var bw: float = r.size.x / float(BINS)
	var line := PackedVector2Array()
	for b in BINS:
		var v: float = clampf(_smooth[b], 0.0, 1.0)
		var x: float = (float(b) + 0.5) * bw
		line.append(Vector2(x, r.end.y - r.size.y * v))
		if v > 0.004:
			draw_rect(Rect2(b * bw + 0.5, r.end.y - r.size.y * v, bw - 1.0,
					r.size.y * v), Color(CdPalette.ACCENT.r, CdPalette.ACCENT.g,
					CdPalette.ACCENT.b, 0.22))
	draw_polyline(line, Color(CdPalette.ACCENT.r, CdPalette.ACCENT.g,
			CdPalette.ACCENT.b, 0.7), 1.2, true)
