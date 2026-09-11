class_name CdEqCurve
extends Control
## EQ Eight's display: live spectrum behind, the filter response in front, and
## one draggable handle per band. Both curves come from the engine's own filters
## (aux 0 is the response, aux 1 the analyser) rather than being recomputed
## here, so what you see is what is running.

signal param_changed()

var ref := {}
var params: Array = []

const BANDS := 8
var _idx := {}          # band -> {on, type, freq, gain, q}
var _drag := -1
var _hover := -1


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	focus_mode = Control.FOCUS_NONE
	tooltip_text = "Drag a band; wheel over it changes Q; right-click for its type"
	_map_params()
	set_process(true)


func _map_params() -> void:
	for p in params:
		var id := String(p.id)
		for b in BANDS:
			if not id.begins_with("b%d_" % b):
				continue
			if not _idx.has(b):
				_idx[b] = {}
			_idx[b][id.substr(3)] = int(p.index)


func _process(_dt: float) -> void:
	if _drag >= 0 and not Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		_drag = -1
		param_changed.emit()
	queue_redraw()


func _pget(b: int, key: String) -> float:
	if not _idx.has(b) or not _idx[b].has(key):
		return 0.0
	return App.get_plugin_param(ref, int(_idx[b][key]))


func _pset(b: int, key: String, v: float) -> void:
	if not _idx.has(b) or not _idx[b].has(key):
		return
	App.set_plugin_param(ref, int(_idx[b][key]), v)


func _hz_to_x(hz: float) -> float:
	return size.x * clampf(log(maxf(20.0, hz) / 20.0) / log(1000.0), 0.0, 1.0)


func _x_to_hz(x: float) -> float:
	return 20.0 * pow(1000.0, clampf(x / maxf(1.0, size.x), 0.0, 1.0))


func _db_to_y(db: float) -> float:
	return size.y * 0.5 - (db / 30.0) * (size.y * 0.5 - 8.0)


func _y_to_db(y: float) -> float:
	return clampf((size.y * 0.5 - y) / (size.y * 0.5 - 8.0) * 30.0, -24.0, 24.0)


func _band_pos(b: int) -> Vector2:
	return Vector2(_hz_to_x(_pget(b, "freq")), _db_to_y(_pget(b, "gain")))


func _band_at(pos: Vector2) -> int:
	for b in BANDS:
		if _band_pos(b).distance_to(pos) < 11.0:
			return b
	return -1


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed:
				_drag = _band_at(mb.position)
				if _drag >= 0:
					if mb.double_click:
						_pset(_drag, "on", 0.0 if _pget(_drag, "on") > 0.5 else 1.0)
						param_changed.emit()
					elif _pget(_drag, "on") < 0.5:
						_pset(_drag, "on", 1.0)
						param_changed.emit()
			else:
				if _drag >= 0:
					param_changed.emit()
				_drag = -1
			accept_event()
		elif mb.button_index == MOUSE_BUTTON_RIGHT and mb.pressed:
			var b := _band_at(mb.position)
			if b >= 0:
				_type_menu(b)
			accept_event()
		elif mb.pressed and mb.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]:
			var b := _band_at(mb.position)
			if b >= 0:
				var q := _pget(b, "q")
				_pset(b, "q", clampf(q * (1.15 if mb.button_index == MOUSE_BUTTON_WHEEL_UP else 1.0 / 1.15), 0.1, 18.0))
				param_changed.emit()
				accept_event()
	elif event is InputEventMouseMotion:
		var mm := event as InputEventMouseMotion
		if _drag >= 0:
			_pset(_drag, "freq", clampf(_x_to_hz(mm.position.x), 20.0, 20000.0))
			_pset(_drag, "gain", _y_to_db(mm.position.y))
			accept_event()
		else:
			var h := _band_at(mm.position)
			if h != _hover:
				_hover = h
				queue_redraw()


func _type_menu(b: int) -> void:
	var pm := PopupMenu.new()
	add_child(pm)
	var names := ["Low Shelf", "Bell", "High Shelf", "High Pass", "Low Pass", "Notch", "Band Pass"]
	for i in names.size():
		pm.add_item(names[i], i)
	pm.add_separator()
	pm.add_item("Enabled", 100)
	pm.set_item_as_checkable(pm.item_count - 1, true)
	pm.set_item_checked(pm.item_count - 1, _pget(b, "on") > 0.5)
	pm.id_pressed.connect(func(id):
		if id == 100:
			_pset(b, "on", 0.0 if _pget(b, "on") > 0.5 else 1.0)
		else:
			_pset(b, "type", float(id))
		param_changed.emit()
		pm.queue_free())
	pm.popup(Rect2i(DisplayServer.mouse_get_position(), Vector2i(1, 1)))


func _draw() -> void:
	var font := get_theme_default_font()
	draw_rect(Rect2(Vector2.ZERO, size), CdPalette.WELL)

	for hz in [50, 100, 200, 500, 1000, 2000, 5000, 10000]:
		var x := _hz_to_x(float(hz))
		draw_line(Vector2(x, 0), Vector2(x, size.y), CdPalette.GRID_FINE, 1.0)
		draw_string(font, Vector2(x + 2, size.y - 3), "%dk" % (hz / 1000) if hz >= 1000 else str(hz),
				HORIZONTAL_ALIGNMENT_LEFT, -1, 8, CdPalette.TEXT_MUTE)
	for db in [-18, -12, -6, 0, 6, 12, 18]:
		var y := _db_to_y(float(db))
		draw_line(Vector2(0, y), Vector2(size.x, y), CdPalette.GRID_BEAT if db == 0 else CdPalette.GRID_FINE, 1.0)

	var h := App.handle_for(ref)
	if h < 0:
		return

	# Analyser.
	var spec: PackedFloat32Array = App.engine().plugin_aux(h, 1, 512)
	if spec.size() > 4:
		var rate := float(App.engine().sample_rate())
		var pts := PackedVector2Array()
		pts.append(Vector2(0, size.y))
		for i in range(1, spec.size()):
			var hz := float(i) * rate / 1024.0
			if hz < 20.0 or hz > 20000.0:
				continue
			var x := _hz_to_x(hz)
			var y := size.y - clampf((spec[i] + 78.0) / 78.0, 0.0, 1.0) * size.y
			pts.append(Vector2(x, y))
		pts.append(Vector2(size.x, size.y))
		if pts.size() > 3:
			draw_colored_polygon(pts, Color(CdPalette.ACCENT.r, CdPalette.ACCENT.g, CdPalette.ACCENT.b, 0.13))

	# Response.
	var curve: PackedFloat32Array = App.engine().plugin_aux(h, 0, 129)
	if curve.size() > 2:
		var line := PackedVector2Array()
		for i in curve.size():
			var hz := 20.0 * pow(1000.0, float(i) / float(curve.size() - 1))
			line.append(Vector2(_hz_to_x(hz), _db_to_y(curve[i])))
		draw_polyline(line, CdPalette.ACCENT, 2.0, true)

	for b in BANDS:
		var on := _pget(b, "on") > 0.5
		var p := _band_pos(b)
		var col := CdPalette.ACCENT if on else CdPalette.TEXT_MUTE
		draw_circle(p, 6.0 if b != _hover else 8.0, Color(col.r, col.g, col.b, 0.85 if on else 0.4))
		draw_arc(p, 6.0, 0, TAU, 20, CdPalette.WELL, 1.5, true)
		draw_string(font, p + Vector2(-3, 4), str(b + 1), HORIZONTAL_ALIGNMENT_LEFT, -1, 9, CdPalette.WELL)
