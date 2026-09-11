extends Control
## The little level lamp beside a channel's name: peak level with a slow fall,
## so a short hit still registers on the eye.

var channel := 0
var _level := 0.0
var _peak := 0.0


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	focus_mode = Control.FOCUS_NONE
	set_process(true)


func _process(dt: float) -> void:
	if Audio.engine == null:
		return
	var v: float = Audio.engine.channel_level(channel)
	var was := Vector2(_level, _peak)
	_level = maxf(v, _level - dt * 1.6)
	_peak = maxf(v, _peak - dt * 0.5)
	# Redrawing a silent lamp sixty times a second is sixty draw calls for the
	# same picture, and there is one of these per channel.
	if absf(_level - was.x) > 0.002 or absf(_peak - was.y) > 0.002:
		queue_redraw()


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), CdPalette.WELL)
	if _level <= 0.0005:
		return
	var t := clampf(pow(clampf((Cd.gain_to_db(_level) + 48.0) / 48.0, 0.0, 1.0), 1.3), 0.0, 1.0)
	var h := size.y * t
	draw_rect(Rect2(0, size.y - h, size.x, h), CdPalette.meter_color(Cd.gain_to_db(_level)))
	var ph := size.y * clampf(pow(clampf((Cd.gain_to_db(_peak) + 48.0) / 48.0, 0.0, 1.0), 1.3), 0.0, 1.0)
	if ph > 1.0:
		draw_rect(Rect2(0, size.y - ph, size.x, 1.0), CdPalette.TEXT_DIM)
