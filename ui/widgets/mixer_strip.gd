extends PanelContainer
## One mixer channel: name, pan, inserts summary, fader, meter, mute and solo.

signal selected_changed(track: int)

var track := 0

var _selected := false


@onready var _name: Button = $Col/Name
@onready var _pan: CdKnob = $Col/Pan
@onready var _fader: CdFader = $Col/Mid/Fader
@onready var _meter: CdMeter = $Col/Mid/Meter
@onready var _mute: CdLed = $Col/Leds/Mute
@onready var _solo: CdLed = $Col/Leds/Solo
@onready var _fx: Label = $Col/Fx


func _ready() -> void:
	# The strip is mixer_strip.tscn; which track it belongs to is set on it
	# before it goes into the tree, so the wiring can use it here.
	_meter.track = track
	_mute.on_color = CdPalette.BAD
	_solo.on_color = CdPalette.WARN

	_name.pressed.connect(func():
		selected_changed.emit(track)
		_flag())
	_name.gui_input.connect(func(e):
		if e is InputEventMouseButton and e.double_click:
			_rename()
		elif e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_RIGHT:
			_strip_menu())
	_pan.value_changed.connect(func(v): App.set_mixer_prop(track, "pan", v))
	_fader.value_changed.connect(func(v): App.set_mixer_prop(track, "vol", v))
	_pan.auto_ref = {"target": Cd.AutoTarget.MIXER_PAN, "ref": {}, "a": track, "b": 0}
	_fader.auto_ref = {"target": Cd.AutoTarget.MIXER_VOL, "ref": {}, "a": track, "b": 0}
	_pan.menu_requested.connect(func(_at): _control_menu(false))
	_fader.menu_requested.connect(func(_at): _control_menu(true))
	_mute.toggled_state.connect(func(on): App.set_mixer_prop(track, "mute", on, "Mute"))
	_solo.toggled_state.connect(func(on): App.set_mixer_prop(track, "solo", on, "Solo"))
	refresh()


func _flag() -> void:
	mark_selected(App.current_mixer == track)


## Told from the outside when the selection moves, so the strip that has just
## lost it repaints as well as the one that has just taken it. Without that the
## old outline stayed until something else happened to redraw the strip.
func mark_selected(on: bool) -> void:
	if _selected == on:
		return
	_selected = on
	queue_redraw()


func _rename() -> void:
	var dlg := AcceptDialog.new()
	dlg.title = "Rename Mixer Track"
	var field := LineEdit.new()
	field.text = String(App.project.mixer[track].name)
	field.custom_minimum_size.x = 220
	dlg.add_child(field)
	dlg.register_text_enter(field)
	add_child(dlg)
	dlg.confirmed.connect(func():
		App.set_mixer_prop(track, "name", field.text, "Rename track")
		dlg.queue_free())
	dlg.popup_centered()
	field.grab_focus()
	field.select_all()


## Everything you would otherwise go hunting for: renaming, the effect picker,
## emptying the chain, and resetting the fader.
func _strip_menu() -> void:
	selected_changed.emit(track)
	var pm := PopupMenu.new()
	add_child(pm)
	pm.add_item("Rename...", 0)
	pm.add_item("Add Effect...", 1)
	pm.add_separator()
	var sub := _automation_menu(pm)
	pm.add_child(sub)
	pm.add_submenu_item("Automate", sub.name)
	pm.add_separator()
	pm.add_item("Clear Effects", 2)
	pm.add_item("Reset Volume", 3)
	pm.add_item("Reset Pan", 4)
	pm.add_separator()
	pm.add_item("Unmute Everything", 5)
	pm.id_pressed.connect(func(id):
		match id:
			0: _rename()
			1: App.status.emit("Pick an effect for %s" % String(App.project.mixer[track].name))
			2: App.clear_inserts(track)
			3: App.set_mixer_prop(track, "vol", 1.0 if track > 0 else 0.85, "Reset volume")
			4: App.set_mixer_prop(track, "pan", 0.0, "Reset pan")
			5: App.clear_mutes()
		if id == 1:
			Shortcuts.command.emit("add_effect")
		pm.queue_free())
	pm.popup(Rect2i(DisplayServer.mouse_get_position(), Vector2i(1, 1)))


## Right-clicking the fader or the pan knob. Reset is what was there before;
## automation is what FL puts on the same menu, and it is the reason anyone
## right-clicks a fader in the first place.
func _control_menu(is_vol: bool) -> void:
	selected_changed.emit(track)
	var pm := PopupMenu.new()
	add_child(pm)
	pm.add_item("Create automation clip", 0)
	pm.add_separator()
	if is_vol:
		pm.add_item("Reset to 0 dB", 1)
		pm.add_item("Silence", 2)
	else:
		pm.add_item("Centre", 1)
	pm.id_pressed.connect(func(id):
		match id:
			0: App.automate(Cd.AutoTarget.MIXER_VOL if is_vol else Cd.AutoTarget.MIXER_PAN, {}, track)
			1: App.set_mixer_prop(track, "vol" if is_vol else "pan",
					1.0 if is_vol else 0.0, "Reset")
			2: App.set_mixer_prop(track, "vol", 0.0, "Silence")
		refresh()
		pm.queue_free())
	pm.popup_hide.connect(func(): pm.queue_free(), CONNECT_DEFERRED)
	pm.popup(Rect2i(DisplayServer.mouse_get_position(), Vector2i(1, 1)))


## Everything on this strip that can be automated: its own volume and pan, the
## sends that go anywhere, and every parameter of every effect on it.
func _automation_menu(parent: PopupMenu) -> PopupMenu:
	var sub := PopupMenu.new()
	sub.name = "automate%d" % track
	var entries := []
	var m: Dictionary = App.project.mixer[track]
	entries.append({"target": Cd.AutoTarget.MIXER_VOL, "a": track, "b": 0, "ref": {}})
	sub.add_item("Volume", 0)
	entries.append({"target": Cd.AutoTarget.MIXER_PAN, "a": track, "b": 0, "ref": {}})
	sub.add_item("Pan", 1)
	for i in m.sends.size():
		var snd: Dictionary = m.sends[i]
		if int(snd.dest) < 0:
			continue
		var dest := String(App.project.mixer[int(snd.dest)].name) \
				if int(snd.dest) < App.project.mixer.size() else "?"
		entries.append({"target": Cd.AutoTarget.SEND, "a": track, "b": i, "ref": {}})
		sub.add_item("Send to %s" % dest, entries.size() - 1)
	for slot in m.inserts.size():
		if m.inserts[slot] == null:
			continue
		var ref := {"kind": "insert", "track": track, "slot": slot}
		var params: Array = App.plugin_params(ref)
		if params.is_empty():
			continue
		var fx := PopupMenu.new()
		fx.name = "fx%d_%d" % [track, slot]
		for prm in params:
			entries.append({"target": Cd.AutoTarget.PLUGIN, "a": 0, "b": int(prm.index), "ref": ref})
			fx.add_item(String(prm.name), entries.size() - 1)
		fx.id_pressed.connect(func(id): _run_automation(entries[id], parent))
		sub.add_child(fx)
		sub.add_submenu_item(String(m.inserts[slot].get("name", "Effect %d" % (slot + 1))), fx.name)
	sub.id_pressed.connect(func(id): _run_automation(entries[id], parent))
	return sub


func _run_automation(entry: Dictionary, pm: PopupMenu) -> void:
	App.automate(int(entry.target), entry.ref, int(entry.a), int(entry.b))
	pm.queue_free()


func refresh() -> void:
	if track >= App.project.mixer.size():
		return
	var m: Dictionary = App.project.mixer[track]
	# A 66 px strip cannot hold "Insert 12"; the number is the part that
	# identifies it, so an unrenamed track shows just that.
	var label := String(m.name)
	if label == "Insert %d" % track:
		label = str(track)
	_name.text = label
	_name.tooltip_text = "%s\nClick to select, double-click to rename" % String(m.name)
	_fader.gain = float(m.vol)
	_pan.value = float(m.pan)
	_mute.on = bool(m.mute)
	_solo.on = bool(m.solo)
	var used := 0
	for p in m.inserts:
		if p != null:
			used += 1
	var feeds := 0
	for c in App.project.channels:
		if int(c.mixer) == track:
			feeds += 1
	_fx.text = "%d fx" % used if feeds == 0 else "%d fx  %dch" % [used, feeds]
	_flag()


func _draw() -> void:
	if _selected:
		draw_rect(Rect2(Vector2.ZERO, size), CdPalette.ACCENT, false, 2.0)
