class_name CdGateDynView
extends Control
## The gate: how loud the signal it is listening to is, where the threshold sits
## on that, and whether the gate is open right now.

var ref := {}
var params: Array = []

var _open := 0.0
var _level := -90.0
var _thresh := -40.0
var _range := -60.0


func _ready() -> void:
	custom_minimum_size.y = 116
	set_process(true)


func _process(_dt: float) -> void:
	if not is_visible_in_tree():
		return
	var h: int = App.handle_for(ref)
	if h < 0:
		return
	var a: PackedFloat32Array = App.engine().plugin_aux(h, 0, 4)
	if a.size() == 4:
		_open = a[0]
		_level = a[1]
		_thresh = a[2]
		_range = a[3]
	queue_redraw()


func _draw() -> void:
	var font := get_theme_default_font()
	draw_rect(Rect2(Vector2.ZERO, size), CdPalette.WELL)
	var r := Rect2(10, 22, size.x - 20.0, size.y - 52.0)
	draw_rect(r, CdPalette.PANEL)
	draw_string(font, Vector2(r.position.x, r.position.y - 6.0), "KEY",
			HORIZONTAL_ALIGNMENT_LEFT, r.size.x, 8, CdPalette.TEXT_MUTE)
	# Seventy two decibels across, which is as far down as a gate is ever set.
	const LO := -72.0
	for db in [-60.0, -48.0, -36.0, -24.0, -12.0]:
		var x: float = r.position.x + r.size.x * (db - LO) / -LO
		draw_line(Vector2(x, r.position.y), Vector2(x, r.end.y), Color(1, 1, 1, 0.05), 1.0)
		draw_string(font, Vector2(x + 2.0, r.end.y - 3.0), "%d" % int(db),
				HORIZONTAL_ALIGNMENT_LEFT, -1, 8, Color(1, 1, 1, 0.20))
	var lvl: float = clampf((_level - LO) / -LO, 0.0, 1.0)
	draw_rect(Rect2(r.position.x, r.position.y, r.size.x * lvl, r.size.y),
			Color(CdPalette.ACCENT.r, CdPalette.ACCENT.g, CdPalette.ACCENT.b, 0.35))
	var tx: float = r.position.x + r.size.x * clampf((_thresh - LO) / -LO, 0.0, 1.0)
	draw_line(Vector2(tx, r.position.y - 4.0), Vector2(tx, r.end.y + 4.0), CdPalette.BAD, 1.4)
	draw_string(font, Vector2(tx + 4.0, r.position.y + 11.0),
			Cd.format_param(_thresh, Cd.ParamKind.DB), HORIZONTAL_ALIGNMENT_LEFT,
			-1, 9, CdPalette.BAD)

	# The lamp: open, closed, or somewhere between while it moves.
	var lamp := Rect2(r.position.x, r.end.y + 8.0, 10.0, 10.0)
	draw_rect(lamp, CdPalette.GOOD if _open > 0.5 else CdPalette.PANEL)
	draw_string(font, Vector2(lamp.end.x + 6.0, lamp.end.y - 1.0),
			"%s   floor %s" % ["open" if _open > 0.5 else "closed",
			"silent" if _range <= -89.0 else Cd.format_param(_range, Cd.ParamKind.DB)],
			HORIZONTAL_ALIGNMENT_LEFT, r.size.x, 9, CdPalette.TEXT_DIM)
