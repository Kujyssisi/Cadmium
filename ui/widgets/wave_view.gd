class_name CdWaveView
extends Control
## The sampler's waveform, with draggable start, end and loop markers.

var ref := {}
var _peaks := PackedFloat32Array()
var _drag := ""


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	focus_mode = Control.FOCUS_NONE
	tooltip_text = "Drag the markers to set the played region and the loop"
	set_process(true)
	refresh()


func _process(_dt: float) -> void:
	if not _drag.is_empty() and not Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		_drag = ""


func refresh() -> void:
	var h := App.handle_for(ref)
	_peaks = App.engine().plugin_aux(h, 0, 1024) if h >= 0 else PackedFloat32Array()
	queue_redraw()


func _param(id: String) -> int:
	for p in App.plugin_params(ref):
		if String(p.id) == id:
			return int(p.index)
	return -1


func _pget(id: String) -> float:
	var i := _param(id)
	return App.get_plugin_param(ref, i) if i >= 0 else 0.0


func _pset(id: String, v: float) -> void:
	var i := _param(id)
	if i >= 0:
		App.set_plugin_param(ref, i, clampf(v, 0.0, 1.0))


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index != MOUSE_BUTTON_LEFT:
			return
		if mb.pressed:
			var t := mb.position.x / maxf(1.0, size.x)
			var candidates := {"start": _pget("start"), "end": _pget("end"),
					"loop_start": _pget("loop_start"), "loop_end": _pget("loop_end")}
			var best := ""
			var best_d := 0.04
			for k in candidates.keys():
				var d: float = absf(float(candidates[k]) - t)
				if d < best_d:
					best_d = d
					best = k
			_drag = best
		else:
			_drag = ""
		accept_event()
	elif event is InputEventMouseMotion and not _drag.is_empty():
		_pset(_drag, event.position.x / maxf(1.0, size.x))
		queue_redraw()
		accept_event()


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), CdPalette.WELL)
	var mid := size.y * 0.5
	if _peaks.size() < 4:
		draw_string(get_theme_default_font(), Vector2(8, mid), "no sample loaded",
				HORIZONTAL_ALIGNMENT_LEFT, -1, 10, CdPalette.TEXT_MUTE)
		return
	var pairs := _peaks.size() / 2
	var w := size.x / float(pairs)
	for i in pairs:
		var lo := _peaks[i * 2]
		var hi := _peaks[i * 2 + 1]
		var x := float(i) * w
		draw_rect(Rect2(x, mid - hi * mid * 0.92, maxf(1.0, w), maxf(1.0, (hi - lo) * mid * 0.92)),
				CdPalette.ACCENT_SOFT)
	draw_line(Vector2(0, mid), Vector2(size.x, mid), Color(1, 1, 1, 0.12), 1.0)

	var s := _pget("start") * size.x
	var e := _pget("end") * size.x
	draw_rect(Rect2(0, 0, s, size.y), Color(0, 0, 0, 0.55))
	draw_rect(Rect2(e, 0, size.x - e, size.y), Color(0, 0, 0, 0.55))
	draw_line(Vector2(s, 0), Vector2(s, size.y), CdPalette.ACCENT, 1.5)
	draw_line(Vector2(e, 0), Vector2(e, size.y), CdPalette.ACCENT, 1.5)
	if _pget("loop_mode") > 0.5:
		var ls := _pget("loop_start") * size.x
		var le := _pget("loop_end") * size.x
		draw_line(Vector2(ls, 0), Vector2(ls, size.y), CdPalette.WARN, 1.0)
		draw_line(Vector2(le, 0), Vector2(le, size.y), CdPalette.WARN, 1.0)
		draw_rect(Rect2(ls, size.y - 4.0, le - ls, 4.0), CdPalette.WARN)
