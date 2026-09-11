extends Control
## Mixer: the strips on the right, the selected strip's effect rack and sends on
## the left. Master is always the first strip.

const STRIP_W := 66.0

var _strip_nodes := {}
## What the rack was last built for. Rebuilding it is not cheap -- every row is
## a scene, and every open row asks its plugin for parameters -- and it used to
## happen on every mixer change, which includes every frame of a wet knob being
## dragged. Nothing but a different set of plugins needs a new set of rows.
var _rack_sig := ""
## Which strip is wearing the selection outline, so the one losing it can be
## told to take it off.
var _selected_strip := -1


@onready var _rack_title: Label = $Row/Rack/Col/Caption/Title
@onready var _rack_box: VBoxContainer = $Row/Rack/Col/Scroll/Pad/Inner/Effects
@onready var _sends_box: VBoxContainer = $Row/Rack/Col/Scroll/Pad/Inner/Sends
@onready var _strips: HBoxContainer = $Row/StripScroll/Col/Strips
@onready var _routing: Control = $Row/StripScroll/Col/Routing


## The band under the strips, the way FL draws it: a socket under every strip,
## and a line from the selected strip along the band and up into each strip its
## audio reaches. Clicking a socket routes into that strip, clicking it again
## stops.
const SOCKET_W := 13.0
const SOCKET_H := 9.0


func _ready() -> void:
	# The frame is mixer.tscn; the strips and rack rows are per track and are
	# made here from their own scenes.
	App.mixer_changed.connect(_refresh)
	App.project_loaded.connect(rebuild)
	App.selection_changed.connect(_refresh_rack)
	App.channels_changed.connect(_refresh)
	_routing.draw.connect(_draw_routing)
	_routing.gui_input.connect(_routing_input)
	App.selection_changed.connect(_flag_selection)
	App.mixer_changed.connect(func(): _routing.queue_redraw())
	rebuild()


func rebuild() -> void:
	for c in _strips.get_children():
		c.queue_free()
	_strip_nodes.clear()
	_rack_sig = ""
	_selected_strip = -1
	for t in App.project.mixer.size():
		var strip := _make_strip(t)
		_strips.add_child(strip)
		_strip_nodes[t] = strip
	# The end of the row: one more track, or one fewer.
	var tail = preload("res://ui/widgets/strip_add.tscn").instantiate()
	_strips.add_child(tail)
	(tail.get_node("Add") as Button).pressed.connect(func():
		var i := App.add_mixer_track()
		App.select_mixer(i)
		App.status.emit("Added %s" % String(App.project.mixer[i].name)))
	(tail.get_node("Remove") as Button).pressed.connect(func():
		if App.remove_mixer_track():
			App.status.emit("Removed the last mixer track"))
	_flag_selection()
	_refresh_rack()


## Only the two strips that changed, so moving the selection across a hundred
## of them costs two redraws rather than a hundred.
func _flag_selection() -> void:
	var sel := App.current_mixer
	for t in [_selected_strip, sel]:
		if _strip_nodes.has(t) and is_instance_valid(_strip_nodes[t]):
			_strip_nodes[t].mark_selected(t == sel)
	_selected_strip = sel
	_routing.queue_redraw()


func _refresh() -> void:
	# A track added or taken away is a strip that has to appear or go: the row
	# is built per track, and refreshing the ones already there says nothing
	# about the one that is not.
	if _strip_nodes.size() != App.project.mixer.size():
		_resize_row()
	for t in _strip_nodes.keys():
		var s = _strip_nodes[t]
		if is_instance_valid(s):
			s.refresh()
	_refresh_rack()


## Brings the row of strips in line with the number of tracks, without building
## the ones that were already there again: with a hundred tracks in a song,
## adding one should cost one strip rather than a hundred.
func _resize_row() -> void:
	var want := App.project.mixer.size()
	for t in range(want, _strip_nodes.size() + want):
		if not _strip_nodes.has(t):
			break
		var gone = _strip_nodes[t]
		_strip_nodes.erase(t)
		if is_instance_valid(gone):
			gone.queue_free()
	for t in want:
		if _strip_nodes.has(t) and is_instance_valid(_strip_nodes[t]):
			continue
		var strip := _make_strip(t)
		_strips.add_child(strip)
		# Before the +/- at the end of the row, which is always last.
		_strips.move_child(strip, t)
		_strip_nodes[t] = strip
	_selected_strip = -1
	_flag_selection()
	_routing.queue_redraw()


## Where the socket under one strip sits, in the routing band's own space.
## Taken from the strips themselves so the master's wider strip lines up too.
func _socket_rect(track: int) -> Rect2:
	if not _strip_nodes.has(track) or not is_instance_valid(_strip_nodes[track]):
		return Rect2()
	var strip: Control = _strip_nodes[track]
	var mid: float = strip.position.x + strip.size.x * 0.5
	return Rect2(mid - SOCKET_W * 0.5, _routing.size.y - SOCKET_H - 4.0, SOCKET_W, SOCKET_H)


func _draw_routing() -> void:
	var n := App.project.mixer.size()
	if n == 0:
		return
	var sel: int = clampi(App.current_mixer, 0, n - 1)
	var dests: Array = App.routes_of(sel)
	var band_y: float = 10.0
	# Every strip gets a socket, so it is clear where audio can be sent.
	for t in n:
		var r := _socket_rect(t)
		if r.size.x <= 0.0:
			continue
		var lit: bool = dests.has(t)
		var col: Color = CdPalette.ACCENT if lit else CdPalette.BEVEL_LO
		_routing.draw_rect(r, CdPalette.WELL)
		_routing.draw_rect(r.grow(-1.5), col if lit else CdPalette.PANEL)
		_routing.draw_rect(r, CdPalette.BEVEL_LO, false, 1.0)
	# And the lines out of the selected strip into the ones it feeds.
	var from := _socket_rect(sel)
	if from.size.x <= 0.0:
		return
	var fx: float = from.get_center().x
	_routing.draw_line(Vector2(fx, 0.0), Vector2(fx, band_y), CdPalette.ACCENT, 2.0)
	for d in dests:
		var to := _socket_rect(int(d))
		if to.size.x <= 0.0:
			continue
		var tx: float = to.get_center().x
		_routing.draw_line(Vector2(fx, band_y), Vector2(tx, band_y), CdPalette.ACCENT, 2.0)
		_routing.draw_line(Vector2(tx, band_y), Vector2(tx, to.position.y), CdPalette.ACCENT, 2.0)
		# An arrowhead into the socket, so which way the audio goes is not a
		# thing you have to work out.
		var tip := Vector2(tx, to.position.y)
		_routing.draw_colored_polygon(PackedVector2Array([
				tip, tip + Vector2(-4.0, -5.0), tip + Vector2(4.0, -5.0)]), CdPalette.ACCENT)


func _routing_input(event: InputEvent) -> void:
	if not (event is InputEventMouseButton) or not event.pressed:
		return
	var mb := event as InputEventMouseButton
	if mb.button_index != MOUSE_BUTTON_LEFT:
		return
	var sel := App.current_mixer
	for t in App.project.mixer.size():
		var r := _socket_rect(t)
		if r.size.x <= 0.0 or not r.grow(3.0).has_point(mb.position):
			continue
		if t == sel:
			App.status.emit("A strip cannot route into itself")
			return
		if sel <= 0:
			App.status.emit("The master goes to the speakers; it has nowhere else to go")
			return
		var on: bool = not App.routes_of(sel).has(t)
		App.set_route(sel, t, on)
		App.status.emit("%s %s %s" % [String(App.project.mixer[sel].name),
				"now feeds" if on else "no longer feeds", String(App.project.mixer[t].name)])
		_routing.queue_redraw()
		return


func _make_strip(track: int) -> Control:
	var strip = preload("res://ui/widgets/mixer_strip.tscn").instantiate()
	strip.track = track
	strip.size_flags_vertical = Control.SIZE_EXPAND_FILL
	strip.custom_minimum_size = Vector2(STRIP_W if track > 0 else STRIP_W + 8.0, 0)
	strip.selected_changed.connect(func(t): App.select_mixer(t))
	return strip


# ---------------------------------------------------------------------------
## Identifies the rack's shape: which strip, which plugins in which slots, and
## the strip names the two drop-downs list. Anything else that changes -- a
## bypass lamp, a send amount, a fader -- is a value the existing rows can be
## given without being built again.
func _rack_signature(t: int) -> String:
	var m: Dictionary = App.project.mixer[t]
	var parts := PackedStringArray([str(t)])
	for p in m.inserts:
		parts.append("-" if p == null else "%s:%s" % [p.get("kind", ""), p.get("id", "")])
	# Where the strip's audio goes is part of the shape: the output chooser and
	# the send rows are built from it, and it can be changed from the routing
	# band underneath rather than from here.
	parts.append(str(int(m.route)))
	parts.append(str((m.sends as Array).size()))
	for snd in m.sends:
		parts.append(str(int(snd.dest)))
	for d in App.project.mixer:
		parts.append(String(d.name))
	return "|".join(parts)


func _refresh_rack() -> void:
	var t := App.current_mixer
	if t >= App.project.mixer.size():
		return
	var m: Dictionary = App.project.mixer[t]
	_rack_title.text = String(m.name).to_upper()
	var sig := _rack_signature(t)
	if sig == _rack_sig and _rack_box.get_child_count() > 0:
		for c in _rack_box.get_children() + _sends_box.get_children():
			if c.has_method("refresh"):
				c.refresh()
		return
	_rack_sig = sig
	for c in _rack_box.get_children():
		c.queue_free()
	var inserts: Array = m.inserts
	var filled := 0
	for slot in inserts.size():
		if inserts[slot] == null:
			continue
		_rack_box.add_child(_make_slot(t, slot, inserts[slot]))
		filled += 1
	# One "add" row rather than seven empty ones: the chain reads as a stack of
	# what is actually in it.
	var free := -1
	for i in inserts.size():
		if inserts[i] == null:
			free = i
			break
	if free >= 0:
		_rack_box.add_child(_make_add_row(t, free))
	for c in _sends_box.get_children():
		c.queue_free()
	# Four rows at least, and one more for every extra send the routing band
	# has added beyond them.
	for i in maxi(4, (m.sends as Array).size()):
		while i >= (m.sends as Array).size():
			(m.sends as Array).append({"dest": -1, "amount": 0.0, "pre": false, "sidechain": false})
		_sends_box.add_child(_make_send(t, i, m.sends[i]))
	# Where this strip's audio goes next.
	var out_cap := Label.new()
	out_cap.theme_type_variation = "SectionLabel"
	out_cap.text = "OUTPUT"
	_sends_box.add_child(out_cap)
	var route := HBoxContainer.new()
	route.custom_minimum_size.y = 22
	var btn := OptionButton.new()
	btn.focus_mode = Control.FOCUS_NONE
	btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	btn.add_item("(none)")
	btn.set_item_metadata(0, -1)
	for d in App.project.mixer.size():
		if d == t:
			continue
		btn.add_item(String(App.project.mixer[d].name))
		btn.set_item_metadata(btn.item_count - 1, d)
	for i in btn.item_count:
		if int(btn.get_item_metadata(i)) == int(m.route):
			btn.select(i)
	btn.item_selected.connect(func(i): App.set_mixer_prop(t, "route", int(btn.get_item_metadata(i)), "Route"))
	btn.disabled = t == 0
	btn.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	Cd.compact(btn, "OptionButton", 4.0)
	btn.clip_text = true
	route.add_child(btn)
	_sends_box.add_child(route)

	# The strip's own level, so the rack reads as part of the same channel.
	var level := CdMeter.new()
	level.track = t
	level.horizontal = true
	level.custom_minimum_size = Vector2(0, 14)
	_sends_box.add_child(level)


## Ctrl+F from anywhere: opens the picker on the selected strip's next slot.
func add_effect_here() -> void:
	var t := App.current_mixer
	if t < 0 or t >= App.project.mixer.size():
		return
	var inserts: Array = App.project.mixer[t].inserts
	for i in inserts.size():
		if inserts[i] == null:
			_effect_menu(t, i)
			return
	App.status.emit("%s has no free effect slot" % String(App.project.mixer[t].name))


func _make_slot(track: int, slot: int, plug) -> Control:
	var row = preload("res://ui/widgets/fx_slot.tscn").instantiate()
	row.track = track
	row.slot = slot
	row.plug = plug
	row.menu_requested.connect(func(s): _slot_menu(track, s))
	return row


## The end of the chain: one button that adds the next effect, and a drop target
## so an effect dragged past the last slot lands there.
func _make_add_row(track: int, slot: int) -> Control:
	var row := _DropRow.new()
	row.track = track
	row.slot = slot
	row.custom_minimum_size.y = 21
	var btn := Button.new()
	btn.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	btn.text = "  + add effect"
	btn.theme_type_variation = "Flat"
	btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
	btn.focus_mode = Control.FOCUS_NONE
	btn.tooltip_text = "Add an effect to the end of this chain"
	btn.pressed.connect(func(): _effect_menu(track, slot))
	row.add_child(btn)
	return row


## Drop target for the "add" row: dragging an effect onto it sends it to the end
## of the chain.
class _DropRow extends Control:
	var track := 0
	var slot := 0

	func _can_drop_data(_pos: Vector2, data: Variant) -> bool:
		return data is Dictionary and data.get("cd_fx", false) and int(data.get("track", -1)) == track

	func _drop_data(_pos: Vector2, data: Variant) -> void:
		App.move_insert(track, int(data.slot), maxi(0, slot - 1))


func _make_send(track: int, index: int, _send: Dictionary) -> Control:
	var row = preload("res://ui/panels/send_row.tscn").instantiate()
	row.track = track
	row.index = index
	return row


## A drop-down at the pointer rather than a window in the middle of the screen:
## putting an effect on a slot is a one-click decision and should cost one.
func _effect_menu(track: int, slot: int) -> void:
	CdPluginMenu.open(self, true, func(plug: Dictionary): App.set_insert(track, slot, plug))


func _slot_menu(track: int, slot: int) -> void:
	var pm := PopupMenu.new()
	add_child(pm)
	pm.add_item("Open", 0)
	pm.add_item("Replace...", 1)
	pm.add_item("Remove", 2)
	pm.add_separator()
	pm.add_item("Move Up", 3)
	pm.add_item("Move Down", 4)
	pm.add_separator()
	pm.add_item("Copy to...", 5)
	var params: Array = App.plugin_params({"kind": "insert", "track": track, "slot": slot})
	if not params.is_empty():
		var auto := PopupMenu.new()
		auto.name = "auto%d_%d" % [track, slot]
		for i in params.size():
			auto.add_item(String(params[i].name), i)
		auto.id_pressed.connect(func(id):
			App.automate(Cd.AutoTarget.PLUGIN, {"kind": "insert", "track": track, "slot": slot},
					0, int(params[id].index))
			pm.queue_free())
		pm.add_child(auto)
		pm.add_submenu_item("Automate", auto.name)
	pm.id_pressed.connect(func(id):
		match id:
			0: App.request_plugin_window({"kind": "insert", "track": track, "slot": slot})
			1: _effect_menu(track, slot)
			2: App.remove_insert(track, slot)
			3: App.move_insert(track, slot, maxi(0, slot - 1))
			4: App.move_insert(track, slot, mini(7, slot + 1))
			5: _copy_menu(track, slot)
		pm.queue_free())
	pm.popup(Rect2i(DisplayServer.mouse_get_position(), Vector2i(1, 1)))


## Sends a copy of this effect, settings and all, to another strip.
func _copy_menu(track: int, slot: int) -> void:
	var pm := PopupMenu.new()
	add_child(pm)
	for d in App.project.mixer.size():
		if d == track:
			continue
		pm.add_item(String(App.project.mixer[d].name), d)
	pm.id_pressed.connect(func(dest):
		App.copy_insert(track, slot, int(dest))
		pm.queue_free())
	pm.popup(Rect2i(DisplayServer.mouse_get_position(), Vector2i(1, 1)))
