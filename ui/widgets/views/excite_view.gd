class_name CdExciteView
extends Control
## Where the exciter is working and how much it is adding. The band above the
## corner lights as it generates, and the blend between even and odd harmonics
## is drawn as the harmonics themselves.

var ref := {}
var params: Array = []

var _freq := 3000.0
var _added := 0.0
var _blend := 0.5


func _ready() -> void:
	custom_minimum_size.y = 120
	set_process(true)


func _process(_dt: float) -> void:
	if not is_visible_in_tree():
		return
	var h: int = App.handle_for(ref)
	if h < 0:
		return
	var a: PackedFloat32Array = App.engine().plugin_aux(h, 0, 3)
	if a.size() == 3:
		_freq = a[0]
		_added = a[1]
		_blend = a[2]
	queue_redraw()


func _draw() -> void:
	var font := get_theme_default_font()
	draw_rect(Rect2(Vector2.ZERO, size), CdPalette.WELL)
	var r := Rect2(10, 16, size.x - 20.0, size.y - 40.0)
	draw_rect(r, CdPalette.PANEL)
	draw_string(font, Vector2(r.position.x, r.position.y - 4.0), "HARMONICS",
			HORIZONTAL_ALIGNMENT_LEFT, r.size.x, 8, CdPalette.TEXT_MUTE)
	const LO := 100.0
	const HI := 20000.0
	for hz in [500.0, 2000.0, 8000.0]:
		var t: float = log(hz / LO) / log(HI / LO)
		var x: float = r.position.x + r.size.x * t
		draw_line(Vector2(x, r.position.y), Vector2(x, r.end.y), Color(1, 1, 1, 0.05), 1.0)
		draw_string(font, Vector2(x + 2.0, r.end.y - 3.0),
				"%dk" % int(hz / 1000.0) if hz >= 1000.0 else "%d" % int(hz),
				HORIZONTAL_ALIGNMENT_LEFT, -1, 8, Color(1, 1, 1, 0.20))
	var ft: float = clampf(log(clampf(_freq, LO, HI) / LO) / log(HI / LO), 0.0, 1.0)
	var fx: float = r.position.x + r.size.x * ft
	var heat: float = clampf(_added * 6.0, 0.0, 1.0)
	draw_rect(Rect2(fx, r.position.y, r.end.x - fx, r.size.y),
			Color(CdPalette.ACCENT.r, CdPalette.ACCENT.g, CdPalette.ACCENT.b,
			0.06 + heat * 0.30))
	draw_line(Vector2(fx, r.position.y), Vector2(fx, r.end.y), CdPalette.ACCENT, 1.4)

	# The harmonics it is making, above the corner: even ones are shorter as the
	# blend moves to odd, which is the difference you hear.
	for k in range(2, 9):
		var hz: float = _freq * float(k) * 0.5
		if hz > HI:
			break
		var t2: float = log(clampf(hz, LO, HI) / LO) / log(HI / LO)
		var x2: float = r.position.x + r.size.x * t2
		var even: bool = k % 2 == 0
		var amp: float = (1.0 - _blend if even else _blend) * heat / float(k) * 3.0
		amp = clampf(amp, 0.0, 1.0)
		draw_line(Vector2(x2, r.end.y), Vector2(x2, r.end.y - r.size.y * amp),
				CdPalette.ACCENT if not even else CdPalette.TEXT_DIM, 2.0)

	draw_string(font, Vector2(r.position.x, r.end.y + 13.0),
			"above %s   %s" % [Cd.format_param(_freq, Cd.ParamKind.HZ),
			"mostly odd" if _blend > 0.6 else ("mostly even" if _blend < 0.4 else "even and odd")],
			HORIZONTAL_ALIGNMENT_LEFT, r.size.x, 9, CdPalette.TEXT_DIM)
