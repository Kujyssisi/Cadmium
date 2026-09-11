class_name CdFlareView
extends VBoxContainer
## FLARE's panel.
##
## Three hundred and fifty-eight parameters is a wall of knobs if you draw it
## as one, so this does not: seven pages, each with a picture of what it
## controls, the eight macros the preset named always in reach, and the browser
## a keystroke away. Nothing here is drawn by the plugin -- it is Cadmium's own
## widgets throughout, which is what makes it scale, take the theme and behave
## like the rest of the program.

signal param_changed()

var ref := {}
var params: Array = []

## How often the controls are read back: automation moves them, and so does
## loading a preset. Every frame would be several hundred round trips through
## the audio lock for a picture that changes at reading speed.
const POLL_HZ := 15.0
const KNOB_W := 72.0
const PAGES := ["MAIN", "OSC", "FILTER", "MOD", "MATRIX", "ARP", "FX"]

var _by_id := {}          ## parameter id -> descriptor
var _bound := {}          ## parameter index -> the control showing it
var _pictures: Array = [] ## the drawn widgets, refreshed on the poll
var _tabs: TabBar
var _pages: Array = []    ## one container per tab
var _poll := 0.0
var _meta := {}
var _presets: Array = []
var _browser: Control
var _list: ItemList
var _search: LineEdit
var _facets := {}
var _title: Label
var _subtitle: Label
var _macro_knobs: Array = []
var _meter: Control
## A preset chosen but not loaded yet. See _want_preset.
var _pending := -1
var _pending_at := 0
## The row numbers down the matrix, lit when the row is actually doing
## something. Sixteen rows of "--" otherwise look identical to sixteen rows of
## live routings.
var _slot_numbers: Array = []


func _ready() -> void:
	add_theme_constant_override("separation", 4)
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	# What the panel wants to open at. Two columns side by side need about
	# this much; below it they stack, which still works.
	custom_minimum_size = Vector2(790, 560)
	for p in params:
		_by_id[String(p.id)] = p
	_read_meta()
	_build_header()
	_build_tabs()
	_build_macros()
	set_process(true)


# ---------------------------------------------------------------------------
# Frame
# ---------------------------------------------------------------------------
func _build_header() -> void:
	var card := PanelContainer.new()
	card.theme_type_variation = "Card"
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	card.add_child(row)

	var mark := Label.new()
	mark.text = "FLARE"
	mark.theme_type_variation = "SectionLabel"
	mark.add_theme_color_override("font_color", CdPalette.ACCENT)
	row.add_child(mark)

	row.add_child(_gap(6))
	row.add_child(_small_button("<", func(): _step_preset(-1), "Previous preset"))
	row.add_child(_small_button(">", func(): _step_preset(1), "Next preset"))

	# The patch, in a well so it reads as a display rather than a caption.
	var namecol := VBoxContainer.new()
	namecol.add_theme_constant_override("separation", 0)
	namecol.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	namecol.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	# The name gives way, not the buttons. A label's minimum size is the width
	# of its text, so a long preset name would otherwise push Browse and Save
	# off the end of the row and there would be no way to reach either.
	namecol.custom_minimum_size.x = 70
	_title = Label.new()
	_title.text = String(_meta.get("name", "Init"))
	_title.clip_text = true
	_title.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	namecol.add_child(_title)
	_subtitle = Label.new()
	_subtitle.theme_type_variation = "MuteLabel"
	_subtitle.clip_text = true
	_subtitle.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	namecol.add_child(_subtitle)
	row.add_child(namecol)

	# What it is doing, right now: the level going out and how many voices are
	# sounding. A synth panel without either is a panel you have to play blind.
	_meter = OutputMeter.new()
	_meter.view = self
	_meter.custom_minimum_size = Vector2(96, 26)
	_pictures.append(_meter)
	row.add_child(_meter)

	var browse := Button.new()
	browse.text = "Browse"
	browse.toggle_mode = true
	browse.focus_mode = Control.FOCUS_NONE
	browse.tooltip_text = "The preset library"
	browse.toggled.connect(func(on): _show_browser(on))
	row.add_child(browse)
	row.add_child(_small_button("Save", func(): _save_preset(), "Save this patch to your own presets"))
	row.add_child(_small_button("Init", func(): _init_patch(), "Start from nothing"))
	add_child(card)
	_update_subtitle()


func _build_tabs() -> void:
	_tabs = TabBar.new()
	# Likewise: a focused tab bar answers to the arrow keys, which are the
	# transport and the octave.
	_tabs.focus_mode = Control.FOCUS_NONE
	for name in PAGES:
		_tabs.add_tab(String(name))
	_tabs.tab_changed.connect(_on_tab)
	add_child(_tabs)

	# One container per page, all built up front and hidden but for the first.
	# Building on demand made the first click on every tab stutter, and there
	# is not enough here to be worth that.
	# A plain column, not a fixed-height stack with anchored children: the
	# window this sits in scrolls already, and a page that is taller than a
	# number picked in advance should make it scroll rather than be cut off.
	var stack := VBoxContainer.new()
	stack.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	stack.add_theme_constant_override("separation", 0)
	add_child(stack)

	for i in PAGES.size():
		var page := VBoxContainer.new()
		page.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		page.add_theme_constant_override("separation", 4)
		page.visible = i == 0
		stack.add_child(page)
		_pages.append(page)
	_page_main(_pages[0])
	_page_osc(_pages[1])
	_page_filter(_pages[2])
	_page_mod(_pages[3])
	_page_matrix(_pages[4])
	_page_arp(_pages[5])
	_page_fx(_pages[6])

	# The browser takes the place of the pages rather than sitting beside them:
	# it wants the whole panel when it is open and none of it when it is not.
	_browser = _build_browser()
	_browser.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_browser.visible = false
	stack.add_child(_browser)


func _on_tab(i: int) -> void:
	for k in _pages.size():
		_pages[k].visible = k == i and not _browser.visible


func _show_browser(on: bool) -> void:
	_browser.visible = on
	if on:
		_load_presets()
	_on_tab(_tabs.current_tab)


func _build_macros() -> void:
	var card := PanelContainer.new()
	card.theme_type_variation = "Card"
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 1)
	card.add_child(col)
	var head := Label.new()
	head.theme_type_variation = "MuteLabel"
	head.text = "MACROS"
	col.add_child(head)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 4)
	col.add_child(row)
	_macro_knobs.clear()
	for i in 8:
		var k = _control("macro%d" % (i + 1), 84.0)
		if k != null:
			k.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			row.add_child(k)
			_macro_knobs.append(k)
	add_child(card)
	_apply_macro_names()


## A macro with no name is a knob that does nothing you can see. Only the
## preset knows what it was wired to, and it says so here.
func _apply_macro_names() -> void:
	var names: Array = _meta.get("macros", [])
	for i in mini(names.size(), _macro_knobs.size()):
		var n := String(names[i]).strip_edges()
		var k = _macro_knobs[i]
		if k is CdKnob:
			k.label = n if not n.is_empty() else "Macro %d" % (i + 1)
			k.queue_redraw()


# ---------------------------------------------------------------------------
# Building blocks
# ---------------------------------------------------------------------------
func _gap(w: float) -> Control:
	var c := Control.new()
	c.custom_minimum_size.x = w
	return c


func _small_button(text: String, action: Callable, tip: String = "") -> Button:
	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	b.tooltip_text = tip
	b.pressed.connect(action)
	return b


## A titled card, optionally with the on/off switch for what is inside it in
## its heading rather than lost among the controls it switches.
func _card(title: String, enable_id: String = "") -> Array:
	var card := PanelContainer.new()
	card.theme_type_variation = "Card"
	card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 2)
	card.add_child(col)
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 6)
	col.add_child(head)
	if not enable_id.is_empty() and _by_id.has(enable_id):
		var p: Dictionary = _by_id[enable_id]
		var idx := int(p.index)
		var cb := CheckButton.new()
		cb.focus_mode = Control.FOCUS_NONE
		cb.set_pressed_no_signal(_value(idx) > 0.5)
		cb.tooltip_text = "%s on/off" % title
		cb.toggled.connect(func(on):
			App.set_plugin_param(ref, idx, 1.0 if on else 0.0)
			param_changed.emit())
		head.add_child(cb)
		_bound[idx] = cb
	var lbl := Label.new()
	lbl.theme_type_variation = "SectionLabel"
	lbl.text = title
	head.add_child(lbl)
	return [card, col]


## A row of controls from a list of parameter ids. `strip` comes off the front
## of each label, so a knob inside a card called CHORUS says "Rate" and not
## "Chorus Rate" cut off after eleven characters.
func _row(into: Control, ids: Array, strip: String = "", knob_w: float = KNOB_W,
		compact: bool = false) -> HFlowContainer:
	# Flow, not a fixed row. The panel has to look right in a window the user
	# sized, at whatever the interface scale is set to, and a row of eight
	# knobs that simply runs off the edge is the thing that makes a plugin
	# look broken.
	var row := HFlowContainer.new()
	row.add_theme_constant_override("h_separation", 3)
	row.add_theme_constant_override("v_separation", 2)
	into.add_child(row)
	for id in ids:
		var c := _control(String(id), knob_w, strip, compact)
		if c != null:
			row.add_child(c)
	return row


## Two columns side by side while there is room for both, and one above the
## other when there is not. Everything that used a fixed pair of columns goes
## through here, so no page has a width below which it falls apart.
const COLUMN_MIN := 350.0

func _columns(page: Control) -> Array:
	var flow := HFlowContainer.new()
	flow.add_theme_constant_override("h_separation", 4)
	flow.add_theme_constant_override("v_separation", 4)
	flow.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	page.add_child(flow)
	var made := []
	for i in 2:
		var col := VBoxContainer.new()
		col.add_theme_constant_override("separation", 4)
		col.custom_minimum_size.x = COLUMN_MIN
		col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		flow.add_child(col)
		made.append(col)
	return made


func _control(id: String, knob_w: float = KNOB_W, strip: String = "",
		compact: bool = false) -> Control:
	if not _by_id.has(id):
		return null
	var p: Dictionary = _by_id[id]
	var idx := int(p.index)
	var value := _value(idx)
	var name := String(p.name)
	if not strip.is_empty() and name.begins_with(strip):
		name = name.substr(strip.length())

	if int(p.kind) == Cd.ParamKind.BOOL:
		var cb := CheckBox.new()
		cb.text = name
		cb.focus_mode = Control.FOCUS_NONE
		cb.set_pressed_no_signal(value > 0.5)
		cb.toggled.connect(func(on):
			App.set_plugin_param(ref, idx, 1.0 if on else 0.0)
			param_changed.emit())
		_bound[idx] = cb
		return cb

	if int(p.kind) == Cd.ParamKind.CHOICE and not String(p.choices).is_empty():
		var opt := OptionButton.new()
		opt.focus_mode = Control.FOCUS_NONE
		opt.custom_minimum_size.x = maxf(88.0, knob_w + 24.0)
		opt.clip_text = true
		opt.tooltip_text = name
		for c in String(p.choices).split("|"):
			opt.add_item(c)
		opt.select(clampi(int(round(value)), 0, opt.item_count - 1))
		opt.item_selected.connect(func(i):
			App.set_plugin_param(ref, idx, float(i))
			param_changed.emit())
		_bound[idx] = opt
		if compact:
			return opt
		var box := VBoxContainer.new()
		box.add_theme_constant_override("separation", 0)
		var lbl := Label.new()
		lbl.theme_type_variation = "MuteLabel"
		lbl.text = name
		box.add_child(lbl)
		box.add_child(opt)
		return box

	var k := CdKnob.new()
	k.setup(p, value)
	k.label = name
	if knob_w >= 84.0:
		k.knob_size = 40.0
	# Both dimensions, together. CdKnob works its own minimum out in _ready,
	# but only while nothing has been set -- and setting just the width leaves
	# it nothing to draw the dial and its two lines of text in.
	k.custom_minimum_size = Vector2(knob_w, k.knob_size + 30.0)
	# FLARE spells its own values; ours would say "43%" where it means
	# "2.4 kHz" or "1/8.".
	k.value_text_fn = func(v: float) -> String:
		var h := App.handle_for(ref)
		return App.engine().plugin_param_text(h, idx, v) if h >= 0 else ""
	k.auto_ref = {"target": Cd.AutoTarget.PLUGIN, "ref": ref, "a": 0, "b": idx}
	k.value_changed.connect(func(v):
		App.set_plugin_param(ref, idx, v)
		param_changed.emit())
	k.menu_requested.connect(func(_pos): _param_menu(p))
	_bound[idx] = k
	return k


func _picture(w: Control, height: float) -> Control:
	w.custom_minimum_size.y = height
	w.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	w.set("view", self)
	_pictures.append(w)
	return w


func _param_menu(p: Dictionary) -> void:
	var pm := PopupMenu.new()
	add_child(pm)
	pm.add_item("Reset", 0)
	pm.add_item("Create Automation Clip", 1)
	pm.id_pressed.connect(func(id):
		if id == 0:
			App.set_plugin_param(ref, int(p.index), float(p.default))
			refresh_all()
		else:
			var nm := "FLARE: %s" % String(p.name)
			var ai := App.add_automation(nm, Cd.AutoTarget.PLUGIN, ref, 0, int(p.index),
					float(p.min), float(p.max))
			App.add_clip(Cd.ClipType.AUTOMATION, ai, 0, 0.0, maxf(4.0, App.project.length_beats()))
			App.status.emit("Automation clip added for %s" % String(p.name))
		param_changed.emit()
		pm.queue_free())
	pm.popup(Rect2i(DisplayServer.mouse_get_position(), Vector2i(1, 1)))


# ---------------------------------------------------------------------------
# Pages
# ---------------------------------------------------------------------------
## What gets touched on nearly every patch, all on one page: the three
## oscillators with their waves, the filter with its curve, the amplifier with
## its envelope, and the two sends.
func _page_main(page: Control) -> void:
	var cols := _columns(page)
	var left: VBoxContainer = cols[0]
	var right: VBoxContainer = cols[1]

	# --- oscillators, side by side, each with its own wave
	var osc := _card("OSCILLATORS")
	# Exactly three across, always. A flow container would let them expand to
	# fill a line and push the third onto the next one, which is neither what
	# the layout wants nor what an oscillator section should ever look like.
	var orow := GridContainer.new()
	orow.columns = 3
	orow.add_theme_constant_override("h_separation", 6)
	orow.add_theme_constant_override("v_separation", 4)
	orow.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	osc[1].add_child(orow)
	for i in 3:
		var pre := "osc%s." % ["a", "b", "c"][i]
		var strip := VBoxContainer.new()
		strip.add_theme_constant_override("separation", 2)
		strip.custom_minimum_size.x = 104.0
		strip.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		orow.add_child(strip)
		var head := HBoxContainer.new()
		head.add_theme_constant_override("separation", 4)
		strip.add_child(head)
		var on := _control(pre + "on")
		if on != null:
			on.text = "OSC %s" % ["A", "B", "C"][i]
			head.add_child(on)
		strip.add_child(_picture(WaveView.new_for(i), 40.0))
		var wave := _control(pre + "wave", 40.0, ["A ", "B ", "C "][i], true)
		if wave != null:
			strip.add_child(wave)
		var krow := _row(strip, [pre + "level", pre + "unison", pre + "detune"],
				["A ", "B ", "C "][i], 40.0)
		for k in krow.get_children():
			k.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	left.add_child(osc[0])

	# --- filter, with the curve above the controls
	var flt := _card("FILTER", "filter1.on")
	flt[1].add_child(_picture(FilterView.new(), 66.0))
	_row(flt[1], ["filter1.type", "filter1.cutoff", "filter1.reso", "filter1.drive",
			"filter1.env"], "F1 ", KNOB_W, true)
	left.add_child(flt[0])

	# --- amplifier
	var amp := _card("AMPLIFIER")
	amp[1].add_child(_picture(EnvView.new_for(0), 58.0))
	_row(amp[1], ["env1.attack", "env1.decay", "env1.sustain", "env1.release",
			"master.vol", "master.vel_vol"], "E1 ")
	left.add_child(amp[0])

	# --- how it plays, and the two sends everybody reaches for
	var voice := _card("VOICE")
	_row(voice[1], ["master.mode", "master.poly"], "")
	_row(voice[1], ["master.glide", "master.octave", "master.semi", "master.tune"], "")
	right.add_child(voice[0])

	var dly := _card("DELAY", "fx.delay.on")
	_row(dly[1], ["fx.delay.div", "fx.delay.feedback", "fx.delay.mix"], "Delay ")
	right.add_child(dly[0])

	var rev := _card("REVERB", "fx.reverb.on")
	_row(rev[1], ["fx.reverb.size", "fx.reverb.damp", "fx.reverb.mix"], "Reverb ")
	right.add_child(rev[0])

	var arp := _card("ARP", "arp.on")
	_row(arp[1], ["arp.mode", "arp.div"], "Arp ")
	_row(arp[1], ["arp.octaves", "arp.gate", "arp.swing"], "Arp ")
	right.add_child(arp[0])

	var spacer := Control.new()
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	right.add_child(spacer)


func _page_osc(page: Control) -> void:
	for i in 3:
		var letter: String = ["A", "B", "C"][i]
		var pre := "osc%s." % letter.to_lower()
		var card := _card("OSCILLATOR %s" % letter, pre + "on")
		var body := HFlowContainer.new()
		body.add_theme_constant_override("h_separation", 8)
		body.add_theme_constant_override("v_separation", 2)
		card[1].add_child(body)

		var side := VBoxContainer.new()
		side.add_theme_constant_override("separation", 2)
		side.custom_minimum_size.x = 156
		body.add_child(side)
		side.add_child(_picture(WaveView.new_for(i), 48.0))
		var src := _control(pre + "src", 60.0, letter + " ")
		if src != null:
			side.add_child(src)
		var wave := _control(pre + "wave", 60.0, letter + " ")
		if wave != null:
			side.add_child(wave)
		side.add_child(_content_row(i))

		var knobs := VBoxContainer.new()
		knobs.add_theme_constant_override("separation", 2)
		knobs.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		body.add_child(knobs)
		_row(knobs, [pre + "level", pre + "pan", pre + "octave", pre + "semi", pre + "fine",
				pre + "pos", pre + "warp", pre + "warp_mode"], letter + " ")
		_row(knobs, [pre + "unison", pre + "detune", pre + "spread", pre + "blend",
				pre + "phase", pre + "fm", pre + "rm", pre + "filter"], letter + " ")
		page.add_child(card[0])

	var bottom := HBoxContainer.new()
	bottom.add_theme_constant_override("separation", 4)
	page.add_child(bottom)
	var sub := _card("SUB", "sub.on")
	_row(sub[1], ["sub.wave", "sub.level", "sub.octave", "sub.pan"], "Sub ")
	bottom.add_child(sub[0])
	var noise := _card("NOISE", "noise.on")
	_row(noise[1], ["noise.type", "noise.level", "noise.cut", "noise.pan"], "Noise ")
	bottom.add_child(noise[0])


## The file an oscillator is playing when it is set to a sample, and a way to
## change it. Only FLARE knows what a sample means to it; Cadmium knows the key
## to write it under and where to put the file dialogue.
func _content_row(part: int) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 3)
	var key := "osc%s.sample" % ["a", "b", "c"][part]
	var lbl := Label.new()
	lbl.theme_type_variation = "MuteLabel"
	lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	lbl.clip_text = true
	lbl.text = String(_meta.get(key, "")).get_file()
	row.add_child(lbl)
	row.add_child(_small_button("...", func(): _pick_content(key, lbl),
			"Load a WAV, a folder of WAVs, or a SoundFont"))
	row.add_child(_small_button("x", func():
			App.set_plugin_string(ref, key, "")
			lbl.text = ""
			param_changed.emit(), "Clear"))
	return row


func _pick_content(key: String, lbl: Label) -> void:
	var dlg := FileDialog.new()
	dlg.file_mode = FileDialog.FILE_MODE_OPEN_ANY
	dlg.access = FileDialog.ACCESS_FILESYSTEM
	dlg.filters = PackedStringArray(["*.wav, *.sf2, *.sf3 ; Samples and SoundFonts"])
	dlg.title = "Load into FLARE"
	dlg.size = Vector2i(780, 540)
	add_child(dlg)
	var apply := func(path: String):
		if App.set_plugin_string(ref, key, path):
			lbl.text = path.get_file()
			App.status.emit("FLARE loaded %s" % path.get_file())
		else:
			App.status.emit("FLARE could not read %s" % path.get_file())
		_read_meta()
		refresh_all()
		param_changed.emit()
		dlg.queue_free()
	dlg.file_selected.connect(apply)
	dlg.dir_selected.connect(apply)
	dlg.canceled.connect(func(): dlg.queue_free())
	dlg.popup_centered()


func _page_filter(page: Control) -> void:
	page.add_child(_picture(FilterView.new(), 120.0))
	for f in 2:
		var pre := "filter%d." % (f + 1)
		var card := _card("FILTER %d" % (f + 1), pre + "on")
		var body := HBoxContainer.new()
		body.add_theme_constant_override("separation", 8)
		card[1].add_child(body)
		var menus := VBoxContainer.new()
		menus.add_theme_constant_override("separation", 2)
		menus.custom_minimum_size.x = 150
		body.add_child(menus)
		for id in [pre + "type", pre + "env_src", pre + "lfo_src"]:
			var c := _control(id, 60.0, "F%d " % (f + 1))
			if c != null:
				menus.add_child(c)
		var knobs := VBoxContainer.new()
		knobs.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		body.add_child(knobs)
		_row(knobs, [pre + "cutoff", pre + "reso", pre + "drive", pre + "keytrack",
				pre + "env", pre + "lfo", pre + "mix", pre + "pan_spread"], "F%d " % (f + 1))
		page.add_child(card[0])
	var route := _card("ROUTING")
	_row(route[1], ["filter.routing", "osca.filter", "oscb.filter", "oscc.filter"], "")
	page.add_child(route[0])


func _page_mod(page: Control) -> void:
	var cols := _columns(page)
	var left: VBoxContainer = cols[0]
	var right: VBoxContainer = cols[1]

	var env_names := ["ENV 1  AMP", "ENV 2  FILTER", "ENV 3", "ENV 4"]
	for i in 4:
		var card := _card(env_names[i])
		var body := HBoxContainer.new()
		body.add_theme_constant_override("separation", 6)
		card[1].add_child(body)
		var pic := _picture(EnvView.new_for(i), 58.0)
		pic.custom_minimum_size.x = 120
		pic.size_flags_horizontal = Control.SIZE_FILL
		body.add_child(pic)
		var knobs := VBoxContainer.new()
		knobs.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		body.add_child(knobs)
		var pre := "env%d." % (i + 1)
		_row(knobs, [pre + "attack", pre + "decay", pre + "sustain", pre + "release",
				pre + "vel"], "E%d " % (i + 1), 62.0)
		left.add_child(card[0])

	for i in 3:
		var card := _card("LFO %d" % (i + 1))
		var body := HBoxContainer.new()
		body.add_theme_constant_override("separation", 6)
		card[1].add_child(body)
		var pic := _picture(LfoView.new_for(i), 58.0)
		pic.custom_minimum_size.x = 120
		pic.size_flags_horizontal = Control.SIZE_FILL
		body.add_child(pic)
		var col := VBoxContainer.new()
		col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		body.add_child(col)
		var pre := "lfo%d." % (i + 1)
		_row(col, [pre + "shape", pre + "div", pre + "mode"], "L%d " % (i + 1), 60.0)
		_row(col, [pre + "depth", pre + "rate", pre + "phase", pre + "fade"],
				"L%d " % (i + 1), 62.0)
		right.add_child(card[0])


func _page_matrix(page: Control) -> void:
	var card := _card("MODULATION MATRIX")
	var grid := GridContainer.new()
	grid.columns = 5
	grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grid.add_theme_constant_override("h_separation", 6)
	grid.add_theme_constant_override("v_separation", 2)
	card[1].add_child(grid)

	for h in ["", "Source", "Target", "Amount", "Curve"]:
		var l := Label.new()
		l.theme_type_variation = "MuteLabel"
		l.text = String(h)
		grid.add_child(l)

	_slot_numbers.clear()
	for slot in 16:
		var pre := "mod%d." % (slot + 1)
		var n := Label.new()
		n.theme_type_variation = "MuteLabel"
		n.text = "%d" % (slot + 1)
		n.custom_minimum_size.x = 20
		n.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		grid.add_child(n)
		_slot_numbers.append(n)
		grid.add_child(_matrix_cell(pre + "src", 150.0))
		grid.add_child(_matrix_cell(pre + "dst", 150.0))
		grid.add_child(_matrix_cell(pre + "amount", 110.0))
		grid.add_child(_matrix_cell(pre + "curve", 80.0))
	page.add_child(card[0])


## A matrix row wants a menu and a slider, not the captioned control the rest
## of the panel uses: sixty-four captions saying "1 Source", "2 Source" is not
## a table anybody can read down.
func _matrix_cell(id: String, width: float) -> Control:
	if not _by_id.has(id):
		return Control.new()
	var p: Dictionary = _by_id[id]
	var idx := int(p.index)
	if int(p.kind) == Cd.ParamKind.CHOICE:
		var opt := OptionButton.new()
		opt.focus_mode = Control.FOCUS_NONE
		opt.custom_minimum_size.x = width
		opt.clip_text = true
		for c in String(p.choices).split("|"):
			opt.add_item(c)
		opt.select(clampi(int(round(_value(idx))), 0, opt.item_count - 1))
		opt.item_selected.connect(func(i):
			App.set_plugin_param(ref, idx, float(i))
			param_changed.emit())
		_bound[idx] = opt
		return opt
	# A modulation amount runs either side of nothing, so it is drawn out from
	# the middle. A stock slider fills from its left end, which puts half a bar
	# of colour on every unused row and makes the page look full of settings.
	var bar := BipolarBar.new()
	bar.view = self
	bar.index = idx
	bar.minimum = float(p.min)
	bar.maximum = float(p.max)
	bar.custom_minimum_size = Vector2(width, 18)
	_bound[idx] = bar
	_pictures.append(bar)
	return bar


func _page_arp(page: Control) -> void:
	var arp := _card("ARPEGGIATOR", "arp.on")
	var body := HBoxContainer.new()
	body.add_theme_constant_override("separation", 8)
	arp[1].add_child(body)
	var menus := VBoxContainer.new()
	menus.custom_minimum_size.x = 150
	body.add_child(menus)
	for id in ["arp.mode", "arp.div"]:
		var c := _control(id, 60.0, "Arp ")
		if c != null:
			menus.add_child(c)
	var latch := _control("arp.latch")
	if latch != null:
		menus.add_child(latch)
	var knobs := VBoxContainer.new()
	knobs.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body.add_child(knobs)
	_row(knobs, ["arp.octaves", "arp.gate", "arp.swing", "arp.steps"], "Arp ")
	page.add_child(arp[0])

	var gate := _card("STEP GATE", "gate.on")
	_row(gate[1], ["gate.div", "gate.smooth"], "Gate ")
	gate[1].add_child(_picture(StepView.new(), 130.0))
	var hint := Label.new()
	hint.theme_type_variation = "MuteLabel"
	hint.text = "Drag across the steps to draw the pattern."
	gate[1].add_child(hint)
	page.add_child(gate[0])


func _page_fx(page: Control) -> void:
	var slots := [
		["FX FILTER", "fx.filter.on", "Filter ", ["fx.filter.type", "fx.filter.cutoff",
				"fx.filter.reso", "fx.filter.mix"]],
		["DISTORTION", "fx.dist.on", "Dist ", ["fx.dist.type", "fx.dist.drive",
				"fx.dist.tone", "fx.dist.mix"]],
		["EQ", "fx.eq.on", "", ["fx.eq.lo_gain", "fx.eq.lo_freq", "fx.eq.mid_gain",
				"fx.eq.mid_freq", "fx.eq.mid_q", "fx.eq.hi_gain", "fx.eq.hi_freq"]],
		["CHORUS", "fx.chorus.on", "Chorus ", ["fx.chorus.rate", "fx.chorus.depth",
				"fx.chorus.voices", "fx.chorus.width", "fx.chorus.feedback", "fx.chorus.mix"]],
		["PHASER", "fx.phaser.on", "Phaser ", ["fx.phaser.rate", "fx.phaser.depth",
				"fx.phaser.centre", "fx.phaser.feedback", "fx.phaser.stages",
				"fx.phaser.spread", "fx.phaser.mix"]],
		["DELAY", "fx.delay.on", "Delay ", ["fx.delay.sync", "fx.delay.div", "fx.delay.time",
				"fx.delay.feedback", "fx.delay.ping", "fx.delay.locut", "fx.delay.hicut",
				"fx.delay.width", "fx.delay.mix"]],
		["REVERB", "fx.reverb.on", "Reverb ", ["fx.reverb.size", "fx.reverb.damp",
				"fx.reverb.width", "fx.reverb.predelay", "fx.reverb.locut",
				"fx.reverb.diffuse", "fx.reverb.mix"]],
		["COMPRESSOR", "fx.comp.on", "Comp ", ["fx.comp.thresh", "fx.comp.ratio",
				"fx.comp.attack", "fx.comp.release", "fx.comp.makeup"]],
		["LIMITER", "fx.limit.on", "", ["fx.limit.ceiling"]],
	]
	var cols := _columns(page)
	var left: VBoxContainer = cols[0]
	var right: VBoxContainer = cols[1]

	for i in slots.size():
		var s: Array = slots[i]
		var card := _card(String(s[0]), String(s[1]))
		# Wrapped at six across, so the wide ones do not push the panel out.
		var ids: Array = s[3]
		var at := 0
		while at < ids.size():
			_row(card[1], ids.slice(at, at + 5), String(s[2]), 62.0)
			at += 5
		(left if i < 5 else right).add_child(card[0])
	var pad := Control.new()
	pad.size_flags_vertical = Control.SIZE_EXPAND_FILL
	right.add_child(pad)


# ---------------------------------------------------------------------------
# Preset browser
# ---------------------------------------------------------------------------
func _build_browser() -> Control:
	var card := PanelContainer.new()
	card.theme_type_variation = "Card"
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 4)
	card.add_child(col)

	var tools := HBoxContainer.new()
	tools.add_theme_constant_override("separation", 6)
	col.add_child(tools)
	_search = LineEdit.new()
	_search.placeholder_text = "Search presets..."
	_search.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_search.text_changed.connect(func(_t): _fill_presets())
	tools.add_child(_search)
	for facet in ["pack", "type", "style"]:
		var opt := OptionButton.new()
		opt.focus_mode = Control.FOCUS_NONE
		opt.custom_minimum_size.x = 130
		opt.clip_text = true
		opt.item_selected.connect(func(_i): _fill_presets())
		tools.add_child(opt)
		_facets[facet] = opt
	tools.add_child(_small_button("Rescan", func():
			App.set_plugin_string(ref, "rescan", "1")
			_load_presets()
			App.status.emit("FLARE: %d presets" % _presets.size()),
			"Look again for presets on disk"))

	_list = ItemList.new()
	# The letter keys play notes -- that is how you check what a preset sounds
	# like -- so nothing in the browser may take them. An ItemList grabs the
	# keyboard by default and treats a letter as "jump to the next preset
	# starting with it", which meant auditioning a patch on the C key loaded
	# whatever came after Chord Pulse.
	_list.allow_search = false
	_list.focus_mode = Control.FOCUS_NONE
	_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_list.custom_minimum_size.y = 340
	_list.max_columns = 0
	_list.same_column_width = true
	_list.fixed_column_width = 210
	_list.item_selected.connect(_want_preset)
	col.add_child(_list)

	var count := Label.new()
	count.theme_type_variation = "MuteLabel"
	count.name = "Count"
	col.add_child(count)
	return card


func _load_presets() -> void:
	var text := _get_string("presets")
	var parsed = JSON.parse_string(text) if not text.is_empty() else null
	_presets = parsed if typeof(parsed) == TYPE_ARRAY else []
	for facet in _facets:
		var opt: OptionButton = _facets[facet]
		opt.clear()
		opt.add_item("All %ss" % String(facet).capitalize())
		var seen := {}
		for p in _presets:
			for v in _tags(p, String(facet)):
				seen[v] = true
		var keys := seen.keys()
		keys.sort()
		for v in keys:
			opt.add_item(String(v))
		opt.select(0)
	_fill_presets()


## A style is a list; each of its tags filters on its own.
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
	if _list == null:
		return
	var needle := _search.text.to_lower() if _search != null else ""
	_list.clear()
	var shown := 0
	for p in _presets:
		if not needle.is_empty():
			var hay := "%s %s %s %s" % [String(p.get("name", "")), String(p.get("pack", "")),
					String(p.get("type", "")), String(p.get("author", ""))]
			if not hay.to_lower().contains(needle):
				continue
		var keep := true
		for facet in _facets:
			var opt: OptionButton = _facets[facet]
			if opt.selected <= 0:
				continue
			if not opt.get_item_text(opt.selected) in _tags(p, String(facet)):
				keep = false
		if not keep:
			continue
		var t := String(p.get("type", ""))
		var i := _list.add_item(String(p.get("name", "?")) + ("    " + t if not t.is_empty() else ""))
		_list.set_item_metadata(i, String(p.get("path", "")))
		_list.set_item_tooltip(i, "%s\n%s" % [String(p.get("pack", "")), String(p.get("style", ""))])
		if String(p.get("name", "")) == String(_meta.get("name", "")):
			_list.select(i)
		shown += 1
	var count := _browser.find_child("Count", true, false)
	if count != null:
		if _presets.is_empty():
			count.text = "No presets found. They go in %s" % String(_meta.get("user_dir", ""))
		else:
			count.text = "%d of %d presets" % [shown, _presets.size()]


## An ItemList reports a selection while the button is still down, so running
## a cursor down the list -- or holding one of the arrows -- used to load every
## preset it passed over, each of which reads files and rebuilds every voice.
## The choice is remembered and acted on once it has stopped changing.
const SETTLE_MS := 130

func _want_preset(i: int) -> void:
	_pending = i
	_pending_at = Time.get_ticks_msec()


func _choose_preset(i: int) -> void:
	if i < 0 or i >= _list.item_count:
		return
	var path := String(_list.get_item_metadata(i))
	if path.is_empty():
		return
	if not App.set_plugin_string(ref, "preset", path):
		App.status.emit("FLARE: %s would not load" % path.get_file())
		return
	_read_meta()
	refresh_all()
	# Whoever just picked a preset wants to hear it, and the keys that play it
	# are the ones the search box would otherwise still be eating.
	if _search != null and _search.has_focus():
		_search.release_focus()
	App.status.emit("FLARE: %s" % String(_meta.get("name", path.get_file())))
	param_changed.emit()


func _step_preset(delta: int) -> void:
	if _presets.is_empty():
		_load_presets()
	if _presets.is_empty():
		return
	if Time.get_ticks_msec() - _pending_at < SETTLE_MS:
		return
	_pending_at = Time.get_ticks_msec()
	var at := -1
	for i in _presets.size():
		if String(_presets[i].get("name", "")) == String(_meta.get("name", "")):
			at = i
	at = (at + delta + _presets.size()) % _presets.size()
	if not App.set_plugin_string(ref, "preset", String(_presets[at].get("path", ""))):
		return
	_read_meta()
	refresh_all()
	App.status.emit("FLARE: %s" % String(_meta.get("name", "")))
	param_changed.emit()


func _save_preset() -> void:
	var dlg := AcceptDialog.new()
	dlg.title = "Save FLARE preset"
	var box := VBoxContainer.new()
	var field := LineEdit.new()
	field.text = String(_meta.get("name", "Init"))
	field.placeholder_text = "Preset name"
	field.custom_minimum_size.x = 260
	box.add_child(field)
	var where := Label.new()
	where.theme_type_variation = "MuteLabel"
	where.text = String(_meta.get("user_dir", ""))
	box.add_child(where)
	dlg.add_child(box)
	dlg.register_text_enter(field)
	add_child(dlg)
	dlg.confirmed.connect(func():
		var name := field.text.strip_edges().replace("/", "-")
		if not name.is_empty():
			App.set_plugin_string(ref, "name", name)
			var path := String(_meta.get("user_dir", "")) + "/" + name + ".flare"
			if App.set_plugin_string(ref, "save_preset", path):
				App.status.emit("FLARE: saved %s" % name)
				_read_meta()
				_load_presets()
			else:
				App.status.emit("FLARE: could not write %s" % path)
		dlg.queue_free())
	dlg.canceled.connect(func(): dlg.queue_free())
	dlg.popup_centered()


func _init_patch() -> void:
	App.set_plugin_string(ref, "init", "1")
	_read_meta()
	refresh_all()
	param_changed.emit()
	App.status.emit("FLARE: initialised")


# ---------------------------------------------------------------------------
# Keeping up with the plugin
# ---------------------------------------------------------------------------
func _process(dt: float) -> void:
	if not is_visible_in_tree():
		return
	if _pending >= 0 and Time.get_ticks_msec() - _pending_at > SETTLE_MS:
		var want := _pending
		_pending = -1
		_choose_preset(want)
	_poll += dt
	if _poll < 1.0 / POLL_HZ:
		return
	_poll = 0.0
	# Only what is on screen: a tab nobody is looking at is read when it is
	# opened, not fifteen times a second while it is hidden.
	for idx in _bound:
		var c = _bound[idx]
		if c == null or not is_instance_valid(c) or not c.is_visible_in_tree():
			continue
		_apply(int(idx), c)
	for w in _pictures:
		if is_instance_valid(w) and w.is_visible_in_tree():
			w.queue_redraw()
	_light_matrix()


## Which modulation slots are wired to something, at a glance.
func _light_matrix() -> void:
	if _slot_numbers.is_empty() or not _slot_numbers[0].is_visible_in_tree():
		return
	for i in _slot_numbers.size():
		var pre := "mod%d." % (i + 1)
		var live: bool = value_of(pre + "src") > 0.5 and value_of(pre + "dst") > 0.5 \
				and absf(value_of(pre + "amount")) > 0.001
		_slot_numbers[i].add_theme_color_override("font_color",
				CdPalette.ACCENT if live else CdPalette.TEXT_MUTE)


func refresh_all() -> void:
	for idx in _bound:
		var c = _bound[idx]
		if is_instance_valid(c):
			_apply(int(idx), c)
	_apply_macro_names()
	_update_subtitle()
	for w in _pictures:
		if is_instance_valid(w):
			w.queue_redraw()


func _apply(idx: int, c: Control) -> void:
	var v := _value(idx)
	if c is CdKnob:
		if not c._dragging:
			c.value = v
	elif c is CheckBox or c is CheckButton:
		c.set_pressed_no_signal(v > 0.5)
	elif c is OptionButton:
		var want := clampi(int(round(v)), 0, c.item_count - 1)
		if c.selected != want:
			c.select(want)
	elif c is BipolarBar:
		c.queue_redraw()


func _update_subtitle() -> void:
	if _title != null:
		_title.text = String(_meta.get("name", "Init"))
	if _subtitle == null:
		return
	var bits := []
	for k in ["pack", "type", "style", "author"]:
		var s := String(_meta.get(k, "")).strip_edges()
		if not s.is_empty():
			bits.append(s)
	_subtitle.text = "  ·  ".join(bits) if not bits.is_empty() else "untagged patch"


func _read_meta() -> void:
	var parsed = JSON.parse_string(_get_string("meta"))
	_meta = parsed if typeof(parsed) == TYPE_DICTIONARY else {}


func _value(index: int) -> float:
	return float(App.get_plugin_param(ref, index))


func _text_of(index: int, v: float) -> String:
	var h := App.handle_for(ref)
	return App.engine().plugin_param_text(h, index, v) if h >= 0 else ""


func _get_string(key: String) -> String:
	var h := App.handle_for(ref)
	return App.engine().plugin_get_string(h, key) if h >= 0 else ""


## For the drawn widgets, which know a parameter by name and nothing else.
func value_of(id: String, fallback: float = 0.0) -> float:
	return _value(int(_by_id[id].index)) if _by_id.has(id) else fallback


## By index, for the drawn controls that already know one.
func set_by_id_index(index: int, v: float) -> void:
	App.set_plugin_param(ref, index, v)
	param_changed.emit()


func set_by_id(id: String, v: float) -> void:
	if not _by_id.has(id):
		return
	App.set_plugin_param(ref, int(_by_id[id].index), v)
	param_changed.emit()


func aux(what: int, count: int) -> PackedFloat32Array:
	var h := App.handle_for(ref)
	return App.engine().plugin_aux(h, what, count) if h >= 0 else PackedFloat32Array()


# ===========================================================================
# The pictures. Each reads the parameters it draws and nothing else, so none of
# them needs to be told when something changes.
# ===========================================================================
class WaveView extends Control:
	var view
	var part := 0

	static func new_for(p: int) -> WaveView:
		var w := WaveView.new()
		w.part = p
		return w

	func _draw() -> void:
		draw_rect(Rect2(Vector2.ZERO, size), CdPalette.WELL)
		var on: bool = view.value_of("osc%s.on" % ["a", "b", "c"][part], 0.0) > 0.5
		var data: PackedFloat32Array = view.aux(0, 3 * 96)
		var mid := size.y * 0.5
		draw_line(Vector2(2, mid), Vector2(size.x - 2, mid), CdPalette.RULE_DARK, 1.0)
		if data.size() < (part + 1) * 96:
			return
		var pts := PackedVector2Array()
		for i in 96:
			pts.append(Vector2(2.0 + (size.x - 4.0) * float(i) / 95.0,
					mid - clampf(data[part * 96 + i], -1.2, 1.2) * size.y * 0.42))
		var col: Color = CdPalette.ACCENT if on else CdPalette.TEXT_MUTE
		# Shaded down to the centre line, a column at a time rather than as one
		# filled shape. A waveform crosses the middle over and over, so closing
		# the path back along it makes a polygon that crosses itself, and the
		# triangulator rejects the lot -- once per frame, per oscillator.
		var shade := Color(col.r, col.g, col.b, 0.16)
		for pt in pts:
			if absf(pt.y - mid) > 0.5:
				draw_line(Vector2(pt.x, mid), pt, shade, 1.6)
		draw_polyline(pts, col, 1.5, true)


class FilterView extends Control:
	var view

	func _draw() -> void:
		draw_rect(Rect2(Vector2.ZERO, size), CdPalette.WELL)
		for d in 3:
			var t := float(d + 1) / 4.0
			draw_line(Vector2(size.x * t, 2), Vector2(size.x * t, size.y - 2),
					CdPalette.RULE_DARK, 1.0)
		draw_line(Vector2(0, size.y * 0.5), Vector2(size.x, size.y * 0.5),
				CdPalette.RULE_DARK, 1.0)
		for f in 2:
			var pre := "filter%d." % (f + 1)
			var on: bool = view.value_of(pre + "on", 0.0) > 0.5
			var cut: float = view.value_of(pre + "cutoff", 1000.0)
			var res: float = view.value_of(pre + "reso", 0.2)
			var type := int(view.value_of(pre + "type", 0))
			# Two curves on one graph need telling apart at a glance.
			var col: Color = CdPalette.ACCENT if f == 0 else CdPalette.FOCUS
			col.a = 1.0 if on else 0.2
			var pts := PackedVector2Array()
			for x in 150:
				var t := float(x) / 149.0
				var hz: float = 20.0 * pow(1000.0, t)
				var db := _db(hz, cut, res, type)
				pts.append(Vector2(size.x * t,
						size.y * 0.5 - clampf(db, -34.0, 20.0) / 46.0 * size.y))
			if on:
				var fill := PackedVector2Array(pts)
				fill.append(Vector2(size.x, size.y))
				fill.append(Vector2(0.0, size.y))
				draw_colored_polygon(fill, Color(col.r, col.g, col.b, 0.10))
			draw_polyline(pts, col, 1.6, true)
			var mark: float = clampf(log(maxf(cut, 20.0) / 20.0) / log(1000.0), 0.0, 1.0)
			draw_line(Vector2(size.x * mark, 0), Vector2(size.x * mark, size.y),
					Color(col.r, col.g, col.b, 0.25 if on else 0.08), 1.0)
		var font := get_theme_default_font()
		draw_string(font, Vector2(4, size.y - 3), "20        200        2k        20k",
				HORIZONTAL_ALIGNMENT_LEFT, size.x, 8, CdPalette.TEXT_MUTE)

	## The right shape, not FLARE's own maths -- only FLARE has that, and a
	## curve is for reading at a glance.
	func _db(hz: float, cut: float, res: float, type: int) -> float:
		var ratio: float = hz / maxf(cut, 5.0)
		var oct: float = log(maxf(ratio, 0.0001)) / log(2.0)
		var bump: float = res * 22.0 * exp(-pow(oct / 0.42, 2.0))
		match type:
			0: return (-12.0 * oct if ratio > 1.0 else 0.0) + bump
			1, 2: return (-24.0 * oct if ratio > 1.0 else 0.0) + bump
			3: return (12.0 * oct if ratio < 1.0 else 0.0) + bump
			4: return (24.0 * oct if ratio < 1.0 else 0.0) + bump
			5, 6: return -12.0 * absf(oct) + bump
			7: return -45.0 * exp(-pow(oct / 0.16, 2.0))
			8: return bump
			11, 12: return 8.0 * cos(ratio * 3.0) * res
			15: return 0.0
			_: return bump


class EnvView extends Control:
	var view
	var which := 0

	static func new_for(n: int) -> EnvView:
		var e := EnvView.new()
		e.which = n
		return e

	func _draw() -> void:
		draw_rect(Rect2(Vector2.ZERO, size), CdPalette.WELL)
		var pre := "env%d." % (which + 1)
		var d: float = view.value_of(pre + "delay", 0.0)
		var a: float = view.value_of(pre + "attack", 5.0)
		var hold: float = view.value_of(pre + "hold", 0.0)
		var dec: float = view.value_of(pre + "decay", 300.0)
		var sus: float = view.value_of(pre + "sustain", 0.6)
		var rel: float = view.value_of(pre + "release", 200.0)
		var ac: float = view.value_of(pre + "atk_curve", 0.0)
		var dc: float = view.value_of(pre + "dec_curve", -0.4)
		var rc: float = view.value_of(pre + "rel_curve", -0.4)
		# A held stretch in the middle, so a patch with a long sustain still
		# shows its release rather than running off the side.
		var held: float = maxf(150.0, (d + a + hold + dec + rel) * 0.22)
		var total: float = maxf(1.0, d + a + hold + dec + held + rel)
		var pad := 4.0
		var top := 5.0
		var bot: float = size.y - 5.0
		var w: float = size.x - pad * 2.0
		var pts := PackedVector2Array()
		var x := pad
		pts.append(Vector2(x, bot))
		x += w * d / total
		pts.append(Vector2(x, bot))
		for i in 13:
			var t := float(i) / 12.0
			pts.append(Vector2(x + w * a / total * t, bot - (bot - top) * _shape(t, ac)))
		x += w * a / total
		x += w * hold / total
		pts.append(Vector2(x, top))
		for i in 13:
			var t := float(i) / 12.0
			var v: float = 1.0 + (sus - 1.0) * _shape(t, dc)
			pts.append(Vector2(x + w * dec / total * t, bot - (bot - top) * v))
		x += w * dec / total
		x += w * held / total
		pts.append(Vector2(x, bot - (bot - top) * sus))
		for i in 13:
			var t := float(i) / 12.0
			var v: float = sus * (1.0 - _shape(t, rc))
			pts.append(Vector2(x + w * rel / total * t, bot - (bot - top) * v))
		# Filled under the line, so the shape reads without being traced.
		var c: Color = CdPalette.ACCENT
		var tallest := 0.0
		for pt in pts:
			tallest = maxf(tallest, bot - pt.y)
		if tallest > 0.75:
			var fill := PackedVector2Array(pts)
			fill.append(Vector2(pts[pts.size() - 1].x, bot))
			fill.append(Vector2(pad, bot))
			draw_colored_polygon(fill, Color(c.r, c.g, c.b, 0.16))
		draw_polyline(pts, c, 1.6, true)

	func _shape(t: float, c: float) -> float:
		if c > 0.001:
			return pow(t, 1.0 + c * 3.0)
		if c < -0.001:
			return 1.0 - pow(1.0 - t, 1.0 - c * 3.0)
		return t


class LfoView extends Control:
	var view
	var which := 0

	static func new_for(n: int) -> LfoView:
		var l := LfoView.new()
		l.which = n
		return l

	func _draw() -> void:
		draw_rect(Rect2(Vector2.ZERO, size), CdPalette.WELL)
		var pre := "lfo%d." % (which + 1)
		var shape := int(view.value_of(pre + "shape", 0))
		var depth: float = view.value_of(pre + "depth", 1.0)
		var phase: float = view.value_of(pre + "phase", 0.0)
		var mid := size.y * 0.5
		draw_line(Vector2(0, mid), Vector2(size.x, mid), CdPalette.RULE_DARK, 1.0)
		var pts := PackedVector2Array()
		for i in 120:
			var t: float = fmod(float(i) / 119.0 * 2.0 + phase, 1.0)
			pts.append(Vector2(size.x * float(i) / 119.0,
					mid - _shape(shape, t, i) * depth * size.y * 0.4))
		draw_polyline(pts, CdPalette.ACCENT, 1.5, true)

	func _shape(kind: int, t: float, i: int) -> float:
		match kind:
			0: return sin(TAU * t)
			1: return 4.0 * absf(t - 0.5) - 1.0
			2: return t * 2.0 - 1.0
			3: return 1.0 - t * 2.0
			4: return 1.0 if t < 0.5 else -1.0
			5: return 1.0 if t < 0.25 else -1.0
			6, 7: return sin(TAU * floor(t * 8.0) / 8.0)
			8: return view.value_of("gate.step%d" % (int(t * 16.0) + 1), 1.0) * 2.0 - 1.0
			9: return pow(t, 3.0) * 2.0 - 1.0
			10: return pow(1.0 - t, 3.0) * 2.0 - 1.0
			11: return sin(TAU * t) * 0.6 + sin(TAU * t * 2.7) * 0.4
			_: return clampf((absf(t - 0.5) * 4.0 - 1.0) * 1.8, -1.0, 1.0)


class StepView extends Control:
	var view
	var _drag := false

	func _draw() -> void:
		draw_rect(Rect2(Vector2.ZERO, size), CdPalette.WELL)
		var w: float = size.x / 16.0
		for i in 16:
			var v: float = view.value_of("gate.step%d" % (i + 1), 1.0)
			var r := Rect2(i * w + 1.0, size.y * (1.0 - v), w - 2.0, size.y * v)
			var c: Color = CdPalette.ACCENT
			draw_rect(r, Color(c.r, c.g, c.b, 0.9 if i % 4 == 0 else 0.6))
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
		var i := clampi(int(p.x / (size.x / 16.0)), 0, 15)
		view.set_by_id("gate.step%d" % (i + 1), clampf(1.0 - p.y / size.y, 0.0, 1.0))
		queue_redraw()


class OutputMeter extends Control:
	var view
	var _l := 0.0
	var _r := 0.0

	func _draw() -> void:
		var a: PackedFloat32Array = view.aux(2, 2)
		var voices := int(a[0]) if a.size() > 0 else 0
		var peak: float = a[1] if a.size() > 1 else 0.0
		# Falls back slowly so a peak can be read, rather than flickering.
		_l = maxf(peak, _l * 0.88)
		var font := get_theme_default_font()
		draw_string(font, Vector2(0, 9), "OUT", HORIZONTAL_ALIGNMENT_LEFT, size.x, 8,
				CdPalette.TEXT_MUTE)
		draw_string(font, Vector2(0, 9), "%d voice%s" % [voices, "" if voices == 1 else "s"],
				HORIZONTAL_ALIGNMENT_RIGHT, size.x, 8, CdPalette.TEXT_MUTE)
		var bar := Rect2(0, 13, size.x, size.y - 16)
		draw_rect(bar, CdPalette.WELL)
		var t: float = clampf(sqrt(_l), 0.0, 1.0)
		if t > 0.001:
			var c: Color = CdPalette.METER_HIGH if t > 0.94 else CdPalette.METER_LOW
			draw_rect(Rect2(bar.position, Vector2(bar.size.x * t, bar.size.y)), c)
		# Marks at the quarters, so the bar says something rather than moving.
		for i in 3:
			var x: float = bar.position.x + bar.size.x * float(i + 1) * 0.25
			draw_line(Vector2(x, bar.position.y), Vector2(x, bar.end.y),
					CdPalette.WINDOW, 1.0)


## A modulation amount: drawn out from the middle, dragged left and right.
class BipolarBar extends Control:
	var view
	var index := -1
	var minimum := -1.0
	var maximum := 1.0
	var _drag := false

	func _draw() -> void:
		var v: float = view._value(index)
		draw_rect(Rect2(Vector2.ZERO, size), CdPalette.WELL)
		var mid: float = size.x * 0.5
		var span: float = maxf(0.0001, maxf(absf(minimum), absf(maximum)))
		var x: float = mid + (v / span) * (size.x * 0.5 - 1.0)
		if absf(v) > 0.0005:
			draw_rect(Rect2(Vector2(minf(mid, x), 2.0),
					Vector2(absf(x - mid), size.y - 4.0)), CdPalette.ACCENT)
		draw_line(Vector2(mid, 1.0), Vector2(mid, size.y - 1.0), CdPalette.RULE_LIGHT, 1.0)
		var font := get_theme_default_font()
		draw_string(font, Vector2(0, size.y - 4.0), view._text_of(index, v),
				HORIZONTAL_ALIGNMENT_CENTER, size.x, 8,
				CdPalette.TEXT if absf(v) > 0.0005 else CdPalette.TEXT_MUTE)

	func _gui_input(e: InputEvent) -> void:
		if e is InputEventMouseButton and e.button_index == MOUSE_BUTTON_LEFT:
			_drag = e.pressed
			if e.pressed:
				# Double click puts it back to nothing, like every other
				# control in the program.
				if e.double_click:
					view.set_by_id_index(index, 0.0)
				else:
					_set_from(e.position)
			accept_event()
		elif e is InputEventMouseMotion and _drag:
			_set_from(e.position)
			accept_event()

	func _set_from(p: Vector2) -> void:
		var span: float = maxf(0.0001, maxf(absf(minimum), absf(maximum)))
		var v: float = clampf((p.x - size.x * 0.5) / (size.x * 0.5) * span, minimum, maximum)
		view.set_by_id_index(index, v)
		queue_redraw()
