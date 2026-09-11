extends PanelContainer
## Channel Rack: one row per instrument, with the sixteenth-note step grid that
## makes a pattern without opening the piano roll.

const ROW_H := 26.0
const STEP_W := 22.0
const HEAD_W := 300.0

var _row_nodes: Array = []


@onready var _title: Label = $Col/Caption/Row/Title
@onready var _steps_label: Label = $Col/Caption/Row/Steps
@onready var _bars: SpinBox = $Col/Caption/Row/Bars
@onready var _scroll: ScrollContainer = $Col/Scroll
@onready var _rows: VBoxContainer = $Col/Scroll/Rows


func _ready() -> void:
	# The frame is channel_rack.tscn; the rows are per channel and are made in
	# rebuild(). Icons and menu items are set here because neither belongs in a
	# scene file: one is rasterised at run time, the other is a list.
	($Col/Caption/Row/Icon as TextureRect).texture = Icons.get_icon("rack", 14)
	var add_btn: Button = $Col/Caption/Row/AddChannel
	add_btn.icon = Icons.get_icon("add", 14)
	add_btn.pressed.connect(_popup_add_menu)

	_bars.value_changed.connect(func(v):
		var beats := float(v) * float(App.project.sig_num)
		if absf(beats - float(App.project.patterns[App.current_pattern].length)) > 0.01:
			App.set_pattern_prop(App.current_pattern, "length", beats, "Pattern length"))

	var tp: PopupMenu = ($Col/Caption/Row/PatternMenu as MenuButton).get_popup()
	tp.add_item("New Pattern", 0)
	tp.add_item("Clone Pattern", 1)
	tp.add_item("Rename Pattern...", 2)
	tp.add_item("Delete Pattern", 3)
	tp.id_pressed.connect(_pattern_tool)

	App.channels_changed.connect(rebuild)
	App.patterns_changed.connect(_repaint)
	App.pattern_selected.connect(func(_i): rebuild())
	App.project_loaded.connect(rebuild)
	App.selection_changed.connect(_repaint)
	rebuild()


func grab_focus_row() -> void:
	if not _row_nodes.is_empty():
		_scroll.ensure_control_visible(_row_nodes[App.current_channel] if App.current_channel < _row_nodes.size() else _row_nodes[0])


func _repaint() -> void:
	for r in _row_nodes:
		if is_instance_valid(r):
			r.queue_redraw()
			for c in r.get_children():
				if c is Control:
					c.queue_redraw()


func rebuild() -> void:
	for c in _rows.get_children():
		c.queue_free()
	_row_nodes.clear()
	var pattern: Dictionary = App.project.patterns[App.current_pattern] if App.current_pattern < App.project.patterns.size() else {}
	var steps := int(round(float(pattern.get("length", 16.0)) / Cd.STEP))
	_steps_label.text = "%s  -  %d steps" % [String(pattern.get("name", "")), steps]
	if _bars != null:
		_bars.set_value_no_signal(maxf(1.0, float(pattern.get("length", 16.0)) / float(App.project.sig_num)))
	for i in App.project.channels.size():
		var row := _make_row(i, steps)
		_rows.add_child(row)
		_row_nodes.append(row)


## One row per channel, from channel_row.tscn. What it shows is the channel's;
## what it does when you click it is the rack's, so the row asks by signal.
func _make_row(index: int, steps: int) -> Control:
	var row = preload("res://ui/panels/channel_row.tscn").instantiate()
	row.index = index
	row.steps = steps
	row.custom_minimum_size.y = ROW_H
	row.menu_requested.connect(func(i, e): _row_input(e, i))
	row.layers_requested.connect(open_layers)
	row.route_requested.connect(_route_menu)
	return row


func _pattern_tool(id: int) -> void:
	match id:
		0:
			App.add_pattern()
		1:
			App.clone_pattern(App.current_pattern)
		2:
			_rename_pattern()
		3:
			App.remove_pattern(App.current_pattern)


func _rename_pattern() -> void:
	var dlg := AcceptDialog.new()
	dlg.title = "Rename Pattern"
	var field := LineEdit.new()
	field.text = String(App.project.patterns[App.current_pattern].name)
	field.custom_minimum_size.x = 240
	dlg.add_child(field)
	dlg.register_text_enter(field)
	add_child(dlg)
	dlg.confirmed.connect(func():
		App.set_pattern_prop(App.current_pattern, "name", field.text, "Rename pattern")
		dlg.queue_free())
	dlg.popup_centered()
	field.grab_focus()
	field.select_all()


func _row_input(event: InputEvent, index: int) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_RIGHT:
		_channel_menu(index)


func _channel_menu(index: int) -> void:
	var pm := PopupMenu.new()
	add_child(pm)
	pm.add_item("Rename...", 0)
	pm.add_item("Open Piano Roll", 1)
	pm.add_item("Replace Instrument...", 2)
	pm.add_separator()
	pm.add_item("Layers...", 7)
	pm.add_separator()
	pm.add_item("Clone Channel", 3)
	pm.add_item("Delete Channel", 4)
	pm.add_separator()
	pm.add_item("Clear Steps", 5)
	pm.add_item("Fill Every 4th", 6)
	pm.id_pressed.connect(func(id):
		match id:
			0: _rename(index)
			1:
				App.select_channel(index)
				owner_main().tabs.current_tab = 1
				owner_main().piano.focus_channel(index)
			2: _replace_instrument(index)
			3: _clone(index)
			4: App.remove_channel(index)
			5: _clear_steps(index)
			6: _fill_steps(index, 4)
			7: open_layers(index)
		pm.queue_free())
	pm.popup(Rect2i(DisplayServer.mouse_get_position(), Vector2i(1, 1)))


func owner_main():
	var n: Node = self
	while n != null and not (n.get_script() != null and n.has_method("open_plugin_window")):
		n = n.get_parent()
	return n


func _rename(index: int) -> void:
	var dlg := AcceptDialog.new()
	dlg.title = "Rename Channel"
	var field := LineEdit.new()
	field.text = String(App.project.channels[index].name)
	field.custom_minimum_size.x = 260
	dlg.add_child(field)
	dlg.register_text_enter(field)
	add_child(dlg)
	dlg.confirmed.connect(func():
		App.set_channel_prop(index, "name", field.text, "Rename channel")
		dlg.queue_free())
	dlg.popup_centered()
	field.grab_focus()
	field.select_all()


func _clone(index: int) -> void:
	var src: Dictionary = App.project.channels[index]
	var plug: Dictionary = (src.plugin as Dictionary).duplicate(true)
	var i := App.add_channel(plug, String(src.name) + " copy")
	App.set_channel_prop(i, "vol", float(src.vol))
	App.set_channel_prop(i, "pan", float(src.pan))


func _clear_steps(index: int) -> void:
	App.snapshot("Clear steps")
	var notes: Array = App.project.patterns[App.current_pattern].notes
	var keep := []
	for n in notes:
		if int(n.ch) != index:
			keep.append(n)
	App.project.patterns[App.current_pattern].notes = keep
	App.push_pattern(App.current_pattern)
	App.patterns_changed.emit()


func _fill_steps(index: int, every: int) -> void:
	App.snapshot("Fill steps")
	_clear_steps(index)
	var steps := int(round(float(App.project.patterns[App.current_pattern].length) / Cd.STEP))
	var root := int(App.project.channels[index].get("root", 60))
	for s in range(0, steps, every):
		App.add_note(App.current_pattern, index, float(s) * Cd.STEP, Cd.STEP, root,
				float(Settings.get_value("velocity", 0.78)))


func _route_menu(index: int) -> void:
	var pm := PopupMenu.new()
	add_child(pm)
	for t in App.project.mixer.size():
		pm.add_item("%02d  %s" % [t, String(App.project.mixer[t].name)], t)
	pm.id_pressed.connect(func(id):
		App.set_channel_prop(index, "mixer", id, "Route channel")
		pm.queue_free())
	pm.popup(Rect2i(DisplayServer.mouse_get_position(), Vector2i(220, 400)))


func open_layers(index: int) -> void:
	# Nothing to layer onto yet: say so rather than opening an empty window.
	if index < 0 or index >= App.project.channels.size():
		App.status.emit("Add a channel before layering one onto another")
		return
	var dlg = preload("res://ui/dialogs/layers_dialog.tscn").instantiate()
	dlg.channel = index
	get_tree().root.add_child(dlg)


func _replace_instrument(index: int) -> void:
	CdPluginMenu.open(self, false, func(plug: Dictionary): App.replace_channel_plugin(index, plug))


func _popup_add_menu() -> void:
	CdPluginMenu.open(self, false, func(plug: Dictionary): App.add_channel(plug, String(plug.get("name", "Channel"))))
