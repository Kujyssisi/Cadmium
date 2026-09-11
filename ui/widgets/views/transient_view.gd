class_name CdTransientView
extends Control
## The two envelopes the transient shaper compares -- one quick, one slow -- and
## the gain that comes out of the difference between them. Where the quick one
## is above the slow one is an onset; below it is the tail.

var ref := {}
var params: Array = []

var _gain := 1.0
var _fast := 0.0
var _slow := 0.0
var _trail := PackedFloat32Array()

const TRAIL := 160


func _ready() -> void:
	custom_minimum_size.y = 122
	_trail.resize(TRAIL)
	_trail.fill(1.0)
	set_process(true)


func _process(_dt: float) -> void:
	if not is_visible_in_tree():
		return
	var h: int = App.handle_for(ref)
	if h < 0:
		return
	var a: PackedFloat32Array = App.engine().plugin_aux(h, 0, 4)
	if a.size() == 4:
		_gain = a[0]
		_fast = a[1]
		_slow = a[2]
		for i in TRAIL - 1:
			_trail[i] = _trail[i + 1]
		_trail[TRAIL - 1] = _gain
	queue_redraw()


func _draw() -> void:
	var font := get_theme_default_font()
	draw_rect(Rect2(Vector2.ZERO, size), CdPalette.WELL)
	var r := Rect2(10, 16, size.x - 20.0, size.y - 40.0)
	draw_rect(r, CdPalette.PANEL)
	draw_string(font, Vector2(r.position.x, r.position.y - 4.0), "GAIN",
			HORIZONTAL_ALIGNMENT_LEFT, r.size.x, 8, CdPalette.TEXT_MUTE)
	# Unity across the middle: above it the shaper is adding, below it is taking.
	var mid := r.get_center().y
	draw_line(Vector2(r.position.x, mid), Vector2(r.end.x, mid), Color(1, 1, 1, 0.12), 1.0)
	var pts := PackedVector2Array()
	for i in TRAIL:
		var db: float = Cd.gain_to_db(maxf(_trail[i], 0.02))
		var y: float = mid - clampf(db / 12.0, -1.0, 1.0) * r.size.y * 0.46
		pts.append(Vector2(r.position.x + r.size.x * float(i) / float(TRAIL - 1), y))
	draw_polyline(pts, CdPalette.ACCENT, 1.4, true)

	# The two envelopes as bars, so the comparison the plugin makes is visible.
	var bar_w := 14.0
	for i in 2:
		var v: float = clampf((_fast if i == 0 else _slow) * 2.0, 0.0, 1.0)
		var bar := Rect2(r.end.x - bar_w * float(2 - i) - 4.0, r.end.y - r.size.y * v,
				bar_w - 3.0, r.size.y * v)
		draw_rect(bar, CdPalette.ACCENT if i == 0 else CdPalette.TEXT_DIM)
	draw_string(font, Vector2(r.position.x, r.end.y + 13.0),
			"now %s   quick and slow envelopes on the right" %
			Cd.format_param(Cd.gain_to_db(maxf(_gain, 0.02)), Cd.ParamKind.DB),
			HORIZONTAL_ALIGNMENT_LEFT, r.size.x, 9, CdPalette.TEXT_DIM)
