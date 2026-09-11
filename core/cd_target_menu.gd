class_name CdTargetMenu
extends RefCounted
## Everything in the song that can be automated, as a drop-down.
##
## One list, offered from wherever the question comes up: the arrangement's
## "make an automation clip", and the automation editor's "drive this as well".
## Written once so the two cannot end up knowing about different halves of the
## program.

## Opens at the pointer. `on_pick` is handed {target, ref, a, b, name, lo, hi}.
static func open(host: Node, on_pick: Callable) -> PopupMenu:
	var pm := PopupMenu.new()
	pm.name = "TargetMenu"
	host.add_child(pm)
	var entries: Array = []

	# Every mixer strip: its volume and pan, the sends that go anywhere, and
	# every parameter of every effect on it.
	pm.add_separator("Mixer")
	for t in App.project.mixer.size():
		var m: Dictionary = App.project.mixer[t]
		var strip := PopupMenu.new()
		strip.name = "mx%d" % t
		_add(entries, strip, {"target": Cd.AutoTarget.MIXER_VOL, "a": t, "b": 0, "ref": {},
				"name": "%s volume" % String(m.name), "lo": 0.0, "hi": 1.25}, "Volume")
		_add(entries, strip, {"target": Cd.AutoTarget.MIXER_PAN, "a": t, "b": 0, "ref": {},
				"name": "%s pan" % String(m.name), "lo": -1.0, "hi": 1.0}, "Pan")
		for si in (m.sends as Array).size():
			var snd: Dictionary = m.sends[si]
			if int(snd.dest) < 0 or int(snd.dest) >= App.project.mixer.size():
				continue
			var dest := String(App.project.mixer[int(snd.dest)].name)
			_add(entries, strip, {"target": Cd.AutoTarget.SEND, "a": t, "b": si, "ref": {},
					"name": "%s send to %s" % [String(m.name), dest], "lo": 0.0, "hi": 1.0},
					"Send to %s" % dest)
		for slot in (m.inserts as Array).size():
			if m.inserts[slot] == null:
				continue
			var iref := {"kind": "insert", "track": t, "slot": slot}
			var fx: PopupMenu = _params_menu(entries, iref, String(m.inserts[slot].get("name", "Effect")),
					"mx%d_%d" % [t, slot], on_pick, pm)
			if fx != null:
				strip.add_child(fx)
				strip.add_submenu_item(String(m.inserts[slot].get("name", "Effect %d" % (slot + 1))),
						fx.name)
		strip.id_pressed.connect(func(id): _pick(entries, id, on_pick, pm))
		pm.add_child(strip)
		pm.add_submenu_item(String(m.name), strip.name)

	pm.add_separator("Channels")
	for i in App.project.channels.size():
		var ch: Dictionary = App.project.channels[i]
		var sub := PopupMenu.new()
		sub.name = "ch%d" % i
		_add(entries, sub, {"target": Cd.AutoTarget.CHANNEL_VOL, "a": i, "b": 0, "ref": {},
				"name": "%s volume" % String(ch.name), "lo": 0.0, "hi": 1.25}, "Volume")
		_add(entries, sub, {"target": Cd.AutoTarget.CHANNEL_PAN, "a": i, "b": 0, "ref": {},
				"name": "%s pan" % String(ch.name), "lo": -1.0, "hi": 1.0}, "Pan")
		var pref := {"kind": "channel", "index": i}
		var pmenu: PopupMenu = _params_menu(entries, pref, String(ch.name), "chp%d" % i, on_pick, pm)
		if pmenu != null:
			sub.add_child(pmenu)
			sub.add_submenu_item("Parameters", pmenu.name)
		sub.id_pressed.connect(func(id): _pick(entries, id, on_pick, pm))
		pm.add_child(sub)
		pm.add_submenu_item(String(ch.name), sub.name)

	# Samples: what each plays at and where it sits. The rest of a sampler's
	# settings change the file itself and are decided once.
	if not App.project.assets.is_empty():
		pm.add_separator("Samples")
		for si in App.project.assets.size():
			var nm := String(App.project.assets[si].get("name", "sample"))
			var smenu := PopupMenu.new()
			smenu.name = "smp%d" % si
			_add(entries, smenu, {"target": Cd.AutoTarget.SAMPLE_VOL, "a": si, "b": 0, "ref": {},
					"name": "%s volume" % nm, "lo": 0.0, "hi": 2.0}, "Volume")
			_add(entries, smenu, {"target": Cd.AutoTarget.SAMPLE_PAN, "a": si, "b": 0, "ref": {},
					"name": "%s pan" % nm, "lo": -1.0, "hi": 1.0}, "Pan")
			_add(entries, smenu, {"target": Cd.AutoTarget.SAMPLE_PITCH, "a": si, "b": 0, "ref": {},
					"name": "%s pitch" % nm, "lo": -24.0, "hi": 24.0}, "Pitch")
			_add(entries, smenu, {"target": Cd.AutoTarget.SAMPLE_SPEED, "a": si, "b": 0, "ref": {},
					"name": "%s speed" % nm, "lo": 0.25, "hi": 4.0}, "Speed")
			smenu.id_pressed.connect(func(id): _pick(entries, id, on_pick, pm))
			pm.add_child(smenu)
			pm.add_submenu_item(nm, smenu.name)

	pm.add_separator("Transport")
	_add(entries, pm, {"target": Cd.AutoTarget.TEMPO, "a": 0, "b": 0, "ref": {},
			"name": "Tempo", "lo": 60.0, "hi": 200.0}, "Tempo")

	pm.id_pressed.connect(func(id): _pick(entries, id, on_pick, pm))
	pm.popup_hide.connect(func(): pm.queue_free(), CONNECT_DEFERRED)
	pm.popup(Rect2i(DisplayServer.mouse_get_position(), Vector2i(1, 1)))
	return pm


static func _add(entries: Array, menu: PopupMenu, entry: Dictionary, label: String) -> void:
	entries.append(entry)
	menu.add_item(label, entries.size() - 1)


## One plugin's parameters, or null when it has none to offer.
static func _params_menu(entries: Array, ref: Dictionary, owner: String, name: String,
		on_pick: Callable, root: PopupMenu) -> PopupMenu:
	var params: Array = App.plugin_params(ref)
	if params.is_empty():
		return null
	var menu := PopupMenu.new()
	menu.name = name
	for p in params:
		_add(entries, menu, {"target": Cd.AutoTarget.PLUGIN, "a": 0, "b": int(p.index),
				"ref": ref, "name": "%s: %s" % [owner, String(p.name)],
				"lo": float(p.min), "hi": float(p.max)}, String(p.name))
	menu.id_pressed.connect(func(id): _pick(entries, id, on_pick, root))
	return menu


static func _pick(entries: Array, id: int, on_pick: Callable, pm: PopupMenu) -> void:
	if id < 0 or id >= entries.size():
		return
	on_pick.call(entries[id])
	if is_instance_valid(pm):
		pm.queue_free()
