class_name CdMultibandView
extends Control
## Gain reduction per band, as three falling bars with the crossover
## frequencies written under them.

var ref := {}
var params: Array = []
var _gr := PackedFloat32Array([0, 0, 0])

func _ready() -> void:
	custom_minimum_size.y = 116
	set_process(true)

func _process(_dt: float) -> void:
	if not is_visible_in_tree():
		return
	var h: int = App.handle_for(ref)
	if h < 0:
		return
	var a: PackedFloat32Array = App.engine().plugin_aux(h, 0, 3)
	if a.size() == 3:
		_gr = a
		queue_redraw()

func _draw() -> void:
	var font := get_theme_default_font()
	draw_rect(Rect2(Vector2.ZERO, size), CdPalette.WELL)
	var names := ["LOW", "MID", "HIGH"]
	var lo := _param_value("x_low", 180.0)
	var hi := _param_value("x_high", 2800.0)
	var edges := ["below %s" % Cd.format_param(lo, Cd.ParamKind.HZ),
			"%s - %s" % [Cd.format_param(lo, Cd.ParamKind.HZ), Cd.format_param(hi, Cd.ParamKind.HZ)],
			"above %s" % Cd.format_param(hi, Cd.ParamKind.HZ)]
	var w := size.x / 3.0
	# Twelve decibels of travel: past that the bar is pinned and the number
	# is what tells you how far.
	const RANGE := 12.0
	for b in 3:
		var r := Rect2(b * w + 4.0, 16.0, w - 8.0, size.y - 38.0)
		draw_rect(r, CdPalette.PANEL)
		var db: float = -Cd.gain_to_db(1.0 - clampf(_gr[b], 0.0, 0.98))
		var t: float = clampf(db / RANGE, 0.0, 1.0)
		if t > 0.001:
			# Drawn downwards, the way a gain reduction meter always is.
			draw_rect(Rect2(r.position.x, r.position.y, r.size.x, r.size.y * t),
					CdPalette.ACCENT if t < 0.85 else CdPalette.BAD)
		draw_string(font, Vector2(r.position.x, 12), names[b], HORIZONTAL_ALIGNMENT_LEFT,
				r.size.x, 9, CdPalette.TEXT_MUTE)
		draw_string(font, Vector2(r.position.x, size.y - 12), edges[b],
				HORIZONTAL_ALIGNMENT_LEFT, r.size.x, 8, CdPalette.TEXT_DIM)
		draw_string(font, Vector2(r.position.x, size.y - 24), "-%.1f dB" % db,
				HORIZONTAL_ALIGNMENT_RIGHT, r.size.x, 9, CdPalette.TEXT)

func _param_value(id: String, fallback: float) -> float:
	for i in params.size():
		if String(params[i].id) == id:
			return App.get_plugin_param(ref, int(params[i].index))
	return fallback
