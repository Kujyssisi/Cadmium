class_name CdLoudView
extends Control
## How loud it is by the measure streaming services use: momentary, short term
## and integrated loudness, with the target marked, and the true peak beside
## them because that is the other number that gets a master sent back.

var ref := {}
var params: Array = []

var _m := -100.0
var _s := -100.0
var _i := -100.0
var _peak := -100.0
var _target := -14.0


func _ready() -> void:
	custom_minimum_size.y = 190
	set_process(true)


func _process(_dt: float) -> void:
	if not is_visible_in_tree():
		return
	var h: int = App.handle_for(ref)
	if h < 0:
		return
	var a: PackedFloat32Array = App.engine().plugin_aux(h, 0, 5)
	if a.size() == 5:
		_m = a[0]
		_s = a[1]
		_i = a[2]
		_peak = a[3]
		_target = a[4]
	queue_redraw()


func _draw() -> void:
	var font := get_theme_default_font()
	draw_rect(Rect2(Vector2.ZERO, size), CdPalette.WELL)
	var bars := Rect2(10, 18, size.x - 20.0, size.y - 60.0)
	# Forty units of scale, from silence up past anything anyone masters to.
	const LO := -40.0
	const HI := 0.0
	var rows := [{"n": "MOMENTARY", "v": _m}, {"n": "SHORT TERM", "v": _s},
			{"n": "INTEGRATED", "v": _i}]
	var h := bars.size.y / float(rows.size())
	for i in rows.size():
		var row: Dictionary = rows[i]
		var r := Rect2(bars.position.x + 76.0, bars.position.y + float(i) * h + 3.0,
				bars.size.x - 86.0, h - 10.0)
		draw_rect(r, CdPalette.PANEL)
		var v: float = float(row.v)
		var t: float = clampf((v - LO) / (HI - LO), 0.0, 1.0)
		if t > 0.002:
			var over: bool = v > _target + 1.0
			var under: bool = v < _target - 1.0
			draw_rect(Rect2(r.position, Vector2(r.size.x * t, r.size.y)),
					CdPalette.BAD if over else (CdPalette.ACCENT if under else CdPalette.GOOD))
		draw_string(font, Vector2(bars.position.x, r.get_center().y + 3.0),
				String(row.n), HORIZONTAL_ALIGNMENT_LEFT, 74.0, 8, CdPalette.TEXT_MUTE)
		draw_string(font, Vector2(r.position.x + 4.0, r.end.y - 3.0),
				"-inf" if v <= -99.0 else "%.1f LUFS" % v,
				HORIZONTAL_ALIGNMENT_LEFT, r.size.x, 9, CdPalette.TEXT)
	# The target, straight down through all three, which is how you aim at it.
	var tx: float = bars.position.x + 76.0 + (bars.size.x - 86.0) * clampf(
			(_target - LO) / (HI - LO), 0.0, 1.0)
	draw_line(Vector2(tx, bars.position.y), Vector2(tx, bars.end.y), CdPalette.TEXT_DIM, 1.2)
	draw_string(font, Vector2(tx + 3.0, bars.position.y + 9.0),
			"target %.0f" % _target, HORIZONTAL_ALIGNMENT_LEFT, -1, 8, CdPalette.TEXT_DIM)

	var over: bool = _peak > -1.0
	draw_string(font, Vector2(10, size.y - 12.0),
			"true peak %.1f dB" % _peak, HORIZONTAL_ALIGNMENT_LEFT, size.x - 20.0, 10,
			CdPalette.BAD if over else CdPalette.TEXT_DIM)
	if _i > -99.0:
		draw_string(font, Vector2(10, size.y - 12.0),
				"%+.1f to target" % (_target - _i), HORIZONTAL_ALIGNMENT_RIGHT,
				size.x - 20.0, 10, CdPalette.TEXT_DIM)
