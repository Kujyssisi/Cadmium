class_name CdPickerPanel
extends PanelContainer
## Everything the song is made of, down the left of the arrangement: the
## patterns, the audio files it uses, and the automation clips. Click one to
## make it the one you are editing, drag it onto the arrangement to place it.
##
## It exists because the alternative was a drop-down at the top of the window:
## you cannot see what a song contains through a drop-down, and putting a
## pattern down meant selecting it there first and then drawing it here.
##
## The frame is picker_panel.tscn; the rows are per item and come from
## picker_row.tscn.

const SECTIONS := ["pattern", "sample", "automation"]

var section := "pattern"
var _rows: Array = []
var _filter := ""

@onready var _tabs: Array = [$Col/Tabs/Patterns, $Col/Tabs/Samples, $Col/Tabs/Automation]
@onready var _filter_field: LineEdit = $Col/Filter
@onready var _list: VBoxContainer = $Col/Scroll/List
@onready var _add: Button = $Col/Foot/Add
@onready var _count: Label = $Col/Foot/Count


func _ready() -> void:
	for i in _tabs.size():
		var b: Button = _tabs[i]
		b.text = ["Patterns", "Audio", "Auto"][i]
		Cd.compact(b, "Button", 4.0)
		b.pressed.connect(func(): _select_section(SECTIONS[i]))
	_filter_field.right_icon = Icons.get_icon("search", 12)
	_filter_field.text_changed.connect(func(t):
		_filter = String(t).to_lower()
		rebuild())
	_add.pressed.connect(_on_add)
	App.patterns_changed.connect(rebuild)
	App.pattern_selected.connect(func(_i): _mark())
	App.paint_item_changed.connect(func(_k, _i): _mark())
	# A changed sample is a changed picture, and the rows draw their own.
	App.sample_changed.connect(func(_i): rebuild())
	App.playlist_changed.connect(rebuild)
	App.automation_changed.connect(rebuild)
	App.project_loaded.connect(rebuild)
	_select_section("pattern")


func _select_section(which: String) -> void:
	section = which
	for i in _tabs.size():
		(_tabs[i] as Button).button_pressed = SECTIONS[i] == which
	_add.text = {"pattern": "Add pattern", "sample": "Add audio...",
			"automation": "Add automation..."}[which]
	rebuild()


func rebuild() -> void:
	if _list == null:
		return
	for c in _list.get_children():
		c.queue_free()
	_rows.clear()
	match section:
		"pattern":
			for i in App.project.patterns.size():
				var p: Dictionary = App.project.patterns[i]
				_add_row("pattern", i, String(p.name), _pattern_detail(p),
						CdPalette.track_color(int(p.get("color", i))))
		"sample":
			for i in App.project.assets.size():
				var a: Dictionary = App.project.assets[i]
				_add_row("sample", i, String(a.get("name", "audio")),
						_uses("sample", i), CdPalette.track_color(i + 3))
		"automation":
			for i in App.project.automations.size():
				var a: Dictionary = App.project.automations[i]
				_add_row("automation", i, String(a.get("name", "automation")),
						_uses("automation", i), CdPalette.track_color(i + 7))
	_count.text = "%d" % _rows.size()
	_mark()


## How many notes a pattern holds, which is the one thing worth knowing about
## it from a list.
func _pattern_detail(p: Dictionary) -> String:
	var n: int = (p.get("notes", []) as Array).size()
	return "" if n == 0 else str(n)


## How many times this is already on the timeline.
func _uses(kind: String, index: int) -> String:
	var type := Cd.ClipType.AUDIO if kind == "sample" else Cd.ClipType.AUTOMATION
	var n := 0
	for c in App.project.clips:
		if int(c.type) == type and int(c.index) == index:
			n += 1
	return "" if n == 0 else "x%d" % n


func _add_row(kind: String, index: int, label: String, detail: String, tint: Color) -> void:
	if not _filter.is_empty() and not label.to_lower().contains(_filter):
		return
	var row = preload("res://ui/panels/picker_row.tscn").instantiate()
	row.kind = kind
	row.index = index
	row.label = label
	row.detail = detail
	row.tint = tint
	row.picked.connect(func(): _on_picked(kind, index))
	row.menu_requested.connect(func(at): _menu(kind, index, at))
	_list.add_child(row)
	_rows.append(row)


## Which row is the one being edited: the current pattern, or nothing in the
## other two sections.
func _mark() -> void:
	var item := App.current_paint_item()
	for row in _rows:
		if is_instance_valid(row):
			row.refresh(String(row.kind) == String(item.kind) and int(row.index) == int(item.index))


func _on_picked(kind: String, index: int) -> void:
	# Clicking it makes it the thing the timeline draws, the way FL does.
	App.set_paint_item(kind, index)
	_mark()
	match kind:
		"pattern":
			App.select_pattern(index)
		"sample":
			# The same gesture as a plugin in the rack: click it and its
			# sampler opens.
			CdSampleWindow.open(self, index)
		"automation":
			# The same gesture as a sample: click it and its editor opens.
			CdAutomationWindow.open(self, index)


func _menu(kind: String, index: int, _at: Vector2) -> void:
	var pm := PopupMenu.new()
	add_child(pm)
	match kind:
		"pattern":
			pm.add_item("Rename...", 0)
			pm.add_item("Duplicate", 1)
			pm.add_item("Transpose...", 6)
			pm.add_item("Place at the start", 2)
			pm.add_separator()
			pm.add_item("Delete", 3)
		"sample":
			pm.add_item("Sampler...", 4)
			pm.add_item("Place at the start", 2)
			pm.add_separator()
			pm.add_item("Remove from the song", 3)
		"automation":
			pm.add_item("Edit...", 5)
			pm.add_item("Rename...", 0)
			pm.add_item("Place at the start", 2)
			pm.add_separator()
			pm.add_item("Delete", 3)
	pm.id_pressed.connect(func(id): _command(kind, index, int(id)))
	pm.popup_hide.connect(func(): pm.queue_free(), CONNECT_DEFERRED)
	# The pointer as the desktop knows it, not as the viewport does: a popup is
	# placed in screen coordinates, and handing it a position from inside a
	# scaled window put the menu somewhere near the pointer rather than on it.
	pm.popup(Rect2i(DisplayServer.mouse_get_position(), Vector2i(1, 1)))


func _command(kind: String, index: int, id: int) -> void:
	if id == 4:
		CdSampleWindow.open(self, index)
		return
	if id == 5:
		CdAutomationWindow.open(self, index)
		return
	if id == 6:
		# Everything picked in the arrangement, when this row is one of them;
		# otherwise just this one.
		var picked: Array = App.selected_pattern_indices()
		if not picked.has(index):
			picked = [index]
		# Whoever above this knows how to ask: the panel is a long way down
		# from the window that owns the dialog.
		var host: Node = self
		while host != null and not host.has_method("transpose_prompt"):
			host = host.get_parent()
		if host != null:
			host.transpose_prompt(picked)
		return
	match id:
		0:
			_rename(kind, index)
		1:
			if kind == "pattern":
				App.select_pattern(App.clone_pattern(index))
		2:
			place(kind, index, 0, 0.0)
		3:
			match kind:
				"pattern":
					App.remove_pattern(index)
				"sample":
					_remove_asset(index)
				"automation":
					_remove_automation(index)
			rebuild()


## Puts one of these on the timeline, which is what dragging it does and what
## the menu offers for people who would rather not drag.
func place(kind: String, index: int, track: int, beat: float) -> int:
	return App.place_item(kind, index, track, beat)


func _rename(kind: String, index: int) -> void:
	var dlg := AcceptDialog.new()
	dlg.title = "Rename"
	var field := LineEdit.new()
	field.custom_minimum_size.x = 220
	field.text = String(App.project.patterns[index].name) if kind == "pattern" \
			else String(App.project.automations[index].name)
	dlg.add_child(field)
	dlg.register_text_enter(field)
	add_child(dlg)
	dlg.confirmed.connect(func():
		var name := field.text.strip_edges()
		if not name.is_empty():
			if kind == "pattern":
				App.set_pattern_prop(index, "name", name, "Rename pattern")
			else:
				App.project.automations[index]["name"] = name
				App.project.dirty = true
				App.automation_changed.emit()
		rebuild()
		dlg.queue_free())
	dlg.canceled.connect(func(): dlg.queue_free())
	dlg.popup_centered()
	field.grab_focus()
	field.select_all()


## An audio file the song no longer uses. Clips that point at it go with it,
## and everything after it in the list shifts down.
func _remove_asset(index: int) -> void:
	App.snapshot("Remove audio")
	var doomed := []
	for i in App.project.clips.size():
		var c: Dictionary = App.project.clips[i]
		if int(c.type) == Cd.ClipType.AUDIO and int(c.index) == index:
			doomed.append(i)
	App.remove_clips(doomed)
	App.project.assets.remove_at(index)
	for c in App.project.clips:
		if int(c.type) == Cd.ClipType.AUDIO and int(c.index) > index:
			c["index"] = int(c.index) - 1
	App.project.dirty = true
	App.push_playlist()
	App.playlist_changed.emit()


func _remove_automation(index: int) -> void:
	App.remove_automation(index)


func _on_add() -> void:
	match section:
		"pattern":
			App.select_pattern(App.add_pattern())
		"sample":
			var fd := FileDialog.new()
			fd.file_mode = FileDialog.FILE_MODE_OPEN_FILES
			fd.access = FileDialog.ACCESS_FILESYSTEM
			fd.use_native_dialog = DisplayServer.has_feature(DisplayServer.FEATURE_NATIVE_DIALOG_FILE)
			var filters := PackedStringArray()
			for ext in Cd.AUDIO_EXTS:
				filters.append("*.%s" % ext)
			fd.filters = PackedStringArray(["%s ; Audio" % " , ".join(filters)])
			add_child(fd)
			fd.files_selected.connect(func(paths):
				for p in paths:
					App.add_audio_asset(String(p))
				rebuild()
				fd.queue_free())
			fd.canceled.connect(func(): fd.queue_free())
			fd.popup_centered(Vector2i(880, 600))
		"automation":
			# The arrangement already knows how to offer every automatable
			# thing in the project; this is the same list.
			var pl = get_parent().get_node_or_null("Arrangement")
			if pl != null and pl.has_method("automation_menu"):
				pl.automation_menu(0)
