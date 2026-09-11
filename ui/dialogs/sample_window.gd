class_name CdSampleWindow
extends Window
## The sampler for one sample in the project.
##
## This is FL's audio clip channel: what the file is, what to do to it once
## (reverse it, normalise it, take the silence off the ends), how to stretch
## it, and how loud and how wide it sits. What it deliberately does not have is
## the playback section -- start point, loop points, envelope -- because those
## belong to a sampler being played from the piano roll, not to a clip that is
## simply a piece of audio on the timeline. The sampler instrument has both.
##
## Every control here is one entry in the same list the engine takes, so a
## setting cannot be shown in one place and stored under another name.

## The knobs, in the order they appear. {key, label, min, max, kind, section}
const KNOBS := [
	{"key": "pitch", "label": "PITCH", "min": -24.0, "max": 24.0, "kind": Cd.ParamKind.SEMI,
		"section": "stretch"},
	{"key": "stretch", "label": "MUL", "min": 0.25, "max": 4.0, "kind": Cd.ParamKind.FLOAT,
		"section": "stretch"},
	{"key": "start", "label": "SMP START", "min": 0.0, "max": 0.99, "kind": Cd.ParamKind.PCT,
		"section": "effects"},
	{"key": "length", "label": "LENGTH", "min": 0.01, "max": 1.0, "kind": Cd.ParamKind.PCT,
		"section": "effects"},
	{"key": "fade_in", "label": "IN", "min": 0.0, "max": 2.0, "kind": Cd.ParamKind.SEC,
		"section": "effects"},
	{"key": "fade_out", "label": "OUT", "min": 0.0, "max": 2.0, "kind": Cd.ParamKind.SEC,
		"section": "effects"},
	{"key": "trim_db", "label": "TRIM", "min": -100.0, "max": -20.0, "kind": Cd.ParamKind.DB,
		"section": "effects"},
	{"key": "gain", "label": "VOL", "min": 0.0, "max": 2.0, "kind": Cd.ParamKind.PCT,
		"section": "levels"},
	{"key": "pan", "label": "PAN", "min": -1.0, "max": 1.0, "kind": Cd.ParamKind.PCT,
		"section": "levels"},
]
const SWITCHES := [
	{"key": "remove_dc", "label": "Remove DC offset"},
	{"key": "polarity", "label": "Reverse polarity"},
	{"key": "normalize", "label": "Normalise"},
	{"key": "fade_stereo", "label": "Fade stereo"},
	{"key": "reverse", "label": "Reverse"},
	{"key": "swap_stereo", "label": "Swap stereo"},
]
## What each stretching mode does with the two knobs above it.
const MODES := ["Resample", "Stretch", "Pitch", "Off"]
const MODE_HELP := [
	"Speed and pitch together, the way a record plays faster.",
	"Longer or shorter, at the pitch it was.",
	"Higher or lower, as long as it was.",
	"Played exactly as it is.",
]

var asset := -1

var _knobs := {}
var _switches := {}
var _peaks: PackedFloat32Array = PackedFloat32Array()

@onready var _file: Label = $Root/Col/Head/File
@onready var _mode: OptionButton = $Root/Col/Stretch/StretchCol/Row/ModeCol/Mode
@onready var _mixer: OptionButton = $Root/Col/Head/Mixer
@onready var _view: Control = $Root/Col/Wave/View
@onready var _note: Label = $Root/Col/Foot/Note


func configure(args: Dictionary) -> void:
	asset = int(args.get("asset", -1))


func _ready() -> void:
	var sc := Settings.ui_scale()
	content_scale_factor = sc
	size = Vector2i(int(560.0 * sc), int(470.0 * sc))
	close_requested.connect(queue_free)
	($Root/Col/Foot/Close as Button).pressed.connect(queue_free)
	($Root/Col/Foot/Reset as Button).pressed.connect(_reset)
	($Root/Col/Head/Replace as Button).pressed.connect(_replace)

	var boxes := {
		"stretch": $Root/Col/Stretch/StretchCol/Row/Knobs,
		"effects": $Root/Col/Effects/EffectsCol/Knobs,
		"levels": $Root/Col/Levels,
	}
	for entry in KNOBS:
		var k := CdKnob.new()
		k.label = String(entry.label)
		k.minimum = float(entry.min)
		k.maximum = float(entry.max)
		k.kind = int(entry.kind)
		k.knob_size = 26.0
		k.custom_minimum_size = Vector2(52, 52)
		if AUTO_OF.has(String(entry.key)):
			# Level and position are the very thing the automation moves, so
			# they follow it. Pitch and the multiplier are automated as
			# playback speed instead, so they light up but stay where set.
			k.auto_ref = {"target": int(AUTO_OF[String(entry.key)]), "ref": {}, "a": asset,
					"b": 0, "follow": String(entry.key) in ["gain", "pan"]}
		k.value_changed.connect(func(v): _change(String(entry.key), v))
		k.edit_finished.connect(func(): App.project.dirty = true)
		k.menu_requested.connect(func(_at): _knob_menu(String(entry.key), String(entry.label), k))
		boxes[String(entry.section)].add_child(k)
		_knobs[String(entry.key)] = k
	for entry in SWITCHES:
		var b := CheckBox.new()
		b.text = String(entry.label)
		b.focus_mode = Control.FOCUS_NONE
		b.toggled.connect(func(on): _change(String(entry.key), on, "Sample %s" % String(entry.label)))
		$Root/Col/Effects/EffectsCol/Switches.add_child(b)
		_switches[String(entry.key)] = b
	for i in MODES.size():
		_mode.add_item(MODES[i])
	Cd.compact(_mode, "OptionButton", 4.0)
	_fill_mixer()
	Cd.compact(_mixer, "OptionButton", 4.0)
	_mixer.item_selected.connect(func(i):
		_change("mixer", int(_mixer.get_item_id(i)), "Sample mixer track"))
	_mode.item_selected.connect(func(i):
		_change("mode", i, "Stretch mode")
		_note.text = MODE_HELP[i])
	_view.draw.connect(_draw_wave)
	App.playlist_changed.connect(_refresh)
	_refresh()


## A window of its own has an input tree of its own, and a window full of
## controls has something focused nearly always -- which eats Space before
## anything else is asked. Handing every key to the shortcuts means the
## transport still works with the sampler in front, exactly as it does with a
## plugin's window in front.
func _input(event: InputEvent) -> void:
	Shortcuts.feed(event, get_viewport())


func _settings() -> Dictionary:
	return App.sample_settings(asset)


func _change(key: String, value, label: String = "") -> void:
	App.set_sample_setting(asset, key, value, label)
	if AUTO_OF.has(key):
		App.note_tweak(int(AUTO_OF[key]), {}, asset, 0)
	_refresh_wave()


## The two that can be automated: what a sample plays at, and where it sits.
## The rest change the file itself and are decided once, not over time.
## What each knob offers to automate. Level and position move the sample as it
## is; pitch and the stretch multiplier are automated as playback speed --
## faster and higher, the way a record does it -- because the stretching modes
## are worked into the audio itself and cannot be redone a hundred times a
## second. The rest change the file and are decided once.
const AUTO_OF := {"gain": Cd.AutoTarget.SAMPLE_VOL, "pan": Cd.AutoTarget.SAMPLE_PAN,
		"pitch": Cd.AutoTarget.SAMPLE_PITCH, "stretch": Cd.AutoTarget.SAMPLE_SPEED}


func _knob_menu(key: String, label: String, k: CdKnob) -> void:
	var pm := PopupMenu.new()
	add_child(pm)
	if AUTO_OF.has(key):
		pm.add_item("Create automation clip", 0)
		pm.add_separator()
	pm.add_item("Reset", 1)
	pm.id_pressed.connect(func(id):
		if id == 0:
			App.automate(int(AUTO_OF[key]), {}, asset, 0)
		else:
			var fresh: Dictionary = App.default_sample_settings()
			_change(key, fresh.get(key, 0.0), "Reset %s" % label)
			_refresh()
		pm.queue_free())
	pm.popup_hide.connect(func(): pm.queue_free(), CONNECT_DEFERRED)
	pm.popup(Rect2i(DisplayServer.mouse_get_position(), Vector2i(1, 1)))


func _refresh() -> void:
	if asset < 0 or asset >= App.project.assets.size():
		queue_free()
		return
	var a: Dictionary = App.project.assets[asset]
	title = "Sampler - %s" % String(a.get("name", "sample"))
	_file.text = String(a.get("name", ""))
	_file.tooltip_text = String(a.get("path", ""))
	var s := _settings()
	for key in _knobs.keys():
		(_knobs[key] as CdKnob).set_value_silent(float(s.get(key, 0.0)))
	for key in _switches.keys():
		(_switches[key] as CheckBox).set_pressed_no_signal(bool(s.get(key, false)))
	_mode.select(clampi(int(s.get("mode", 0)), 0, MODES.size() - 1))
	var want := int(s.get("mixer", -1))
	for i in _mixer.item_count:
		if _mixer.get_item_id(i) == want:
			_mixer.select(i)
			break
	_note.text = MODE_HELP[_mode.selected]
	_refresh_wave()


## Which mixer track the sample plays through.
##
## A sample used to go wherever its clip's own playlist track pointed, which
## meant the only way to put a filter on one was to move the clip. Naming the
## track here instead is how a sample gets an effect chain of its own, and how
## two clips of the same sample on different tracks still land on it.
##
## "As the track says" keeps the old behaviour, and is still the default.
func _fill_mixer() -> void:
	_mixer.clear()
	_mixer.add_item("As the track says")
	_mixer.set_item_id(0, -1)
	for i in App.project.mixer.size():
		var t: Dictionary = App.project.mixer[i]
		var nm := String(t.get("name", ""))
		if nm.is_empty():
			nm = "Master" if i == 0 else "Track %d" % i
		_mixer.add_item(nm)
		_mixer.set_item_id(_mixer.item_count - 1, i)


## The picture is of what is played, not of what is on disk: reverse a sample
## and the drawing turns round with it.
func _refresh_wave() -> void:
	_peaks = Audio.engine.asset_peaks_range(asset, 0.0, 1.0, 320)
	_view.queue_redraw()


func _draw_wave() -> void:
	var r := Rect2(Vector2.ZERO, _view.size)
	_view.draw_rect(r, CdPalette.VIEWPORT)
	var pairs: int = _peaks.size() / 2
	if pairs < 2:
		return
	var mid := r.size.y * 0.5
	var lines := PackedVector2Array()
	for i in pairs:
		var x: float = r.size.x * (float(i) + 0.5) / float(pairs)
		lines.append(Vector2(x, mid - _peaks[i * 2 + 1] * mid * 0.95))
		lines.append(Vector2(x, mid - _peaks[i * 2] * mid * 0.95))
	_view.draw_multiline(lines, CdPalette.ACCENT)
	_view.draw_line(Vector2(0, mid), Vector2(r.size.x, mid), CdPalette.RULE_DARK, 1.0)
	var secs := float(Audio.engine.asset_seconds(asset))
	_view.draw_string(get_theme_default_font(), Vector2(6, r.size.y - 6),
			"%.2f s" % secs, HORIZONTAL_ALIGNMENT_LEFT, r.size.x, 9, CdPalette.TEXT_MUTE)


func _reset() -> void:
	App.snapshot("Reset sample")
	var fresh := App.default_sample_settings()
	# One key at a time through the same door as the knobs: the clips that play
	# it are refitted and everything drawing it is told, which a quiet write
	# into the dictionary would not do.
	for key in fresh.keys():
		App.set_sample_setting(asset, key, fresh[key])
	_refresh()


## The same clips, playing a different file. What the sample is set to stays as
## it is: replacing a take with another take of the same thing should not throw
## away the work done on it.
func _replace() -> void:
	var fd := FileDialog.new()
	fd.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	fd.access = FileDialog.ACCESS_FILESYSTEM
	fd.use_native_dialog = DisplayServer.has_feature(DisplayServer.FEATURE_NATIVE_DIALOG_FILE)
	var filters := PackedStringArray()
	for ext in Cd.AUDIO_EXTS:
		filters.append("*.%s" % ext)
	fd.filters = PackedStringArray(["%s ; Audio" % " , ".join(filters)])
	add_child(fd)
	fd.file_selected.connect(func(path):
		if App.replace_asset(asset, String(path)):
			App.status.emit("%s now plays %s" % [String(App.project.assets[asset].name),
					String(path).get_file()])
		_refresh()
		fd.queue_free())
	fd.canceled.connect(func(): fd.queue_free())
	fd.popup_centered(Vector2i(880, 600))


## One call from anywhere: `CdSampleWindow.open(self, index)`.
static func open(host: Node, index: int) -> Window:
	for w in host.get_tree().root.get_children():
		if w is CdSampleWindow and (w as CdSampleWindow).asset == index:
			w.grab_focus()
			return w
	var win = preload("res://ui/dialogs/sample_window.tscn").instantiate()
	win.asset = index
	host.get_tree().root.add_child(win)
	win.show()
	Cd.place_window(win, host)
	win.grab_focus()
	return win
