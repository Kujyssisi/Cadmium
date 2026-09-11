extends PanelContainer
## Scope: what is actually leaving the master bus, three ways at once --
## waveform, spectrum, and stereo field. Everything is read from the engine's
## own output history, so it shows the mix including every insert.

const SCOPE_FRAMES := 2048
const BINS := 96

var _scope := PackedFloat32Array()
var _spec := PackedFloat32Array()
var _spec_smooth := PackedFloat32Array()
var _peak_hold := PackedFloat32Array()
var _corr := 0.0
var _mode := 0        ## 0 all three, 1 waveform, 2 spectrum, 3 stereo


@onready var _canvas: Control = $Col/Canvas


func _ready() -> void:
	# The frame is visualiser.tscn; the picture is a _draw call below.
	($Col/Caption/Row/Icon as TextureRect).texture = Icons.get_icon("wave", 14)
	var modes: OptionButton = $Col/Caption/Row/Mode
	for m in ["All", "Waveform", "Spectrum", "Stereo"]:
		modes.add_item(m)
	modes.item_selected.connect(func(i):
		_mode = i
		_canvas.queue_redraw())
	_canvas.draw.connect(_draw_canvas)
	set_process(true)


func _process(_dt: float) -> void:
	if Audio.engine == null or not is_visible_in_tree():
		return
	_scope = Audio.engine.scope(SCOPE_FRAMES)
	_spec = Audio.engine.spectrum(BINS)
	if _spec_smooth.size() != _spec.size():
		_spec_smooth = _spec.duplicate()
		_peak_hold = _spec.duplicate()
	for i in _spec.size():
		# Fast attack, slow release: the shape of a transient stays readable.
		_spec_smooth[i] = maxf(_spec[i], lerpf(_spec_smooth[i], _spec[i], 0.35))
		_peak_hold[i] = maxf(_spec[i], _peak_hold[i] - 0.55)
	var sum_lr := 0.0
	var sum_ll := 0.0
	var sum_rr := 0.0
	var i2 := 0
	while i2 + 1 < _scope.size():
		var l := _scope[i2]
		var r := _scope[i2 + 1]
		sum_lr += l * r
		sum_ll += l * l
		sum_rr += r * r
		i2 += 2
	_corr = sum_lr / maxf(0.000001, sqrt(sum_ll * sum_rr))
	_canvas.queue_redraw()


func _draw_canvas() -> void:
	var c := _canvas
	var size := c.size
	c.draw_rect(Rect2(Vector2.ZERO, size), CdPalette.VIEWPORT)
	if size.x < 40.0 or size.y < 40.0:
		return
	match _mode:
		1:
			_waveform(c, Rect2(Vector2.ZERO, size))
		2:
			_spectrum(c, Rect2(Vector2.ZERO, size))
		3:
			_stereo(c, Rect2(Vector2.ZERO, size))
		_:
			var stereo_w: float = minf(size.y, size.x * 0.28)
			var rest := size.x - stereo_w - 4.0
			_waveform(c, Rect2(0, 0, rest, size.y * 0.42))
			_spectrum(c, Rect2(0, size.y * 0.42 + 2.0, rest, size.y * 0.58 - 2.0))
			_stereo(c, Rect2(rest + 4.0, 0, stereo_w, size.y))


func _frame(c: Control, r: Rect2, label: String) -> void:
	c.draw_rect(r, CdPalette.WELL)
	c.draw_rect(r, CdPalette.RULE_DARK, false, 1.0)
	c.draw_string(get_theme_default_font(), r.position + Vector2(6, 12), label,
			HORIZONTAL_ALIGNMENT_LEFT, -1, 9, CdPalette.TEXT_MUTE)


## Waveform, triggered on a rising zero crossing so a steady tone stands still
## instead of sliding across the display.
func _waveform(c: Control, r: Rect2) -> void:
	_frame(c, r, "WAVEFORM")
	if _scope.size() < 64:
		return
	var frames := _scope.size() / 2
	var start := 0
	var half := frames / 2
	for i in range(1, half):
		if _scope[(i - 1) * 2] <= 0.0 and _scope[i * 2] > 0.0:
			start = i
			break
	var span: int = mini(frames - start, half)
	if span < 8:
		return
	var mid := r.position.y + r.size.y * 0.5
	c.draw_line(Vector2(r.position.x, mid), Vector2(r.end.x, mid), CdPalette.GRID_FINE, 1.0)
	var pts_l := PackedVector2Array()
	var pts_r := PackedVector2Array()
	var step: int = maxi(1, span / int(r.size.x))
	var i2 := 0
	while i2 < span:
		var x := r.position.x + r.size.x * float(i2) / float(span)
		pts_l.append(Vector2(x, mid - _scope[(start + i2) * 2] * r.size.y * 0.46))
		pts_r.append(Vector2(x, mid - _scope[(start + i2) * 2 + 1] * r.size.y * 0.46))
		i2 += step
	if pts_r.size() > 1:
		c.draw_polyline(pts_r, Color(CdPalette.ACCENT.r, CdPalette.ACCENT.g, CdPalette.ACCENT.b, 0.45), 1.0, true)
	if pts_l.size() > 1:
		c.draw_polyline(pts_l, CdPalette.ACCENT, 1.2, true)


func _spectrum(c: Control, r: Rect2) -> void:
	_frame(c, r, "SPECTRUM")
	if _spec_smooth.size() < 4:
		return
	var n := _spec_smooth.size()
	var bw := r.size.x / float(n)
	for hz in [100, 1000, 10000]:
		var t: float = log(float(hz) / 20.0) / log(1000.0)
		var x: float = r.position.x + r.size.x * t
		c.draw_line(Vector2(x, r.position.y), Vector2(x, r.end.y), CdPalette.GRID_FINE, 1.0)
		c.draw_string(get_theme_default_font(), Vector2(x + 2, r.end.y - 3),
				"%dk" % (hz / 1000) if hz >= 1000 else str(hz),
				HORIZONTAL_ALIGNMENT_LEFT, -1, 8, CdPalette.TEXT_MUTE)
	for i in n:
		var db: float = _spec_smooth[i]
		var t: float = clampf((db + 84.0) / 84.0, 0.0, 1.0)
		var h: float = r.size.y * t
		var x: float = r.position.x + float(i) * bw
		var col := CdPalette.meter_color(db + 12.0)
		c.draw_rect(Rect2(x, r.end.y - h, maxf(1.0, bw - 1.0), h), col)
		var ph: float = r.size.y * clampf((_peak_hold[i] + 84.0) / 84.0, 0.0, 1.0)
		if ph > 1.0:
			c.draw_rect(Rect2(x, r.end.y - ph, maxf(1.0, bw - 1.0), 1.5), CdPalette.TEXT_DIM)


## Goniometer: L/R rotated 45 degrees, so mono is a vertical line and a wide
## mix fills the disc. The bar underneath is phase correlation.
func _stereo(c: Control, r: Rect2) -> void:
	_frame(c, r, "STEREO")
	var pad := 10.0
	var side: float = minf(r.size.x, r.size.y - 34.0) - pad * 2.0
	if side < 20.0:
		return
	var centre := Vector2(r.position.x + r.size.x * 0.5, r.position.y + pad + side * 0.5 + 6.0)
	var rad := side * 0.5
	c.draw_arc(centre, rad, 0, TAU, 48, CdPalette.GRID_FINE, 1.0)
	c.draw_line(centre - Vector2(0, rad), centre + Vector2(0, rad), CdPalette.GRID_FINE, 1.0)
	c.draw_line(centre - Vector2(rad, 0), centre + Vector2(rad, 0), CdPalette.GRID_FINE, 1.0)
	var i := 0
	var step: int = maxi(2, (_scope.size() / 2) / 700) * 2
	while i + 1 < _scope.size():
		var l := _scope[i]
		var rr := _scope[i + 1]
		var p := Vector2((l - rr) * 0.7071, -(l + rr) * 0.7071) * rad
		c.draw_rect(Rect2(centre + p, Vector2(1.4, 1.4)),
				Color(CdPalette.ACCENT.r, CdPalette.ACCENT.g, CdPalette.ACCENT.b, 0.55))
		i += step
	var bar := Rect2(r.position.x + pad, r.end.y - 20.0, r.size.x - pad * 2.0, 8.0)
	c.draw_rect(bar, CdPalette.SUNKEN)
	var mid := bar.position.x + bar.size.x * 0.5
	var w: float = bar.size.x * 0.5 * float(_corr)
	c.draw_rect(Rect2(minf(mid, mid + w), bar.position.y, absf(w), bar.size.y),
			CdPalette.GOOD if _corr >= 0.0 else CdPalette.BAD)
	c.draw_line(Vector2(mid, bar.position.y), Vector2(mid, bar.end.y), CdPalette.TEXT_MUTE, 1.0)
	c.draw_string(get_theme_default_font(), Vector2(bar.position.x, bar.position.y - 3),
			"correlation %+.2f" % _corr, HORIZONTAL_ALIGNMENT_LEFT, -1, 9, CdPalette.TEXT_MUTE)
