class_name CdDeclaredView
extends VBoxContainer
## A panel built from the description a plugin publishes about itself.
##
## Cadmium asks the plugin for a layout -- pages, sections, and which parameter
## belongs to which control -- and builds it out of Cadmium's own widgets. The
## plugin gets an interface in the program's visual language without shipping a
## pixel of it, and Cadmium gets there without knowing anything about the
## plugin in particular: everything here reads the layout, never a name.
##
## Nothing in the description can do more than arrange controls the host
## already has. A layout naming a parameter that does not exist is skipped, and
## a row type this version does not know is skipped, so an older Cadmium opens
## a newer plugin with less of its panel rather than none of it.

signal param_changed()

var ref := {}
var params: Array = []

## How often the controls are read back. Automation, a preset loaded from the
## plugin's own browser and the plugin moving its own values all show up here;
## every frame would be 358 round trips through the audio lock.
const POLL_HZ := 12.0
const KNOB_W := 78.0

var _layout := {}
var _by_id := {}            ## parameter id -> its descriptor
var _bound := {}            ## parameter index -> the control showing it
var _tabs: TabContainer
var _poll := 0.0
var _presets: Array = []
var _preset_list: ItemList
var _preset_search: LineEdit
var _preset_facets := {}    ## facet name -> OptionButton
var _preset_title: Label
var _macro_labels: Array = []
var _macro_knobs: Array = []
var _pictures: Array = []   ## the drawn widgets, redrawn on the poll


func _ready() -> void:
	add_theme_constant_override("separation", 4)
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for p in params:
		_by_id[String(p.id)] = p
	var text := _get_string("ui")
	var parsed = JSON.parse_string(text) if not text.is_empty() else null
	if typeof(parsed) != TYPE_DICTIONARY or not parsed.has("pages"):
		# No usable description: say so rather than showing an empty panel,
		# because the alternative is a plugin that looks broken.
		var l := Label.new()
		l.text = "This plugin did not describe a panel."
		l.theme_type_variation = "MuteLabel"
		add_child(l)
		return
	_layout = parsed
	_build()
	set_process(true)


func _build() -> void:
	_header()
	_tabs = TabContainer.new()
	_tabs.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_tabs.custom_minimum_size.y = float(_layout.get("min_height", 420)) * 0.8
	add_child(_tabs)
	for page in _layout.get("pages", []):
		var scroll := ScrollContainer.new()
		scroll.name = String(page.get("name", "Page"))
		scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
		var col := VBoxContainer.new()
		col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		col.add_theme_constant_override("separation", 4)
		scroll.add_child(col)
		_tabs.add_child(scroll)
		for row in page.get("rows", []):
			var c := _row(row)
			if c != null:
				col.add_child(c)


## The plugin's name and the patch it is on, above the tabs.
func _header() -> void:
	var bar := PanelContainer.new()
	bar.theme_type_variation = "Card"
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	bar.add_child(row)
	var title := Label.new()
	title.text = String(_layout.get("title", "Plugin"))
	title.theme_type_variation = "SectionLabel"
	row.add_child(title)
	var sub := Label.new()
	sub.text = String(_layout.get("subtitle", ""))
	sub.theme_type_variation = "MuteLabel"
	row.add_child(sub)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(spacer)
	_preset_title = Label.new()
	_preset_title.theme_type_variation = "MuteLabel"
	row.add_child(_preset_title)
	add_child(bar)
	_refresh_meta()


func _row(row: Dictionary) -> Control:
	match String(row.get("type", "")):
		"knobs": return _knob_section(row)
		"macros": return _macro_section(row)
		"browser": return _browser(row)
		"scope": return _scope(row)
		"wave": return _picture(WaveStrip.new(), row)
		"filter_curve": return _picture(FilterCurve.new(), row)
		"adsr": return _envelope(row)
		"lfo": return _lfo(row)
		"matrix": return _matrix(row)
		"steps": return _steps(row)
		_: return null


# ---------------------------------------------------------------------------
# Sections of controls
# ---------------------------------------------------------------------------
func _card(title: String, enable_id: String = "") -> Array:
	## Returns [outer PanelContainer, inner VBoxContainer].
	var section := PanelContainer.new()
	section.theme_type_variation = "Card"
	section.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 2)
	section.add_child(vb)
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 6)
	vb.add_child(head)
	if not enable_id.is_empty() and _by_id.has(enable_id):
		# The section's own on/off, at the top of it rather than lost among the
		# controls it switches.
		var p: Dictionary = _by_id[enable_id]
		var idx := int(p.index)
		var cb := CheckBox.new()
		cb.focus_mode = Control.FOCUS_NONE
		cb.set_pressed_no_signal(_value(idx) > 0.5)
		cb.toggled.connect(func(on):
			App.set_plugin_param(ref, idx, 1.0 if on else 0.0)
			param_changed.emit())
		head.add_child(cb)
		_bound[idx] = cb
	var lbl := Label.new()
	lbl.theme_type_variation = "SectionLabel"
	lbl.text = title.to_upper()
	head.add_child(lbl)
	return [section, vb]


func _knob_section(row: Dictionary) -> Control:
	var parts := _card(String(row.get("title", "")), String(row.get("enable", "")))
	var vb: VBoxContainer = parts[1]
	var flow := HFlowContainer.new()
	flow.add_theme_constant_override("h_separation", 6)
	flow.add_theme_constant_override("v_separation", 2)
	vb.add_child(flow)
	var enable_id := String(row.get("enable", ""))
	for id in row.get("params", []):
		# The section's own switch is already in its heading.
		if String(id) == enable_id:
			continue
		var c := _control(String(id))
		if c != null:
			flow.add_child(c)
	if row.has("content_slot"):
		var slot := _content_slot(row["content_slot"])
		if slot != null:
			vb.add_child(slot)
	return parts[0]


## The file a part is playing, and a button to change it. Only the plugin knows
## what a "sample" means to it; Cadmium only knows the key to write it under.
func _content_slot(slot: Dictionary) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	var lbl := Label.new()
	lbl.theme_type_variation = "MuteLabel"
	lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	lbl.clip_text = true
	row.add_child(lbl)
	for key in ["sample", "wavetable"]:
		if not slot.has(key):
			continue
		var param_key := String(slot[key])
		var b := Button.new()
		b.text = key.capitalize() + "..."
		b.focus_mode = Control.FOCUS_NONE
		b.pressed.connect(func(): _pick_content(param_key, lbl))
		row.add_child(b)
	var clear := Button.new()
	clear.text = "Clear"
	clear.focus_mode = Control.FOCUS_NONE
	clear.pressed.connect(func():
		if slot.has("sample"):
			App.set_plugin_string(ref, String(slot["sample"]), "")
		lbl.text = ""
		param_changed.emit())
	row.add_child(clear)
	# Filled from the plugin's own report of what it is holding.
	_pictures.append(ContentLabel.new_binding(lbl, slot, self))
	return row


func _pick_content(key: String, lbl: Label) -> void:
	var dlg := FileDialog.new()
	dlg.file_mode = FileDialog.FILE_MODE_OPEN_ANY
	dlg.access = FileDialog.ACCESS_FILESYSTEM
	dlg.filters = PackedStringArray(["*.wav, *.sf2, *.sf3 ; Audio and soundfonts"])
	dlg.title = "Choose content"
	dlg.size = Vector2i(760, 520)
	add_child(dlg)
	var apply := func(path: String):
		if App.set_plugin_string(ref, key, path):
			lbl.text = path.get_file()
			App.status.emit("%s loaded" % path.get_file())
		else:
			App.status.emit("%s could not be read" % path.get_file())
		param_changed.emit()
		dlg.queue_free()
	dlg.file_selected.connect(apply)
	dlg.dir_selected.connect(apply)
	dlg.canceled.connect(func(): dlg.queue_free())
	dlg.popup_centered()


func _macro_section(row: Dictionary) -> Control:
	var parts := _card(String(row.get("title", "Macros")))
	var vb: VBoxContainer = parts[1]
	var flow := HFlowContainer.new()
	flow.add_theme_constant_override("h_separation", 10)
	vb.add_child(flow)
	_macro_knobs.clear()
	for id in row.get("params", []):
		var c := _control(String(id), 92.0)
		if c != null:
			flow.add_child(c)
			_macro_knobs.append(c)
	if row.has("labels"):
		_macro_labels = _json_array(_get_string(String(row["labels"])))
		_apply_macro_labels()
	return parts[0]


## A macro is only useful if it says what it does, and only the preset knows.
func _apply_macro_labels() -> void:
	for i in mini(_macro_labels.size(), _macro_knobs.size()):
		var name := String(_macro_labels[i]).strip_edges()
		var k = _macro_knobs[i]
		if k is CdKnob and not name.is_empty():
			k.label = name
			k.queue_redraw()


# ---------------------------------------------------------------------------
# Preset browser
# ---------------------------------------------------------------------------
func _browser(row: Dictionary) -> Control:
	var parts := _card("Presets")
	var vb: VBoxContainer = parts[1]
	var tools := HBoxContainer.new()
	tools.add_theme_constant_override("separation", 6)
	vb.add_child(tools)

	_preset_search = LineEdit.new()
	_preset_search.placeholder_text = "Search presets..."
	_preset_search.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_preset_search.text_changed.connect(func(_t): _fill_presets())
	tools.add_child(_preset_search)

	for facet in row.get("facets", []):
		var opt := OptionButton.new()
		opt.focus_mode = Control.FOCUS_NONE
		opt.custom_minimum_size.x = 118
		opt.item_selected.connect(func(_i): _fill_presets())
		tools.add_child(opt)
		_preset_facets[String(facet)] = opt

	var refresh := Button.new()
	refresh.text = "Rescan"
	refresh.focus_mode = Control.FOCUS_NONE
	refresh.pressed.connect(func():
		App.set_plugin_string(ref, "rescan", "1")
		_load_presets(String(row.get("list", "presets")))
		App.status.emit("%d presets found" % _presets.size()))
	tools.add_child(refresh)

	_preset_list = ItemList.new()
	_preset_list.custom_minimum_size.y = float(row.get("height", 220))
	_preset_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_preset_list.max_columns = 0
	_preset_list.same_column_width = true
	_preset_list.fixed_column_width = 210
	var select_key := String(row.get("select", "preset"))
	_preset_list.item_activated.connect(func(i): _choose_preset(i, select_key))
	_preset_list.item_selected.connect(func(i): _choose_preset(i, select_key))
	vb.add_child(_preset_list)

	_load_presets(String(row.get("list", "presets")))
	return parts[0]


func _load_presets(key: String) -> void:
	_presets = _json_array(_get_string(key))
	for facet in _preset_facets:
		var seen := {}
		var opt: OptionButton = _preset_facets[facet]
		opt.clear()
		opt.add_item("All " + String(facet) + "s")
		for p in _presets:
			# A style is a list; each of its tags is its own choice.
			for v in _tags(p, String(facet)):
				if not seen.has(v):
					seen[v] = true
		var keys := seen.keys()
		keys.sort()
		for v in keys:
			opt.add_item(String(v))
		opt.select(0)
	_fill_presets()


func _tags(p: Dictionary, facet: String) -> Array:
	var raw := String(p.get(facet, "")).strip_edges()
	if raw.is_empty():
		return []
	var out := []
	for t in raw.split(","):
		var s := String(t).strip_edges()
		if not s.is_empty():
			out.append(s)
	return out


func _fill_presets() -> void:
	if _preset_list == null:
		return
	var needle := _preset_search.text.to_lower() if _preset_search != null else ""
	_preset_list.clear()
	for p in _presets:
		if not needle.is_empty():
			var hay := "%s %s %s %s" % [String(p.get("name", "")), String(p.get("pack", "")),
					String(p.get("type", "")), String(p.get("author", ""))]
			if not hay.to_lower().contains(needle):
				continue
		var keep := true
		for facet in _preset_facets:
			var opt: OptionButton = _preset_facets[facet]
			if opt.selected <= 0:
				continue
			if not opt.get_item_text(opt.selected) in _tags(p, String(facet)):
				keep = false
		if not keep:
			continue
		var i := _preset_list.add_item(String(p.get("name", "?")))
		_preset_list.set_item_metadata(i, String(p.get("path", "")))
		var sub := String(p.get("type", ""))
		if not String(p.get("pack", "")).is_empty():
			sub = String(p.get("pack", "")) + ("  -  " + sub if not sub.is_empty() else "")
		_preset_list.set_item_tooltip(i, sub)
	if _preset_list.item_count == 0 and not _presets.is_empty():
		_preset_list.add_item("nothing matches")
		_preset_list.set_item_disabled(0, true)
	elif _presets.is_empty():
		_preset_list.add_item("no presets installed")
		_preset_list.set_item_disabled(0, true)


func _choose_preset(i: int, key: String) -> void:
	if i < 0 or i >= _preset_list.item_count:
		return
	var path := String(_preset_list.get_item_metadata(i))
	if path.is_empty():
		return
	if not App.set_plugin_string(ref, key, path):
		App.status.emit("%s would not load" % path.get_file())
		return
	# A preset moves everything at once, so everything is read back.
	refresh_all()
	_refresh_meta()
	param_changed.emit()


func _refresh_meta() -> void:
	var meta = JSON.parse_string(_get_string("meta"))
	if typeof(meta) != TYPE_DICTIONARY:
		return
	if _preset_title != null:
		var n := String(meta.get("name", ""))
		var t := String(meta.get("type", ""))
		_preset_title.text = n + ("  -  " + t if not t.is_empty() else "")
	_macro_labels = _json_array(_get_string("macro_names"))
	_apply_macro_labels()


# ---------------------------------------------------------------------------
# Drawn widgets
# ---------------------------------------------------------------------------
func _scope(row: Dictionary) -> Control:
	var v = load("res://ui/widgets/views/scope_view.tscn").instantiate()
	v.ref = ref
	v.params = params
	v.custom_minimum_size.y = float(row.get("height", 88))
	return v


func _picture(w: Control, row: Dictionary) -> Control:
	w.custom_minimum_size.y = float(row.get("height", 110))
	w.set("view", self)
	w.set("spec", row)
	_pictures.append(w)
	return w


func _envelope(row: Dictionary) -> Control:
	var parts := _card(String(row.get("title", "Envelope")))
	var vb: VBoxContainer = parts[1]
	var curve := EnvCurve.new()
	curve.custom_minimum_size.y = float(row.get("height", 96))
	curve.view = self
	curve.spec = row
	vb.add_child(curve)
	_pictures.append(curve)
	var flow := HFlowContainer.new()
	flow.add_theme_constant_override("h_separation", 6)
	vb.add_child(flow)
	for id in row.get("params", []):
		var c := _control(String(id), 66.0)
		if c != null:
			flow.add_child(c)
	return parts[0]


func _lfo(row: Dictionary) -> Control:
	var parts := _card(String(row.get("title", "LFO")))
	var vb: VBoxContainer = parts[1]
	var body := HBoxContainer.new()
	body.add_theme_constant_override("separation", 8)
	vb.add_child(body)
	var curve := LfoCurve.new()
	curve.custom_minimum_size = Vector2(200, float(row.get("height", 72)))
	curve.view = self
	curve.spec = row
	body.add_child(curve)
	_pictures.append(curve)
	var flow := HFlowContainer.new()
	flow.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	flow.add_theme_constant_override("h_separation", 6)
	body.add_child(flow)
	for id in row.get("params", []):
		var c := _control(String(id), 66.0)
		if c != null:
			flow.add_child(c)
	return parts[0]


func _steps(row: Dictionary) -> Control:
	var parts := _card(String(row.get("title", "Steps")))
	var vb: VBoxContainer = parts[1]
	var flow := HFlowContainer.new()
	flow.add_theme_constant_override("h_separation", 6)
	vb.add_child(flow)
	for id in row.get("controls", []):
		var c := _control(String(id))
		if c != null:
			flow.add_child(c)
	var grid := StepGrid.new()
	grid.custom_minimum_size.y = float(row.get("height", 100))
	grid.view = self
	grid.prefix = String(row.get("prefix", ""))
	grid.count = int(row.get("count", 16))
	vb.add_child(grid)
	_pictures.append(grid)
	return parts[0]


# ---------------------------------------------------------------------------
# Modulation matrix
# ---------------------------------------------------------------------------
func _matrix(row: Dictionary) -> Control:
	var parts := _card(String(row.get("title", "Modulation")))
	var vb: VBoxContainer = parts[1]
	var cols: Array = row.get("columns", [])
	var grid := GridContainer.new()
	grid.columns = cols.size() + 1
	grid.add_theme_constant_override("h_separation", 6)
	grid.add_theme_constant_override("v_separation", 2)
	vb.add_child(grid)

	var blank := Label.new()
	blank.text = " "
	grid.add_child(blank)
	for h in row.get("headings", cols):
		var l := Label.new()
		l.theme_type_variation = "MuteLabel"
		l.text = String(h)
		grid.add_child(l)

	var prefix := String(row.get("prefix", "mod"))
	for slot in int(row.get("slots", 0)):
		var n := Label.new()
		n.theme_type_variation = "MuteLabel"
		n.text = "%d" % (slot + 1)
		grid.add_child(n)
		for col in cols:
			var id := "%s%d.%s" % [prefix, slot + 1, String(col)]
			var c := _matrix_cell(id)
			grid.add_child(c if c != null else Control.new())
	return parts[0]


## One matrix cell: a menu for the choices, a slim slider for the amounts. The
## generic control would give every row a caption it does not need, sixty-four
## times over.
func _matrix_cell(id: String) -> Control:
	if not _by_id.has(id):
		return null
	var p: Dictionary = _by_id[id]
	var idx := int(p.index)
	if int(p.kind) == Cd.ParamKind.CHOICE and not String(p.choices).is_empty():
		var opt := OptionButton.new()
		opt.focus_mode = Control.FOCUS_NONE
		opt.custom_minimum_size.x = 158
		opt.fit_to_longest_item = false
		for c in String(p.choices).split("|"):
			opt.add_item(c)
		opt.select(clampi(int(round(_value(idx))), 0, opt.item_count - 1))
		opt.item_selected.connect(func(i):
			App.set_plugin_param(ref, idx, float(i))
			param_changed.emit())
		_bound[idx] = opt
		return opt
	var k := CdKnob.new()
	k.setup(p, _value(idx))
	k.knob_size = 22.0
	k.show_label = false
	k.custom_minimum_size.x = 54.0
	k.value_text_fn = func(v: float) -> String: return _param_text(idx, v)
	k.auto_ref = {"target": Cd.AutoTarget.PLUGIN, "ref": ref, "a": 0, "b": idx}
	k.value_changed.connect(func(v):
		App.set_plugin_param(ref, idx, v)
		param_changed.emit())
	_bound[idx] = k
	return k


# ---------------------------------------------------------------------------
# One control
# ---------------------------------------------------------------------------
func _control(id: String, width: float = KNOB_W) -> Control:
	if not _by_id.has(id):
		return null
	var p: Dictionary = _by_id[id]
	var idx := int(p.index)
	var value := _value(idx)

	if int(p.kind) == Cd.ParamKind.BOOL:
		var b := CheckBox.new()
		b.text = String(p.name)
		b.focus_mode = Control.FOCUS_NONE
		b.set_pressed_no_signal(value > 0.5)
		b.toggled.connect(func(on):
			App.set_plugin_param(ref, idx, 1.0 if on else 0.0)
			param_changed.emit())
		_bound[idx] = b
		return b

	if int(p.kind) == Cd.ParamKind.CHOICE and not String(p.choices).is_empty():
		var box := VBoxContainer.new()
		box.add_theme_constant_override("separation", 0)
		var lbl := Label.new()
		lbl.theme_type_variation = "MuteLabel"
		lbl.text = String(p.name)
		box.add_child(lbl)
		var opt := OptionButton.new()
		opt.focus_mode = Control.FOCUS_NONE
		opt.custom_minimum_size.x = maxf(112.0, width + 30.0)
		for c in String(p.choices).split("|"):
			opt.add_item(c)
		opt.select(clampi(int(round(value)), 0, opt.item_count - 1))
		opt.item_selected.connect(func(i):
			App.set_plugin_param(ref, idx, float(i))
			param_changed.emit())
		box.add_child(opt)
		_bound[idx] = opt
		return box

	var k := CdKnob.new()
	k.setup(p, value)
	k.custom_minimum_size.x = width
	if width >= 90.0:
		k.knob_size = 42.0
	# The plugin spells its own values; ours would say "43%" where it means
	# "2.4 kHz" or "1/8.".
	k.value_text_fn = func(v: float) -> String: return _param_text(idx, v)
	k.auto_ref = {"target": Cd.AutoTarget.PLUGIN, "ref": ref, "a": 0, "b": idx}
	k.value_changed.connect(func(v):
		App.set_plugin_param(ref, idx, v)
		param_changed.emit())
	k.menu_requested.connect(func(_pos): _menu(p))
	_bound[idx] = k
	return k


func _menu(p: Dictionary) -> void:
	var pm := PopupMenu.new()
	add_child(pm)
	pm.add_item("Reset", 0)
	pm.add_item("Create Automation Clip", 1)
	pm.id_pressed.connect(func(id):
		if id == 0:
			App.set_plugin_param(ref, int(p.index), float(p.default))
			refresh_all()
		else:
			var nm := "%s: %s" % [String(_layout.get("title", "Plugin")), String(p.name)]
			var ai := App.add_automation(nm, Cd.AutoTarget.PLUGIN, ref, 0, int(p.index),
					float(p.min), float(p.max))
			App.add_clip(Cd.ClipType.AUTOMATION, ai, 0, 0.0, maxf(4.0, App.project.length_beats()))
			App.status.emit("Automation clip added for %s" % String(p.name))
		param_changed.emit()
		pm.queue_free())
	pm.popup(Rect2i(DisplayServer.mouse_get_position(), Vector2i(1, 1)))


# ---------------------------------------------------------------------------
# Keeping up with the plugin
# ---------------------------------------------------------------------------
func _process(dt: float) -> void:
	if not is_visible_in_tree():
		return
	_poll += dt
	if _poll < 1.0 / POLL_HZ:
		return
	_poll = 0.0
	# Only what is on screen. A tab nobody is looking at is read when it is
	# opened, not sixty times a second while it is hidden.
	for idx in _bound:
		var c: Control = _bound[idx]
		if c == null or not is_instance_valid(c) or not c.is_visible_in_tree():
			continue
		_apply(idx, c)
	for w in _pictures:
		if is_instance_valid(w) and w.is_visible_in_tree():
			w.queue_redraw()


func refresh_all() -> void:
	for idx in _bound:
		var c = _bound[idx]
		if is_instance_valid(c):
			_apply(int(idx), c)


func _apply(idx: int, c: Control) -> void:
	var v := _value(idx)
	if c is CdKnob:
		if not c._dragging:
			c.value = v
	elif c is CheckBox:
		c.set_pressed_no_signal(v > 0.5)
	elif c is OptionButton:
		var want := clampi(int(round(v)), 0, c.item_count - 1)
		if c.selected != want:
			c.select(want)


func _value(index: int) -> float:
	return float(App.get_plugin_param(ref, index))


func _param_text(index: int, v: float) -> String:
	var h := App.handle_for(ref)
	if h < 0:
		return ""
	return App.engine().plugin_param_text(h, index, v)


func _get_string(key: String) -> String:
	var h := App.handle_for(ref)
	return App.engine().plugin_get_string(h, key) if h >= 0 else ""


func _json_array(text: String) -> Array:
	var v = JSON.parse_string(text) if not text.is_empty() else null
	return v if typeof(v) == TYPE_ARRAY else []


## The value of a parameter the layout named, for the drawn widgets.
func value_of(id: String, fallback: float = 0.0) -> float:
	return _value(int(_by_id[id].index)) if _by_id.has(id) else fallback


func has_param(id: String) -> bool:
	return _by_id.has(id)


func set_by_id(id: String, v: float) -> void:
	if not _by_id.has(id):
		return
	App.set_plugin_param(ref, int(_by_id[id].index), v)
	param_changed.emit()


func desc_of(id: String) -> Dictionary:
	return _by_id.get(id, {})


func aux(what: int, count: int) -> PackedFloat32Array:
	var h := App.handle_for(ref)
	return App.engine().plugin_aux(h, what, count) if h >= 0 else PackedFloat32Array()


# ===========================================================================
# The drawn widgets. Each reads the parameters the layout named for it, so
# none of them knows which plugin it is drawing.
# ===========================================================================
class WaveStrip extends Control:
	var view
	var spec := {}

	func _draw() -> void:
		var n := int(spec.get("parts", 3))
		draw_rect(Rect2(Vector2.ZERO, size), CdPalette.WELL)
		var data: PackedFloat32Array = view.aux(int(spec.get("aux", 1)), n * 96)
		var w := size.x / float(maxi(1, n))
		var font := get_theme_default_font()
		for i in n:
			var r := Rect2(i * w + 4.0, 14.0, w - 8.0, size.y - 22.0)
			draw_rect(r, CdPalette.PANEL)
			draw_string(font, Vector2(r.position.x + 2.0, r.position.y - 3.0),
					"OSC %s" % char(65 + i), HORIZONTAL_ALIGNMENT_LEFT, r.size.x, 8,
					CdPalette.TEXT_MUTE)
			if data.size() < (i + 1) * 96:
				continue
			var pts := PackedVector2Array()
			for k in 96:
				pts.append(Vector2(r.position.x + r.size.x * float(k) / 95.0,
						r.get_center().y - clampf(data[i * 96 + k], -1.2, 1.2) * r.size.y * 0.44))
			draw_polyline(pts, CdPalette.ACCENT, 1.5, true)


class FilterCurve extends Control:
	var view
	var spec := {}

	func _draw() -> void:
		draw_rect(Rect2(Vector2.ZERO, size), CdPalette.WELL)
		var font := get_theme_default_font()
		var n := int(spec.get("filters", 2))
		for f in n:
			var pre := "filter%d." % (f + 1)
			if not view.has_param(pre + "cutoff"):
				continue
			var on: bool = view.value_of(pre + "on", 1.0) > 0.5
			var cut: float = view.value_of(pre + "cutoff", 1000.0)
			var res: float = view.value_of(pre + "reso", 0.2)
			var type := int(view.value_of(pre + "type", 0))
			var col: Color = CdPalette.ACCENT if f == 0 else CdPalette.TEXT_DIM
			col.a = 1.0 if on else 0.25
			var pts := PackedVector2Array()
			for x in 160:
				var t := float(x) / 159.0
				var hz: float = 20.0 * pow(1000.0, t)
				var db := _response(hz, cut, res, type)
				pts.append(Vector2(size.x * t,
						size.y * (0.5 - clampf(db, -30.0, 18.0) / 48.0)))
			draw_polyline(pts, col, 1.6, true)
			var mark: float = clampf(log(maxf(cut, 20.0) / 20.0) / log(1000.0), 0.0, 1.0)
			draw_line(Vector2(size.x * mark, 0), Vector2(size.x * mark, size.y),
					Color(col.r, col.g, col.b, 0.25), 1.0)
		draw_string(font, Vector2(4, size.y - 4), "20 Hz          200          2 k          20 k",
				HORIZONTAL_ALIGNMENT_LEFT, size.x, 8, CdPalette.TEXT_MUTE)

	## A rough magnitude for the picture. Not the filter's own maths -- only the
	## plugin has that -- but the right shape, which is what the curve is for.
	func _response(hz: float, cut: float, res: float, type: int) -> float:
		var r: float = hz / maxf(cut, 5.0)
		var peak: float = res * 22.0
		var bump: float = peak * exp(-pow(log(maxf(r, 0.001)) / 0.35, 2.0))
		match type:
			0: return -12.0 * log(maxf(r, 0.001)) / log(2.0) * (1.0 if r > 1.0 else 0.0) + bump
			1, 2: return -24.0 * log(maxf(r, 0.001)) / log(2.0) * (1.0 if r > 1.0 else 0.0) + bump
			3: return 12.0 * log(maxf(r, 0.001)) / log(2.0) * (1.0 if r < 1.0 else 0.0) + bump
			4: return 24.0 * log(maxf(r, 0.001)) / log(2.0) * (1.0 if r < 1.0 else 0.0) + bump
			5, 6: return -12.0 * abs(log(maxf(r, 0.001)) / log(2.0)) + bump
			7: return -40.0 * exp(-pow(log(maxf(r, 0.001)) / 0.2, 2.0))
			_: return bump


class EnvCurve extends Control:
	var view
	var spec := {}

	func _draw() -> void:
		draw_rect(Rect2(Vector2.ZERO, size), CdPalette.WELL)
		var st: Dictionary = spec.get("stages", {})
		if st.is_empty():
			return
		var d: float = view.value_of(String(st.get("delay", "")), 0.0)
		var a: float = view.value_of(String(st.get("attack", "")), 5.0)
		var h: float = view.value_of(String(st.get("hold", "")), 0.0)
		var dec: float = view.value_of(String(st.get("decay", "")), 300.0)
		var s: float = view.value_of(String(st.get("sustain", "")), 0.6)
		var r: float = view.value_of(String(st.get("release", "")), 200.0)
		var ac: float = view.value_of(String(st.get("attack_curve", "")), 0.0)
		var dc: float = view.value_of(String(st.get("decay_curve", "")), -0.4)
		var rc: float = view.value_of(String(st.get("release_curve", "")), -0.4)
		# A held section between decay and release, so a patch with a long
		# sustain still shows its release rather than a line off the edge.
		var sustain_ms: float = maxf(120.0, (d + a + h + dec + r) * 0.25)
		var total: float = maxf(1.0, d + a + h + dec + sustain_ms + r)
		var pad := 6.0
		var w: float = size.x - pad * 2.0
		var top: float = 8.0
		var bot: float = size.y - 10.0
		var pts := PackedVector2Array()
		var x := pad
		var y := func(v: float) -> float: return bot - (bot - top) * clampf(v, 0.0, 1.0)
		pts.append(Vector2(x, y.call(0.0)))
		x += w * d / total
		pts.append(Vector2(x, y.call(0.0)))
		for i in 17:
			var t := float(i) / 16.0
			pts.append(Vector2(x + w * a / total * t, y.call(_shape(t, ac))))
		x += w * a / total
		x += w * h / total
		pts.append(Vector2(x, y.call(1.0)))
		for i in 17:
			var t := float(i) / 16.0
			pts.append(Vector2(x + w * dec / total * t, y.call(lerpf(1.0, s, _shape(t, dc)))))
		x += w * dec / total
		x += w * sustain_ms / total
		pts.append(Vector2(x, y.call(s)))
		for i in 17:
			var t := float(i) / 16.0
			pts.append(Vector2(x + w * r / total * t, y.call(s * (1.0 - _shape(t, rc)))))
		draw_polyline(pts, CdPalette.ACCENT, 1.8, true)
		var sy: float = y.call(s)
		draw_line(Vector2(pad, sy), Vector2(size.x - pad, sy),
				Color(CdPalette.TEXT_DIM.r, CdPalette.TEXT_DIM.g, CdPalette.TEXT_DIM.b, 0.2), 1.0)
		draw_string(get_theme_default_font(), Vector2(pad + 2.0, 10.0),
				"%.0f ms  ->  %d%%  ->  %.0f ms" % [a, int(round(s * 100.0)), r],
				HORIZONTAL_ALIGNMENT_LEFT, size.x, 8, CdPalette.TEXT_MUTE)

	func _shape(t: float, c: float) -> float:
		if c > 0.001:
			return pow(t, 1.0 + c * 3.0)
		if c < -0.001:
			return 1.0 - pow(1.0 - t, 1.0 - c * 3.0)
		return t


class LfoCurve extends Control:
	var view
	var spec := {}

	func _draw() -> void:
		draw_rect(Rect2(Vector2.ZERO, size), CdPalette.WELL)
		var shape := int(view.value_of(String(spec.get("shape", "")), 0.0))
		var depth: float = view.value_of(String(spec.get("depth", "")), 1.0)
		var phase: float = view.value_of(String(spec.get("phase", "")), 0.0)
		var mid: float = size.y * 0.5
		draw_line(Vector2(0, mid), Vector2(size.x, mid), CdPalette.RULE_DARK, 1.0)
		var pts := PackedVector2Array()
		for i in 128:
			var t: float = fmod(float(i) / 127.0 * 2.0 + phase, 1.0)
			pts.append(Vector2(size.x * float(i) / 127.0,
					mid - _shape(shape, t) * depth * size.y * 0.42))
		draw_polyline(pts, CdPalette.ACCENT, 1.6, true)

	func _shape(kind: int, t: float) -> float:
		match kind:
			0: return sin(TAU * t)
			1: return 4.0 * abs(t - 0.5) - 1.0
			2: return t * 2.0 - 1.0
			3: return 1.0 - t * 2.0
			4: return 1.0 if t < 0.5 else -1.0
			5: return 1.0 if t < 0.25 else -1.0
			6, 7: return sin(TAU * floor(t * 8.0) / 8.0)
			8: return sin(TAU * floor(t * 16.0) / 16.0)
			9: return pow(t, 3.0) * 2.0 - 1.0
			10: return pow(1.0 - t, 3.0) * 2.0 - 1.0
			11: return sin(TAU * t) * 0.6 + sin(TAU * t * 2.7) * 0.4
			_: return clampf((abs(t - 0.5) * 4.0 - 1.0) * 1.8, -1.0, 1.0)


class StepGrid extends Control:
	var view
	var prefix := ""
	var count := 16
	var _drag := false

	func _draw() -> void:
		draw_rect(Rect2(Vector2.ZERO, size), CdPalette.WELL)
		var w: float = size.x / float(maxi(1, count))
		for i in count:
			var v: float = view.value_of("%s%d" % [prefix, i + 1], 1.0)
			var r := Rect2(i * w + 1.0, size.y * (1.0 - v), w - 2.0, size.y * v)
			var col: Color = CdPalette.ACCENT
			# Every fourth step a shade brighter, so the beat is countable.
			draw_rect(r, Color(col.r, col.g, col.b, 0.85 if i % 4 == 0 else 0.55))
			if i % 4 == 0:
				draw_line(Vector2(i * w, 0), Vector2(i * w, size.y), CdPalette.RULE_DARK, 1.0)

	func _gui_input(e: InputEvent) -> void:
		if e is InputEventMouseButton and e.button_index == MOUSE_BUTTON_LEFT:
			_drag = e.pressed
			if e.pressed:
				_set_from(e.position)
			accept_event()
		elif e is InputEventMouseMotion and _drag:
			_set_from(e.position)
			accept_event()

	func _set_from(p: Vector2) -> void:
		var w: float = size.x / float(maxi(1, count))
		var i := clampi(int(p.x / w), 0, count - 1)
		view.set_by_id("%s%d" % [prefix, i + 1], clampf(1.0 - p.y / size.y, 0.0, 1.0))
		queue_redraw()


## Keeps a label showing whatever content a part is holding, which only the
## plugin can report.
class ContentLabel extends RefCounted:
	var label: Label
	var slot := {}
	var view

	static func new_binding(l: Label, s: Dictionary, v) -> Control:
		# A Control so the poll list can treat it like the drawn widgets; it
		# draws nothing and only exists to refresh the label.
		var c := ContentPoller.new()
		c.label = l
		c.slot = s
		c.view = v
		return c


class ContentPoller extends Control:
	var label: Label
	var slot := {}
	var view
	var _last := ""

	func _draw() -> void:
		var meta = JSON.parse_string(view._get_string("meta"))
		if typeof(meta) != TYPE_DICTIONARY:
			return
		var text := ""
		for key in ["sample", "wavetable"]:
			if not slot.has(key):
				continue
			var got := String(meta.get(String(slot[key]), ""))
			if not got.is_empty():
				text = got.get_file()
		if text != _last:
			_last = text
			label.text = text
