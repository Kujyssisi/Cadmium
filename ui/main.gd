extends Control
## The window: menus, transport, the dock layout, and the test hooks.

@onready var transport: CdTransportBar = $Frame/Root/TransportBar
@onready var browser = $Frame/Root/Split/Browser
@onready var rack = $Frame/Root/Split/Right/ChannelRack
@onready var playlist = $"Frame/Root/Split/Right/Tabs/Playlist/Arrangement"
@onready var picker: CdPickerPanel = $"Frame/Root/Split/Right/Tabs/Playlist/Picker"
@onready var piano = $"Frame/Root/Split/Right/Tabs/Piano Roll"
@onready var mixer = $Frame/Root/Split/Right/Tabs/Mixer
@onready var scope = $Frame/Root/Split/Right/Tabs/Scope
@onready var tabs: TabContainer = $Frame/Root/Split/Right/Tabs
@onready var status_label: Label = $Frame/Root/StatusBar/Row/Status
@onready var _undo_btn: Button = $Frame/Root/MenuBar/Row/History/Undo
@onready var _redo_btn: Button = $Frame/Root/MenuBar/Row/History/Redo
@onready var _voices: Label = $Frame/Root/StatusBar/Row/Readouts/Voices
@onready var _cpu: Label = $Frame/Root/StatusBar/Row/Readouts/Cpu
@onready var _master_knob: CdKnob = $Frame/Root/StatusBar/Row/Readouts/MasterKnob
var _plugin_windows := {}
var _shot_path := ""
var _shot_view := ""
var _shot_arg := ""
## True while the unsaved-changes question is on screen, so a second way of
## closing cannot stack another one on top of it.
var _asking := false
## Records how the application is running, on request, so a report about it
## being slow can arrive with numbers attached. See CdPerfLog.
var _addon_actions: Array = []
var _perf := CdPerfLog.new()
## What is on screen while the rest of this is being built. Null on a headless
## or scripted run, and dropped once it has closed itself.
var _splash: CdSplash = null


func _ready() -> void:
	name = "Root"
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_apply_scale()
	# Before anything opens a window of its own: dialogs are real windows here,
	# and this cannot be changed once one is on screen.
	get_tree().root.gui_embed_subwindows = false
	if not _scripted_run():
		_open_full_screen()
		_splash = CdSplash.open(self)
	_build()
	if _splash != null:
		_splash.step("interface", "Building the interface")
	App.status.connect(_on_status)
	App.title_changed.connect(_update_title)
	App.open_plugin.connect(open_plugin_window)
	App.toggle_plugin.connect(_toggle_plugin_window)
	App.plugin_destroyed.connect(_close_windows_for)
	Shortcuts.command.connect(_on_command)
	piano.menu_command.connect(_on_command)
	get_window().files_dropped.connect(_on_files_dropped)
	# The title bar's close button asks the same question the menu does; the
	# notification is what carries it, so no signal is connected here as well.
	get_tree().set_auto_accept_quit(false)
	_parse_args()
	_update_title()
	_report_last_crash()
	set_process(true)
	call_deferred("_sync_window_minimum")


## The screenshot and test hooks drive the interface themselves and want the
## window they were given: nothing in front of it, and no filling the screen.
func _scripted_run() -> bool:
	for arg in OS.get_cmdline_user_args():
		# Opening a song is an ordinary start, however it was asked for.
		if arg.begins_with("--cd-") and not arg.begins_with("--cd-open="):
			return true
	return false


## Cadmium opens maximised: the whole screen, with the title bar still there to
## move it, un-maximise it or put it on another display. F11 goes the rest of
## the way to full screen and back, and which of the two you left it in is what
## it opens in next time.
##
## Full screen here is the windowed kind, never exclusive: the screen's video
## mode is left alone, so switching away and back is instant and a plugin
## window can still come up over the top.
func _open_full_screen() -> void:
	var full := bool(Settings.get_value("fullscreen", false))
	get_window().mode = Window.MODE_FULLSCREEN if full else Window.MODE_MAXIMIZED


func _toggle_full_screen() -> void:
	var win := get_window()
	var on := win.mode != Window.MODE_FULLSCREEN
	# Back to maximised rather than to a small window: leaving full screen
	# should give the title bar back, not the desktop.
	win.mode = Window.MODE_FULLSCREEN if on else Window.MODE_MAXIMIZED
	Settings.set_value("fullscreen", on)
	App.status.emit("Full screen" if on else "Maximised")


## If the last run ended badly, say so and say what it was doing. A program
## that simply vanished and then came back as though nothing had happened is
## the worst way to find out that a plugin cannot be opened.
func _report_last_crash() -> void:
	var since := CdCrash.since_last_run()
	CdCrash.mark_run()
	if since.is_empty():
		return
	var what := CdCrash.doing(String(since[0].path))
	App.status.emit("Cadmium stopped unexpectedly last time%s -- Help > Crash Reports"
			% ("" if what.is_empty() else " while %s" % what))


## Hosted plugins keep timers on a run loop we own; they have to be ticked every
## frame or a plugin's meters freeze and some stop answering altogether -- even
## the ones with no editor on screen.
func _process(_dt: float) -> void:
	_perf.tick(_dt)
	# The first frame through here is the first one with an interface on it,
	# which is what the splash has been waiting to hear. It closes itself.
	if _splash != null:
		if is_instance_valid(_splash):
			_splash.done()
		_splash = null
	if Audio.engine == null:
		return
	Audio.engine.vst3_idle_all()
	_voices.text = "%d voices" % Audio.engine.voices()
	_cpu.text = "CPU %d%%" % int(Audio.engine.cpu() * 100.0)
	var u := App.undo_label()
	var r := App.redo_label()
	_undo_btn.disabled = u.is_empty()
	_redo_btn.disabled = r.is_empty()
	_undo_btn.tooltip_text = ("Undo %s  (Ctrl+Z)" % u) if not u.is_empty() else "Nothing to undo"
	_redo_btn.tooltip_text = ("Redo %s  (Ctrl+Shift+Z)" % r) if not r.is_empty() else "Nothing to redo"


## Closing the window, or the desktop asking the application to go away.
func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		_on_command("quit")


func _apply_scale() -> void:
	var s := Settings.ui_scale()
	get_window().content_scale_factor = s
	get_window().content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED
	# A 240 Hz display would otherwise have the whole interface redraw 240
	# times a second, which is work taken away from the audio thread and from
	# the plugin interfaces this loop also drives. 120 is past the point where
	# anyone can see the difference.
	Engine.max_fps = int(Settings.get_value("max_fps", 120))


## Wiring, not building: the layout is main.tscn. What is filled in here is
## what a scene file cannot hold -- menu items that come from a list, icons
## rasterised at run time, and the tab icons.
func _build() -> void:
	tabs.set_tab_icon(0, Icons.get_icon("playlist", 14))
	tabs.set_tab_icon(1, Icons.get_icon("piano", 14))
	tabs.set_tab_icon(2, Icons.get_icon("mixer", 14))
	tabs.set_tab_icon(3, Icons.get_icon("wave", 14))
	var brand: Label = $Frame/Root/MenuBar/Row/Brand
	brand.add_theme_color_override("font_color", CdPalette.ACCENT)
	Accent.accent_changed.connect(func(c: Color): brand.add_theme_color_override("font_color", c))

	_menu($Frame/Root/MenuBar/Row/File, [
		["New", "new"], ["Open...", "open"], ["Open Recent", "@recent"],
		["Save", "save"], ["Save As...", "save_as"], [],
		["Project Settings...", "project_settings"], [],
		["Import MIDI...", "import_midi"], ["Export MIDI...", "export_midi"], [],
		["Export Audio...", "export"], ["Export Stems...", "export_stems"], [],
		["Quit", "quit"],
	])
	_menu($Frame/Root/MenuBar/Row/Edit, [
		["Undo", "undo"], ["Redo", "redo"], [],
		["Cut", "cut"], ["Copy", "copy"], ["Paste", "paste"], ["Duplicate", "duplicate"], [],
		["Select All", "select_all"], ["Delete Selection", "delete"],
		["Quantize Selection", "quantize"], ["Legato Selection", "legato"],
		["Transpose Patterns...", "transpose"], [],
		["New Pattern", "new_pattern"], ["Duplicate Pattern", "duplicate_pattern"], [],
		["Preferences...", "settings"],
	])
	_menu($Frame/Root/MenuBar/Row/View, [
		["Playlist", "view_playlist"], ["Piano Roll", "view_piano"], ["Mixer", "view_mixer"],
		["Channel Rack", "view_rack"], ["Scope", "view_scope"], [],
		["Full Screen", "fullscreen"], ["Interface Colour...", "accent"],
	])
	_menu($Frame/Root/MenuBar/Row/Tools, [
		["Detect Tempo and Key from Audio...", "detect_tempo"], ["Tap Tempo", "tap"], [],
		["Draw Tool", "tool_draw"], ["Select Tool", "tool_select"], ["Slice Tool", "tool_slice"],
		["Mute Tool", "tool_mute"], [],
		["Rescan VST3 Plugins", "rescan_vst3"], ["All Notes Off", "panic"], [],
		["Add Instrument...", "add_instrument"], ["Add Effect...", "add_effect"],
		["Layer Channels...", "layers"], [],
		["Add-ons...", "addons"],
	])
	_addon_menu()
	Addons.changed.connect(_addon_menu)
	_menu($Frame/Root/MenuBar/Row/Help, [
			["Start Performance Log", "perf_log"], ["Open Performance Logs", "perf_folder"],
			["Crash Reports...", "crashes"], [],
			["Keyboard Shortcuts", "help"], ["About Cadmium", "about"]])

	_undo_btn.icon = Icons.get_icon("undo", 14)
	_redo_btn.icon = Icons.get_icon("redo", 14)
	Cd.icon_button(_undo_btn, 23.0)
	Cd.icon_button(_redo_btn, 23.0)
	_undo_btn.pressed.connect(func(): App.undo())
	_redo_btn.pressed.connect(func(): App.redo())

	if not App.project.mixer.is_empty():
		_master_knob.value = float(App.project.mixer[0].vol)
	_master_knob.value_changed.connect(func(v): App.set_mixer_prop(0, "vol", v))
	App.mixer_changed.connect(func():
		if not App.project.mixer.is_empty():
			_master_knob.set_value_silent(float(App.project.mixer[0].vol)))


## Fills one of the scene's menu buttons. The items are a list, which is data,
## not layout -- a scene file would be a worse place for them.
## Renames the Help menu's recording entry, so the same item starts and stops.
func _perf_item(text: String) -> void:
	var pm: PopupMenu = ($Frame/Root/MenuBar/Row/Help as MenuButton).get_popup()
	for i in pm.item_count:
		var meta = pm.get_item_metadata(i)
		if meta != null and String(meta) == "perf_log":
			pm.set_item_text(i, text)
			return


## Whatever the enabled add-ons offer, at the end of the Tools menu. Rebuilt
## when one is switched on or off.
func _addon_menu() -> void:
	var tools: MenuButton = $Frame/Root/MenuBar/Row/Tools
	var pm := tools.get_popup()
	# Everything this added last time comes off first. Add-on entries are the
	# ones whose command starts with "addon:".
	for i in range(pm.item_count - 1, -1, -1):
		var meta = pm.get_item_metadata(i)
		if meta != null and String(meta).begins_with("addon:"):
			pm.remove_item(i)
	while pm.item_count > 0 and pm.is_item_separator(pm.item_count - 1):
		pm.remove_item(pm.item_count - 1)
	_addon_actions = Addons.actions()
	if _addon_actions.is_empty():
		return
	pm.add_separator()
	for i in _addon_actions.size():
		pm.add_item(String(_addon_actions[i].label))
		pm.set_item_metadata(pm.item_count - 1, "addon:%d" % i)


func _menu(mb: MenuButton, items: Array) -> void:
	var pm := mb.get_popup()
	for entry in items:
		if entry.is_empty():
			pm.add_separator()
		elif String(entry[1]) == "@recent":
			var sub := PopupMenu.new()
			sub.name = "RecentMenu"
			pm.add_child(sub)
			pm.add_submenu_item(String(entry[0]), "RecentMenu")
			# Filled when it opens, so it is never out of date.
			sub.about_to_popup.connect(func(): _fill_recent(sub))
			sub.id_pressed.connect(func(id): _open_recent(sub, id))
		else:
			pm.add_item(String(entry[0]))
			pm.set_item_metadata(pm.item_count - 1, String(entry[1]))
	pm.id_pressed.connect(func(id):
		var meta = pm.get_item_metadata(id)
		if meta != null:
			_on_command(String(meta)))


func _fill_recent(sub: PopupMenu) -> void:
	sub.clear()
	var recent: Array = Settings.get_value("recent", [])
	var shown := 0
	for path in recent:
		if not FileAccess.file_exists(String(path)):
			continue
		sub.add_item(String(path).get_file().get_basename(), shown)
		sub.set_item_tooltip(sub.item_count - 1, String(path))
		sub.set_item_metadata(sub.item_count - 1, String(path))
		shown += 1
	if shown == 0:
		sub.add_item("Nothing yet", -1)
		sub.set_item_disabled(sub.item_count - 1, true)
		return
	sub.add_separator()
	sub.add_item("Clear the list", 999)


func _open_recent(sub: PopupMenu, id: int) -> void:
	if id == 999:
		Settings.set_value("recent", [])
		App.status.emit("Recent projects cleared")
		return
	for i in sub.item_count:
		if sub.get_item_id(i) == id:
			var path := String(sub.get_item_metadata(i))
			if not path.is_empty():
				App.load_project(path)
			return


func _on_status(msg: String) -> void:
	status_label.text = msg


func _update_title() -> void:
	get_window().title = App.title()


# ---------------------------------------------------------------------------
func _on_command(cmd: String) -> void:
	if cmd.begins_with("addon:"):
		var i := int(cmd.substr(6))
		if i >= 0 and i < _addon_actions.size():
			var a: Dictionary = _addon_actions[i]
			Addons.run(String(a.addon), String(a.id), self)
		return
	match cmd:
		"new":
			_if_saved(func(): App.new_project())
		"open":
			_if_saved(func():
				_file_dialog(FileDialog.FILE_MODE_OPEN_FILE, ["*.cadmium ; Cadmium project"],
						func(p): App.load_project(p)))
		"save":
			if App.project.path.is_empty():
				_on_command("save_as")
			else:
				App.save_project(App.project.path)
		"save_as":
			_file_dialog(FileDialog.FILE_MODE_SAVE_FILE, ["*.cadmium ; Cadmium project"],
					func(p): App.save_project(p if p.ends_with(".cadmium") else p + ".cadmium"))
		"import_midi":
			_file_dialog(FileDialog.FILE_MODE_OPEN_FILE, ["*.mid, *.midi ; MIDI file"],
					func(p): _import_midi(p))
		"export_midi":
			_file_dialog(FileDialog.FILE_MODE_SAVE_FILE, ["*.mid ; MIDI file"],
					func(p): _export_midi(p if p.ends_with(".mid") else p + ".mid"))
		"score_open":
			_file_dialog(FileDialog.FILE_MODE_OPEN_FILE, [CdScore.FILTER],
					func(p): _open_score(p))
		"score_browse":
			_file_dialog(FileDialog.FILE_MODE_OPEN_FILE, [CdScore.FILTER],
					func(p): _open_score(p), Settings.scores_dir())
		"score_save":
			_file_dialog(FileDialog.FILE_MODE_SAVE_FILE, [CdScore.FILTER],
					func(p): _save_score(p), Settings.scores_dir(),
					_score_filename("." + CdScore.EXT))
		"score_midi_import":
			_file_dialog(FileDialog.FILE_MODE_OPEN_FILE, ["*.mid, *.midi ; MIDI file"],
					func(p): _score_import_midi(p))
		"score_midi_export":
			_file_dialog(FileDialog.FILE_MODE_SAVE_FILE, ["*.mid ; MIDI file"],
					func(p): _score_export_midi(p if p.ends_with(".mid") else p + ".mid"),
					"", _score_filename(".mid"))
		"score_sheet":
			_file_dialog(FileDialog.FILE_MODE_SAVE_FILE, ["*.txt ; Score sheet"],
					func(p): _score_sheet(p if p.ends_with(".txt") else p + ".txt"),
					"", _score_filename(".txt"))
		"score_midi_copy":
			_score_midi_copy()
		"score_midi_paste":
			_score_midi_paste()
		"export":
			_open_dialog(preload("res://ui/dialogs/export_dialog.tscn"))
		"export_stems":
			_open_dialog(preload("res://ui/dialogs/export_dialog.tscn"), {"stems": true})
		"settings":
			_open_dialog(preload("res://ui/dialogs/settings_dialog.tscn"))
		"project_settings":
			_open_dialog(preload("res://ui/dialogs/project_dialog.tscn"))
		"fullscreen":
			_toggle_full_screen()
		"addons":
			_open_dialog(preload("res://ui/dialogs/settings_dialog.tscn"), {"page": 4})
		"accent":
			_open_dialog(preload("res://ui/dialogs/settings_dialog.tscn"), {"page": 1})
		"about", "help":
			_open_dialog(preload("res://ui/dialogs/about_dialog.tscn"), {"help": cmd == "help"})
		"undo":
			App.undo()
		"redo":
			App.redo()
		"perf_log":
			if _perf.running:
				var where := _perf.stop()
				_perf_item("Start Performance Log")
				if where.is_empty():
					App.status.emit("Could not write the performance log")
				else:
					App.status.emit("Performance log written to %s" % where)
					OS.shell_open(where.get_base_dir())
			else:
				_perf.start()
				_perf_item("Stop Performance Log and Save")
				App.status.emit("Recording performance -- use the Help menu again to stop and save")
		"crashes":
			_open_dialog(preload("res://ui/dialogs/crash_dialog.tscn"))
		"perf_folder":
			var dir := OS.get_user_data_dir().path_join("performance")
			DirAccess.make_dir_recursive_absolute(dir)
			OS.shell_open(dir)
		"panic":
			Shortcuts.release_all()
			App.live_all_off()
			App.status.emit("All notes off")
		"rescan_vst3":
			App.status.emit("Scanning VST3 plugins...")
			await get_tree().process_frame
			var n: int = await Plugins.rescan_vst3()
			App.status.emit("Found %d VST3 plugin%s" % [n, "" if n == 1 else "s"])
		"add_instrument":
			CdPluginMenu.open(self, false, func(plug: Dictionary):
				App.add_channel(plug, String(plug.get("name", "Channel")))
				tabs.current_tab = 2)
		"view_playlist":
			tabs.current_tab = 0
		"view_piano":
			tabs.current_tab = 1
		"view_mixer":
			tabs.current_tab = 2
		"view_scope":
			tabs.current_tab = 3
		"view_rack":
			rack.grab_focus_row()
		"copy":
			if tabs.current_tab == 1:
				var n := App.copy_notes(App.selected_notes)
				App.status.emit("Copied %d note%s" % [n, "" if n == 1 else "s"])
			elif tabs.current_tab == 0:
				var n2 := App.copy_clips(App.selected_clips)
				App.status.emit("Copied %d clip%s" % [n2, "" if n2 == 1 else "s"])
		"cut":
			if tabs.current_tab == 1:
				App.cut_notes(App.selected_notes)
				App.status.emit("Cut")
			elif tabs.current_tab == 0:
				App.cut_clips(App.selected_clips)
				App.status.emit("Cut")
		"paste":
			if tabs.current_tab == 1:
				var at: float = piano.paste_anchor()
				App.paste_notes(at)
				App.status.emit("Pasted at %s" % Cd.format_beats(at, App.project.sig_num))
			elif tabs.current_tab == 0:
				var at2: float = playlist.paste_anchor()
				App.paste_clips(at2)
				App.status.emit("Pasted at %s" % Cd.format_beats(at2, App.project.sig_num))
		"transpose":
			transpose_prompt(App.selected_pattern_indices())
		"quantize":
			if tabs.current_tab == 1:
				var sel: Array = App.selected_notes
				if sel.is_empty():
					piano.select_all()
					sel = App.selected_notes
				var n3 := App.quantize_notes(sel, 1.0)
				App.status.emit("Quantized %d note%s to %s" % [n3, "" if n3 == 1 else "s", App.snap])
		"record":
			transport._on_record()
		"metronome":
			var on := not bool(Settings.get_value("metronome", false))
			Settings.set_value("metronome", on)
			Audio.engine.set_metronome(on)
			transport._refresh()
			App.status.emit("Metronome %s" % ("on" if on else "off"))
		"zoom_in", "zoom_out":
			var f := 1.25 if cmd == "zoom_in" else 0.8
			if tabs.current_tab == 1:
				piano.px_per_beat = clampf(piano.px_per_beat * f, 8.0, 600.0)
				piano.queue_redraw()
			elif tabs.current_tab == 0:
				playlist.px_per_beat = clampf(playlist.px_per_beat * f, 2.0, 200.0)
				playlist.queue_redraw()
		"select_all":
			if tabs.current_tab == 1:
				piano.select_all()
			elif tabs.current_tab == 0:
				App.selected_clips.clear()
				for i in App.project.clips.size():
					App.selected_clips.append(i)
				App.selection_changed.emit()
		"delete":
			if tabs.current_tab == 1:
				piano.delete_selection()
			elif tabs.current_tab == 0:
				playlist.delete_selection()
		"tool_draw":
			transport.set_tool(Cd.Tool.DRAW)
		"tool_select":
			transport.set_tool(Cd.Tool.SELECT)
		"tool_slice":
			transport.set_tool(Cd.Tool.SLICE)
		"tool_mute":
			transport.set_tool(Cd.Tool.MUTE)
		"tap":
			transport._on_tap()
		"loop":
			transport.toggle_loop()
		"new_pattern":
			App.add_pattern()
			App.status.emit("New pattern")
		"duplicate_pattern":
			App.duplicate_pattern(App.current_pattern)
			App.status.emit("Duplicated the pattern")
		"duplicate":
			_duplicate_selection()
		"legato":
			tabs.current_tab = 1
			piano.quick_legato()
		"add_effect":
			tabs.current_tab = 2
			mixer.add_effect_here()
		"layers":
			rack.open_layers(App.current_channel)
		"detect_tempo":
			_file_dialog(FileDialog.FILE_MODE_OPEN_FILE,
					[Cd.AUDIO_FILTER], func(p): _detect_tempo(p))
		"quit":
			_if_saved(func(): get_tree().quit())


## Anything that would throw away the project asks first -- and offers to save,
## because "are you sure" with only yes and no is a question you can only answer
## badly. A project with nothing in it yet is not worth asking about.
func _if_saved(then: Callable) -> void:
	if _asking:
		return
	if not App.project.dirty:
		then.call()
		return
	_asking = true
	var dlg := ConfirmationDialog.new()
	dlg.title = "Unsaved changes"
	dlg.dialog_text = "%s has changes you have not saved.\n\nSave them before closing?" % (
			App.project.name if not String(App.project.name).is_empty() else "This project")
	dlg.ok_button_text = "Save"
	dlg.cancel_button_text = "Cancel"
	var discard := dlg.add_button("Discard", true, "discard")
	dlg.content_scale_factor = Settings.ui_scale()
	add_child(dlg)
	dlg.confirmed.connect(func():
		_asking = false
		dlg.queue_free()
		# Saving may need a file dialog first; only carry on once it lands.
		if App.project.path.is_empty():
			_file_dialog(FileDialog.FILE_MODE_SAVE_FILE, ["*.cadmium ; Cadmium project"],
					func(p):
						App.save_project(p if p.ends_with(".cadmium") else p + ".cadmium")
						then.call())
		else:
			App.save_project(App.project.path)
			then.call())
	dlg.custom_action.connect(func(which):
		if which == "discard":
			_asking = false
			dlg.queue_free()
			then.call())
	dlg.canceled.connect(func():
		_asking = false
		dlg.queue_free())
	discard.pressed.connect(func(): dlg.hide())
	dlg.popup_centered()


## Ctrl+D: a copy of the selection placed straight after it, which is how most
## repeated material actually gets written.
func _duplicate_selection() -> void:
	if tabs.current_tab == 1:
		var n: int = App.duplicate_notes(App.selected_notes)
		App.status.emit("Duplicated %d note%s" % [n, "" if n == 1 else "s"])
	elif tabs.current_tab == 0:
		var n2: int = App.duplicate_clips(App.selected_clips)
		App.status.emit("Duplicated %d clip%s" % [n2, "" if n2 == 1 else "s"])


## `start_dir` overrides where the chooser opens -- the scores folder, for the
## things that live there -- and `suggest` is the name a save is offered.
func _file_dialog(mode: int, filters: Array, done: Callable, start_dir: String = "",
		suggest: String = "") -> void:
	var fd := FileDialog.new()
	fd.file_mode = mode
	fd.access = FileDialog.ACCESS_FILESYSTEM
	fd.filters = PackedStringArray(filters)
	# The desktop's own chooser when the platform offers one (the XDG portal on
	# Linux, the shell dialog on Windows); Godot's built-in is the fallback.
	fd.use_native_dialog = DisplayServer.has_feature(DisplayServer.FEATURE_NATIVE_DIALOG_FILE)
	fd.size = Vector2i(900, 620)
	# Wherever you were last, or Cadmium's own folder under Documents the first
	# time -- never the process's working directory.
	var last := start_dir
	if last.is_empty():
		last = String(Settings.get_value("last_dir", ""))
	if last.is_empty() or not DirAccess.dir_exists_absolute(last):
		last = Settings.projects_dir()
	fd.current_dir = last
	if mode == FileDialog.FILE_MODE_SAVE_FILE:
		if not suggest.is_empty():
			fd.current_file = suggest
		elif not App.project.path.is_empty():
			fd.current_file = App.project.path.get_file()
	add_child(fd)
	fd.file_selected.connect(func(p):
		Settings.set_value("last_dir", p.get_base_dir())
		done.call(p)
		fd.queue_free())
	fd.canceled.connect(func(): fd.queue_free())
	fd.popup_centered()


## Dialogs are scenes; `configure` runs before the window is shown so a dialog
## that comes in two flavours knows which one it is before it lays itself out.
## How many semitones, and which patterns. Whole patterns rather than selected
## notes: moving a part into another key is a thing you do to the part.
func transpose_prompt(patterns: Array) -> void:
	if patterns.is_empty():
		App.status.emit("Nothing to transpose")
		return
	var names := []
	for p in patterns:
		names.append(String(App.project.patterns[int(p)].name))
	var dlg := AcceptDialog.new()
	dlg.title = "Transpose"
	dlg.dialog_text = "%s by" % ", ".join(names.slice(0, 3)) if names.size() <= 3 			else "%d patterns by" % names.size()
	var field := SpinBox.new()
	field.min_value = -48
	field.max_value = 48
	field.step = 1
	field.value = 0
	field.prefix = "semitones"
	field.custom_minimum_size.x = 160
	dlg.add_child(field)
	add_child(dlg)
	dlg.confirmed.connect(func():
		var semis := int(field.value)
		var moved := App.transpose_patterns(patterns, semis)
		App.status.emit("Nothing moved" if moved == 0
				else "Moved %d note%s by %+d semitone%s" % [moved, "" if moved == 1 else "s",
						semis, "" if absi(semis) == 1 else "s"])
		dlg.queue_free())
	dlg.canceled.connect(func(): dlg.queue_free())
	dlg.popup_centered()
	field.get_line_edit().grab_focus()
	field.get_line_edit().select_all()


func _open_dialog(scene: PackedScene, args := {}) -> void:
	var dlg = scene.instantiate()
	if dlg.has_method("configure"):
		dlg.configure(args)
	add_child(dlg)
	dlg.popup_centered()
	# And on the screen: a dialog sized in scaled units can be taller than the
	# display, and one placed half off the edge reads as one that never opened.
	Cd.place_window(dlg, self)


# ---------------------------------------------------------------------------
func open_plugin_window(ref: Dictionary) -> Window:
	var key := JSON.stringify(ref)
	if _plugin_windows.has(key) and is_instance_valid(_plugin_windows[key]):
		var w = _plugin_windows[key]
		w.grab_focus()
		return w
	var win = preload("res://ui/panels/plugin_window.tscn").instantiate()
	add_child(win)
	win.setup(ref)
	_plugin_windows[key] = win
	win.close_requested.connect(func(): _close_plugin_window(ref))
	return win


## The plugin's own window, opened or put away. Clicking the name of a plugin
## whose window is already up means you are done with it.
func _toggle_plugin_window(ref: Dictionary) -> void:
	var key := JSON.stringify(ref)
	if _plugin_windows.has(key) and is_instance_valid(_plugin_windows[key]):
		_close_plugin_window(ref)
		return
	open_plugin_window(ref)


## The plugin behind a window has gone: the window goes with it. Anything else
## leaves an interface pointing at nothing, or at whichever plugin moved up to
## take the slot.
func _close_windows_for(handle: int) -> void:
	if handle < 0:
		return
	for key in _plugin_windows.keys():
		var w = _plugin_windows[key]
		if not is_instance_valid(w):
			_plugin_windows.erase(key)
			continue
		if int(w.handle) != handle:
			continue
		_plugin_windows.erase(key)
		if w.has_method("_detach_editor"):
			w._detach_editor()
		w.queue_free()


## Closes one plugin window the way the title bar's close button would.
func _close_plugin_window(ref: Dictionary) -> void:
	var key := JSON.stringify(ref)
	var win = _plugin_windows.get(key)
	_plugin_windows.erase(key)
	if win == null or not is_instance_valid(win):
		return
	if win.has_method("_detach_editor"):
		win._detach_editor()
	win.queue_free()


## Where the pointer was when the window handed over a dropped file, in `ctl`'s
## own coordinates. The signal does not carry a position, so it comes from the
## display server and back through the window and canvas transforms. A drop
## that landed somewhere else entirely reads as far below `ctl`, which is what
## makes it settle under the arrangement instead of on top of it.
func _drop_point(ctl: Control) -> Vector2:
	var win := get_window()
	var in_win := Vector2(DisplayServer.mouse_get_position() - win.position)
	var local: Vector2 = ctl.get_global_transform_with_canvas().affine_inverse() \
			* (win.get_final_transform().affine_inverse() * in_win)
	if not Rect2(Vector2.ZERO, ctl.size).has_point(local):
		return Vector2(0.0, INF)
	return local


## Dropping a file on the window does the obvious thing with it.
func _on_files_dropped(files: PackedStringArray) -> void:
	for f in files:
		var ext := String(f).get_extension().to_lower()
		match ext:
			"cadmium":
				App.load_project(String(f))
			"mid", "midi":
				# Into the pattern being edited when that is what you are
				# looking at, and into the project as a whole otherwise -- the
				# same split the audio drop below makes. Dropping a riff onto an
				# open piano roll and having it build a second arrangement
				# somewhere else is not what anybody means by it.
				if tabs.current_tab == 1:
					_score_import_midi(String(f))
				else:
					_import_midi(String(f))
			CdScore.EXT:
				_open_score(String(f))
			"sf2", "sf3":
				browser._add_soundfont(String(f), String(f).get_file())
			_:
				if not Cd.is_audio_file(String(f)):
					App.status.emit("Cadmium does not open %s files" % ext)
					continue
				if tabs.current_tab == 0:
					playlist.drop_audio_at(String(f), _drop_point(playlist))
					App.status.emit("Added %s to the playlist" % String(f).get_file())
				else:
					browser._add_sample(String(f), String(f).get_file())


## Tempo and key from a file: the engine does the analysis, this reports it and
## offers to apply it.
func _detect_tempo(path: String) -> void:
	App.status.emit("Analysing %s..." % path.get_file())
	await get_tree().process_frame
	var wav := Audio.to_engine_wav(path)
	if wav.is_empty():
		App.status.emit("Could not decode %s" % path.get_file())
		return
	var res: Dictionary = Audio.engine.analyze(wav)
	if not bool(res.get("ok", false)):
		App.status.emit("No tempo found in %s" % path.get_file())
		return
	var dlg := ConfirmationDialog.new()
	dlg.title = "Analysis"
	dlg.dialog_text = "%s\n\nTempo:  %.2f BPM   (confidence %d%%)\nKey:  %s   (confidence %d%%)\nLength:  %.1f s\n\nUse this tempo for the project?" % [
		path.get_file(), float(res.bpm), int(float(res.bpm_confidence) * 100.0),
		Cd.key_name(int(res.key), bool(res.minor)), int(float(res.key_confidence) * 100.0),
		float(res.duration)]
	dlg.ok_button_text = "Set Tempo"
	add_child(dlg)
	dlg.confirmed.connect(func():
		App.set_bpm(float(res.bpm))
		transport._refresh()
		App.status.emit("Tempo set to %.2f" % float(res.bpm))
		dlg.queue_free())
	dlg.canceled.connect(func(): dlg.queue_free())
	dlg.popup_centered()


# ---------------------------------------------------------------------------
# Scores: one pattern, as the piano roll is editing it
# ---------------------------------------------------------------------------
## What a score of the pattern being edited would sensibly be called.
func _score_filename(ext: String) -> String:
	var name := "Score"
	if App.current_pattern < App.project.patterns.size():
		name = String(App.project.patterns[App.current_pattern].get("name", "Score"))
	return name.validate_filename() + ext


func _open_score(path: String) -> void:
	var score := CdScore.load_file(path)
	if score.is_empty():
		App.status.emit("%s is not a Cadmium score" % path.get_file())
		return
	App.snapshot("Open score")
	var res := CdScore.apply(App.project, App.current_pattern, score, true)
	_after_score_change(res)
	App.status.emit("Opened %s: %d note%s on %d channel%s" % [path.get_file(),
			int(res.notes), "" if int(res.notes) == 1 else "s",
			int(res.parts), "" if int(res.parts) == 1 else "s"])


func _save_score(path: String) -> void:
	var out := path if path.ends_with("." + CdScore.EXT) else path + "." + CdScore.EXT
	if CdScore.save(out, App.project, App.current_pattern) == OK:
		App.status.emit("Saved %s" % out.get_file())
	else:
		App.status.emit("Could not write %s" % out.get_file())


## A MIDI file into the pattern being edited, rather than into a project of its
## own: one part lands on the channel the piano roll is pointing at, several get
## a channel each.
func _score_import_midi(path: String) -> void:
	var midi := CdMidi.read_file(path)
	if midi.is_empty():
		App.status.emit("Could not read %s" % path.get_file())
		return
	App.snapshot("Import MIDI")
	var res := CdScore.midi_into_pattern(midi, App.project, App.current_pattern,
			App.current_channel, false)
	if res.is_empty():
		App.status.emit("Nothing in %s to import" % path.get_file())
		return
	_after_score_change(res)
	var tempo := ""
	if bool(res.get("has_tempo", false)) and absf(float(res.bpm) - App.project.bpm) > 0.05:
		tempo = "  (the file is %.2f BPM; the song stays at %.2f)" % [float(res.bpm), App.project.bpm]
	App.status.emit("Imported %d note%s from %s onto %d channel%s%s" % [
			int(res.notes), "" if int(res.notes) == 1 else "s", path.get_file(),
			int(res.parts), "" if int(res.parts) == 1 else "s", tempo])


func _score_export_midi(path: String) -> void:
	if CdScore.export_midi(path, App.project, App.current_pattern) == OK:
		App.status.emit("Wrote %s" % path.get_file())
	else:
		App.status.emit("Could not write %s" % path.get_file())


func _score_sheet(path: String) -> void:
	var score := CdScore.from_pattern(App.project, App.current_pattern)
	if CdScore.save_sheet(path, score) == OK:
		App.status.emit("Wrote %s" % path.get_file())
	else:
		App.status.emit("Could not write %s" % path.get_file())


## The MIDI clipboard. There is no such thing on a desktop, so the notes go on
## the ordinary text clipboard as a MIDI file in base64 behind a marker line:
## another Cadmium pastes it straight back, and anything else sees text it can
## keep rather than nothing at all.
const MIDI_CLIP_MARK := "Cadmium-MIDI-v1:"


func _score_midi_copy() -> void:
	var only: Array = App.selected_notes if not App.selected_notes.is_empty() else []
	var score := CdScore.from_pattern(App.project, App.current_pattern, -1, only)
	if score.is_empty() or (score.parts as Array).is_empty():
		App.status.emit("Nothing to copy")
		return
	var bytes := CdScore.midi_bytes(score)
	DisplayServer.clipboard_set(MIDI_CLIP_MARK + Marshalls.raw_to_base64(bytes))
	var n := 0
	for part in score.parts:
		n += (part.notes as Array).size()
	App.status.emit("Copied %d note%s to the MIDI clipboard" % [n, "" if n == 1 else "s"])


func _score_midi_paste() -> void:
	var text := DisplayServer.clipboard_get().strip_edges()
	if not text.begins_with(MIDI_CLIP_MARK):
		App.status.emit("There is no MIDI on the clipboard")
		return
	var bytes := Marshalls.base64_to_raw(text.substr(MIDI_CLIP_MARK.length()))
	var midi := CdMidi.read(bytes)
	if midi.is_empty():
		App.status.emit("The MIDI on the clipboard could not be read")
		return
	App.snapshot("Paste MIDI")
	var res := CdScore.midi_into_pattern(midi, App.project, App.current_pattern,
			App.current_channel, false, piano.paste_anchor())
	_after_score_change(res)
	App.status.emit("Pasted %d note%s" % [int(res.notes), "" if int(res.notes) == 1 else "s"])


## Anything that has put notes into the pattern from outside: the rack may have
## grown, so the engine is brought up to date and everything looking at the
## project is told.
func _after_score_change(res: Dictionary) -> void:
	App.selected_notes.clear()
	if int(res.get("channels_made", 0)) > 0:
		App.sync_all()
		App.channels_changed.emit()
	else:
		App.push_pattern(App.current_pattern)
	App.patterns_changed.emit()
	App.selection_changed.emit()
	piano.queue_redraw()


# ---------------------------------------------------------------------------
func _import_midi(path: String) -> void:
	var res := CdMidi.import_file(path, App.project)
	if res.is_empty():
		App.status.emit("Could not read %s" % path.get_file())
		return
	App.sync_all()
	App.patterns_changed.emit()
	App.channels_changed.emit()
	App.project_loaded.emit()
	App.status.emit("Imported %d track%s from %s" % [res.tracks, "" if res.tracks == 1 else "s", path.get_file()])


func _export_midi(path: String) -> void:
	if CdMidi.export_file(path, App.project) == OK:
		App.status.emit("Wrote %s" % path.get_file())
	else:
		App.status.emit("Could not write %s" % path.get_file())


# ---------------------------------------------------------------------------
# Window sizing and test hooks
# ---------------------------------------------------------------------------
## Godot derives a window minimum from its child Controls, but the root here is
## a plain Control, which reports nothing -- so mirror the layout's real minimum
## up, capped to the usable screen.
func _sync_window_minimum() -> void:
	var want := get_combined_minimum_size()
	var screen := DisplayServer.screen_get_usable_rect(DisplayServer.window_get_current_screen())
	var scale := get_window().content_scale_factor
	var px := Vector2i(int(want.x * scale), int(want.y * scale))
	px.x = mini(px.x, screen.size.x - 40)
	px.y = mini(px.y, screen.size.y - 60)
	get_window().min_size = px


func _parse_args() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--cd-shot="):
			var v := arg.substr(10)
			var parts := v.split(",")
			_shot_path = parts[0]
			_shot_view = parts[1] if parts.size() > 1 else ""
			_run_shot()
		elif arg.begins_with("--cd-audiotest"):
			_run_audiotest()
		elif arg.begins_with("--cd-inputtest"):
			_run_inputtest(arg.substr(14).lstrip("="))
		elif arg.begins_with("--cd-voicetest"):
			_run_voicetest(arg.substr(14).lstrip("="))
		elif arg.begins_with("--cd-lagtest="):
			_run_lagtest(arg.substr(13))
		elif arg.begins_with("--cd-selftest="):
			_run_selftest(arg.substr(14))
		elif arg.begins_with("--cd-vsttest="):
			_run_vsttest(arg.substr(13))
		elif arg.begins_with("--cd-livetest"):
			_run_livetest(arg.substr(13).lstrip("="))
		elif arg.begins_with("--cd-themetest"):
			_run_themetest()
		elif arg.begins_with("--cd-rolltest"):
			_run_rolltest(arg.substr(13).lstrip("="))
		elif arg.begins_with("--cd-paramtest"):
			_run_paramtest(arg.substr(14).lstrip("="))
		elif arg.begins_with("--cd-fxtest"):
			_run_fxtest(arg.substr(11).lstrip("="))
		elif arg.begins_with("--cd-crashtest"):
			_run_crashtest()
		elif arg.begins_with("--cd-vstscan="):
			_run_vstscan(arg.substr(13))
		elif arg.begins_with("--cd-statetest"):
			_run_statetest(arg.substr(14).lstrip("="))
		elif arg.begins_with("--cd-uitest"):
			_run_uitest()
		elif arg.begins_with("--cd-plugshot="):
			_run_plugshot(arg.substr(14))
		elif arg.begins_with("--cd-iconshot="):
			_run_iconshot(arg.substr(14))
		elif arg.begins_with("--cd-open="):
			App.load_project(arg.substr(10))
		elif arg.ends_with(".cadmium"):
			App.load_project(arg)


## Every icon rasterised on its own, so the artwork can be checked for being
## centred in its own square without a button's layout in the way.
func _run_iconshot(dir: String) -> void:
	await _wait_for_app()
	DirAccess.make_dir_recursive_absolute(dir)
	for name in CdIcons.names():
		var tex := CdIcons.render(String(name), CdPalette.ACCENT, 64)
		if tex == null:
			continue
		var img: Image = (tex as ImageTexture).get_image()
		img.save_png(dir.path_join("%s.png" % name))
	print("icons: wrote %d to %s" % [CdIcons.names().size(), dir])
	get_tree().quit(0)


## Puts one plugin on a channel, opens its window, and holds it open long
## enough for a picture to be taken of what is actually on screen.
##   --cd-plugshot=<plugin id>[,<seconds>]
func _run_plugshot(arg: String) -> void:
	await _wait_for_app()
	var parts := arg.split(",")
	var want := String(parts[0])
	var hold := int(parts[1]) if parts.size() > 1 else 25
	var plug := {}
	for p in Plugins.stock:
		if String(p.id) == want:
			plug = p
	if plug.is_empty():
		print("plugshot: no plugin called %s" % want)
		get_tree().quit(1)
		return
	var idx: int = App.add_channel(plug, String(plug.name))
	for i in 20:
		await get_tree().process_frame
	open_plugin_window({"kind": "channel", "index": idx})
	var ref := {"kind": "channel", "index": idx}
	var t := Time.get_ticks_msec()
	var said := false
	while Time.get_ticks_msec() - t < hold * 1000:
		await get_tree().process_frame
		var h: int = App.handle_for(ref)
		if not said and Time.get_ticks_msec() - t > 4000:
			said = true
			print("plugshot: handle=%d open=%s ready=%s showing=%s" % [h,
					Audio.engine.plugin_editor_open(h),
					Audio.engine.plugin_editor_ready(h),
					Audio.engine.plugin_editor_showing(h)])
			print("plugshot: READY")
	get_tree().quit(0)


## Drives the editing gestures with synthetic mouse events.
func _run_uitest() -> void:
	await _wait_for_app()
	await get_tree().process_frame
	var bad: int = await CdUiTest.run(self, get_tree())
	get_tree().quit(mini(bad, 120))


## Opens every hosted plugin's own editor and checks it really drew something.
## Frames per second with a plugin editor up, printed once a second. A plugin's
## interface is serviced from this loop, so its responsiveness is bounded by it.
func _fps_watch() -> void:
	var t := 0.0
	while is_inside_tree():
		await get_tree().process_frame
		t += get_process_delta_time()
		if t >= 1.0:
			t = 0.0
			var extra := ""
			for k in _plugin_windows.keys():
				var w = _plugin_windows[k]
				if is_instance_valid(w) and w.has_method("_generic_size"):
					extra += "  win %s" % str(w.size)
			print("fps %d  windows %d  notes held %d%s" % [Engine.get_frames_per_second(),
					1 + _plugin_windows.size(), App.live_notes_held(), extra])


func _run_vsttest(arg: String) -> void:
	await _wait_for_app()
	var parts := arg.split(",")
	if Plugins.vst3.is_empty():
		await Plugins.rescan_vst3()
	var bad: int = await CdVstTest.run(self, parts[0], parts[1] if parts.size() > 1 else "",
			int(parts[2]) if parts.size() > 2 else 0)
	get_tree().quit(mini(bad, 120))


## Plays the demo for a few seconds through the real audio device and reports
## what actually came out of the mixer and out of Godot's master bus. The
## offline render tests the DSP; this tests the callback.
## Drops the same audio file onto the playlist over and over and reports what
## drawing it costs. A long .wav on the timeline was the thing that made the
## interface crawl, and "it lags" is not something that can be fixed twice
## without a number attached to it.
##
## `--cd-lagtest=<file>[,<count>]`
func _run_lagtest(arg: String) -> void:
	await _wait_for_app()
	var parts := arg.split(",")
	var path := parts[0]
	var count := int(parts[1]) if parts.size() > 1 else 100
	if not FileAccess.file_exists(path):
		print("lagtest: no such file: %s" % path)
		get_tree().quit(1)
		return
	App.new_project()
	await get_tree().process_frame
	var t_load := Time.get_ticks_msec()
	var asset: int = App.add_audio_asset(path)
	if asset < 0:
		print("lagtest: could not read %s" % path)
		get_tree().quit(1)
		return
	print("lagtest: read %s in %d ms" % [path.get_file(), Time.get_ticks_msec() - t_load])
	var length: float = App.asset_length_beats(path)
	while App.project.tracks.size() < 8:
		App.project.tracks.append({"name": "Track %d" % (App.project.tracks.size() + 1),
				"height": 46.0, "mute": false, "color": App.project.tracks.size()})
	for i in count:
		App.add_clip(Cd.ClipType.AUDIO, asset, i % maxi(1, App.project.tracks.size()),
				float(i) * length * 0.25, length, {"name": path.get_file()})
	App.clip_edit_done()
	tabs.current_tab = 0
	await get_tree().process_frame
	print("lagtest: %d clips of %.1f beats each" % [count, length])

	# Three passes over the arrangement at three zoom levels, timing the frames,
	# once with the waveforms drawn and once without so the two can be told
	# apart.
	for waves: bool in [true, false]:
		playlist.set("draw_waveforms", waves)
		print("lagtest: waveforms %s" % ("on" if waves else "off"))
		await _lagtest_pass(length)
	playlist.set("draw_waveforms", true)
	get_tree().quit(0)


func _lagtest_pass(length: float) -> void:
	for zoom: float in [4.0, 24.0, 120.0]:
		playlist.px_per_beat = zoom
		playlist.scroll_beat = 0.0
		await get_tree().process_frame
		var worst := 0.0
		var total := 0.0
		var frames := 90
		for f in frames:
			playlist.scroll_beat += length * 0.05
			playlist.queue_redraw()
			var t0 := Time.get_ticks_usec()
			await get_tree().process_frame
			var dt := float(Time.get_ticks_usec() - t0) / 1000.0
			worst = maxf(worst, dt)
			total += dt
		print("lagtest: %6.1f px/beat   average %5.2f ms   worst %5.2f ms   (%.0f fps average)"
				% [zoom, total / float(frames), worst, 1000.0 / maxf(0.01, total / float(frames))])


func _run_audiotest() -> void:
	await _wait_for_app()
	CdFixture.build(App)
	for i in 8:
		await get_tree().process_frame
	App.set_mode(Cd.Mode.SONG)
	print("audiotest: channels=%d engine_channels=%d handles=%s clips=%d patterns=%d" % [
		App.project.channels.size(), Audio.engine.channel_count(), str(App.channel_handles),
		App.project.clips.size(), App.project.patterns.size()])
	print("audiotest: mode=%d playing=%s" % [Audio.engine.get_mode(), str(Audio.engine.is_playing())])
	Audio.play(true)
	var peak_master := 0.0
	var peak_bus := -120.0
	var frames := 0
	var voices := 0
	var cpu := 0.0
	for i in 240:
		await get_tree().process_frame
		var p: Vector2 = Audio.peak(0)
		peak_master = maxf(peak_master, maxf(p.x, p.y))
		peak_bus = maxf(peak_bus, AudioServer.get_bus_peak_volume_left_db(0, 0))
		voices = maxi(voices, Audio.engine.voices())
		cpu = maxf(cpu, Audio.engine.cpu())
		frames += 1
	print("audiotest: frames=%d position=%.2f beats" % [frames, Audio.position()])
	print("audiotest: engine master peak %.4f  (%.1f dBFS)" % [peak_master, Cd.gain_to_db(peak_master)])
	print("audiotest: godot bus peak %.1f dBFS" % peak_bus)
	print("audiotest: max voices %d, engine cpu %.1f%%" % [voices, cpu * 100.0])
	Audio.stop()
	get_tree().quit(0 if peak_master > 0.01 else 2)


## The machine's own input, end to end: open it, put it on a strip, record a
## take, and say what arrived and what became of it.
##   --cd-inputtest[=<seconds>]
func _run_inputtest(arg: String) -> void:
	await _wait_for_app()
	var secs := float(arg) if arg.is_valid_float() else 4.0
	print("inputtest: devices %s" % str(Audio.input_devices()))
	print("inputtest: device \"%s\"" % Audio.input_device())
	App.set_input_track(1, true)
	await get_tree().process_frame
	print("inputtest: open=%s problem=%s engine track=%d" % [
			Audio.input_on, Audio.input_problem, Audio.engine.input_track()])
	if not Audio.input_on:
		get_tree().quit(2)
		return
	# Muted, so a test run is silent however the machine is wired up.
	App.set_mixer_prop(1, "mute", true)
	App.set_mode(Cd.Mode.SONG)
	App.set_recording(true)
	Audio.play(true)
	var peak := 0.0
	var t := Time.get_ticks_msec()
	var said := 0
	while Time.get_ticks_msec() - t < int(secs * 1000.0):
		await get_tree().process_frame
		peak = maxf(peak, Audio.engine.input_peak())
		var el := Time.get_ticks_msec() - t
		if el / 1000 > said:
			said = el / 1000
			print("inputtest:  %ds  pushed %.2f s  take %.2f s  beat %.2f" % [said,
					float(Audio.input_frames) / 48000.0, Audio.engine.take_seconds(),
					Audio.position()])
	print("inputtest: input peak %.4f  take %.2f s  armed=%s" % [
			peak, Audio.engine.take_seconds(), Audio.engine.record_armed()])
	Audio.stop()
	for i in 10:
		await get_tree().process_frame
	App.set_recording(false)
	var made := []
	for c in App.project.clips:
		if int(c.type) == Cd.ClipType.AUDIO:
			made.append("%s at beat %.2f for %.2f (asset %d)" % [
					String(c.get("name", "?")), float(c.start), float(c.length), int(c.index)])
	print("inputtest: samples=%d clips=%s" % [App.project.assets.size(), str(made)])
	for a in App.project.assets:
		print("inputtest: take file %s" % String(a.get("path", "")))
	get_tree().quit(0 if not made.is_empty() else 3)


## A synth, a vocoder on it, and the machine's own input wired into the
## vocoder's sidechain in one click -- which is the whole of what someone
## wanting to sing through it has to do.
##   --cd-voicetest[=<seconds>]
func _run_voicetest(arg: String) -> void:
	await _wait_for_app()
	var secs := float(arg) if arg.is_valid_float() else 8.0
	var idx: int = App.add_stock_channel("cd.ember")
	App.set_channel_prop(idx, "mixer", 1)
	for i in 6:
		await get_tree().process_frame
	# Silent: this is a measurement, not a performance.
	App.set_mixer_prop(0, "vol", 0.0)
	var hold := func():
		for k in [40, 47, 52, 59]:
			App.live_note_on(k, 0.85, "test")
	var drop := func():
		for k in [40, 47, 52, 59]:
			App.live_note_off(k, "test")
	hold.call()
	print("voicetest: carrier alone -> strip1 %.4f (channel %.4f)"
			% [await _watch_strip(1, 1.5), Audio.engine.channel_level(idx)])
	drop.call()

	App.set_insert(1, 0, CdProject.plugin_dict("stock", "cd.vocoder", "", "Vocoder"))
	for i in 8:
		await get_tree().process_frame
	var voc: int = App.handle_for({"kind": "insert", "track": 1, "slot": 0})
	hold.call()
	print("voicetest: vocoder in, nothing speaking -> strip1 %.4f (handle %d, channel %.4f)"
			% [await _watch_strip(1, 1.5), voc, Audio.engine.channel_level(idx)])
	drop.call()

	var input_strip := App.wire_input_to(1)
	for i in 8:
		await get_tree().process_frame
	print("voicetest: input on strip %d, sidechain sources %s"
			% [input_strip, str(App.sidechain_sources(1))])
	if input_strip < 0:
		get_tree().quit(2)
		return
	hold.call()
	var master := 0.0
	var chan := 0.0
	var bands := 0.0
	var modulator := 0.0
	var inp := 0.0
	var t := Time.get_ticks_msec()
	var struck := -1
	while Time.get_ticks_msec() - t < int(secs * 1000.0):
		await get_tree().process_frame
		# The stock patch is a stab, not a pad: struck again every half second
		# so there is something for the voice to speak through.
		var half := int((Time.get_ticks_msec() - t) / 500)
		if half != struck:
			struck = half
			drop.call()
			hold.call()
		master = maxf(master, maxf(Audio.peak(1).x, Audio.peak(1).y))
		chan = maxf(chan, Audio.engine.channel_level(idx))
		var a2: PackedFloat32Array = Audio.engine.plugin_aux(voc, 0, 34)
		for i in range(1, a2.size()):
			bands = maxf(bands, a2[i])
		var m: PackedFloat32Array = Audio.engine.plugin_aux(voc, 1, 1)
		if m.size() > 0:
			modulator = maxf(modulator, m[0])
		inp = maxf(inp, Audio.engine.input_peak())
	drop.call()
	print("voicetest: input %.4f  modulator %.4f  loudest band %.3f  channel %.4f  strip1 %.4f"
			% [inp, modulator, bands, chan, master])
	get_tree().quit(0 if bands > 0.05 and master > 0.001 else 3)


## The loudest strip 1 gets over a stretch of seconds.
func _watch_strip(track: int, secs: float) -> float:
	var peak := 0.0
	var t := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t < int(secs * 1000.0):
		await get_tree().process_frame
		peak = maxf(peak, maxf(Audio.peak(track).x, Audio.peak(track).y))
	return peak


func _run_selftest(out_dir: String) -> void:
	await _wait_for_app()
	# A bare name means a folder of Cadmium's own rather than one in whatever
	# directory it happened to be started from -- which, run from the project,
	# is the project, and the renders would then be packaged into the build.
	if not out_dir.is_absolute_path():
		out_dir = OS.get_user_data_dir().path_join("selftest").path_join(out_dir)
		print("selftest: writing to %s" % out_dir)
	var failed: int = await CdSelfTest.run(App, get_tree(), out_dir)
	get_tree().quit(1 if failed > 0 else 0)


## App builds its first project a frame after startup; every command-line hook
## has to let that happen or it edits a project that is about to be replaced.
func _wait_for_app() -> void:
	var guard := 0
	while not App.initialized and guard < 240:
		await get_tree().process_frame
		guard += 1


func _run_shot() -> void:
	await _wait_for_app()
	if _shot_view.begins_with("dialog:"):
		_shot_arg = _shot_view.substr(7)
		_shot_view = "dialog"
		# A dialog is a window of its own and does not appear in a picture of
		# this one. For a screenshot, and only then, they are drawn inside it.
		get_tree().root.gui_embed_subwindows = true
	if _shot_view.begins_with("zoomed:"):
		_shot_arg = _shot_view.substr(7)
		_shot_view = "zoomed"
	if _shot_view.begins_with("audioclip:"):
		_shot_arg = _shot_view.substr(10)
		_shot_view = "audioclip"
	if _shot_view.begins_with("audiostretch:"):
		_shot_arg = _shot_view.substr(13)
		_shot_view = "audioclip_stretched"
	if _shot_view.begins_with("audioscroll:"):
		_shot_arg = _shot_view.substr(12)
		_shot_view = "audioclip_scrolled"
	if _shot_view.begins_with("sampler:"):
		_shot_arg = _shot_view.substr(8)
		_shot_view = "sampler"
	if _shot_view.begins_with("prism:"):
		_shot_arg = _shot_view.substr(6)
		_shot_view = "prism"
	if _shot_view.begins_with("vocoderwired"):
		_shot_view = "vocoderwired"
	if _shot_view.begins_with("stock:"):
		_shot_arg = _shot_view.substr(6)
		_shot_view = "stock"
	if _shot_view.begins_with("stockinst:"):
		_shot_arg = _shot_view.substr(10)
		_shot_view = "stockinst"
	if _shot_view.begins_with("stockplay:"):
		_shot_arg = _shot_view.substr(10)
		_shot_view = "stockplay"
	if _shot_view.begins_with("themedialog:"):
		_shot_arg = _shot_view.substr(12)
		_shot_view = "themedialog"
	if _shot_view.begins_with("theme:"):
		_shot_arg = _shot_view.substr(6)
		_shot_view = "theme"
	if _shot_view.begins_with("themelive:"):
		_shot_arg = _shot_view.substr(10)
		_shot_view = "themelive"
	if _shot_view.begins_with("vst3hold:"):
		_shot_arg = _shot_view.substr(9)
		_shot_view = "vst3hold"
	if _shot_view.begins_with("demo_"):
		CdFixture.build(App)
		for i in 6:
			await get_tree().process_frame
		_shot_view = _shot_view.substr(5)
	# After demo_, so that demo_piano:<pattern> works as well as piano:<pattern>.
	if _shot_view.begins_with("piano:"):
		_shot_arg = _shot_view.substr(6)
		_shot_view = "piano"
	match _shot_view:
		"piano":
			# piano:<pattern>[:<channel>] picks what to photograph. The comma
			# after the path is already the view's own separator, so these are
			# colon-separated.
			tabs.current_tab = 1
			if not _shot_arg.is_empty():
				var want := _shot_arg.split(":")
				App.select_pattern(int(want[0]))
				if want.size() > 1:
					App.select_channel(int(want[1]))
				for i in 6:
					await get_tree().process_frame
			piano.focus_channel(App.current_channel)
		"mixer":
			tabs.current_tab = 2
		"automated":
			# A strip with something driving its fader beside one without, so
			# the lighter drawing can be compared against the plain one.
			CdFixture.build(App)
			tabs.current_tab = 2
			App.automate(Cd.AutoTarget.MIXER_VOL, {}, 1)
			App.automate(Cd.AutoTarget.MIXER_PAN, {}, 2)
			for i in 8:
				await get_tree().process_frame
		"playlist":
			tabs.current_tab = 0
		"plugin":
			if not App.project.channels.is_empty():
				open_plugin_window({"kind": "channel", "index": 0})
		"scale":
			# The piano roll in a key, so the highlighting can be seen.
			CdFixture.build(App)
			tabs.current_tab = 1
			piano.scale_root = 0
			piano.scale_name = "Minor"
			piano.queue_redraw()
			for i in 8:
				await get_tree().process_frame
		"themedialog":
			# A window that was already open when the colours changed, against
			# the same window opened afterwards.
			get_tree().root.gui_embed_subwindows = true
			if _shot_arg == "live":
				_on_command("settings")
				for i in 10:
					await get_tree().process_frame
				Accent.apply(Color("#4a90d9"), false)
				Secondary.apply(Color("#3d444d"), false)
			else:
				Accent.apply(Color("#4a90d9"), false)
				Secondary.apply(Color("#3d444d"), false)
				for i in 4:
					await get_tree().process_frame
				_on_command("settings")
			for i in 12:
				await get_tree().process_frame
		"themelive":
			# The same colours as "theme", but applied after the interface is
			# already up: anything that differs between the two pictures is
			# something that did not follow the change.
			CdFixture.build(App)
			tabs.current_tab = int(_shot_arg) if _shot_arg.is_valid_int() else 2
			for i in 10:
				await get_tree().process_frame
			Accent.apply(Color("#4a90d9"), false)
			Secondary.apply(Color("#3d444d"), false)
			for i in 10:
				await get_tree().process_frame
		"theme":
			# The interface in a different pair of colours, so both halves can
			# be seen to have moved.
			CdFixture.build(App)
			Accent.apply(Color("#4a90d9"), false)
			Secondary.apply(Color("#3d444d"), false)
			tabs.current_tab = int(_shot_arg) if _shot_arg.is_valid_int() else 2
			for i in 10:
				await get_tree().process_frame
		"sampler":
			# A sample in the project with its sampler open, so both can be
			# looked at at once.
			var wav := ""
			for d in ["/usr/share/sounds/alsa", "/usr/share/sounds"]:
				var dir := DirAccess.open(d)
				if dir == null:
					continue
				for fn in dir.get_files():
					if fn.ends_with(".wav"):
						wav = d.path_join(fn)
						break
				if not wav.is_empty():
					break
			if wav.is_empty():
				return
			get_tree().root.gui_embed_subwindows = true
			var ai := App.add_audio_asset(wav)
			App.set_sample_setting(ai, "normalize", true)
			await get_tree().process_frame
			var w := CdSampleWindow.open(self, ai)
			w.position = Vector2i(40, 40)
			if _shot_arg == "auto":
				# Playing, with a lane driving the stretching: the knobs light
				# up and the lane rides their rims.
				var lane := App.automate(Cd.AutoTarget.SAMPLE_SPEED, {}, ai)
				App.project.automations[lane].points = [
					{"beat": 0.0, "value": 0.25, "curve": 0.0},
					{"beat": 8.0, "value": 4.0, "curve": 0.0},
				]
				for c in App.project.clips:
					if int(c.type) == Cd.ClipType.AUTOMATION and int(c.index) == lane:
						c["length"] = 8.0
				App.clip_edit_done()
				App.push_automation()
				App.automate(Cd.AutoTarget.SAMPLE_PITCH, {}, ai)
				App.set_mode(Cd.Mode.SONG)
				Audio.seek(5.0)
				Audio.play(false)
			for i in 12:
				await get_tree().process_frame
		"autoedit":
			# A lane with a shape in it, open in its own editor.
			CdFixture.build(App)
			get_tree().root.gui_embed_subwindows = true
			var lane := App.automate(Cd.AutoTarget.MIXER_VOL, {}, 1)
			App.set_automation_points(lane, [
				{"beat": 0.0, "value": 0.2, "curve": 0.0},
				{"beat": 4.0, "value": 1.1, "curve": 0.6},
				{"beat": 8.0, "value": 0.5, "curve": -0.4},
				{"beat": 12.0, "value": 0.9, "curve": 0.0},
			])
			var aw := CdAutomationWindow.open(self, lane)
			aw.position = Vector2i(40, 40)
			for i in 12:
				await get_tree().process_frame
		"routing":
			# A strip feeding a few others, so the lines under the mixer have
			# something to draw.
			CdFixture.build(App)
			tabs.current_tab = 2
			App.select_mixer(1)
			App.set_route(1, 3, true)
			App.set_route(1, 5, true)
			for i in 8:
				await get_tree().process_frame
		"arrangement":
			# A song with something in it, so the picker's previews have
			# something to show.
			CdFixture.build(App)
			tabs.current_tab = 0
			for i in 8:
				await get_tree().process_frame
		"busy":
			# The waiting screen a hosted plugin's window shows while the
			# plugin builds its interface, held still so it can be looked at.
			get_tree().root.gui_embed_subwindows = true
			App.add_stock_channel("cd.ember")
			await get_tree().process_frame
			var w = open_plugin_window({"kind": "channel", "index": 0})
			await get_tree().process_frame
			# Cadmium's own plugins are never kept waiting, so the state has to
			# be put on deliberately to be looked at.
			w.content_scale_factor = 1.0
			w.position = Vector2i(60, 60)
			w.size = Vector2i(460, 330)
			w._native = true
			w._hole.visible = true
			w._scroll.visible = false
			w._show_busy(true)
			for i in 20:
				await get_tree().process_frame
		"vst3hold":
			await _hold_vst3(_shot_arg)
			_fps_watch()
			_shot_path = ""      # stay open; the X server is screenshotted instead
			return
		"vst3":
			for entry in Plugins.vst3:
				if bool(entry.get("instrument", false)):
					var idx: int = App.add_vst3_channel(entry)
					for i in 30:
						await get_tree().process_frame
					open_plugin_window({"kind": "channel", "index": idx})
					break
		"fx":
			# The effect stack with something in it: two effects, the first
			# folded out to its quick controls.
			tabs.current_tab = 2
			App.select_mixer(1)
			App.set_insert(1, 0, CdProject.plugin_dict("stock", "cd.filter", "", "Filter"))
			App.set_insert(1, 1, CdProject.plugin_dict("stock", "cd.reverb", "", "Reverb"))
			App.project.mixer[1].inserts[0]["expanded"] = true
			App.mixer_changed.emit()
			for i in 6:
				await get_tree().process_frame
		"stock":
			# One of the new stock plugins with its own display, for a look at
			# how it comes out.
			tabs.current_tab = 2
			App.select_mixer(1)
			App.set_insert(1, 0, CdProject.plugin_dict("stock", _shot_arg, "", _shot_arg))
			App.mixer_changed.emit()
			for i in 6:
				await get_tree().process_frame
			open_plugin_window({"kind": "insert", "track": 1, "slot": 0})
			for i in 30:
				await get_tree().process_frame
		"vocoderwired":
			# The vocoder with its modulator wired the way its own panel wires
			# it: one button, and the machine's input is on a muted strip
			# feeding this one's sidechain.
			tabs.current_tab = 2
			App.select_mixer(1)
			App.add_stock_channel("cd.ember")
			App.set_channel_prop(0, "mixer", 1)
			App.set_insert(1, 0, CdProject.plugin_dict("stock", "cd.vocoder", "", "Vocoder"))
			for i in 8:
				await get_tree().process_frame
			open_plugin_window({"kind": "insert", "track": 1, "slot": 0})
			for i in 10:
				await get_tree().process_frame
			App.wire_input_to(1)
			for i in 180:
				await get_tree().process_frame
				if i % 20 == 0:
					for k in [40, 47, 52, 59]:
						App.live_note_off(k, "shot")
						App.live_note_on(k, 0.85, "shot")
		"stockplay":
			# The same, with something going through it, so the displays that
			# read the plugin's own output have an output to read.
			var kind: String = "insert"
			if bool(Plugins.stock_by_id(_shot_arg).get("instrument", false)):
				var ci: int = App.add_stock_channel(_shot_arg)
				App.add_note(App.current_pattern, ci, 0.0, 8.0, 45, 0.9)
				App.add_note(App.current_pattern, ci, 0.0, 8.0, 52, 0.9)
				App.note_edit_done(App.current_pattern)
				for i in 6:
					await get_tree().process_frame
				Audio.play(true)
				for i in 40:
					await get_tree().process_frame
				open_plugin_window({"kind": "channel", "index": ci})
			else:
				var si: int = App.add_stock_channel("cd.pulse")
				App.add_note(App.current_pattern, si, 0.0, 8.0, 40, 0.9)
				App.add_note(App.current_pattern, si, 0.0, 8.0, 47, 0.9)
				App.note_edit_done(App.current_pattern)
				App.set_insert(1, 0, CdProject.plugin_dict("stock", _shot_arg, "", _shot_arg))
				App.mixer_changed.emit()
				for i in 6:
					await get_tree().process_frame
				Audio.play(true)
				for i in 40:
					await get_tree().process_frame
				open_plugin_window({"kind": kind, "track": 1, "slot": 0})
			for i in 40:
				await get_tree().process_frame
		"stockinst":
			var idx: int = App.add_stock_channel(_shot_arg)
			for i in 8:
				await get_tree().process_frame
			open_plugin_window({"kind": "channel", "index": idx})
			for i in 30:
				await get_tree().process_frame
		"zoomed":
			# Zoomed right out, to see how the ruler thins its numbers.
			CdFixture.build(App)
			tabs.current_tab = 0
			for i in 6:
				await get_tree().process_frame
			playlist.px_per_beat = float(_shot_arg.to_float()) if not _shot_arg.is_empty() else 2.5
			playlist.scroll_beat = 0.0
			playlist.queue_redraw()
			for i in 4:
				await get_tree().process_frame
		"audioclip":
			# A real audio clip on the playlist, so the waveform can be seen.
			tabs.current_tab = 0
			playlist.add_audio_clip(_shot_arg, 0, 0.0)
			for i in 10:
				await get_tree().process_frame
		"audioclip_stretched":
			# The same file three times: as long as it is, dragged out to twice
			# that, and played at double speed. A clip is a stretch of the
			# arrangement and the sample under it runs at its own rate, so all
			# three have to draw the audio at the same scale and stop where the
			# audio stops.
			tabs.current_tab = 0
			playlist.add_audio_clip(_shot_arg, 0, 0.0)
			for i in 6:
				await get_tree().process_frame
			var natural: float = float(App.project.clips[0].length)
			playlist.add_audio_clip(_shot_arg, 1, 0.0)
			playlist.add_audio_clip(_shot_arg, 2, 0.0)
			for i in 6:
				await get_tree().process_frame
			App.update_clip(1, {"length": natural * 2.0})
			App.update_clip(2, {"length": natural * 0.5})
			App.clip_edit_done()
			for i in 10:
				await get_tree().process_frame
		"audioclip_scrolled":
			# The same clip, zoomed in and scrolled so it runs off both edges:
			# the case where the waveform used to be drawn over the track
			# headers and past the end of the panel.
			tabs.current_tab = 0
			playlist.add_audio_clip(_shot_arg, 0, 0.0)
			for i in 6:
				await get_tree().process_frame
			playlist.px_per_beat = 90.0
			playlist.scroll_beat = 40.0
			playlist.queue_redraw()
			for i in 6:
				await get_tree().process_frame
		"prism":
			# A picture loaded and playing, so the panel can be looked at.
			var idx: int = App.add_stock_channel("cd.prism")
			for i in 6:
				await get_tree().process_frame
			App.load_plugin_image({"kind": "channel", "index": idx}, _shot_arg, 128, 256)
			App.add_note(App.current_pattern, idx, 0.0, 4.0, 60, 0.9)
			App.note_edit_done(App.current_pattern)
			Audio.play(true)
			open_plugin_window({"kind": "channel", "index": idx})
			for i in 60:
				await get_tree().process_frame
		"dialog":
			# Any dialog, by command name, so the scenes can be looked at.
			_on_command(_shot_arg)
			for i in 12:
				await get_tree().process_frame
		"picker":
			var pick = preload("res://ui/dialogs/plugin_picker.tscn").instantiate()
			pick.effects_only = true
			get_tree().root.add_child(pick)
			for i in 8:
				await get_tree().process_frame
		"layers":
			CdFixture.build(App)
			for i in 6:
				await get_tree().process_frame
			var dlg = preload("res://ui/dialogs/layers_dialog.tscn").instantiate()
			dlg.channel = 0
			get_tree().root.add_child(dlg)
			for i in 8:
				await get_tree().process_frame
		"sf2":
			var fonts := Plugins.soundfonts()
			if not fonts.is_empty():
				browser._add_soundfont(String(fonts[0].path), String(fonts[0].name))
				for i in 20:
					await get_tree().process_frame
		"scope":
			CdFixture.build(App)
			App.set_mode(Cd.Mode.SONG)
			Audio.play(true)
			tabs.current_tab = 3
			for i in 150:
				await get_tree().process_frame
		"pianolive":
			CdFixture.build(App)
			App.set_mode(Cd.Mode.SONG)
			Audio.play(true)
			tabs.current_tab = 1
			piano.focus_channel(3)
			for i in 130:
				await get_tree().process_frame
		"eq":
			App.set_insert(1, 0, CdProject.plugin_dict("stock", "cd.eq8", "", "EQ Eight"))
			await get_tree().process_frame
			open_plugin_window({"kind": "insert", "track": 1, "slot": 0})
		"tool_draw":
			transport.set_tool(Cd.Tool.DRAW)
		"tool_select":
			transport.set_tool(Cd.Tool.SELECT)
		"tool_slice":
			transport.set_tool(Cd.Tool.SLICE)
		"tool_mute":
			transport.set_tool(Cd.Tool.MUTE)
		"tap":
			transport._on_tap()
		"detect_tempo":
			_file_dialog(FileDialog.FILE_MODE_OPEN_FILE,
					[Cd.AUDIO_FILTER], func(p): _detect_tempo(p))
		"demo":
			_demo_song()
	for i in 12:
		await get_tree().process_frame
	var img := get_viewport().get_texture().get_image()
	if img != null:
		img.save_png(_shot_path)
		print("Cadmium: wrote ", _shot_path)
	# Sub-windows are their own viewports; walk the tree and shoot each one.
	var n := 0
	var stack: Array = [get_tree().root]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		for child in node.get_children():
			stack.append(child)
		if node is Window and node != get_window() and node.visible:
			var wi = (node as Window).get_texture().get_image()
			if wi != null:
				wi.save_png(_shot_path.get_basename() + "_win%d.png" % n)
				print("Cadmium: wrote window shot ", n)
				n += 1
	get_tree().quit()


## Opens one hosted plugin and leaves it open, for the X-server screenshot
## harness (Godot's own framebuffer never contains a native plugin window).
func _hold_vst3(want: String) -> void:
	for entry in Plugins.vst3:
		var name := String(entry.name)
		if not want.is_empty() and not name.to_lower().contains(want.to_lower()):
			continue
		var ref := {}
		if bool(entry.get("instrument", false)):
			ref = {"kind": "channel", "index": App.add_vst3_channel(entry)}
		else:
			App.set_insert(1, 0, CdProject.plugin_dict("vst3", String(entry.cid),
					String(entry.path), name))
			ref = {"kind": "insert", "track": 1, "slot": 0}
		for i in 40:
			await get_tree().process_frame
		print("holding: ", name)
		open_plugin_window(ref)
		return
	print("no VST3 matching ", want)


func _demo_song() -> void:
	CdFixture.build(App)
	await get_tree().process_frame


## Adding and removing an effect, timed, with real hosted plugins in the chain.
## "Adding a filter is slow" is a claim about a number, and the number is worth
## having before and after: the cost is nearly all in the work done around the
## plugin, not in the plugin itself.
##
## `--cd-fxtest[=<count>]`
func _run_fxtest(arg: String) -> void:
	await _wait_for_app()
	var args := arg.split(",")
	var count := int(args[0]) if args[0].is_valid_int() and int(args[0]) > 0 else 6
	var heavy := args[1] if args.size() > 1 else "Vital"
	if Plugins.vst3.is_empty():
		await Plugins.rescan_vst3()
	var fx := []
	for p in Plugins.vst3:
		if not bool(p.get("instrument", false)) and String(p.get("error", "")).is_empty():
			fx.append(p)
	if fx.is_empty():
		print("fxtest: no VST3 effects found; the timings would say nothing")
		get_tree().quit(1)
		return
	App.new_project()
	await get_tree().process_frame
	tabs.current_tab = 2
	App.select_mixer(1)
	await get_tree().process_frame
	# A heavy hosted instrument in the project is what makes the difference
	# between a snapshot costing nothing and costing a second: its state is the
	# expensive thing to ask for.
	for p in Plugins.vst3:
		if bool(p.get("instrument", false)) and String(p.get("name", "")).contains(heavy):
			var t0 := Time.get_ticks_usec()
			App.add_vst3_channel(p)
			await get_tree().process_frame
			print("fxtest: instrument %s loaded in %.1f ms"
					% [String(p.name), float(Time.get_ticks_usec() - t0) / 1000.0])
			break
	print("fxtest: %d slots on insert 1, from %d VST3 effect(s)" % [count, fx.size()])

	var adds := []
	for i in count:
		var e: Dictionary = fx[i % fx.size()]
		var plug := CdProject.plugin_dict("vst3", String(e.cid), String(e.path), String(e.name))
		var t0 := Time.get_ticks_usec()
		App.set_insert(1, i, plug)
		adds.append(float(Time.get_ticks_usec() - t0) / 1000.0)
		await get_tree().process_frame
		print("fxtest:   add %-22s %8.1f ms" % [String(e.name), adds[-1]])

	# The pieces on their own, so the total can be attributed.
	_fxtest_phase("snapshot (state capture + copy)", func(): App.snapshot("bench"))
	_fxtest_phase("sync_all", func(): App.sync_all())
	_fxtest_phase("  _sync_plugins", func(): App.call("_sync_plugins"))
	_fxtest_phase("  push_channels", func(): App.push_channels())
	_fxtest_phase("  push_mixer", func(): App.push_mixer())
	_fxtest_phase("  push_patterns", func(): App.push_patterns())
	_fxtest_phase("  push_playlist", func(): App.push_playlist())
	_fxtest_phase("  push_automation", func(): App.push_automation())
	_fxtest_phase("mixer UI rebuild", func(): App.mixer_changed.emit())
	_fxtest_phase("plugin drop-down", func():
		var pm := CdPluginMenu.open(self, true, func(_p): pass)
		pm.hide())
	_fxtest_phase("bypass toggle", func(): App.set_insert_flag(1, 0, "bypass", false))

	_fxtest_phase("remove first slot", func(): App.remove_insert(1, 0))
	await get_tree().process_frame
	_fxtest_phase("remove last slot", func(): App.remove_insert(1, maxi(0, count - 2)))
	await get_tree().process_frame
	_fxtest_phase("move slot", func(): App.move_insert(1, 0, 2))
	await get_tree().process_frame
	get_tree().quit(0)


func _fxtest_phase(label: String, work: Callable) -> void:
	var t0 := Time.get_ticks_usec()
	work.call()
	print("fxtest:   %-24s %8.1f ms" % [label, float(Time.get_ticks_usec() - t0) / 1000.0])


## Every hosted plugin, asked whether moving one of its controls from Cadmium
## actually moves it. "I changed it in the interface and nothing happened" is a
## claim about one plugin, and the only way to find which is to ask all of them.
##
## Falls over on purpose, to prove the report gets written.
##
## `--cd-crashtest`. Leaves a note first, so what comes out can be checked for
## saying what was being done as well as for existing at all.
func _run_crashtest() -> void:
	await _wait_for_app()
	CdCrash.note("opening the plugin that was asked for by --cd-crashtest")
	await get_tree().process_frame
	Audio.engine.crash_now()


## Plugins loaded somewhere they cannot take the program with them.
##
## `--cd-vstscan=<list file>,<results file>`. Reads one bundle path per line and
## writes a line of JSON for each: first that it is about to open it, then what
## it found. A plugin that brings the process down leaves its "about to open"
## line as the last thing in the file, which is how whatever started this knows
## which one it was.
func _run_vstscan(arg: String) -> void:
	await _wait_for_app()
	# This copy of Cadmium exists to be taken down by a plugin. Its reports are
	# kept -- they say which plugin and how far it got -- under a name of their
	# own, so the next real start does not read one as the program crashing.
	CdCrash.arm(CdCrash.SCAN_PREFIX)
	var bits := arg.split(",")
	if bits.size() < 2:
		get_tree().quit(2)
		return
	var listing := FileAccess.open(bits[0], FileAccess.READ)
	if listing == null:
		get_tree().quit(2)
		return
	var paths := listing.get_as_text().split("\n", false)
	listing.close()
	var out := FileAccess.open(bits[1], FileAccess.WRITE)
	if out == null:
		get_tree().quit(2)
		return
	for path in paths:
		var bundle := String(path).strip_edges()
		if bundle.is_empty():
			continue
		out.store_line(JSON.stringify({"probing": bundle}))
		out.flush()
		var entries: Array = Audio.engine.probe_vst3_bundle(bundle)
		out.store_line(JSON.stringify({"path": bundle, "entries": entries}))
		out.flush()
	out.store_line(JSON.stringify({"done": true}))
	out.close()
	get_tree().quit(0)


## `--cd-statetest[=<filter>]`
## Whether a plugin that has been set up stays set up while the rest of the
## program is used.
func _run_statetest(filter: String) -> void:
	await _wait_for_app()
	var bad: int = await CdStateTest.run(self, filter)
	get_tree().quit(1 if bad > 0 else 0)


## `--cd-paramtest[=<filter>]`
func _run_paramtest(arg: String) -> void:
	await _wait_for_app()
	if Plugins.vst3.is_empty():
		await Plugins.rescan_vst3()
	# `<filter>,<from>,<count>`: a plugin that takes the process down with it
	# must not stop the rest being asked, so the run can be picked up again
	# from where it stopped.
	var bits := arg.split(",")
	var filter := bits[0]
	var from := int(bits[1]) if bits.size() > 1 else 0
	var count := int(bits[2]) if bits.size() > 2 else 0
	var wanted := []
	for e in Plugins.vst3:
		if not String(e.get("error", "")).is_empty():
			continue
		if filter.is_empty() or String(e.name).to_lower().contains(filter.to_lower()):
			wanted.append(e)
	var total := wanted.size()
	if from > 0:
		wanted = wanted.slice(mini(from, total))
	if count > 0:
		wanted = wanted.slice(0, count)
	print("paramtest: %d of %d plugin%s, from %d"
			% [wanted.size(), total, "" if total == 1 else "s", from])
	var deaf := []
	var split := []
	var mute := []
	var checked := 0
	for e in wanted:
		App.new_project()
		await get_tree().process_frame
		var plug := CdProject.plugin_dict("vst3", String(e.cid), String(e.path), String(e.name))
		var ref := {}
		if bool(e.get("instrument", false)):
			App.project.add_channel(String(e.name), plug, 1)
			ref = {"kind": "channel", "index": 0}
		else:
			# An effect needs something to work on, so it goes on the insert
			# chain of a strip that has one of Cadmium's own synths feeding it.
			App.add_stock_channel("cd.ember")
			App.project.mixer[1].inserts[0] = plug
			ref = {"kind": "insert", "track": 1, "slot": 0}
		App.sync_all()
		App.add_note(0, 0, 0.0, 1.5, 60, 0.9)
		App.note_edit_done(0)
		Audio.engine.set_mode(Cd.Mode.PATTERN)
		Audio.engine.set_current_pattern(0)
		await get_tree().process_frame
		var h := App.handle_for(ref)
		if h < 0:
			print("  --    %-32s would not load" % String(e.name))
			continue
		# The shape of the plugin. One object that both processes and draws is
		# allowed and common; what is not allowed is us making a second copy of
		# it to draw with, which leaves its own controls driving nothing.
		var info: Dictionary = App.plugin_info(ref)
		if bool(info.get("single_component", false)) and not bool(info.get("controller_is_component", false)):
			split.append(String(e.name))
			print("  FAIL  %-32s its interface is a second copy of the plugin" % String(e.name))
			continue
		var params: Array = App.plugin_params(ref)
		var moved := 0
		var stuck := []
		# A handful spread across the list rather than the first few: the ones
		# at the top are often the least interesting.
		var step: int = maxi(1, params.size() / 6)
		var i := 0
		while i < params.size() and moved < 6:
			var p: Dictionary = params[i]
			i += step
			if bool(p.get("readonly", false)):
				continue      # a readout; the plugin owns it
			var idx := int(p.index)
			var before: float = float(Audio.engine.plugin_param_live(h, idx))
			if before < 0.0:
				continue
			# Somewhere it certainly is not now.
			var want: float = 0.85 if before < 0.5 else 0.15
			App.set_plugin_param(ref, idx, want)
			await get_tree().process_frame
			var after: float = float(Audio.engine.plugin_param_live(h, idx))
			moved += 1
			# A stepped control lands on one of its steps, and which way it
			# rounds is the plugin's business -- some floor, some round. What
			# matters is that it landed within a step of what it was told.
			var steps := int(p.get("steps", 0))
			var slack: float = 0.02 if steps <= 0 else 1.0 / float(steps) + 0.02
			if absf(after - want) > slack:
				stuck.append("%s (%.2f -> %.2f, asked %.2f%s)" % [String(p.name), before, after, want,
						", %d steps" % steps if steps > 0 else ""])
		checked += 1
		# And the other direction: a control moved inside the plugin's own
		# interface has to reach its audio side, which is the host's job and
		# not the plugin's.
		var relay := await _paramtest_relay(ref, h, params)
		if not String(relay).is_empty():
			mute.append(String(e.name))
			stuck.append(relay)
		if stuck.is_empty():
			print("  ok    %-32s %d of %d controls answered%s"
					% [String(e.name), moved, params.size(),
					"  (one object)" if bool(info.get("single_component", false)) else ""])
		else:
			deaf.append(String(e.name))
			print("  FAIL  %-32s %s" % [String(e.name), ", ".join(stuck)])
		App.new_project()
		await get_tree().process_frame
	print("")
	print("paramtest: %d checked" % checked)
	if not split.is_empty():
		print("  drawn by a second copy of themselves: %s" % ", ".join(split))
	if not mute.is_empty():
		print("  their own controls do not reach their audio: %s" % ", ".join(mute))
	if not deaf.is_empty():
		print("  ignored what they were told: %s" % ", ".join(deaf))
	get_tree().quit(mini(deaf.size() + split.size(), 120))


## Finds a control that audibly does something, then moves it the way the
## plugin's own interface would and checks that it still does. Empty when all
## is well, or when nothing this plugin has makes an audible difference.
func _paramtest_relay(ref: Dictionary, h: int, params: Array) -> String:
	var base := _paramtest_rms("base")
	if base < 0.0:
		return ""
	# The same render again, to see how much the answer moves on its own: a
	# compressor or a reverb carries state from one render into the next, and
	# that drift must not be mistaken for a control doing nothing.
	var noise: float = absf(_paramtest_rms("base2") - base)
	var step: int = maxi(1, params.size() / 5)
	var i := 0
	var tried := 0
	while i < params.size() and tried < 5:
		var p: Dictionary = params[i]
		i += step
		if bool(p.get("readonly", false)):
			continue
		tried += 1
		var idx := int(p.index)
		var was: float = float(Audio.engine.plugin_param_live(h, idx))
		var want: float = 0.9 if was < 0.5 else 0.1
		# Through the host, which is known to work: does this control do
		# anything you can hear at all?
		App.set_plugin_param(ref, idx, want)
		await get_tree().process_frame
		# Rendered twice, the second one kept: a compressor or a maximiser
		# carries the last render's envelope into the next, and a plugin that
		# ramps its parameters spends the first one getting there.
		_paramtest_rms("host")
		var host_rms := _paramtest_rms("host")
		App.set_plugin_param(ref, idx, was)
		await get_tree().process_frame
		if host_rms < 0.0 or absf(host_rms - base) < maxf(maxf(0.0005, base * 0.05), noise * 4.0):
			continue    # nothing audible over the drift; try another control
		# The same move, made the way the plugin's own knob makes it.
		Audio.engine.plugin_simulate_gui_edit(h, idx, want)
		await get_tree().process_frame
		_paramtest_rms("gui")
		var gui_rms := _paramtest_rms("gui")
		var live_after: float = float(Audio.engine.plugin_param_live(h, idx))
		# Deliberately narrow: not "did it sound the same" -- a plugin with an
		# envelope or an oscillator in it answers differently depending on what
		# it was doing a moment ago, and chasing that produces false alarms by
		# the dozen. What is asked is whether the plugin's own control did
		# anything at all, when the same move from Cadmium plainly did.
		if absf(gui_rms - base) < maxf(0.0005, noise * 2.0):
			return ("%s: moving it from the plugin's own control does nothing, while the same move "
					+ "from Cadmium does (%.4f against %.4f, from %.4f; the plugin reads %.3f, asked %.3f)") \
					% [String(p.name), gui_rms, host_rms, base, live_after, want]
		return ""
	return ""


## Two beats of the project, as a level. -1 when it could not be rendered.
func _paramtest_rms(tag: String) -> float:
	var path := OS.get_user_data_dir().path_join("paramtest_%s.wav" % tag)
	if not Audio.engine.render(path, 0.0, 2.0, 0.1, 24, false):
		return -1.0
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return -1.0
	var data := f.get_buffer(f.get_length())
	f.close()
	var sum := 0.0
	var n := 0
	var i := 44
	while i + 3 <= data.size():
		var v: int = data[i] | (data[i + 1] << 8) | (data[i + 2] << 16)
		if v & 0x800000:
			v -= 0x1000000
		var x := float(v) / 8388608.0
		sum += x * x
		n += 1
		i += 3
	return sqrt(sum / maxf(1.0, float(n)))


## A run of short notes on one key, at several densities and on several
## instruments, counting how many of them can actually be heard.
##
## `--cd-rolltest[=<instrument id>]`
func _run_rolltest(only: String) -> void:
	await _wait_for_app()
	var dir := OS.get_user_data_dir().path_join("rolltest")
	DirAccess.make_dir_recursive_absolute(dir)
	# "vst3:<filter>" runs the hosted instruments instead of Cadmium's own.
	var vst3 := only.begins_with("vst3")
	var insts := []
	if vst3:
		if Plugins.vst3.is_empty():
			await Plugins.rescan_vst3()
		var want := only.substr(5)
		for e in Plugins.vst3:
			if not bool(e.get("instrument", false)):
				continue
			if want.is_empty() or String(e.name).to_lower().contains(want.to_lower()):
				insts.append(e)
	elif not only.is_empty():
		insts = [only]
	else:
		for p in Plugins.stock:
			if bool(p.instrument) and String(p.id) != "cd.prism":
				insts.append(String(p.id))
	# How long each note is, as a multiple of the gap between them: staccato,
	# just touching, and overlapping the ones after it -- which is what drawing
	# a run of notes with a long length already chosen produces.
	var lengths: Array = [0.8, 1.0, 4.0]
	print("rolltest: %d instrument%s" % [insts.size(), "" if insts.size() == 1 else "s"])
	var bad := 0
	for id in insts:
		for hold: float in lengths:
			var line := "  %-20s x%-4.1f" % [(String(id.name) if vst3 else String(id)), hold]
			for step: float in [0.25, 0.125, 0.0625]:
				var count := int(round(4.0 / step))
				App.new_project()
				await get_tree().process_frame
				if vst3:
					App.add_vst3_channel(id)
				elif String(id) == "cd.sampler":
					var smp := CdProject.plugin_dict("stock", "cd.sampler", "", "Sampler")
					smp["strings"]["sample"] = _rolltest_sample()
					App.project.add_channel("Sampler", smp, 1)
					App.sync_all()
				elif String(id) == "cd.soundfont":
					var sf := _rolltest_soundfont()
					if sf.is_empty():
						line += "  (no soundfont)"
						break
					var sfp := CdProject.plugin_dict("stock", "cd.soundfont", "", "SoundFont")
					sfp["strings"]["file"] = sf
					App.project.add_channel("SoundFont", sfp, 1)
					App.sync_all()
				else:
					App.add_stock_channel(String(id))
				for i in count:
					App.add_note(0, 0, float(i) * step, step * hold, 60, 0.9)
				App.note_edit_done(0)
				App.project.patterns[0]["length"] = 4.0
				App.push_pattern(0)
				Audio.engine.set_mode(Cd.Mode.PATTERN)
				Audio.engine.set_current_pattern(0)
				await get_tree().process_frame
				var path := dir.path_join("roll.wav")
				var made: bool = Audio.engine.render_loop(path, 0.0, 4.0, 0.05, 24, false, false)
				var secs: float = 4.0 * 60.0 / float(App.project.bpm)
				var heard := 0
				var loud := 0.0
				var slices := []
				for i in count:
					var r := _roll_rms(path, secs * float(i) / float(count),
							secs * float(i + 1) / float(count))
					slices.append(r)
					loud = maxf(loud, r)
				for r in slices:
					if float(r) > loud * 0.1:
						heard += 1
				if not made:
					heard = -1
				line += "  1/%d: %d/%d" % [int(round(4.0 / step)), heard, count]
				if heard < count - 1:
					bad += 1
			print(line)
	print("")
	print("rolltest: %d run%s lost notes" % [bad, "" if bad == 1 else "s"])
	get_tree().quit(mini(bad, 120))


## The first soundfont installed on this machine, if any.
func _rolltest_soundfont() -> String:
	for d in Plugins.soundfonts():
		return String(d.path)
	return ""


## A short click of a file for the sampler to play, written once.
func _rolltest_sample() -> String:
	var path := OS.get_user_data_dir().path_join("rolltest").path_join("click.wav")
	if FileAccess.file_exists(path):
		return path
	var rate := int(Audio.engine.sample_rate())
	var frames := int(rate * 0.08)
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_buffer("RIFF".to_ascii_buffer())
	f.store_32(36 + frames * 4)
	f.store_buffer("WAVEfmt ".to_ascii_buffer())
	f.store_32(16)
	f.store_16(1)
	f.store_16(2)
	f.store_32(rate)
	f.store_32(rate * 4)
	f.store_16(4)
	f.store_16(16)
	f.store_buffer("data".to_ascii_buffer())
	f.store_32(frames * 4)
	for i in frames:
		var env: float = 1.0 - float(i) / float(frames)
		var v := int(clampf(sin(TAU * 440.0 * float(i) / float(rate)) * env, -1.0, 1.0) * 20000.0)
		f.store_16(v & 0xFFFF)
		f.store_16(v & 0xFFFF)
	f.close()
	return path


func _roll_rms(path: String, from_sec: float, to_sec: float) -> float:
	if not FileAccess.file_exists(path) or to_sec <= from_sec:
		return 0.0
	var f := FileAccess.open(path, FileAccess.READ)
	var data := f.get_buffer(f.get_length())
	f.close()
	var rate := float(Audio.engine.sample_rate())
	var i: int = 44 + int(from_sec * rate) * 6
	var last: int = mini(data.size(), 44 + int(to_sec * rate) * 6)
	var sum := 0.0
	var n := 0
	while i + 3 <= last:
		var v: int = data[i] | (data[i + 1] << 8) | (data[i + 2] << 16)
		if v & 0x800000:
			v -= 0x1000000
		var x := float(v) / 8388608.0
		sum += x * x
		n += 1
		i += 3
	return sqrt(sum / maxf(1.0, float(n)))


## The same run of short notes, but played through the audio device rather than
## rendered offline. What the user hears comes out of the callback, and the
## callback sees the pattern one block at a time.
##
## `--cd-livetest[=<instrument id>][,<notes per beat>]`
func _run_livetest(arg: String) -> void:
	await _wait_for_app()
	var bits := arg.split(",")
	var id := bits[0] if not bits[0].is_empty() else "cd.pluck"
	var per_beat := int(bits[1]) if bits.size() > 1 else 4
	var step := 1.0 / float(maxi(1, per_beat))
	var count := int(round(4.0 / step))
	App.new_project()
	await get_tree().process_frame
	App.add_stock_channel(id)
	for i in count:
		App.add_note(0, 0, float(i) * step, step * 0.8, 60, 0.9)
	App.note_edit_done(0)
	App.project.patterns[0]["length"] = 4.0
	App.push_pattern(0)
	App.set_mode(Cd.Mode.PATTERN)
	await get_tree().process_frame
	print("livetest: %s, %d notes over 4 beats" % [id, count])

	# Watched through the mixer's own meter, which is what the callback filled.
	Audio.play(true)
	var seen := []
	var last := 0.0
	var t := 0.0
	var secs: float = 4.0 * 60.0 / float(App.project.bpm)
	while t < secs * 2.0:
		await get_tree().process_frame
		t += get_process_delta_time()
		var m: PackedFloat32Array = Audio.engine.meters()
		var lvl: float = maxf(m[4], m[5]) if m.size() > 5 else 0.0
		# An onset is a jump in level after a quieter moment.
		if lvl > 0.02 and lvl > last * 1.6:
			seen.append(t)
		last = lvl
	Audio.engine.stop()
	# Two laps of the pattern were played, so twice the notes should be heard.
	var wanted := count * 2
	print("livetest: heard %d onsets, expected about %d" % [seen.size(), wanted])
	var gaps := []
	for i in range(1, seen.size()):
		gaps.append(seen[i] - seen[i - 1])
	if not gaps.is_empty():
		gaps.sort()
		print("livetest: gap between onsets: shortest %.3f s, middle %.3f s, longest %.3f s"
				% [gaps[0], gaps[gaps.size() / 2], gaps[gaps.size() - 1]])
	get_tree().quit(0 if seen.size() >= wanted / 2 else 1)


## What changing the interface's colours costs. "The theme is laggy" is a claim
## about a number of milliseconds, and the picker asks for a new colour on
## every frame it is dragged.
func _run_themetest() -> void:
	await _wait_for_app()
	CdFixture.build(App)
	for i in 6:
		await get_tree().process_frame
	# Where the time goes, not just how much of it there is.
	var t_icons := Time.get_ticks_usec()
	Icons.repaint()
	print("themetest: repainting %d cached icons took %.1f ms" % [Icons._cache.size(),
			float(Time.get_ticks_usec() - t_icons) / 1000.0])
	var colours := [Color("#4a90d9"), Color("#5fbf6f"), Color("#b06fd0"), Color("#e8a33d")]
	for what in ["primary", "secondary"]:
		var worst := 0.0
		var total := 0.0
		for c in colours:
			var t0 := Time.get_ticks_usec()
			if what == "primary":
				Accent.apply(c, false)
			else:
				Secondary.apply(c, false)
			var ms := float(Time.get_ticks_usec() - t0) / 1000.0
			worst = maxf(worst, ms)
			total += ms
		print("themetest: %-10s average %6.2f ms   worst %6.2f ms" % [what,
				total / float(colours.size()), worst])
	Accent.apply(CdPalette.ACCENT_DEFAULT, false)
	Secondary.apply(CdPalette.SECONDARY_DEFAULT, false)

	# And what a drag costs: the picker asks on every frame, and the answer has
	# to be that most of those cost nothing at all.
	var t1 := Time.get_ticks_usec()
	for i in 60:
		Secondary.apply_soon(Color.from_hsv(float(i) / 60.0, 0.3, 0.28))
		await get_tree().process_frame
	print("themetest: sixty frames of dragging the picker took %.1f ms in total"
			% (float(Time.get_ticks_usec() - t1) / 1000.0))
	get_tree().quit(0)
