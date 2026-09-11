class_name CdTransportBar
extends PanelContainer
## Play, stop, record, tempo, position, pattern, mode, snap, tools.
##
## The layout is transport_bar.tscn; this wires it up. Icons are rasterised at
## run time from SVG, so they are set here rather than baked into the scene.

@onready var _play_btn: Button = $Scroll/Row/Transport/Row/Play
@onready var _stop_btn: Button = $Scroll/Row/Transport/Row/Stop
@onready var _rec_btn: Button = $Scroll/Row/Transport/Row/Record
@onready var _home_btn: Button = $Scroll/Row/Transport/Row/Home
@onready var _loop_btn: Button = $Scroll/Row/Transport/Row/Loop
@onready var _pos_label: Label = $Scroll/Row/Clock/Position
@onready var _time_label: Label = $Scroll/Row/Clock/Time
@onready var _bpm_field: CdDragField = $Scroll/Row/Tempo/Row/Bpm
@onready var _tap_btn: Button = $Scroll/Row/Tempo/Row/Tap
@onready var _metro_btn: Button = $Scroll/Row/Tempo/Row/Metronome
@onready var _pattern_btn: OptionButton = $Scroll/Row/Pattern/Row/Pattern
@onready var _add_btn: Button = $Scroll/Row/Pattern/Row/Add
@onready var _dup_btn: Button = $Scroll/Row/Pattern/Row/Duplicate
@onready var _mode_btn: Button = $Scroll/Row/Pattern/Row/Mode
@onready var _snap_btn: OptionButton = $Scroll/Row/Edit/Row/Snap
@onready var _tweak_knob: CdKnob = $Scroll/Row/Tweak/Row/Knob
@onready var _tweak_name: Label = $Scroll/Row/Tweak/Row/Name

## The control the toolbar knob is currently holding: App.last_tweaked[0] as it
## was when the display was last brought up to date.
var _tweak: Dictionary = {}
var _recording := false
var _tool_buttons := {}
var _taps: Array = []


func _ready() -> void:
	_icons()
	_wire()
	_fill_snap()

	App.patterns_changed.connect(_refresh)
	App.pattern_selected.connect(func(_i): _refresh())
	App.project_loaded.connect(_refresh)
	App.selection_changed.connect(_refresh_tools)
	App.tweaked.connect(func(_e): _refresh_tweak())
	App.project_loaded.connect(_refresh_tweak)
	_wire_tweak()
	Audio.transport_changed.connect(_refresh)
	set_process(true)
	_refresh()


# ---------------------------------------------------------------------------
# Last tweaked
# ---------------------------------------------------------------------------
## The knob in the toolbar holds whichever control was moved last -- a mixer
## fader, one of Cadmium's own parameters, or a knob inside a hosted plugin's
## own window -- so it can be nudged from here and, more to the point, turned
## into an automation clip without going looking for it again.
func _wire_tweak() -> void:
	_tweak_knob.show_label = false
	_tweak_knob.knob_size = 20.0
	_tweak_knob.value_changed.connect(func(v):
		if not _tweak.is_empty():
			App.set_tweak_value(_tweak, v))
	_tweak_knob.menu_requested.connect(func(_p): _tweak_menu())
	_tweak_name.mouse_filter = Control.MOUSE_FILTER_STOP
	_tweak_name.gui_input.connect(func(e):
		if e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_RIGHT:
			_tweak_menu())
	_refresh_tweak()


func _refresh_tweak() -> void:
	_tweak = App.last_tweaked[0] if not App.last_tweaked.is_empty() else {}
	var d := App.tweak_describe(_tweak) if not _tweak.is_empty() else {}
	if d.is_empty():
		_tweak = {}
		_tweak_name.text = "nothing yet"
		_tweak_knob.tooltip_text = "Move any knob, fader or plugin control and it appears here"
		_tweak_knob.set_value_silent(0.0)
		return
	_tweak_knob.minimum = float(d.lo)
	_tweak_knob.maximum = float(d.hi)
	_tweak_knob.default_value = float(d.default)
	_tweak_knob.kind = int(d.kind)
	_tweak_knob.choices = String(d.choices)
	_tweak_knob.skew = float(d.skew)
	_tweak_knob.set_value_silent(float(d.value))
	_tweak_name.text = String(d.short)
	_tweak_name.tooltip_text = String(d.name)
	_tweak_knob.tooltip_text = "%s\nDrag to change it, right-click to make an automation clip" % String(d.name)


func _tweak_menu() -> void:
	var pm := PopupMenu.new()
	add_child(pm)
	pm.add_separator("Automation")
	if _tweak.is_empty():
		pm.add_item("Nothing tweaked yet", 90)
		pm.set_item_disabled(pm.item_count - 1, true)
	else:
		pm.add_item("Create automation clip", 0)
	if App.last_tweaked.size() > 1:
		pm.add_item("Create automation clips for the last %d" % App.last_tweaked.size(), 1)
	# Anything else moved recently, so a clip can be made for the one before
	# last without having to go and touch it again.
	if App.last_tweaked.size() > 1:
		pm.add_separator("Recently tweaked")
		for i in App.last_tweaked.size():
			var d := App.tweak_describe(App.last_tweaked[i])
			if d.is_empty():
				continue
			pm.add_item(String(d.name), 100 + i)
	if not _tweak.is_empty():
		pm.add_separator("Value")
		pm.add_item("Reset", 2)
	pm.add_separator()
	pm.add_item("Forget the list", 3)
	pm.id_pressed.connect(func(id): _tweak_command(int(id)))
	pm.popup_hide.connect(func(): pm.queue_free(), CONNECT_DEFERRED)
	pm.popup(Rect2i(DisplayServer.mouse_get_position(), Vector2i(1, 1)))


func _tweak_command(id: int) -> void:
	if id >= 100:
		_make_tweak_clips([App.last_tweaked[id - 100]])
		return
	match id:
		0:
			_make_tweak_clips([_tweak])
		1:
			_make_tweak_clips(App.last_tweaked.duplicate())
		2:
			var d := App.tweak_describe(_tweak)
			if not d.is_empty():
				App.set_tweak_value(_tweak, float(d.default))
				_refresh_tweak()
		3:
			App.last_tweaked.clear()
			_refresh_tweak()
			App.status.emit("Forgot which controls were moved")


## A clip each, on a track with room for it, so several at once do not land on
## top of each other.
func _make_tweak_clips(entries: Array) -> void:
	var made := 0
	for e in entries:
		var length: float = maxf(4.0, App.project.length_beats())
		if App.automation_from_tweak(e, _free_track(length)) >= 0:
			made += 1
	App.playlist_changed.emit()
	if made == 0:
		App.status.emit("That control is not there any more")
	else:
		App.status.emit("Added %d automation clip%s" % [made, "" if made == 1 else "s"])


func _free_track(length: float) -> int:
	for t in App.project.tracks.size():
		var busy := false
		for c in App.project.clips:
			if int(c.track) == t and float(c.start) < length:
				busy = true
				break
		if not busy:
			return t
	return maxi(0, App.project.tracks.size() - 1)


## The glyphs, and the squaring-off that keeps them centred in their buttons.
func _icons() -> void:
	var art := {
		_play_btn: "play", _stop_btn: "stop", _rec_btn: "record",
		_home_btn: "skip_start", _loop_btn: "loop",
	}
	for b in art.keys():
		b.icon = Icons.get_icon(String(art[b]), 16)
		Cd.icon_button(b, 26.0)
	var small := {
		_metro_btn: "metronome", _add_btn: "add", _dup_btn: "copy",
		$Scroll/Row/Edit/Row/Draw: "pencil", $Scroll/Row/Edit/Row/Select: "select",
		$Scroll/Row/Edit/Row/Slice: "slice", $Scroll/Row/Edit/Row/Mute: "mute",
	}
	for b in small.keys():
		b.icon = Icons.get_icon(String(small[b]), 14)
		Cd.icon_button(b, 23.0)
	Cd.compact(_tap_btn, "Button")
	Cd.compact(_mode_btn, "Button")


func _wire() -> void:
	_play_btn.pressed.connect(_on_play)
	_stop_btn.pressed.connect(func(): Audio.stop())
	_rec_btn.pressed.connect(_on_record)
	_home_btn.pressed.connect(func(): Audio.seek(0.0))
	_loop_btn.button_pressed = bool(Settings.get_value("loop", true))
	_loop_btn.pressed.connect(_on_loop)

	_pos_label.gui_input.connect(func(e):
		if e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_LEFT:
			Audio.seek(0.0))

	_bpm_field.dragged.connect(func(v):
		App.set_bpm(v)
		_bpm_field.text = "%.2f" % App.project.bpm)
	_bpm_field.text_submitted.connect(func(t):
		App.set_bpm(t.to_float())
		_refresh()
		_bpm_field.release_focus())
	_bpm_field.focus_exited.connect(func():
		App.set_bpm(_bpm_field.text.to_float())
		_refresh())
	_tap_btn.pressed.connect(_on_tap)
	_metro_btn.pressed.connect(_on_metro)

	_pattern_btn.item_selected.connect(func(i): App.select_pattern(i))
	_add_btn.pressed.connect(func(): App.add_pattern())
	_dup_btn.pressed.connect(_on_duplicate_pattern)
	_mode_btn.pressed.connect(func():
		App.set_mode(Cd.Mode.SONG if _mode_btn.button_pressed else Cd.Mode.PATTERN)
		_refresh())

	_snap_btn.item_selected.connect(func(idx): App.set_snap(_snap_btn.get_item_text(idx)))
	for entry in [[Cd.Tool.DRAW, "Draw"], [Cd.Tool.SELECT, "Select"],
			[Cd.Tool.SLICE, "Slice"], [Cd.Tool.MUTE, "Mute"]]:
		var t: int = int(entry[0])
		var b: Button = get_node("Scroll/Row/Edit/Row/%s" % String(entry[1]))
		b.button_pressed = App.tool == t
		b.pressed.connect(func(): set_tool(t))
		_tool_buttons[t] = b


func _fill_snap() -> void:
	_snap_btn.clear()
	var i := 0
	for key in Cd.SNAPS.keys():
		_snap_btn.add_item(key)
		if key == App.snap:
			_snap_btn.select(i)
		i += 1


func _refresh_tools() -> void:
	for k in _tool_buttons.keys():
		_tool_buttons[k].button_pressed = int(k) == App.tool


func _on_play() -> void:
	Audio.toggle()
	_refresh()


func set_tool(tool: int) -> void:
	App.tool = tool
	_refresh_tools()
	App.selection_changed.emit()
	App.status.emit(["Draw", "Select", "Slice", "Mute"][clampi(tool, 0, 3)] + " tool")


## Four taps is enough for a stable average and short enough to stay in time.
func _on_tap() -> void:
	var now := Time.get_ticks_msec() / 1000.0
	if not _taps.is_empty() and now - float(_taps[-1]) > 2.5:
		_taps.clear()
	_taps.append(now)
	while _taps.size() > 5:
		_taps.pop_front()
	if _taps.size() < 2:
		App.status.emit("Keep tapping...")
		return
	var total := float(_taps[-1]) - float(_taps[0])
	var bpm := 60.0 * float(_taps.size() - 1) / maxf(0.001, total)
	while bpm < 60.0:
		bpm *= 2.0
	while bpm > 220.0:
		bpm *= 0.5
	App.set_bpm(snappedf(bpm, 0.01))
	_refresh()
	App.status.emit("Tempo %.2f from %d taps" % [App.project.bpm, _taps.size()])


func _on_loop() -> void:
	Settings.set_value("loop", _loop_btn.button_pressed)
	App.set_loop_enabled(_loop_btn.button_pressed)
	App.status.emit("Loop on" if _loop_btn.button_pressed else "Loop off")


func toggle_loop() -> void:
	_loop_btn.button_pressed = not _loop_btn.button_pressed
	_on_loop()


func _on_duplicate_pattern() -> void:
	App.duplicate_pattern(App.current_pattern)


func _on_metro() -> void:
	Settings.set_value("metronome", _metro_btn.button_pressed)
	Audio.engine.set_metronome(_metro_btn.button_pressed)


func _on_record() -> void:
	_recording = not _recording
	_rec_btn.modulate = Color(1.5, 0.75, 0.7) if _recording else Color.WHITE
	App.set_recording(_recording)


func recording() -> bool:
	return _recording


func _process(_dt: float) -> void:
	if Audio.engine == null:
		return
	var beat: float = Audio.position()
	_pos_label.text = Cd.format_beats(beat, App.project.sig_num)
	_time_label.text = Cd.format_time(beat, App.project.bpm)
	var playing: bool = Audio.playing()
	_play_btn.icon = Icons.get_icon("pause" if playing else "play", 16)


func _refresh() -> void:
	_bpm_field.text = "%.2f" % App.project.bpm
	_metro_btn.button_pressed = bool(Settings.get_value("metronome", false))
	var song := App.mode() == Cd.Mode.SONG
	_mode_btn.button_pressed = song
	_mode_btn.text = "SONG" if song else "PAT"
	_pattern_btn.clear()
	for p in App.project.patterns:
		_pattern_btn.add_item(String(p.name))
	if App.current_pattern < _pattern_btn.item_count:
		_pattern_btn.select(App.current_pattern)
