extends PanelContainer
## Browser: instruments, effects, soundfonts, samples, the project's own
## patterns, and recent files. Double-click puts a thing to work.

var _roots := {}
var _pick_channel := -1
var _player: AudioStreamPlayer = null
var _playing_path := ""
## Whether clicking a file plays it. On by default: hearing a sample is the
## whole reason to click one.
var _preview_on := true


@onready var _tree: Tree = $Col/Tree
@onready var _search: LineEdit = $Col/Search
@onready var _listen_btn: Button = $Col/Caption/Row/Listen
@onready var _rescan_btn: Button = $Col/Caption/Row/Rescan


func _ready() -> void:
	# The layout is browser.tscn. Icons are rasterised at run time, so they are
	# set here rather than baked into it.
	($Col/Caption/Row/Icon as TextureRect).texture = Icons.get_icon("browser", 14)
	_listen_btn.icon = Icons.get_icon("play", 13)
	Cd.icon_button(_listen_btn, 22.0)
	_listen_btn.toggled.connect(func(on):
		_preview_on = on
		if not on:
			stop_audition())

	_rescan_btn.icon = Icons.get_icon("search", 13)
	Cd.icon_button(_rescan_btn, 22.0)
	_rescan_btn.pressed.connect(func():
		App.status.emit("Scanning VST3 plugins...")
		await get_tree().process_frame
		var n: int = await Plugins.rescan_vst3()
		App.status.emit("Found %d VST3 plugin%s" % [n, "" if n == 1 else "s"])
		rebuild())

	_search.text_changed.connect(func(_t): rebuild())
	_tree.set_drag_forwarding(_drag_data, Callable(), Callable())
	_tree.item_activated.connect(_on_activate)
	_tree.item_selected.connect(_on_select)

	Plugins.catalog_changed.connect(rebuild)
	App.patterns_changed.connect(rebuild)
	App.project_loaded.connect(rebuild)
	# "In This Project" is only worth having if it keeps up with the project.
	App.channels_changed.connect(rebuild)
	App.mixer_changed.connect(rebuild)
	App.playlist_changed.connect(rebuild)
	rebuild()


## Samples and patterns can be dragged straight onto the playlist.
func _drag_data(_pos: Vector2) -> Variant:
	var it := _tree.get_selected()
	if it == null:
		return null
	var meta = it.get_metadata(0)
	if typeof(meta) != TYPE_DICTIONARY:
		return null
	var kind := String(meta.get("kind", ""))
	if not kind in ["sample", "pattern", "sf2", "stock_inst", "vst3_inst", "stock_fx", "vst3_fx"]:
		return null
	var preview := Label.new()
	preview.text = "  %s  " % it.get_text(0)
	preview.theme_type_variation = "Caption"
	_tree.set_drag_preview(preview)
	var data: Dictionary = meta.duplicate()
	data["label"] = it.get_text(0)
	data["cadmium"] = true
	return data


func focus_instruments() -> void:
	if _roots.has("instruments"):
		_roots["instruments"].collapsed = false
	_search.grab_focus()


func pick_instrument_for(channel: int) -> void:
	_pick_channel = channel
	focus_instruments()
	App.status.emit("Pick an instrument in the browser to replace this channel's")


func rebuild() -> void:
	_tree.clear()
	_roots.clear()
	var filter := _search.text.strip_edges().to_lower()
	var root := _tree.create_item()

	# What this project actually uses, at the top where it is worth having:
	# the instruments on its channels, the effects in its racks, and every
	# sample and soundfont it has loaded. Opening one takes you to it.
	_project_section(root, filter)

	var inst := _section(root, "Instruments", "synth")
	_roots["instruments"] = inst
	for p in Plugins.stock:
		if not bool(p.instrument):
			continue
		_leaf(inst, String(p.name), {"kind": "stock_inst", "id": String(p.id)},
				_icon_for_stock(String(p.id)), filter, String(p.category))
	var v_inst := 0
	for p in Plugins.vst3:
		if bool(p.get("instrument", false)):
			_leaf(inst, String(p.name), {"kind": "vst3_inst", "entry": p}, "vst", filter, String(p.vendor))
			v_inst += 1

	var fx := _section(root, "Effects", "fx")
	for p in Plugins.stock:
		if bool(p.instrument):
			continue
		_leaf(fx, String(p.name), {"kind": "stock_fx", "id": String(p.id)}, "fx", filter, String(p.category))
	for p in Plugins.vst3:
		if not bool(p.get("instrument", false)):
			_leaf(fx, String(p.name), {"kind": "vst3_fx", "entry": p}, "vst", filter, String(p.vendor))

	var sf := _section(root, "SoundFonts", "soundfont")
	var fonts := Plugins.soundfonts()
	for f in fonts:
		_leaf(sf, String(f.name), {"kind": "sf2", "path": String(f.path)}, "soundfont", filter, String(f.dir))
	if fonts.is_empty():
		_leaf(sf, "Add a folder in Preferences...", {"kind": "settings"}, "settings", filter, "")

	var smp := _section(root, "Samples", "wave")
	var found := Plugins.samples()
	for f in found:
		_leaf(smp, String(f.name), {"kind": "sample", "path": String(f.path)}, "file_audio", filter, String(f.dir))
	if found.is_empty():
		_leaf(smp, "Add a folder in Preferences...", {"kind": "settings"}, "settings", filter, "")

	var pat := _section(root, "Patterns", "grid")
	for i in App.project.patterns.size():
		_leaf(pat, String(App.project.patterns[i].name), {"kind": "pattern", "index": i}, "note", filter, "")

	# Bundles that would not open. Without this a plugin that failed to load is
	# indistinguishable from one that was never installed, and the only report
	# anyone can make is "it didn't appear".
	if not Plugins.problems.is_empty():
		var bad := _section(root, "Would not load", "panic")
		for p in Plugins.problems:
			_leaf(bad, String(p.get("name", "?")), {"kind": "vst3_problem", "entry": p},
					"panic", filter, String(p.get("error", "")))

	var recent := _section(root, "Recent", "open")
	for p in Settings.get_value("recent", []):
		_leaf(recent, String(p).get_file(), {"kind": "project", "path": String(p)}, "open", filter, String(p))

	# A filter that matched nothing anywhere is worth saying out loud.
	if not filter.is_empty():
		for key in _roots.keys():
			pass


func _project_section(root: TreeItem, filter: String) -> void:
	var used := _section(root, "In This Project", "note")
	used.collapsed = false
	var any := false

	for i in App.project.channels.size():
		var c: Dictionary = App.project.channels[i]
		var plug: Dictionary = c.plugin
		var vst := String(plug.get("kind", "stock")) == "vst3"
		# "Kick - Kick" says nothing twice; a channel named after its
		# instrument just gets the one name.
		var pname := String(plug.get("name", ""))
		var label := String(c.name) if pname == String(c.name) or pname.is_empty() \
				else "%s  -  %s" % [String(c.name), pname]
		_leaf(used, label,
				{"kind": "used_channel", "index": i},
				"vst" if vst else _icon_for_stock(String(plug.get("id", ""))),
				filter, "channel %d" % (i + 1))
		any = true

	for t in App.project.mixer.size():
		var m: Dictionary = App.project.mixer[t]
		for slot in (m.inserts as Array).size():
			var fx = m.inserts[slot]
			if fx == null:
				continue
			var is_vst := String(fx.get("kind", "stock")) == "vst3"
			_leaf(used, "%s  -  %s" % [String(m.name), String(fx.get("name", ""))],
					{"kind": "used_insert", "track": t, "slot": slot},
					"vst" if is_vst else "fx", filter, "insert %d" % (slot + 1))
			any = true

	# Files the project has pulled in, wherever they came from.
	var seen := {}
	for i in App.project.channels.size():
		var strings: Dictionary = App.project.channels[i].plugin.get("strings", {})
		for key in ["sample", "soundfont", "ir"]:
			var path := String(strings.get(key, ""))
			if path.is_empty() or seen.has(path):
				continue
			seen[path] = true
			_leaf(used, path.get_file(), {"kind": "used_file", "path": path, "for": key},
					"soundfont" if key == "soundfont" else "file_audio", filter, path)
			any = true
	for c in App.project.clips:
		if int(c.get("type", 0)) != Cd.ClipType.AUDIO:
			continue
		var ap := String(c.get("path", ""))
		if ap.is_empty() or seen.has(ap):
			continue
		seen[ap] = true
		_leaf(used, ap.get_file(), {"kind": "used_file", "path": ap, "for": "clip"},
				"file_audio", filter, ap)
		any = true

	if not any and filter.is_empty():
		_leaf(used, "nothing yet - add a channel", {"kind": "none"}, "add", filter, "")


func _icon_for_stock(id: String) -> String:
	match id:
		"cd.pulse":
			return "drum"
		"cd.sampler":
			return "sampler"
		"cd.soundfont":
			return "soundfont"
		_:
			return "synth"


func _section(root: TreeItem, title: String, icon: String) -> TreeItem:
	var it := _tree.create_item(root)
	it.set_text(0, title)
	it.set_icon(0, Icons.get_icon(icon, 14))
	it.set_selectable(0, false)
	it.set_custom_color(0, CdPalette.TEXT_DIM)
	it.collapsed = title in ["Samples", "Recent", "Patterns"]
	_roots[title.to_lower()] = it
	return it


func _leaf(parent: TreeItem, text: String, meta: Dictionary, icon: String, filter: String, hint: String) -> void:
	if not filter.is_empty() and not (text.to_lower().contains(filter) or hint.to_lower().contains(filter)):
		return
	var it := _tree.create_item(parent)
	it.set_text(0, text)
	it.set_icon(0, Icons.get_grey(icon, 14))
	it.set_metadata(0, meta)
	if not hint.is_empty():
		it.set_tooltip_text(0, "%s\n%s" % [text, hint])
	if not filter.is_empty():
		parent.collapsed = false


func _on_select() -> void:
	var it := _tree.get_selected()
	if it == null:
		return
	var meta = it.get_metadata(0)
	if typeof(meta) != TYPE_DICTIONARY:
		return
	match String(meta.get("kind", "")):
		"pattern":
			App.select_pattern(int(meta.index))
		"sample", "used_file":
			if _preview_on:
				_audition(String(meta.get("path", "")))


## Plays the selected file straight through Godot's own player, so you can hear
## what something is without loading it into the project first. Long files are
## fine: this streams from disk rather than going near the engine.
func _audition(path: String) -> void:
	if path.is_empty():
		return
	if _player == null:
		_player = AudioStreamPlayer.new()
		_player.bus = "Master"
		add_child(_player)
	if _playing_path == path and _player.playing:
		_player.stop()
		_playing_path = ""
		return
	var stream: AudioStream = null
	# Godot reads these itself; anything else goes through the ffmpeg hop the
	# rest of Cadmium uses, which lands as a plain WAV.
	var ext := path.get_extension().to_lower()
	if ext in ["ogg", "oga"]:
		stream = AudioStreamOggVorbis.load_from_file(path)
	elif ext == "mp3":
		stream = AudioStreamMP3.load_from_file(path)
	else:
		var wav_path := path if ext == "wav" else Audio.to_engine_wav(path)
		if wav_path.is_empty():
			App.status.emit("Could not decode %s" % path.get_file())
			return
		stream = AudioStreamWAV.load_from_file(wav_path)
	if stream == null:
		App.status.emit("Could not preview %s" % path.get_file())
		return
	_player.stream = stream
	_player.play()
	_playing_path = path
	App.status.emit("Playing %s  (%s)" % [path.get_file(), Cd.format_seconds(stream.get_length())])


func stop_audition() -> void:
	if _player != null and _player.playing:
		_player.stop()
	_playing_path = ""


func _on_activate() -> void:
	var it := _tree.get_selected()
	if it == null:
		return
	var meta = it.get_metadata(0)
	if typeof(meta) != TYPE_DICTIONARY:
		return
	match String(meta.get("kind", "")):
		"stock_inst":
			if _pick_channel >= 0:
				App.replace_channel_plugin(_pick_channel,
						CdProject.plugin_dict("stock", String(meta.id), "", it.get_text(0)))
				_pick_channel = -1
			else:
				App.add_stock_channel(String(meta.id))
		"vst3_inst":
			if _pick_channel >= 0:
				var e: Dictionary = meta.entry
				App.replace_channel_plugin(_pick_channel,
						CdProject.plugin_dict("vst3", String(e.cid), String(e.path), String(e.name)))
				_pick_channel = -1
			else:
				App.add_vst3_channel(meta.entry)
		"vst3_problem":
			var e: Dictionary = meta.entry
			App.status.emit("%s: %s" % [String(e.get("path", "")), String(e.get("error", ""))])
		"stock_fx":
			_add_effect(CdProject.plugin_dict("stock", String(meta.id), "", it.get_text(0)))
		"vst3_fx":
			var e2: Dictionary = meta.entry
			_add_effect(CdProject.plugin_dict("vst3", String(e2.cid), String(e2.path), String(e2.name)))
		"sf2":
			_add_soundfont(String(meta.path), it.get_text(0))
		"sample":
			_add_sample(String(meta.path), it.get_text(0))
		"pattern":
			App.select_pattern(int(meta.index))
		"project":
			App.load_project(String(meta.path))
		"settings":
			App.status.emit("Preferences > Folders adds soundfont and sample locations")
		"used_channel":
			# Opening something the project uses takes you to it.
			App.select_channel(int(meta.index))
			App.request_plugin_window({"kind": "channel", "index": int(meta.index)})
		"used_insert":
			App.select_mixer(int(meta.track))
			App.request_plugin_window({"kind": "insert", "track": int(meta.track),
					"slot": int(meta.slot)})
		"used_file":
			App.status.emit(String(meta.path))


func _add_effect(plug: Dictionary) -> void:
	var t := App.current_mixer
	var inserts: Array = App.project.mixer[t].inserts
	for s in inserts.size():
		if inserts[s] == null:
			App.set_insert(t, s, plug)
			App.status.emit("%s added to %s" % [String(plug.name), String(App.project.mixer[t].name)])
			return
	App.status.emit("%s has no free insert slot" % String(App.project.mixer[t].name))


func _add_soundfont(path: String, label: String) -> void:
	var plug := CdProject.plugin_dict("stock", "cd.soundfont", "", label.get_basename())
	plug["strings"]["file"] = path
	var ch := App.add_channel(plug, label.get_basename())
	# The preset list only exists once the file is open, so pick the first one.
	var ref := {"kind": "channel", "index": ch}
	var presets: String = App.engine().plugin_get_string(App.handle_for(ref), "presets")
	if presets.is_empty():
		App.status.emit("Could not read %s" % label)
	else:
		App.status.emit("Loaded %s" % label)
	App.request_plugin_window(ref)


func _add_sample(path: String, label: String) -> void:
	var wav := Audio.to_engine_wav(path)
	if wav.is_empty():
		App.status.emit("Could not decode %s" % label)
		return
	var plug := CdProject.plugin_dict("stock", "cd.sampler", "", label.get_basename())
	plug["strings"]["sample"] = wav
	plug["params"]["18"] = 1.0   # one-shot: a dropped sample is usually a hit
	var ch := App.add_channel(plug, label.get_basename())
	App.status.emit("Loaded %s" % label)
	App.select_channel(ch)
