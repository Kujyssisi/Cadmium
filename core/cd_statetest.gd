## Does anything a plugin is holding survive the rest of the program being
## used?
##
## A synth that has been set up -- by hand, inside its own interface, which is
## where anyone sets up a synth -- must still be set up after an effect is
## added somewhere else, after a mixer track appears, after the chain is
## reordered. Every one of those makes the whole project sync, and a sync that
## is not careful about which plugin is which loads one plugin's settings into
## another, or reloads a plugin over the top of itself.
##
## Run with --cd-statetest[=<name filter>]. Uses a real VST3 -- Vital by
## default if it is installed, otherwise the first instrument found.
class_name CdStateTest
extends RefCounted

var main
var failed := 0
var checked := 0


static func run(m, filter: String) -> int:
	var t := CdStateTest.new()
	t.main = m
	return await t._run(filter)


func _check(what: String, ok: bool, detail: String = "") -> void:
	checked += 1
	if not ok:
		failed += 1
	print("  %s  %s%s" % ["ok  " if ok else "FAIL", what, "  " + detail if detail else ""])


func _pick(filter: String) -> Dictionary:
	var want := filter.to_lower() if not filter.is_empty() else "vital"
	var fallback := {}
	for e in Plugins.vst3:
		if not String(e.get("error", "")).is_empty():
			continue
		if not bool(e.get("instrument", false)):
			continue
		if String(e.name).to_lower().contains(want):
			return e
		if fallback.is_empty():
			fallback = e
	return fallback


## What the plugin is holding: every parameter it exposes, and its own state.
func _snapshot_of(ref: Dictionary) -> Dictionary:
	var out := {"params": [], "state": ""}
	var h: int = App.handle_for(ref)
	if h < 0:
		return out
	for p in App.plugin_params(ref):
		# The plugin's own answer, not the host's cache of it: a stepped control
		# handed 0.87 reads back 0.87 from the cache and 1.0 from the plugin,
		# and it is the plugin's answer that says whether its settings survived.
		var live: float = float(Audio.engine.plugin_param_live(h, int(p.index)))
		out.params.append(live if live >= 0.0 else float(Audio.engine.plugin_get_param(h, int(p.index))))
	out.state = String(Audio.engine.plugin_get_string(h, "state"))
	return out


func _same(a: Dictionary, b: Dictionary) -> String:
	if (a.params as Array).size() != (b.params as Array).size():
		return "%d parameters, was %d" % [(b.params as Array).size(), (a.params as Array).size()]
	var moved := 0
	var worst := 0.0
	for i in (a.params as Array).size():
		var d: float = absf(float(a.params[i]) - float(b.params[i]))
		if d > 0.002:
			moved += 1
			worst = maxf(worst, d)
	if moved > 0:
		return "%d parameters moved, worst by %.4f" % [moved, worst]
	# The state string is deliberately not compared: a plugin is free to write
	# a name, a date or its own idea of a checksum into it, and several do, so
	# two reads a second apart are not the same bytes even when nothing has
	# moved. What must not change is the values.
	return ""


## Which parameters differ, by name, for a report that says what went wrong
## rather than only how many did.
func _diff_detail(ref: Dictionary, a: Dictionary, b: Dictionary) -> String:
	var descr: Array = App.plugin_params(ref)
	var out := []
	for i in mini((a.params as Array).size(), (b.params as Array).size()):
		var x := float(a.params[i])
		var y := float(b.params[i])
		if absf(x - y) <= 0.002:
			continue
		var nm := "#%d" % i
		if i < descr.size():
			nm = "%s (#%d, id %s)" % [String(descr[i].get("name", "?")), int(descr[i].get("index", i)),
					String(descr[i].get("id", ""))]
		out.append("%s %.4f -> %.4f" % [nm, x, y])
	return "\n        ".join(out)


## Something hosted that is not an instrument, to put on a mixer strip.
func _an_effect() -> Dictionary:
	for e in Plugins.vst3:
		if String(e.get("error", "")).is_empty() and not bool(e.get("instrument", false)):
			return e
	return {}


func _run(filter: String) -> int:
	if Plugins.vst3.is_empty():
		await Plugins.rescan_vst3()
	var entry := _pick(filter)
	if entry.is_empty():
		print("statetest: no VST3 instrument installed to test with")
		return 0
	print("statetest: %s" % String(entry.name))

	App.new_project()
	await main.get_tree().process_frame
	var plug := CdProject.plugin_dict("vst3", String(entry.cid), String(entry.path), String(entry.name))
	App.project.add_channel(String(entry.name), plug, 1)
	App.sync_all()
	for i in 30:
		await main.get_tree().process_frame
	var ref := {"kind": "channel", "index": 0}
	var h: int = App.handle_for(ref)
	if h < 0:
		print("  FAIL  %s would not load" % String(entry.name))
		return 1

	# Its own interface first. That is where anyone sets a synth up, and it is
	# also what settles the plugin's two halves -- the part that makes the
	# sound and the part that draws the knobs -- onto the same numbers.
	main.open_plugin_window(ref)
	for i in 60:
		await main.get_tree().process_frame

	# Set up, the way anyone sets a synth up: from inside its own interface,
	# which the host hears about but does not itself do.
	var params: Array = App.plugin_params(ref)
	print("  ..    %d parameters" % params.size())
	var touched := []
	for i in mini(12, params.size()):
		var idx := int(params[i].index)
		var v: float = fmod(0.31 + 0.07 * float(i), 1.0)
		Audio.engine.plugin_simulate_gui_edit(h, idx, v)
		touched.append(idx)
	# Long enough for the plugin to have thought about it: a value handed to a
	# plugin comes back rounded to whatever it actually supports, and it is
	# that settled value the rest of this compares against.
	for i in 60:
		await main.get_tree().process_frame
	var before := _snapshot_of(ref)
	_check("the plugin took the settings", not (before.params as Array).is_empty())
	# What it costs to ask, which is what decides how often we can afford to.
	var t0 := Time.get_ticks_usec()
	for i in 10:
		Audio.engine.plugin_get_string(h, "state")
	print("  ..    reading its state costs %.2f ms (%d bytes base64)" % [
			float(Time.get_ticks_usec() - t0) / 10000.0,
			String(Audio.engine.plugin_get_string(h, "state")).length()])

	# Now use the rest of the program, one thing at a time.
	var steps := [
		["adding an instrument", func(): App.add_stock_channel("cd.ember")],
		["adding an effect to the mixer",
			func(): App.set_insert(1, 0, CdProject.plugin_dict("stock", "cd.reverb", "", "Reverb"))],
		["adding a second effect",
			func(): App.set_insert(1, 1, CdProject.plugin_dict("stock", "cd.delay", "", "Delay"))],
		["moving one effect over the other", func(): App.move_insert(1, 0, 1)],
		["taking an effect off", func(): App.remove_insert(1, 0)],
		["adding a mixer track", func(): App.add_mixer_track()],
		["routing a strip somewhere else", func(): App.set_route(1, 0, true)],
		["removing the mixer track", func(): App.remove_mixer_track()],
		["adding a pattern", func(): App.add_pattern("Another")],
		["turning a mixer fader", func(): App.set_mixer_prop(1, "vol", 0.6, "Volume")],
		["adding a track to the arrangement", func(): App.add_track()],
	]
	# The one the report was about: another plugin being loaded while this one
	# is set up. A second instance of the same plugin is the hardest case --
	# same code, same identity, same everything but which one is which.
	var fx := _an_effect()
	steps.append(["loading a second copy of the same plugin",
			func(): App.add_vst3_channel(entry)])
	if not fx.is_empty():
		steps.append(["loading a plugin as an effect", func(): App.set_insert(1, 0,
				CdProject.plugin_dict("vst3", String(fx.cid), String(fx.path), String(fx.name)))])
		steps.append(["taking that effect off again", func(): App.remove_insert(1, 0)])
	steps.append(["removing the second copy", func(): App.remove_channel(1)])
	steps.append(["undoing that", func(): App.undo()])
	steps.append(["and redoing it", func(): App.redo()])
	for step in steps:
		(step[1] as Callable).call()
		for i in 30:
			await main.get_tree().process_frame
		var now := _snapshot_of(ref)
		var why := _same(before, now)
		_check("%s leaves it alone" % String(step[0]), why.is_empty(), why)
		# Whatever it is now is the baseline for the next step: one complaint
		# per thing that goes wrong, rather than every step after it.
		before = now

	# And with its window open. A window showing a plugin must not write to it:
	# a switch standing part way used to be shown as on and written back as
	# fully on, so simply looking at a plugin changed it.
	var probe_ids := touched.slice(0, 6)
	var win = main._plugin_windows.get(JSON.stringify(ref))
	if win != null and win.has_method("_refresh_values"):
		var switches := []
		for key in win._knobs.keys():
			if win._knobs[key] is CheckBox:
				switches.append(int(key))
		print("  ..    %d of the controls are switches" % switches.size())
		var odd := 0.63
		for idx in switches.slice(0, 8):
			Audio.engine.plugin_simulate_gui_edit(h, idx, odd)
		for i in 20:
			await main.get_tree().process_frame
		win._refresh_values()
		await main.get_tree().process_frame
		var kept := true
		var worst := 0.0
		for idx in switches.slice(0, 8):
			var v := float(Audio.engine.plugin_get_param(h, idx))
			if absf(v - odd) > 0.005:
				kept = false
				worst = maxf(worst, absf(v - odd))
		_check("a window showing a plugin does not write to it", kept,
				"a switch moved by %.3f" % worst)
		# And the ordinary case still works: the window follows what the plugin
		# does rather than ignoring it.
		if not switches.is_empty():
			Audio.engine.plugin_simulate_gui_edit(h, switches[0], 1.0)
			for i in 20:
				await main.get_tree().process_frame
			_check("but it does follow what the plugin reports",
					(win._knobs[switches[0]] as CheckBox).button_pressed)
	before = _snapshot_of(ref)
	App.add_stock_channel("cd.pluck")
	for i in 20:
		await main.get_tree().process_frame
	var after := _snapshot_of(ref)
	var why_open := _same(before, after)
	_check("and adding a plugin with that window open leaves it alone",
			why_open.is_empty(), why_open)

	# --- and the thing the whole file is named for: saved, closed, opened
	# again. Everything above keeps a plugin alive across an edit; this is the
	# only path that takes what it is holding out to a file and puts it back
	# into a plugin that has just been made from nothing.
	print("  --    saving and reopening")
	# A patch is only ever what the plugin makes of it. Handed 0.87, a switch
	# keeps "on" but goes on reporting 0.87 until something has been through
	# its own state; a tempo readout is the host's and not the patch's at all.
	# Putting the state back into the same copy first settles those, so what is
	# compared afterwards is the plugin's reading of the patch and not ours.
	Audio.engine.plugin_set_string(h, "state", String(_snapshot_of(ref).state))
	for i in 60:
		await main.get_tree().process_frame
	before = _snapshot_of(ref)
	var path := OS.get_user_data_dir().path_join("statetest.cadmium")
	_check("the project saves", App.save_project(path) == OK)
	App.new_project()
	for i in 20:
		await main.get_tree().process_frame
	_check("the project opens", App.load_project(path) == OK)
	for i in 90:
		await main.get_tree().process_frame
	var reopened := _snapshot_of(ref)
	var why_file := _same(before, reopened)
	_check("a plugin comes back set up the way it was saved", why_file.is_empty(), why_file)
	if not why_file.is_empty():
		print("        %s" % _diff_detail(ref, before, reopened))

	# The same thing without the file, to say which half is at fault: the state
	# a plugin just handed over, put straight back into a second copy of it.
	var saved_state := String(before.state)
	App.new_project()
	for i in 20:
		await main.get_tree().process_frame
	var fresh := CdProject.plugin_dict("vst3", String(entry.cid), String(entry.path), String(entry.name))
	fresh["state"] = saved_state
	App.project.add_channel(String(entry.name), fresh, 1)
	App.sync_all()
	for i in 90:
		await main.get_tree().process_frame
	var copied := _snapshot_of(ref)
	var why_state := _same(before, copied)
	_check("and the state alone is enough to set a fresh copy up", why_state.is_empty(), why_state)
	if not why_state.is_empty():
		print("        %s" % _diff_detail(ref, before, copied))

	# --- the report this was written for: "I saved, opened it again and the
	# preset was different". A patch chosen inside the plugin moves the state
	# wholesale, and the parameter list the host happens to be keeping beside
	# it is from whatever was loaded before. Both go into the file. Whichever
	# is applied last is what comes back.
	print("  --    a file whose state and parameter list disagree")
	App.new_project()
	for i in 20:
		await main.get_tree().process_frame
	App.project.add_channel(String(entry.name),
			CdProject.plugin_dict("vst3", String(entry.cid), String(entry.path), String(entry.name)), 1)
	App.sync_all()
	for i in 60:
		await main.get_tree().process_frame
	h = App.handle_for(ref)
	var spread: Array = []
	var descr: Array = App.plugin_params(ref)
	var stride := maxi(1, descr.size() / 60)
	for i in range(0, descr.size(), stride):
		spread.append(int(descr[i].index))
	# Patch A.
	for i in spread.size():
		Audio.engine.plugin_simulate_gui_edit(h, int(spread[i]), fmod(0.13 + 0.011 * float(i), 1.0))
	for i in 60:
		await main.get_tree().process_frame
	var state_a := String(Audio.engine.plugin_get_string(h, "state"))
	# Patch B, in the same copy, and the parameter list the host would be
	# holding for it.
	var params_b := {}
	for i in spread.size():
		var v: float = fmod(0.71 + 0.013 * float(i), 1.0)
		Audio.engine.plugin_simulate_gui_edit(h, int(spread[i]), v)
		params_b[str(int(spread[i]))] = v
	for i in 60:
		await main.get_tree().process_frame

	# A fresh copy given nothing but patch A: what the user should get back.
	var want := await _restored(entry, ref, state_a, {})
	# And the same, with patch B's parameter list in the file beside it.
	var got := await _restored(entry, ref, state_a, params_b)
	var why_mix := _same(want, got)
	_check("the saved patch is not overwritten by the values stored beside it",
			why_mix.is_empty(), why_mix)
	if not why_mix.is_empty():
		print("        %s" % _diff_detail(ref, want, got))

	print("%d passed, %d failed" % [checked - failed, failed])
	return failed


## A brand new copy of the plugin, given exactly what a project file would give
## it, and what it is holding once it has settled.
func _restored(entry: Dictionary, ref: Dictionary, state: String, params: Dictionary) -> Dictionary:
	App.new_project()
	for i in 20:
		await main.get_tree().process_frame
	var plug := CdProject.plugin_dict("vst3", String(entry.cid), String(entry.path), String(entry.name))
	plug["state"] = state
	plug["params"] = params.duplicate()
	App.project.add_channel(String(entry.name), plug, 1)
	App.sync_all()
	for i in 90:
		await main.get_tree().process_frame
	return _snapshot_of(ref)
