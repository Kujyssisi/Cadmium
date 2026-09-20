extends Window
## Preferences. The layout is settings_dialog.tscn; what goes in the drop-downs
## comes from the machine, so it is filled in here.

var _page := 0

const SCALES := [0.0, 1.0, 1.25, 1.5, 1.75, 2.0]
const AUTOSAVE_MINUTES := [0, 1, 5, 10, 15, 30]
const FRAME_RATES := [0, 60, 90, 120, 144, 240]
const SWATCHES := ["#e0483c", "#e8a33d", "#4a90d9", "#5fbf6f", "#b06fd0", "#d9d9d9", "#e05c9a"]
## Greys and near-greys for the rest of the interface: darker and lighter than
## the one it is drawn in, and a few with a little colour in them.
## Where the master ceiling can sit. Right at the top for people who want the
## last decibel, and lower for anyone mixing on headphones at night.
const CEILINGS := [-0.1, -0.3, -1.0, -3.0, -6.0, -12.0]
## How much the machine's audio input is turned up on its way in. A quiet
## dynamic microphone wants a lot; an interface with a preamp in it wants none.
const INPUT_GAINS := [0.0, 3.0, 6.0, 12.0, 18.0, 24.0, -6.0, -12.0]
const SECOND_SWATCHES := ["#2f2f2f", "#454545", "#5a5a5a", "#3d444d", "#453f4d", "#3f4a42",
	"#4d453d", "#6a6a6a"]

@onready var _tabs: TabContainer = $Root/Tabs
@onready var _devices: ItemList = $Root/Tabs/General/Devices
@onready var _picker: ColorPickerButton = $Root/Tabs/Appearance/ColourRow/Picker


func configure(args: Dictionary) -> void:
	_page = int(args.get("page", 0))


func _ready() -> void:
	# A window is sized in pixels but laid out in scaled units.
	var sc := Settings.ui_scale()
	content_scale_factor = sc
	size = Vector2i(int(660.0 * sc), int(560.0 * sc))
	close_requested.connect(queue_free)
	_general()
	_appearance()
	_addons()
	_folders()
	_audio()
	_tidy_pages()
	_tabs.current_tab = clampi(_page, 0, _tabs.get_tab_count() - 1)
	# Sized in scaled units, so at a large interface scale the window can come
	# out taller than the display it is opening on.
	Cd.place_window(self, self)


## Every page goes in a scroll and every row is lined up on one column: a label
## of a fixed width, then the control filling the rest. Without the scroll a
## tall page at a large interface scale simply ran off the bottom of the window
## with no way to reach it, and without the column the drop-downs started at
## whatever width their longest entry happened to be.
func _tidy_pages() -> void:
	var pages := []
	for child in _tabs.get_children():
		if child is Control and not (child is ScrollContainer):
			pages.append(child)
	for i in pages.size():
		var page: Control = pages[i]
		_line_up(page)
		var tab_name := page.name
		page.name = "%sBody" % tab_name
		var scroll := ScrollContainer.new()
		scroll.name = tab_name
		scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
		_tabs.remove_child(page)
		_tabs.add_child(scroll)
		_tabs.move_child(scroll, i)
		scroll.add_child(page)
		page.size_flags_horizontal = Control.SIZE_EXPAND_FILL


## One column of labels, one of controls.
func _line_up(page: Control) -> void:
	for row in page.get_children():
		if not (row is HBoxContainer) or row.get_child_count() < 2:
			continue
		var first: Node = row.get_child(0)
		if first is Label:
			(first as Label).custom_minimum_size.x = 170.0
			(first as Label).size_flags_vertical = Control.SIZE_SHRINK_CENTER
		var last: Node = row.get_child(row.get_child_count() - 1)
		if last is Control and not (last is Label):
			(last as Control).size_flags_horizontal = Control.SIZE_EXPAND_FILL


func _general() -> void:
	var scale: OptionButton = $Root/Tabs/General/ScaleRow/Scale
	scale.add_item("Follow desktop (%.2fx)" % Settings.ui_scale())
	for i in range(1, SCALES.size()):
		scale.add_item("%.2fx" % SCALES[i])
	_select(scale, SCALES, Settings.get_value("scale", 0.0))
	scale.item_selected.connect(func(i):
		Settings.set_value("scale", SCALES[i])
		App.status.emit("Interface scale applies when Cadmium restarts"))

	var auto: OptionButton = $Root/Tabs/General/AutosaveRow/Autosave
	for m in AUTOSAVE_MINUTES:
		auto.add_item("Off" if m == 0 else ("Every minute" if m == 1 else "Every %d minutes" % m))
	_select(auto, AUTOSAVE_MINUTES, Settings.get_value("autosave_minutes", 5))
	auto.item_selected.connect(func(i):
		Settings.set_value("autosave_minutes", AUTOSAVE_MINUTES[i])
		App.status.emit("Autosave off" if AUTOSAVE_MINUTES[i] == 0
				else "Autosave every %d minute%s" % [AUTOSAVE_MINUTES[i],
						"" if AUTOSAVE_MINUTES[i] == 1 else "s"]))

	var fps: OptionButton = $Root/Tabs/General/FpsRow/Fps
	for r in FRAME_RATES:
		fps.add_item("As fast as the display" if r == 0 else "%d per second" % r)
	_select(fps, FRAME_RATES, Settings.get_value("max_fps", 120))
	fps.item_selected.connect(func(i):
		Settings.set_value("max_fps", FRAME_RATES[i])
		Engine.max_fps = FRAME_RATES[i]
		App.status.emit("Frame rate limit %s" % ("off" if FRAME_RATES[i] == 0
				else str(FRAME_RATES[i]))))

	# The machine's audio input: which device, and how much of it. The device
	# is not opened here -- it is opened when a mixer strip asks for it -- so
	# changing this while nothing is listening costs nothing.
	var device: OptionButton = $Root/Tabs/General/InputRow/Device
	var names := Audio.input_devices()
	for n in names:
		device.add_item(String(n))
	var want := Audio.input_device()
	if want.is_empty():
		want = "Default"
	for i in device.item_count:
		if device.get_item_text(i) == want:
			device.select(i)
	if device.item_count == 0:
		device.add_item("(no audio inputs found)")
		device.disabled = true
	Cd.compact(device, "OptionButton", 4.0)
	device.item_selected.connect(func(i):
		Audio.set_input_device(device.get_item_text(i))
		App.status.emit("Audio input: %s" % device.get_item_text(i)))

	var gain: OptionButton = $Root/Tabs/General/InputGainRow/InputGain
	for db in INPUT_GAINS:
		gain.add_item("%+.0f dB" % db if db != 0.0 else "0 dB")
	_select(gain, INPUT_GAINS, Cd.gain_to_db(float(Settings.get_value("input_gain", 1.0))))
	Cd.compact(gain, "OptionButton", 4.0)
	gain.item_selected.connect(func(i):
		Settings.set_value("input_gain", Cd.db_to_gain(INPUT_GAINS[i]))
		App.push_input()
		App.status.emit("Input gain %+.0f dB" % INPUT_GAINS[i]))

	var midi: CheckBox = $Root/Tabs/General/Midi
	midi.button_pressed = bool(Settings.get_value("midi_input", true))
	midi.toggled.connect(func(on):
		Settings.set_value("midi_input", on)
		if on:
			if Audio.engine.midi_open():
				var n: int = Audio.engine.midi_connect_all()
				App.status.emit("Connected %d MIDI input%s" % [n, "" if n == 1 else "s"])
		else:
			Audio.engine.midi_close())

	var follow: CheckBox = $Root/Tabs/General/Follow
	follow.button_pressed = bool(Settings.get_value("follow_playhead", true))
	follow.toggled.connect(func(on): Settings.set_value("follow_playhead", on))

	var limiter: CheckBox = $Root/Tabs/General/LimiterRow/Limiter
	var ceiling: OptionButton = $Root/Tabs/General/LimiterRow/Ceiling
	limiter.button_pressed = bool(Settings.get_value("limiter", true))
	for db in CEILINGS:
		ceiling.add_item("%.1f dB" % db)
	_select(ceiling, CEILINGS, float(Settings.get_value("limiter_ceiling", -1.0)))
	Cd.compact(ceiling, "OptionButton", 4.0)
	limiter.toggled.connect(func(on):
		Settings.set_value("limiter", on)
		Audio.apply_limiter()
		App.status.emit("The master ceiling is %s" % ("on" if on else "off")))
	ceiling.item_selected.connect(func(i):
		Settings.set_value("limiter_ceiling", CEILINGS[i])
		Audio.apply_limiter())

	var by_pos: CheckBox = $Root/Tabs/General/ByPosition
	by_pos.button_pressed = bool(Settings.get_value("piano_by_position", true))
	by_pos.toggled.connect(func(on):
		Settings.set_value("piano_by_position", on)
		App.status.emit("The typing keyboard plays by %s"
				% ("where the keys are" if on else "the letters on them")))
	($Root/Tabs/General/Layout as Label).text = "Keyboard: %s" % _layout_name()

	_fill_devices()
	var reconnect: Button = $Root/Tabs/General/Reconnect
	reconnect.icon = Icons.get_icon("midi", 14)
	reconnect.pressed.connect(func():
		Audio.engine.midi_open()
		var n: int = Audio.engine.midi_connect_all()
		App.status.emit("Connected %d MIDI input%s" % [n, "" if n == 1 else "s"])
		_fill_devices())


## What the system says the keyboard is, so it is clear which layout the
## setting above is being applied to.
func _layout_name() -> String:
	var n := DisplayServer.keyboard_get_layout_count()
	if n <= 0:
		return "unknown"
	var i := DisplayServer.keyboard_get_current_layout()
	if i < 0 or i >= n:
		return "unknown"
	var name := DisplayServer.keyboard_get_layout_name(i)
	var code := DisplayServer.keyboard_get_layout_language(i)
	if name.is_empty():
		return code if not code.is_empty() else "unknown"
	return "%s (%s)" % [name, code] if not code.is_empty() else name


func _fill_devices() -> void:
	_devices.clear()
	for d in Audio.midi_devices():
		_devices.add_item("%s  (%d:%d)" % [String(d.name), int(d.client), int(d.port)])
	if _devices.item_count == 0:
		_devices.add_item("(no MIDI sources found)")


func _appearance() -> void:
	_picker.color = CdPalette.ACCENT
	_picker.color_changed.connect(func(c): Accent.apply_soon(c))
	($Root/Tabs/Appearance/ColourRow/Reset as Button).pressed.connect(func():
		Accent.apply(CdPalette.ACCENT_DEFAULT)
		_picker.color = CdPalette.ACCENT_DEFAULT)
	# The swatches are a palette, not a layout: one button per colour.
	var flow: HFlowContainer = $Root/Tabs/Appearance/Swatches
	for hex in SWATCHES:
		var b := Button.new()
		b.custom_minimum_size = Vector2(28, 22)
		b.focus_mode = Control.FOCUS_NONE
		var sb := StyleBoxFlat.new()
		sb.bg_color = Color(hex)
		b.add_theme_stylebox_override("normal", sb)
		b.add_theme_stylebox_override("hover", sb)
		b.pressed.connect(func():
			Accent.apply(Color(hex))
			_picker.color = Color(hex))
		flow.add_child(b)

	# The other half: everything that is not the accent. Greys in the theme,
	# the panels Cadmium draws itself, and the neutral inks in the icons.
	var second: ColorPickerButton = $Root/Tabs/Appearance/SecondRow/Picker
	second.color = CdPalette.SECONDARY
	second.color_changed.connect(func(c): Secondary.apply_soon(c))
	($Root/Tabs/Appearance/SecondRow/Reset as Button).pressed.connect(func():
		Secondary.apply(CdPalette.SECONDARY_DEFAULT)
		second.color = CdPalette.SECONDARY_DEFAULT)
	var flow2: HFlowContainer = $Root/Tabs/Appearance/SecondSwatches
	for hex in SECOND_SWATCHES:
		var b2 := Button.new()
		b2.custom_minimum_size = Vector2(28, 22)
		b2.focus_mode = Control.FOCUS_NONE
		var sb2 := StyleBoxFlat.new()
		sb2.bg_color = Color(hex)
		b2.add_theme_stylebox_override("normal", sb2)
		b2.add_theme_stylebox_override("hover", sb2)
		b2.pressed.connect(func():
			Secondary.apply(Color(hex))
			second.color = Color(hex))
		flow2.add_child(b2)


## One row per add-on: what it is called, what it does, and whether it is on.
func _addons() -> void:
	var list: VBoxContainer = $"Root/Tabs/Add-ons/List"
	for c in list.get_children():
		c.queue_free()
	for e in Addons.list:
		var box := VBoxContainer.new()
		box.add_theme_constant_override("separation", 0)
		var on := CheckBox.new()
		on.text = "%s%s" % [String(e.name), "" if bool(e.built_in) else "  (yours)"]
		on.button_pressed = bool(e.enabled)
		on.focus_mode = Control.FOCUS_NONE
		on.toggled.connect(func(v): Addons.set_enabled(String(e.id), v))
		box.add_child(on)
		if not String(e.description).is_empty():
			var note := Label.new()
			note.text = String(e.description)
			note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			note.theme_type_variation = "MuteLabel"
			box.add_child(note)
		list.add_child(box)
	if Addons.list.is_empty():
		var none := Label.new()
		none.text = "Nothing installed."
		none.theme_type_variation = "MuteLabel"
		list.add_child(none)
	($"Root/Tabs/Add-ons/Row/Folder" as Button).pressed.connect(func():
		var dir := ProjectSettings.globalize_path(Addons.USER_DIR)
		DirAccess.make_dir_recursive_absolute(dir)
		OS.shell_open(dir))
	($"Root/Tabs/Add-ons/Row/Reload" as Button).pressed.connect(func():
		Addons.reload()
		_addons()
		App.status.emit("%d add-on%s" % [Addons.list.size(),
				"" if Addons.list.size() == 1 else "s"]))


func _folders() -> void:
	$Root/Tabs/Folders/Vst3.bind("VST3 plugin folders", "vst3_dirs",
			"Scanned when you press Rescan. %s are always searched."
			% ", ".join(Array(Plugins.vst3_dirs())))
	$Root/Tabs/Folders/SoundFonts.bind("SoundFont folders", "sf2_dirs",
			"Where .sf2 files are looked for.")
	$Root/Tabs/Folders/Samples.bind("Sample folders", "sample_dirs",
			"Searched three levels deep for audio files.")


func _audio() -> void:
	var lat: int = int(ProjectSettings.get_setting("audio/driver/output_latency", 15))
	($Root/Tabs/Audio/Info as Label).text = \
			"Output: %s at %d Hz, %s ms buffer target.\nMixer tracks: %d.  Stock processors: %d." % [
			AudioServer.get_output_device(), int(Audio.engine.sample_rate()), str(lat),
			App.project.mixer.size(), Plugins.stock.size()]

	var opt: OptionButton = $Root/Tabs/Audio/DeviceRow/Device
	var list := AudioServer.get_output_device_list()
	for i in list.size():
		opt.add_item(String(list[i]))
		if String(list[i]) == AudioServer.get_output_device():
			opt.select(i)
	opt.item_selected.connect(func(i):
		AudioServer.set_output_device(String(list[i]))
		App.status.emit("Output device: %s" % list[i]))

	var scan: Button = $Root/Tabs/Audio/Rescan
	scan.icon = Icons.get_icon("vst", 14)
	scan.pressed.connect(func():
		var n: int = await Plugins.rescan_vst3()
		App.status.emit("Found %d VST3 plugin%s" % [n, "" if n == 1 else "s"]))


## Picks the entry whose value matches what is saved.
func _select(opt: OptionButton, values: Array, current) -> void:
	for i in values.size():
		if typeof(values[i]) == TYPE_FLOAT:
			if is_equal_approx(float(values[i]), float(current)):
				opt.select(i)
		elif int(values[i]) == int(current):
			opt.select(i)
