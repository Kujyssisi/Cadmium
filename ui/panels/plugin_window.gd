extends Window
## One floating window per open plugin -- stock or hosted.
##
## The controls are built from the descriptor the engine reports, so a VST3 with
## 400 parameters and Cadmium's own synths go through exactly the same path;
## only the extra panels on top (EQ curve, sampler waveform, soundfont presets)
## are per-plugin.

var ref := {}
var _params: Array = []
var _knobs := {}
var _info := {}
var _custom: Control
var _vst3 := false
## The plugin draws its own interface, whether it is hosted or one of ours.
var _has_editor := false
var _poll := 0.0
## True when the hosted view refuses to be resized; the window then holds the
## size the view asked for instead of the window manager doing it for us.
var _fixed_editor := false
## The one size that view draws at.
var _fixed_size := Vector2i.ZERO
var _filter := ""

## Above this many parameters the panel filters instead of drawing everything:
## Vital publishes 2855, and a wall of that many knobs is not a user interface.
const FILTER_THRESHOLD := 48
## Building a wall of knobs costs a frame hitch and reading it costs longer.
## The filter box above them is how you reach the rest.
const MAX_CONTROLS := 96
## Height of Cadmium's own strip above an embedded plugin editor.
const TOOLBAR_H := 30.0
## How long a resize of our own is left alone before window size changes count
## as the user dragging the corner again.
const SETTLE_MS := 400

@onready var _header_panel: PanelContainer = $Root/Col/Header
@onready var _bypass: Button = $Root/Col/Header/Row/Bypass
@onready var _wet: CdKnob = $Root/Col/Header/Row/Wet
@onready var _ui_toggle: CheckBox = $Root/Col/Header/Row/PluginUi
@onready var _typing: CheckBox = $Root/Col/Header/Row/Typing
@onready var _preset_menu: MenuButton = $Root/Col/Header/Row/Preset
@onready var _hole: Control = $Root/Col/Hole
@onready var _busy: Control = $Root/Col/Hole/Busy
@onready var _busy_label: Label = $Root/Col/Hole/Busy/Box/Label
@onready var _again: Button = $Root/Col/Hole/Busy/Box/Again
@onready var _spin: Control = $Root/Col/Hole/Busy/Box/Spin
@onready var _scroll: ScrollContainer = $Root/Col/Scroll
@onready var _body: VBoxContainer = $Root/Col/Scroll/Body
@onready var _filter_row: HBoxContainer = $Root/Col/FilterRow
@onready var _filter_field: LineEdit = $Root/Col/FilterRow/Field
@onready var _count_label: Label = $Root/Col/FilterRow/Count
@onready var _keys = $Root/Col/Keys

var _native := false          ## the plugin is drawing its own interface
var _native_available := false
var _attached := false
## The size we last asked for ourselves. A window resize is reported back
## asynchronously -- the compositor answers a frame or more later -- so a plain
## "I am busy applying a size" flag is already false by the time the report
## arrives, and the report gets mistaken for the user dragging the corner. That
## turned into a feedback loop: tell the plugin the window size, plugin asks for
## a size, resize the window, tell the plugin the window size... with the window
## losing the height of Cadmium's own strip on every lap.
var _expected_size := Vector2i.ZERO
var _applying_size := false
## When our own resize stops counting as the user dragging the corner. The
## window manager reports a resize back a frame or more after it is asked for,
## and comparing sizes is not enough: a plugin that adjusts what it was given
## produces a different size than the one we asked for, and the difference then
## feeds another round.
var _settle_until := 0
var _had_focus := false
## The engine handle this window was opened on. Kept so the window can be shut
## the moment that plugin is destroyed, whatever happens to the numbering of
## the slots afterwards.
var handle := -1
## Off: Cadmium keeps the keyboard, so the typing keys still play notes while a
## plugin window is in front. On: the plugin's own window takes the keyboard,
## for typing into its preset search and value boxes.
var _keys_to_plugin := false
var _resize_pending := false
## While a hosted editor is building itself. Its canvas is a window of the
## operating system's and is drawn over anything Cadmium paints, so it is
## parked outside this window until it has something to show; what is on
## screen in the meantime is the spinner.
## How long the pointer has been off the plugin's canvas. The keyboard is only
## taken back after it has been away for a moment, so passing over the toolbar
## on the way somewhere else does not interrupt what the plugin is doing.
var _away_since := 0
const AWAY_BEFORE_KEYS := 350
var _waiting_until := 0
var _attach_tries := 0
## One line of geometry per window, not one per frame. See _note_geometry().
var _noted := false
## How long a plugin gets to build its interface before it is attached again
## from scratch -- some plugins produce nothing at all on the first attach and
## work perfectly on the second, which is why "open it twice" was the way to
## make certain plugins appear.
## A big sample-library instrument can take seconds to build its interface, and
## detaching one that is busy doing it is how a slow plugin turns into a broken
## one. Only a plugin that has produced nothing at all is attached again, and
## it is given a good while first.
const ATTACH_RETRY_MS := 2500
const ATTACH_TRIES := 3
## Long enough for three goes at it, plus the time to notice the third failed.
## And how long before whatever it has managed is shown anyway. A plugin that
## draws into the container itself, without a window of its own, never reports
## as ready and must not be hidden forever.
const ATTACH_GIVE_UP_MS := 9000


func setup(r: Dictionary) -> void:
	ref = r
	handle = App.handle_for(r)
	# Opening a plugin's own interface is the other half of what a host does
	# that can take it down; the report should say which one it was.
	var opening = App.plugin_for(r)
	CdCrash.note("opening the interface of %s"
			% (String(opening.get("name", "a plugin")) if opening != null else "a plugin"))
	_info = App.plugin_info(ref)
	_params = App.plugin_params(ref)
	var plug = App.plugin_for(ref)
	_vst3 = plug != null and String(plug.get("kind", "stock")) == "vst3"
	var pname := String(plug.get("name", "Plugin"))
	var where := _where()
	title = pname if where == pname else "%s - %s" % [pname, where]
	# An un-embedded sub-window does not inherit the parent's content scale.
	content_scale_factor = Settings.ui_scale()
	unresizable = false
	size = _generic_size()
	transient = true
	exclusive = false
	# Not "is it a VST3": is it a plugin that draws its own window. A plugin
	# out of the plugin folder does that too, and the window that shows one
	# should not care which kind it is holding.
	_has_editor = App.engine().plugin_has_editor(App.handle_for(ref))
	_native_available = _has_editor and _can_embed()
	var plug2 = App.plugin_for(ref)
	_native = _native_available and bool(plug2.get("native_ui", true)) if plug2 != null else false
	if _native:
		# Before anything asks the plugin how big it is. Asking is what makes
		# the plugin build its view, and a view built without being told the
		# display is scaled works its size out for a hundred percent and then
		# draws for a hundred and fifty -- an interface at the wrong scale with
		# most of it off the edge of the window it was given.
		var scale0 := _display_scale()
		if scale0 > 1.01:
			App.engine().plugin_editor_set_scale(App.handle_for(ref), scale0)
		var es: Vector2i = App.engine().plugin_editor_size(App.handle_for(ref))
		if es.x > 32 and es.y > 32:
			es = _fit(es.x, es.y)
			size = Vector2i(es.x, es.y + int(TOOLBAR_H * content_scale_factor))
	_build()
	popup_centered()
	CdCrash.note("")
	# A plugin Cadmium is refusing to open gets an explanation rather than an
	# empty panel with no name on it.
	var refused := _refused_note()
	if not refused.is_empty():
		_show_refused(refused)
	_free_running()
	set_process(true)
	if _native:
		_attach_editor.call_deferred()


## Embedding puts the plugin's own window inside ours, which needs a windowing
## system we can parent into: X11 (XWayland included) or Windows. On anything
## else the generic panel is the only option, and saying so beats attaching to a
## handle that means something entirely different.
## How many pixels the display puts in a point. One on an ordinary monitor, two
## on a retina one, and whatever the user picked on Windows.
func _display_scale() -> float:
	var screen := get_window().current_screen if is_inside_tree() else 0
	var s := float(DisplayServer.screen_get_scale(screen))
	if s <= 0.0:
		s = 1.0
	if DisplayServer.get_name().to_lower() == "windows":
		# Windows reports the setting as dots per inch against a hundred percent
		# of ninety six.
		var dpi := float(DisplayServer.screen_get_dpi(screen))
		if dpi > 48.0:
			s = maxf(s, dpi / 96.0)
	return clampf(s, 1.0, 4.0)


func _can_embed() -> bool:
	# Godot spells these with the capitals the platform uses -- "Windows",
	# "X11", "Wayland" -- and a comparison that assumed lower case is what kept
	# every plugin's own interface from ever appearing on Windows.
	var ds := DisplayServer.get_name().to_lower()
	return ds == "windows" or ds == "x11"


## Plugins size their editor from the display, and several ask for more than
## the screen actually has once a window frame and a task bar are taken off.
## Anything bigger than that is trimmed, and a resizable plugin is told about
## the trim so it lays out to what it was given instead of being cut off.
func _fit(w: int, h: int) -> Vector2i:
	var top := int(TOOLBAR_H * content_scale_factor)
	var usable := DisplayServer.screen_get_usable_rect(get_window().current_screen if is_inside_tree() else 0)
	# A little off each edge for the window frame the compositor puts around us.
	var max_w: int = maxi(320, usable.size.x - 24)
	var max_h: int = maxi(240, usable.size.y - 48 - top)
	return Vector2i(mini(w, max_w), mini(h, max_h))


## Cadmium's own panel is laid out in scaled units, so its window has to be
## sized in the same units or the bottom of the panel is cut off.
func _generic_size() -> Vector2i:
	var sc := maxf(0.5, content_scale_factor)
	return Vector2i(int(560.0 * sc), int(470.0 * sc))


## Godot waits for vertical blank on every window it draws, so a second window
## halves the frame rate of the whole application -- and the plugin's own event
## loop is serviced once per frame, which is what makes its interface feel slow.
## The plugin's window does not need to be tear-free; the main one still is.
func _free_running() -> void:
	if not is_inside_tree():
		return
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED, get_window_id())


func _where() -> String:
	if String(ref.get("kind", "")) == "channel":
		var i := int(ref.index)
		return String(App.project.channels[i].name) if i < App.project.channels.size() else "channel"
	var t := int(ref.get("track", 0))
	return "%s slot %d" % [String(App.project.mixer[t].name), int(ref.get("slot", 0)) + 1]


func _build() -> void:
	# The frame is plugin_window.tscn. What changes here is which parts of it
	# are shown and what goes in the body, because both depend on the plugin.
	_header()
	_hole.visible = _native
	_scroll.visible = not _native
	_filter_row.visible = not _native and _params.size() > FILTER_THRESHOLD
	_keys.visible = not _native and bool(_info.get("instrument", false))
	if _native:
		return

	for c in _body.get_children():
		c.queue_free()
	_custom = _custom_panel()
	if _custom != null:
		_body.add_child(_custom)
	# A plugin that described its own panel has had every control drawn
	# already; the generic grid underneath would be the same three hundred
	# knobs a second time.
	var kind := int(_info.get("ui", Cd.PlugUI.GENERIC))
	var declared := kind == Cd.PlugUI.DECLARED or kind == Cd.PlugUI.FLARE
	if declared:
		_filter_row.visible = false
		if _keys.visible:
			_keys.channel = int(ref.get("index", App.current_channel))
		# A panel that says how much room it wants is given it, within what the
		# screen has. The generic size is worked out for a grid of knobs and is
		# too narrow for a designed panel, which then opens with half of itself
		# wrapped into a column.
		var want: Vector2 = _custom.custom_minimum_size if _custom != null else Vector2.ZERO
		if want.x > 1.0:
			var sc := maxf(0.5, content_scale_factor)
			var fit := _fit(int(want.x * sc), int(want.y * sc) + int(TOOLBAR_H * sc))
			size = Vector2i(maxi(size.x, fit.x), maxi(size.y, fit.y))
		return
	# An instrument with no display of its own still shows its envelope and its
	# filter, and everything except the equaliser -- which draws a spectrum
	# already -- shows what it is putting out.
	if (_custom == null or int(_info.get("ui", Cd.PlugUI.GENERIC)) == Cd.PlugUI.WAVETABLE) \
			and bool(_info.get("instrument", false)) and CdSynthView.fits(_params):
		_body.add_child(_view(SYNTH_SCENE.instantiate()))
	# A hosted plugin gets one too when we are drawing its controls ourselves,
	# which is exactly when it has no picture of its own. The ones that are
	# already a display of the signal are left alone.
	if not int(_info.get("ui", Cd.PlugUI.GENERIC)) in \
			[Cd.PlugUI.EQ, Cd.PlugUI.SPAN, Cd.PlugUI.TUNER, Cd.PlugUI.OSC,
			Cd.PlugUI.LOUD]:
		_body.add_child(_view(SCOPE_SCENE.instantiate()))
	if _filter_row.visible:
		_filter_field.placeholder_text = "Filter %d parameters..." % _params.size()
		if not _filter_field.text_changed.is_connected(_on_filter):
			_filter_field.text_changed.connect(_on_filter)
	if _keys.visible:
		_keys.channel = int(ref.get("index", App.current_channel))
	_build_groups(_body)


## Fills the strip: which of its controls make sense depends on whether this is
## an insert, and on whether the plugin has an interface of its own.
func _header() -> void:
	($Root/Col/Header/Row/Icon as TextureRect).texture = Icons.get_icon("vst" if _vst3 else "plugin", 16)
	($Root/Col/Header/Row/Name as Label).text = String(_info.get("name", "Plugin"))
	($Root/Col/Header/Row/Kind as Label).text = "  %s  -  %d parameters" % [
			String(_info.get("category", "")), _params.size()]
	if not _header_panel.gui_input.is_connected(_header_input):
		_header_panel.gui_input.connect(_header_input)

	var insert := String(ref.get("kind", "")) == "insert"
	var plug = App.plugin_for(ref)
	_bypass.visible = insert
	_wet.visible = insert
	if insert:
		_bypass.set_pressed_no_signal(plug != null and bool(plug.get("bypass", false)))
		_wet.set_value_silent(float(plug.get("wet", 1.0)) if plug != null else 1.0)
		if not _bypass.toggled.is_connected(_on_bypass):
			_bypass.toggled.connect(_on_bypass)
			_wet.value_changed.connect(func(v):
				App.set_insert_flag(int(ref.track), int(ref.slot), "wet", v))

	_ui_toggle.visible = _native_available or (_has_editor and not _can_embed())
	_ui_toggle.disabled = not _native_available
	if _native_available:
		_ui_toggle.set_pressed_no_signal(_native)
		_ui_toggle.tooltip_text = "Draw the plugin's own interface instead of Cadmium's generic one"
		if not _ui_toggle.toggled.is_connected(_set_native_ui):
			_ui_toggle.toggled.connect(_set_native_ui)
	elif _ui_toggle.visible:
		# Saying why beats leaving the checkbox out and looking like the plugin
		# has no interface of its own.
		_ui_toggle.tooltip_text = ("A plugin's own interface has to be embedded through X11, and "
				+ "this session is running on %s. Start Cadmium with --display-driver x11 for it."
				) % DisplayServer.get_name()

	_typing.visible = _native_available
	if _native_available:
		_typing.set_pressed_no_signal(not _keys_to_plugin)
		if not _typing.toggled.is_connected(_set_typing_keys):
			_typing.toggled.connect(_set_typing_keys)

	if not _preset_menu.get_popup().id_pressed.is_connected(_on_preset):
		var pm := _preset_menu.get_popup()
		pm.add_item("Reset to Default", 0)
		pm.add_item("Randomise", 1)
		pm.add_separator()
		pm.add_item("Save Preset...", 2)
		pm.add_item("Load Preset...", 3)
		pm.id_pressed.connect(_on_preset)


func _on_filter(t: String) -> void:
	_filter = t.strip_edges().to_lower()
	_rebuild_body()


func _on_bypass(on: bool) -> void:
	App.set_insert_flag(int(ref.track), int(ref.slot), "bypass", on)


func _rebuild_body() -> void:
	for c in _body.get_children():
		if c != _custom:
			c.queue_free()
	_knobs.clear()
	_build_groups(_body)


## Right-click anywhere on the strip offers the same switch, because that is
## where people look for it.
func _header_input(event: InputEvent) -> void:
	if not (event is InputEventMouseButton) or not event.pressed:
		return
	if event.button_index != MOUSE_BUTTON_RIGHT:
		return
	var pm := PopupMenu.new()
	add_child(pm)
	if _native_available:
		pm.add_check_item("Use the plugin's own interface", 0)
		pm.set_item_checked(0, _native)
	else:
		pm.add_item("This plugin has no interface of its own", 0)
		pm.set_item_disabled(0, true)
	pm.add_separator()
	pm.add_item("Reset to Default", 1)
	pm.add_item("Save Preset...", 2)
	pm.add_item("Load Preset...", 3)
	pm.id_pressed.connect(func(id):
		match id:
			0: _set_native_ui(not _native)
			1: _on_preset(0)
			2: _save_preset()
			3: _load_preset()
		pm.queue_free())
	pm.popup(Rect2i(DisplayServer.mouse_get_position(), Vector2i(1, 1)))


func _set_native_ui(on: bool) -> void:
	if on == _native:
		return
	var plug = App.plugin_for(ref)
	if plug != null:
		plug["native_ui"] = on
		App.project.dirty = true
	if not on:
		_detach_editor()
		_native = false
		size = _generic_size()
		_build()
		App.status.emit("Using Cadmium's controls for %s" % String(_info.get("name", "")))
		return
	_native = true
	_build()
	var es: Vector2i = App.engine().plugin_editor_size(App.handle_for(ref))
	if es.x > 32 and es.y > 32:
		es = _fit(es.x, es.y)
		size = Vector2i(es.x, es.y + int(TOOLBAR_H * content_scale_factor))
	_attach_editor.call_deferred()
	App.status.emit("Using %s's own interface" % String(_info.get("name", "")))


## The window has to exist natively before the plugin can be told to draw into
## it, so this runs a frame after the popup.
func _attach_editor() -> void:
	if _attached or not _native:
		return
	var h := App.handle_for(ref)
	if h < 0:
		return
	# The window has to exist on screen before anything can be parented into
	# it, and how many frames that takes is up to the compositor.
	var handle := 0
	for attempt in 30:
		await get_tree().process_frame
		if not is_inside_tree() or not _native:
			return
		handle = DisplayServer.window_get_native_handle(DisplayServer.WINDOW_HANDLE, get_window_id())
		if handle != 0:
			break
	if handle == 0:
		_fallback("no native window handle")
		return
	# What the display is really scaled by -- not what Cadmium's own interface
	# is scaled by, which is a preference and has nothing to do with how many
	# pixels the plugin has to draw into. Told before the size is asked for,
	# because a view that lays out on the scale answers differently once it
	# knows what it is.
	var display_scale := _display_scale()
	if display_scale > 1.01:
		App.engine().plugin_editor_set_scale(h, display_scale)
	var es: Vector2i = App.engine().plugin_editor_size(h)
	if es.x <= 32 or es.y <= 32:
		es = Vector2i(maxi(400, size.x), maxi(300, size.y - int(TOOLBAR_H * content_scale_factor)))
	es = _fit(es.x, es.y)
	var top := int(TOOLBAR_H * content_scale_factor)
	if not App.engine().plugin_open_editor(h, handle, 0, top, es.x, es.y):
		_fallback("the editor refused to attach")
		return
	_attached = true
	# Set once, not once per attempt: the deadline is for the whole business of
	# getting an interface out of this plugin, retries included.
	if _attach_tries == 0:
		_waiting_until = Time.get_ticks_msec() + ATTACH_GIVE_UP_MS
	_show_busy(true)
	_applying_size = true
	size = Vector2i(es.x, es.y + top)
	_expected_size = size
	_settle_until = Time.get_ticks_msec() + SETTLE_MS
	_applying_size = false
	# A view that cannot be resized is held at its own size here rather than by
	# telling the window manager the window is fixed: a fixed window gets a
	# dead maximise button in its title bar, next to the close button, and a
	# button that does nothing is worse than a corner that springs back.
	_fixed_editor = not App.engine().plugin_editor_can_resize(h)
	_fixed_size = size
	unresizable = false
	# Never larger than the plugin's own canvas: a small editor in a window with
	# a floor under it leaves a band of Cadmium's background below the plugin.
	min_size = Vector2i(mini(240, es.x), top + mini(120, es.y))
	if _keys_to_plugin:
		_focus_editor()
	size_changed.connect(_on_size_changed)


func _set_typing_keys(on: bool) -> void:
	_keys_to_plugin = not on
	if _keys_to_plugin:
		_focus_editor()
		App.status.emit("Keyboard goes to %s" % String(_info.get("name", "the plugin")))
	else:
		# Take the keyboard back so the typing keys play notes again.
		grab_focus()
		App.status.emit("Keyboard plays notes and drives Cadmium")


func _focus_editor() -> void:
	if _attached:
		App.engine().plugin_editor_focus(App.handle_for(ref))


## Falling back is a failure, not a preference: it is not written into the
## project, so the next time the window opens the plugin gets another go. Only
## the checkbox records a choice.
func _fallback(why: String) -> void:
	_native = false
	_attached = false
	_show_busy(false)
	size = _generic_size()
	_build()
	App.status.emit("%s: %s - using Cadmium's controls" % [String(_info.get("name", "")), why])


## A plugin Cadmium is refusing to open says so, in its own window, with the
## reason and a way out.
##
## Refusing one that has taken the program down is right; leaving somebody
## looking at an empty panel with no name and no controls, wondering what
## happened to their synth, is not. The window is where they go to find out, so
## the answer belongs here.
func _refused_note() -> String:
	if not _vst3:
		return ""
	var plug = App.plugin_for(ref)
	if plug == null:
		return ""
	var path := String(plug.get("path", ""))
	if path.is_empty() or not Plugins.is_broken(path):
		return ""
	return "%s will not be opened: %s." % [path.get_file(), Plugins.broken_reason(path)]


## Says so in the window, with the way out underneath it.
func _show_refused(note: String) -> void:
	_busy_label.text = note + "\n\nIt was refused because it took Cadmium down\n" \
			+ "while it was being opened. If that was something else's doing,\nit can have another go."
	_spin.visible = false
	_again.visible = true
	if not _again.pressed.is_connected(_try_again):
		_again.pressed.connect(_try_again)
	_busy.visible = true


## Forgets that, and loads the plugin again.
func _try_again() -> void:
	var plug = App.plugin_for(ref)
	if plug == null:
		return
	Plugins.forgive(String(plug.get("path", "")))
	App.status.emit("Trying %s again" % String(plug.get("name", "the plugin")))
	_again.visible = false
	_busy_label.text = "Loading..."
	_spin.visible = true
	App.sync_all()
	await get_tree().process_frame
	await get_tree().process_frame
	_info = App.plugin_info(ref)
	_params = App.plugin_params(ref)
	_attached = false
	_noted = false
	_attach_tries = 0
	_native_available = _vst3 and _can_embed() \
			and App.engine().plugin_has_editor(App.handle_for(ref))
	var plug2 = App.plugin_for(ref)
	_native = _native_available and (bool(plug2.get("native_ui", true)) if plug2 != null else false)
	_build()
	_show_busy(false)
	if _native:
		_attach_editor.call_deferred()


## A plugin's window is a window of its own, with its own input tree: without
## this the typing keyboard, the transport keys and the tool keys all stop
## working the moment a plugin is in front.
##
## _input, not _unhandled_key_input: a window full of buttons and knobs has
## something focused nearly all the time, and a focused Button eats Space
## before anything unhandled is ever asked about it. That is why Space stopped
## playing and why a note key sometimes did nothing. Shortcuts.feed steps aside
## on its own when the focus is in a text field.
func _input(event: InputEvent) -> void:
	if _keys_to_plugin:
		return
	Shortcuts.feed(event, get_viewport())


## The plugin has been given a window; this waits for it to put something in
## it. Three things can happen: it builds its interface and is brought in from
## where it was parked, it produces nothing and is attached again from scratch,
## or it goes on producing nothing and is shown regardless.
func _wait_for_editor(h: int) -> void:
	if h < 0 or App.engine().plugin_editor_showing(h):
		return
	if App.engine().plugin_editor_ready(h):
		App.engine().plugin_editor_show(h)
		_show_busy(false)
		_fit_window_to_canvas(h)
		_note_geometry(h, "ready")
		return
	var left := _waiting_until - Time.get_ticks_msec()
	if left <= 0:
		# Nothing of its own to show, or nothing we can see: show the window it
		# was given rather than leave the user watching a spinner.
		App.engine().plugin_editor_show(h)
		_show_busy(false)
		_fit_window_to_canvas(h)
		_note_geometry(h, "gave up waiting")
		return
	# A plugin that has made a window of its own is building its interface, and
	# is left to get on with it however long it takes. Only one that has done
	# nothing at all gets another go.
	if App.engine().plugin_editor_started(h):
		return
	if _attach_tries < ATTACH_TRIES and left <= ATTACH_GIVE_UP_MS - (_attach_tries + 1) * ATTACH_RETRY_MS:
		_attach_tries += 1
		_busy_label.text = "Loading... (%d)" % (_attach_tries + 1)
		# Round again: the view is let go of and made afresh, which is what
		# opening the window a second time used to do by hand.
		App.engine().plugin_close_editor(h)
		_attached = false
		_noted = false
		_attach_editor.call_deferred()


## The window follows the canvas, once, when the interface is finally up.
##
## A plugin does not have to settle on its size before it is given a window,
## and plenty do not: LSP's plugins grow theirs on the way up, and anything that
## works its layout out from the display's scale can only do it once it has
## something to lay out against. The window was sized from the answer given
## before any of that, so what the plugin ends up drawing is taller than the
## room it was given -- an interface with the bottom of it cut off, which is
## the same complaint as "it renders at the wrong scale with most of it
## missing". So the last word goes to the canvas.
func _fit_window_to_canvas(h: int) -> void:
	if h < 0 or not _attached:
		return
	var es: Vector2i = App.engine().plugin_editor_size(h)
	if es.x <= 32 or es.y <= 32:
		return
	var top := int(TOOLBAR_H * content_scale_factor)
	var want := _fit(es.x, es.y)
	var target := Vector2i(want.x, want.y + top)
	if absi(target.x - size.x) <= 2 and absi(target.y - size.y) <= 2:
		return
	_applying_size = true
	size = target
	_expected_size = size
	# A view that cannot be resized is held at one size, and that size is now
	# this one. Without this the window is put straight back to what it was
	# and the correction never survives a frame.
	if _fixed_editor:
		_fixed_size = target
	_settle_until = Time.get_ticks_msec() + SETTLE_MS
	_applying_size = false
	App.engine().plugin_editor_move(h, 0, top, want.x, want.y)


## Every number that decides where a plugin's interface ends up, written down
## next to the crash reports.
##
## An interface that comes up at the wrong size is nearly always two of these
## disagreeing -- what the display is scaled by, what the plugin thinks it was
## told, how big it says it is and how big the window it got actually is -- and
## none of them can be seen from a screenshot. Help > Crash Reports > Open
## Folder is where this lands.
func _note_geometry(h: int, when: String) -> void:
	if h < 0 or _noted:
		return
	_noted = true
	var es: Vector2i = App.engine().plugin_editor_size(h)
	var line := "%s  %s\n" % [Time.get_datetime_string_from_system().replace("T", "  "),
			String(_info.get("name", "?"))]
	line += "    %s, display scale %.2f, %d dpi, Cadmium's own scale %.2f\n" % [
			when, _display_scale(), DisplayServer.screen_get_dpi(current_screen),
			content_scale_factor]
	line += "    window %s at %s, canvas told %s, plugin says %s\n" % [
			str(size), str(position), str(Vector2i(size.x, size.y - int(TOOLBAR_H * content_scale_factor))),
			str(es)]
	line += "    %s\n\n" % String(App.engine().plugin_editor_debug(h))
	var path := CdCrash.dir().path_join("plugin-windows.txt")
	var f := FileAccess.open(path, FileAccess.READ_WRITE) if FileAccess.file_exists(path) \
			else FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return
	f.seek_end()
	f.store_string(line)
	f.close()


## Whether a plugin holding the keyboard while its window is not the one being
## used is something that has to be corrected from here.
##
## On X11 it is. The input focus is a thing of its own there, so a plugin's
## canvas can be holding the keyboard while the window manager says another of
## Cadmium's windows is the one in use: the keys go to the plugin and simply
## vanish, which is one click inside a plugin stopping Space and the transport
## working anywhere in the program.
##
## On Windows it is not, and doing it anyway is actively harmful. Windows sends
## keys to whatever the foreground window's thread has focused, so if you are in
## another of Cadmium's windows the plugin is not getting your keys and there is
## nothing to put right. But the plugin's canvas is a window of its own there,
## and clicking it makes it the one in use -- so this rule saw "not the window
## in use" and took the focus off the plugin *while it was being used*, four
## times a second. A JUCE plugin ends a drag when it loses the focus, so in
## Vital a wavetable drag was cancelled the instant it began.
static func _reclaims_keyboard(platform: String) -> bool:
	return platform != "Windows"


## True when the pointer has been outside the plugin's own canvas long enough
## that whatever it was doing in there is finished.
func _pointer_away_from_plugin() -> bool:
	# A button still down is a drag in progress, and a knob dragged upwards
	# leaves the plugin's canvas long before the user has finished with it.
	var inside := Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT) \
			or (_hole != null and _hole.get_global_rect().has_point(get_mouse_position()))
	return _away_check(inside, Time.get_ticks_msec())


## The rule on its own, so it can be put to the test without a hand on the
## mouse: inside resets the clock, outside starts it, and the keyboard only
## comes back once it has been outside long enough.
func _away_check(inside: bool, now: int) -> bool:
	if inside:
		_away_since = 0
		return false
	if _away_since == 0:
		_away_since = now
	return now - _away_since >= AWAY_BEFORE_KEYS


func _show_busy(on: bool) -> void:
	if _busy == null:
		return
	_busy.visible = on and _native
	if not on:
		_busy_label.text = "Loading..."
		_attach_tries = 0


## Quitting with a plugin editor open destroys this window, and the plugin's
## canvas lives inside it. The plugin has to be told to let go before that
## happens, or it is left drawing into a window that no longer exists.
func _exit_tree() -> void:
	_detach_editor()


func _detach_editor() -> void:
	if not _attached:
		return
	if size_changed.is_connected(_on_size_changed):
		size_changed.disconnect(_on_size_changed)
	App.engine().plugin_close_editor(App.handle_for(ref))
	_attached = false
	_show_busy(false)


## Dragging the corner of the window: the plugin gets to say what sizes it can
## actually draw at, and the window is snapped to the nearest one. Letting the
## two disagree is what left the canvas drawn into the wrong rectangle until the
## interface was switched off and on again.
func _on_size_changed() -> void:
	if not _attached or _applying_size:
		return
	if _fixed_editor and _fixed_size.x > 0:
		# This plugin's view only draws at one size, so put the window back
		# rather than leave a band of nothing around the edge.
		if size != _fixed_size:
			_applying_size = true
			size = _fixed_size
			_applying_size = false
		return
	if size == _expected_size or Time.get_ticks_msec() < _settle_until:
		# Our own resize coming back to us, or the plugin still settling into
		# it. Dragging the corner takes longer than this, so a real resize is
		# picked up on the next report.
		_expected_size = Vector2i.ZERO
		return
	# Coalesce: a corner drag emits this every frame, and each one is a full
	# relayout inside the plugin.
	_resize_pending = true


func _apply_pending_resize() -> void:
	_resize_pending = false
	var h := App.handle_for(ref)
	if h < 0 or not _attached:
		return
	var top := int(TOOLBAR_H * content_scale_factor)
	var want := Vector2i(size.x, maxi(32, size.y - top))
	var fit: Vector2i = App.engine().plugin_editor_constrain(h, want.x, want.y)
	if OS.has_environment("CD_DEBUG_RESIZE"):
		print("resize: want %s -> fit %s (window %s)" % [str(want), str(fit), str(size)])
	if fit.x < 32 or fit.y < 32:
		fit = want
	App.engine().plugin_editor_move(h, 0, top, fit.x, fit.y)
	if fit != want:
		_applying_size = true
		size = Vector2i(fit.x, fit.y + top)
		_expected_size = size
		_settle_until = Time.get_ticks_msec() + SETTLE_MS
		_applying_size = false


func _build_groups(body: Control) -> void:
	var groups := {}
	var order := []
	var shown := 0
	for p in _params:
		if not _filter.is_empty():
			if not (String(p.name).to_lower().contains(_filter) or String(p.group).to_lower().contains(_filter)):
				continue
		shown += 1
		if shown > MAX_CONTROLS:
			break
		var g := String(p.get("group", ""))
		if g.is_empty():
			g = "Parameters"
		if not groups.has(g):
			groups[g] = []
			order.append(g)
		groups[g].append(p)
	if _count_label != null:
		_count_label.text = "showing %d of %d" % [mini(shown, MAX_CONTROLS), _params.size()]
	for g in order:
		var section := PanelContainer.new()
		section.theme_type_variation = "Card"
		section.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		body.add_child(section)
		var vb := VBoxContainer.new()
		vb.add_theme_constant_override("separation", 2)
		section.add_child(vb)
		var lbl := Label.new()
		lbl.theme_type_variation = "SectionLabel"
		lbl.text = g.to_upper()
		vb.add_child(lbl)
		var flow := HFlowContainer.new()
		flow.add_theme_constant_override("h_separation", 6)
		flow.add_theme_constant_override("v_separation", 2)
		vb.add_child(flow)
		for p in groups[g]:
			flow.add_child(_control_for(p))


func _control_for(p: Dictionary) -> Control:
	var index := int(p.index)
	var value := float(App.get_plugin_param(ref, index))
	if int(p.kind) == Cd.ParamKind.BOOL:
		var b := CheckBox.new()
		b.text = String(p.name)
		b.focus_mode = Control.FOCUS_NONE
		b.set_pressed_no_signal(value > 0.5)
		b.toggled.connect(func(on): App.set_plugin_param(ref, index, 1.0 if on else 0.0))
		_knobs[index] = b
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
		opt.custom_minimum_size.x = 104
		for c in String(p.choices).split("|"):
			opt.add_item(c)
		opt.select(clampi(int(round(value)), 0, opt.item_count - 1))
		opt.item_selected.connect(func(i): App.set_plugin_param(ref, index, float(i)))
		box.add_child(opt)
		_knobs[index] = opt
		return box
	var k := CdKnob.new()
	k.setup(p, value)
	# A plugin that spells its own values is asked to: ours would say "43%"
	# where it means "2.4 kHz" or "1/8.". Stock processors say nothing and are
	# formatted from the parameter's kind, as they always were.
	if not String(App.engine().plugin_param_text(App.handle_for(ref), index, value)).is_empty():
		k.custom_minimum_size.x = 74.0
		k.value_text_fn = func(v: float) -> String:
			return App.engine().plugin_param_text(App.handle_for(ref), index, v)
	k.auto_ref = {"target": Cd.AutoTarget.PLUGIN, "ref": ref, "a": 0, "b": index}
	k.value_changed.connect(func(v): App.set_plugin_param(ref, index, v))
	k.menu_requested.connect(func(_pos): _param_menu(p))
	_knobs[index] = k
	return k


func _param_menu(p: Dictionary) -> void:
	var pm := PopupMenu.new()
	add_child(pm)
	pm.add_item("Reset", 0)
	pm.add_item("Create Automation Clip", 1)
	pm.id_pressed.connect(func(id):
		if id == 0:
			App.set_plugin_param(ref, int(p.index), float(p.default))
			_refresh_values()
		else:
			var name := "%s: %s" % [String(_info.get("name", "")), String(p.name)]
			var ai := App.add_automation(name, Cd.AutoTarget.PLUGIN, ref, 0, int(p.index),
					float(p.min), float(p.max))
			App.add_clip(Cd.ClipType.AUTOMATION, ai, 0, 0.0, maxf(4.0, App.project.length_beats()))
			App.status.emit("Automation clip added for %s" % String(p.name))
		pm.queue_free())
	pm.popup(Rect2i(DisplayServer.mouse_get_position(), Vector2i(1, 1)))


func _on_preset(id: int) -> void:
	match id:
		0:
			for p in _params:
				App.set_plugin_param(ref, int(p.index), float(p.default))
			_refresh_values()
		1:
			for p in _params:
				# Leave levels and output alone: a randomiser that can hand you a
				# silent patch or a full-scale one is just annoying.
				var g := String(p.get("group", "")).to_lower()
				if g.contains("output") or String(p.name).to_lower().contains("level"):
					continue
				var v := randf()
				App.set_plugin_param(ref, int(p.index),
						Cd.from_norm(v, float(p.min), float(p.max), float(p.skew)))
			_refresh_values()
		2:
			_save_preset()
		3:
			_load_preset()


func _preset_dir() -> String:
	var d := "user://presets/%s" % String(_info.get("id", "plugin")).replace(".", "_")
	DirAccess.make_dir_recursive_absolute(d)
	return d


func _save_preset() -> void:
	var dlg := AcceptDialog.new()
	dlg.title = "Save Preset"
	var field := LineEdit.new()
	field.placeholder_text = "Preset name"
	field.custom_minimum_size.x = 240
	dlg.add_child(field)
	dlg.register_text_enter(field)
	add_child(dlg)
	dlg.confirmed.connect(func():
		var name := field.text.strip_edges()
		if name.is_empty():
			dlg.queue_free()
			return
		var data := {"plugin": String(_info.get("id", "")), "params": {}, "strings": {}}
		for p in _params:
			data["params"][str(int(p.index))] = App.get_plugin_param(ref, int(p.index))
		var plug = App.plugin_for(ref)
		if plug != null:
			data["strings"] = plug.get("strings", {}).duplicate()
			# Whatever the plugin says its whole state is, hosted or not.
			var st := String(App.engine().plugin_get_string(App.handle_for(ref), "state"))
			if not st.is_empty():
				data["state"] = st
		var f := FileAccess.open(_preset_dir().path_join(name + ".json"), FileAccess.WRITE)
		if f != null:
			f.store_string(JSON.stringify(data, "\t"))
			f.close()
			App.status.emit("Preset saved: %s" % name)
		dlg.queue_free())
	dlg.popup_centered()
	field.grab_focus()


func _load_preset() -> void:
	var dir := DirAccess.open(_preset_dir())
	if dir == null:
		return
	var pm := PopupMenu.new()
	add_child(pm)
	var files := []
	for f in dir.get_files():
		if f.ends_with(".json"):
			files.append(f)
			pm.add_item(f.get_basename(), files.size() - 1)
	if files.is_empty():
		pm.add_item("(no presets saved yet)", -1)
	pm.id_pressed.connect(func(id):
		if id >= 0:
			var f := FileAccess.open(_preset_dir().path_join(String(files[id])), FileAccess.READ)
			if f != null:
				var d = JSON.parse_string(f.get_as_text())
				f.close()
				if typeof(d) == TYPE_DICTIONARY:
					if d.has("state"):
						App.engine().plugin_set_string(App.handle_for(ref), "state", String(d["state"]))
					for k in d.get("strings", {}).keys():
						App.set_plugin_string(ref, String(k), String(d["strings"][k]))
					for k in d.get("params", {}).keys():
						App.set_plugin_param(ref, int(k), float(d["params"][k]))
					_refresh_values()
					App.status.emit("Preset loaded")
		pm.queue_free())
	pm.popup(Rect2i(DisplayServer.mouse_get_position(), Vector2i(200, 300)))


## Showing what the plugin holds, and only showing it. A checkbox set the
## ordinary way emits `toggled`, which is wired to write the parameter back --
## so a switch standing at 0.63 was shown as on and then written back as 1.0,
## and a plugin being read from quietly had its own settings rounded off under
## it. Every control here is set without signals for that reason.
func _refresh_values() -> void:
	for index in _knobs.keys():
		var w = _knobs[index]
		var v := float(App.get_plugin_param(ref, int(index)))
		if w is CdKnob:
			w.value = v
			w.queue_redraw()
		elif w is CheckBox:
			(w as CheckBox).set_pressed_no_signal(v > 0.5)
		elif w is OptionButton:
			w.select(clampi(int(round(v)), 0, w.item_count - 1))
	if _custom != null and _custom.has_method("refresh"):
		_custom.refresh()


## The picture that goes above a stock plugin's controls. One scene per kind,
## loaded rather than built, so what is on screen can be opened and edited.
const PANELS := {
	Cd.PlugUI.EQ: "res://ui/widgets/eq_curve.tscn",
	Cd.PlugUI.COMP: "res://ui/widgets/comp_view.tscn",
	Cd.PlugUI.SAMPLER: "res://ui/panels/sampler_panel.tscn",
	Cd.PlugUI.SOUNDFONT: "res://ui/panels/soundfont_panel.tscn",
	Cd.PlugUI.MULTIBAND: "res://ui/widgets/views/multiband_view.tscn",
	Cd.PlugUI.IMAGER: "res://ui/widgets/views/imager_view.tscn",
	Cd.PlugUI.GATE: "res://ui/widgets/views/gate_view.tscn",
	Cd.PlugUI.ORGAN: "res://ui/widgets/views/organ_view.tscn",
	Cd.PlugUI.PRISM: "res://ui/panels/prism_panel.tscn",
	Cd.PlugUI.CLIP: "res://ui/widgets/views/clip_view.tscn",
	Cd.PlugUI.DEESS: "res://ui/widgets/views/deess_view.tscn",
	Cd.PlugUI.DUCK: "res://ui/widgets/views/duck_view.tscn",
	Cd.PlugUI.SPAN: "res://ui/widgets/views/span_view.tscn",
	Cd.PlugUI.TUNER: "res://ui/widgets/views/tuner_view.tscn",
	Cd.PlugUI.MOD: "res://ui/widgets/views/mod_view.tscn",
	Cd.PlugUI.DELAY: "res://ui/widgets/views/delay_view.tscn",
	Cd.PlugUI.VERB: "res://ui/widgets/views/verb_view.tscn",
	Cd.PlugUI.FILTER: "res://ui/widgets/views/filter_view.tscn",
	Cd.PlugUI.SHAPE: "res://ui/widgets/views/shape_view.tscn",
	Cd.PlugUI.EXCITE: "res://ui/widgets/views/excite_view.tscn",
	Cd.PlugUI.GATEDYN: "res://ui/widgets/views/gate_dyn_view.tscn",
	Cd.PlugUI.TRANSIENT: "res://ui/widgets/views/transient_view.tscn",
	Cd.PlugUI.LEVEL: "res://ui/widgets/views/level_view.tscn",
	Cd.PlugUI.VOCODER: "res://ui/widgets/views/vocoder_view.tscn",
	Cd.PlugUI.PITCH: "res://ui/widgets/views/pitch_view.tscn",
	Cd.PlugUI.ACID: "res://ui/widgets/views/acid_view.tscn",
	Cd.PlugUI.MODAL: "res://ui/widgets/views/modal_view.tscn",
	Cd.PlugUI.VOX: "res://ui/widgets/views/vox_view.tscn",
	Cd.PlugUI.TAPE: "res://ui/widgets/views/tape_view.tscn",
	Cd.PlugUI.DRUM: "res://ui/widgets/views/drum_view.tscn",
	Cd.PlugUI.CONV: "res://ui/panels/space_panel.tscn",
	Cd.PlugUI.OSC: "res://ui/widgets/views/osc_view.tscn",
	Cd.PlugUI.LOUD: "res://ui/widgets/views/loud_view.tscn",
	Cd.PlugUI.AMP: "res://ui/widgets/views/amp_view.tscn",
	Cd.PlugUI.WAVETABLE: "res://ui/widgets/views/wavetable_view.tscn",
	Cd.PlugUI.DECLARED: "res://ui/widgets/views/declared_view.tscn",
	Cd.PlugUI.FLARE: "res://ui/widgets/views/flare_view.tscn",
}

const SCOPE_SCENE := preload("res://ui/widgets/views/scope_view.tscn")
const SYNTH_SCENE := preload("res://ui/widgets/views/synth_view.tscn")


func _custom_panel() -> Control:
	var kind := int(_info.get("ui", Cd.PlugUI.GENERIC))
	if not PANELS.has(kind):
		return null
	return _view(load(String(PANELS[kind])).instantiate())


## Wires one of the stock displays to this plugin. They all read the processor's
## own `aux` output and some of them write parameters back.
func _view(v: Control) -> Control:
	v.ref = ref
	v.params = _params
	if v.has_signal("param_changed"):
		v.param_changed.connect(func(): _refresh_values())
	return v


func _process(dt: float) -> void:
	# Only plugins that draw their own window need their run loop pumping and
	# their canvas kept in the right place.
	if not _has_editor:
		return
	if _attached:
		var h0 := App.handle_for(ref)
		_wait_for_editor(h0)
		if _resize_pending:
			_apply_pending_resize()
		# The run loop itself is pumped for every plugin from the main window.
		var want: Vector2i = App.engine().plugin_editor_take_resize(h0)
		if want.x > 32 and want.y > 32:
			var fit := _fit(want.x, want.y)
			# Applying the plugin's own request must not be reported back to it
			# as a resize, or a view that rounds sizes will bounce forever.
			_applying_size = true
			size = Vector2i(fit.x, fit.y + int(TOOLBAR_H * content_scale_factor))
			_expected_size = size
			_fixed_size = size
			_settle_until = Time.get_ticks_msec() + SETTLE_MS
			_applying_size = false
			# It asked for more than there is room for, so it has to be told
			# what it actually got or it draws off the edge.
			if fit != want:
				App.engine().plugin_editor_move(h0, 0, int(TOOLBAR_H * content_scale_factor), fit.x, fit.y)
		if _keys_to_plugin:
			# Keys go wherever X put the input focus, which is not automatically
			# the plugin's window just because ours is active.
			var focused := has_focus()
			if focused != _had_focus:
				_had_focus = focused
				if focused:
					_focus_editor()

	# A hosted plugin can move its own parameters; pick those up a few times a
	# second rather than every frame.
	_poll += dt
	if _poll < 0.15:
		return
	_poll = 0.0
	var h := App.handle_for(ref)
	if h < 0:
		return
	# A key held on the typing keyboard when the plugin takes the keyboard over
	# can never be seen coming back up: the release goes to the plugin. Rather
	# than leave the note sounding for ever, it is let go of now.
	if _attached and Shortcuts.holding() and App.engine().plugin_editor_has_keys(h):
		Shortcuts.release_all()
	if _attached and _reclaims_keyboard(OS.get_name()) and not has_focus() \
			and App.engine().plugin_editor_has_keys(h):
		# The user is somewhere else in Cadmium now -- the arrangement, the
		# piano roll -- and a plugin's interface has no business still holding
		# the keyboard from a window nobody is looking at. Without this, one
		# click inside a plugin stopped Space, the transport and the typing
		# keys working anywhere in the program until the window was closed.
		App.engine().plugin_editor_unfocus(h)
		Shortcuts.release_all()
	elif _attached and not _keys_to_plugin and _pointer_away_from_plugin():
		# The other way round from _focus_editor, and the reason the typing
		# keyboard used to go quiet in front of some plugins and not others: a
		# plugin whose interface takes the focus when it is clicked keeps every
		# key from then on. Cadmium is holding the keyboard here, so it takes
		# it back -- but only once the pointer has left the plugin's own
		# canvas. Taking it while the pointer is still in there is taking it
		# out of the user's hands mid-sentence: it shuts the plugin's own
		# right-click menus the moment they open and makes its text boxes
		# impossible to type into.
		App.engine().plugin_editor_unfocus(h)
	# A preset chosen inside the plugin moves everything at once and reports
	# none of it: the plugin says so in one go instead, and every value has to
	# be read back.
	if App.engine().plugin_take_restart(h):
		App.touch_plugin(h)
		var plug_all = App.plugin_for(ref)
		if plug_all != null:
			for p in _params:
				plug_all["params"][str(int(p.index))] = App.get_plugin_param(ref, int(p.index))
		_refresh_values()
	var edits: Array = App.engine().plugin_drain_edits(h)
	if edits.is_empty():
		return
	# Moved from inside the plugin, so its state is worth reading back at the
	# next undo point.
	App.touch_plugin(h)
	var plug = App.plugin_for(ref)
	for e in edits:
		var i := int(e[0])
		var v := float(e[1])
		# Moved inside the plugin's own interface, which still counts as the
		# last thing tweaked: the toolbar knob follows it and can make an
		# automation clip from it.
		App.note_tweak(Cd.AutoTarget.PLUGIN, ref, 0, i)
		if plug != null:
			plug["params"][str(i)] = v
		var w = _knobs.get(i)
		if w is CdKnob:
			w.value = v
		elif w is CheckBox:
			# Without signals: this is the plugin telling us what it did, and
			# answering it by writing the value back is how a knob moved inside
			# a plugin's own interface ended up somewhere else.
			(w as CheckBox).set_pressed_no_signal(v > 0.5)
		elif w is OptionButton:
			w.select(clampi(int(round(v)), 0, w.item_count - 1))
