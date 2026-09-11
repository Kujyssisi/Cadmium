class_name CdDelayView
extends Control
## The delay drawn as what you hear: a tap for every repeat, at the time it
## comes back and the level it comes back at, left taps above the line and
## right taps below when they are offset from each other.

var ref := {}
var params: Array = []

var _index := {}


func _ready() -> void:
	custom_minimum_size.y = 126
	set_process(true)


func _process(_dt: float) -> void:
	if is_visible_in_tree():
		queue_redraw()


func _draw() -> void:
	var font := get_theme_default_font()
	draw_rect(Rect2(Vector2.ZERO, size), CdPalette.WELL)
	var r := Rect2(10, 16, size.x - 20.0, size.y - 40.0)
	draw_rect(r, CdPalette.PANEL)
	draw_string(font, Vector2(r.position.x, r.position.y - 4.0), "REPEATS",
			HORIZONTAL_ALIGNMENT_LEFT, r.size.x, 8, CdPalette.TEXT_MUTE)
	var mid := r.get_center().y
	draw_line(Vector2(r.position.x, mid), Vector2(r.end.x, mid), CdPalette.RULE_DARK, 1.0)

	var ms := _time_ms()
	var fb: float = clampf(_p("feedback", 0.4), 0.0, 0.99)
	var ping: bool = _p("pingpong", 0.0) > 0.5
	var offset: float = _p("offset", 0.0)
	# Two seconds of tail across the panel: past that a repeat is inaudible
	# anyway at any sensible feedback.
	const SPAN_MS := 2000.0
	for hz in [500.0, 1000.0, 1500.0]:
		var x: float = r.position.x + r.size.x * (hz / SPAN_MS)
		draw_line(Vector2(x, r.position.y), Vector2(x, r.end.y), Color(1, 1, 1, 0.05), 1.0)
		draw_string(font, Vector2(x + 2.0, r.end.y - 3.0), "%.1fs" % (hz / 1000.0),
				HORIZONTAL_ALIGNMENT_LEFT, -1, 8, Color(1, 1, 1, 0.20))

	# The dry hit, then the repeats falling away by the feedback each time.
	draw_line(Vector2(r.position.x, mid), Vector2(r.position.x, r.position.y + 2.0),
			CdPalette.TEXT_DIM, 2.0)
	var level := 1.0
	var t := 0.0
	for i in 24:
		t += ms
		level *= fb
		if t > SPAN_MS or level < 0.008:
			break
		var side := 1 if (ping and i % 2 == 1) else -1
		var x: float = r.position.x + r.size.x * (t / SPAN_MS)
		# Sixty decibels of travel: at a low feedback the linear height would
		# put every repeat but the first on the floor.
		var h: float = (r.size.y * 0.46) * clampf(
				(Cd.gain_to_db(maxf(level, 0.0001)) + 60.0) / 60.0, 0.0, 1.0)
		if absf(offset) > 0.001 and not ping:
			# Both sides, one nudged: that is what the offset does.
			var xo: float = clampf(x + r.size.x * (offset * ms * 0.5 / SPAN_MS),
					r.position.x, r.end.x)
			draw_line(Vector2(x, mid), Vector2(x, mid - h), CdPalette.ACCENT, 2.0)
			draw_line(Vector2(xo, mid), Vector2(xo, mid + h),
					Color(CdPalette.ACCENT.r, CdPalette.ACCENT.g, CdPalette.ACCENT.b, 0.6), 2.0)
		else:
			draw_line(Vector2(x, mid), Vector2(x, mid + h * side), CdPalette.ACCENT, 2.0)

	var label := "%s   feedback %d%%" % [
			Cd.format_param(ms, Cd.ParamKind.MS), int(round(fb * 100.0))]
	if ping:
		label += "   ping pong"
	draw_string(font, Vector2(r.position.x, r.end.y + 13.0), label,
			HORIZONTAL_ALIGNMENT_LEFT, r.size.x, 9, CdPalette.TEXT_DIM)


## Either the time knob or the division, depending on which one is in charge.
func _time_ms() -> float:
	if _p("sync", 0.0) > 0.5:
		var beats: float = Cd.sync_beats(int(_p("div", 3.0)))
		return beats * 60000.0 / maxf(20.0, float(App.project.bpm))
	return maxf(1.0, _p("time", 300.0))


func _p(id: String, fallback: float) -> float:
	if _index.is_empty():
		for k in params.size():
			_index[String(params[k].id)] = int(params[k].index)
	if _index.has(id):
		return App.get_plugin_param(ref, int(_index[id]))
	return fallback
