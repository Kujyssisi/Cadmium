class_name CdVocoderView
extends Control
## The vocoder's bands, each as tall as the voice going into it is loud in that
## band -- and, above them, the one thing a vocoder needs and nothing else in
## Cadmium does: something to speak into it.
##
## A vocoder with no modulator is a vocoder that does nothing, which is what it
## looks like from the outside when the routing has not been set up. So the
## routing is set up from here: pick a strip to speak from, or hand it the
## machine's own input and it will make one.

var ref := {}
var params: Array = []

var _bands := PackedFloat32Array()
var _sources: Array = []
var _live := -1.0

@onready var _pick: Button = Button.new()
@onready var _mic: Button = Button.new()


func _ready() -> void:
	custom_minimum_size.y = 168
	_pick.focus_mode = Control.FOCUS_NONE
	_pick.tooltip_text = "Which strip speaks through this vocoder"
	_pick.pressed.connect(_source_menu)
	add_child(_pick)
	_mic.focus_mode = Control.FOCUS_NONE
	_mic.text = "Use my microphone"
	_mic.tooltip_text = "Puts the machine's audio input on a muted strip and feeds it in here"
	_mic.pressed.connect(func():
		if _track() >= 0:
			App.wire_input_to(_track())
		_refresh())
	add_child(_mic)
	App.mixer_changed.connect(_refresh)
	_refresh()
	set_process(true)


func _track() -> int:
	return int(ref.get("track", -1)) if String(ref.get("kind", "")) == "insert" else -1


func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED:
		_layout()


func _layout() -> void:
	_pick.position = Vector2(10, 6)
	_pick.size = Vector2(maxf(120.0, size.x * 0.52 - 14.0), 22)
	_mic.position = Vector2(_pick.position.x + _pick.size.x + 6.0, 6)
	_mic.size = Vector2(maxf(90.0, size.x - _mic.position.x - 10.0), 22)


func _refresh() -> void:
	var t := _track()
	_sources = App.sidechain_sources(t) if t >= 0 else []
	if t < 0:
		_pick.text = "Put this on a mixer strip"
		_pick.disabled = true
		_mic.disabled = true
		return
	_pick.disabled = false
	_mic.disabled = false
	if _sources.is_empty():
		_pick.text = "Modulator: nothing"
	else:
		var names := PackedStringArray()
		for s in _sources:
			names.append(String(App.project.mixer[int(s)].name))
		_pick.text = "Modulator: %s" % ", ".join(names)
	_mic.text = "Use my microphone" if App.input_track() < 0 else "Feed the input in"
	_layout()


## Every strip that could speak, with the ones already speaking ticked.
func _source_menu() -> void:
	var t := _track()
	if t < 0:
		return
	var pm := PopupMenu.new()
	add_child(pm)
	var ids := []
	for i in App.project.mixer.size():
		if i == t or i == 0:
			continue
		pm.add_check_item(String(App.project.mixer[i].name), ids.size())
		pm.set_item_checked(pm.item_count - 1, _sources.has(i))
		ids.append(i)
	pm.id_pressed.connect(func(id):
		var track := int(ids[id])
		App.set_sidechain(track, t, not _sources.has(track))
		_refresh())
	pm.popup_hide.connect(func(): pm.queue_free(), CONNECT_DEFERRED)
	pm.popup(Rect2i(DisplayServer.mouse_get_position(), Vector2i(1, 1)))


func _process(_dt: float) -> void:
	if not is_visible_in_tree():
		return
	var h: int = App.handle_for(ref)
	if h < 0:
		return
	var a: PackedFloat32Array = App.engine().plugin_aux(h, 0, 34)
	if a.size() > 1:
		_bands = a
	var lv: PackedFloat32Array = App.engine().plugin_aux(h, 1, 1)
	_live = lv[0] if lv.size() > 0 else -1.0
	queue_redraw()


func _draw() -> void:
	var font := get_theme_default_font()
	draw_rect(Rect2(Vector2.ZERO, size), CdPalette.WELL)
	var r := Rect2(10, 44, size.x - 20.0, size.y - 66.0)
	draw_rect(r, CdPalette.PANEL)
	draw_string(font, Vector2(r.position.x, r.position.y - 4.0), "BANDS",
			HORIZONTAL_ALIGNMENT_LEFT, r.size.x, 8, CdPalette.TEXT_MUTE)
	# How much modulator is arriving at all, which is the difference between
	# "nothing is wired up" and "nothing is being said".
	var lr := Rect2(r.end.x - 54.0, r.position.y - 11.0, 54.0, 7.0)
	draw_rect(lr, CdPalette.WELL)
	if _live >= 0.0:
		draw_rect(Rect2(lr.position, Vector2(lr.size.x * clampf(_live, 0.0, 1.0), lr.size.y)),
				CdPalette.GOOD if _live > 0.01 else CdPalette.BEVEL_HI)

	var n: int = int(_bands[0]) if _bands.size() > 1 else 0
	if n > 0:
		var bw: float = r.size.x / float(n)
		for b in n:
			var v: float = clampf(_bands[b + 1], 0.0, 1.0)
			# A floor under every band, so the bank reads as a bank even in
			# silence rather than as an empty box.
			var h: float = maxf(1.0, r.size.y * v)
			draw_rect(Rect2(r.position.x + float(b) * bw + 1.0, r.end.y - h,
					maxf(1.0, bw - 2.0), h), CdPalette.ACCENT)

	var lo := _param("low", 120.0)
	var hi := _param("high", 8000.0)
	draw_string(font, Vector2(r.position.x, r.end.y + 13.0),
			"%s to %s over %d bands" % [_hz(lo), _hz(hi), maxi(n, 1)],
			HORIZONTAL_ALIGNMENT_LEFT, r.size.x * 0.7, 9, CdPalette.TEXT_DIM)

	var note := ""
	if _live < 0.0:
		note = "nothing is speaking into this yet"
	elif _live < 0.005:
		note = "the modulator is wired up and silent -- say something"
	if not note.is_empty():
		draw_string(font, Vector2(0, r.get_center().y), note,
				HORIZONTAL_ALIGNMENT_CENTER, size.x, 9, CdPalette.TEXT_MUTE)


func _param(id: String, fallback: float) -> float:
	for p in params:
		if String(p.get("id", "")) == id:
			return App.get_plugin_param(ref, int(p.index))
	return fallback


func _hz(v: float) -> String:
	return "%.1f kHz" % (v / 1000.0) if v >= 1000.0 else "%d Hz" % int(v)
