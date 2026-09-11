class_name CdDeessView
extends Control
## Where the de-esser is listening and how hard it is pulling. The band it acts
## on is shaded across a frequency axis, the threshold sits as a line across the
## level it is watching, and the bar underneath is the reduction happening now.

var ref := {}
var params: Array = []

var _gr := 0.0
var _level := -90.0
var _freq := 6500.0
var _thresh := -28.0


func _ready() -> void:
	custom_minimum_size.y = 128
	set_process(true)


func _process(_dt: float) -> void:
	if not is_visible_in_tree():
		return
	var h: int = App.handle_for(ref)
	if h < 0:
		return
	var a: PackedFloat32Array = App.engine().plugin_aux(h, 0, 4)
	if a.size() == 4:
		_gr = a[0]
		_level = a[1]
		_freq = a[2]
		_thresh = a[3]
	queue_redraw()


func _draw() -> void:
	var font := get_theme_default_font()
	draw_rect(Rect2(Vector2.ZERO, size), CdPalette.WELL)
	var band := Rect2(8, 16, size.x - 16.0, size.y - 60.0)
	_draw_band(band, font)
	_draw_gr(Rect2(8, band.end.y + 10.0, size.x - 16.0, 18.0), font)


func _draw_band(r: Rect2, font: Font) -> void:
	draw_rect(r, CdPalette.PANEL)
	draw_string(font, Vector2(r.position.x + 3.0, r.position.y - 4.0), "BAND",
			HORIZONTAL_ALIGNMENT_LEFT, r.size.x, 8, CdPalette.TEXT_MUTE)
	# Two hundred hertz to twenty thousand: the part of the band an "s" lives in.
	const LO := 200.0
	const HI := 20000.0
	for hz in [1000.0, 5000.0, 10000.0]:
		var t: float = log(hz / LO) / log(HI / LO)
		var x: float = r.position.x + r.size.x * t
		draw_line(Vector2(x, r.position.y), Vector2(x, r.end.y), Color(1, 1, 1, 0.06), 1.0)
		draw_string(font, Vector2(x + 2.0, r.end.y - 3.0),
				"%dk" % int(hz / 1000.0), HORIZONTAL_ALIGNMENT_LEFT, -1, 8,
				Color(1, 1, 1, 0.20))
	var ft: float = clampf(log(maxf(LO, _freq) / LO) / log(HI / LO), 0.0, 1.0)
	var fx: float = r.position.x + r.size.x * ft
	# Everything above the corner is what the detector hears; the harder it is
	# pulling, the more of it is coloured.
	var heat: float = clampf(-_gr / 12.0, 0.0, 1.0)
	draw_rect(Rect2(fx, r.position.y, r.end.x - fx, r.size.y),
			Color(CdPalette.ACCENT.r, CdPalette.ACCENT.g, CdPalette.ACCENT.b,
			0.10 + heat * 0.35))
	draw_line(Vector2(fx, r.position.y), Vector2(fx, r.end.y), CdPalette.ACCENT, 1.4)
	draw_string(font, Vector2(fx + 4.0, r.position.y + 12.0),
			Cd.format_param(_freq, Cd.ParamKind.HZ), HORIZONTAL_ALIGNMENT_LEFT,
			-1, 9, CdPalette.TEXT)

	# The level in that band against the threshold, so it is obvious whether
	# anything is going to happen at all.
	var lvl: float = clampf((_level + 72.0) / 72.0, 0.0, 1.0)
	var th: float = clampf((_thresh + 72.0) / 72.0, 0.0, 1.0)
	var meter := Rect2(fx + 1.0, r.end.y - r.size.y * lvl, r.end.x - fx - 2.0, r.size.y * lvl)
	draw_rect(meter, Color(CdPalette.ACCENT.r, CdPalette.ACCENT.g, CdPalette.ACCENT.b, 0.35))
	var ty: float = r.end.y - r.size.y * th
	draw_line(Vector2(fx, ty), Vector2(r.end.x, ty), CdPalette.BAD, 1.2)
	draw_string(font, Vector2(r.end.x - 66.0, ty - 3.0),
			Cd.format_param(_thresh, Cd.ParamKind.DB), HORIZONTAL_ALIGNMENT_RIGHT,
			62.0, 8, CdPalette.BAD)


func _draw_gr(r: Rect2, font: Font) -> void:
	draw_rect(r, CdPalette.PANEL)
	var f: float = clampf(-_gr / 24.0, 0.0, 1.0)
	if f > 0.001:
		# Drawn from the right: a de-esser takes away, so the bar eats inwards.
		draw_rect(Rect2(r.end.x - r.size.x * f, r.position.y, r.size.x * f, r.size.y),
				CdPalette.BAD if f > 0.6 else CdPalette.ACCENT)
	draw_string(font, Vector2(r.position.x + 4.0, r.end.y - 5.0),
			"reduction %.1f dB" % _gr, HORIZONTAL_ALIGNMENT_LEFT, r.size.x, 9,
			CdPalette.TEXT)
