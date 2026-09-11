## Opens every hosted plugin's own editor in turn and reads back what it
## actually painted, so "the editor attached" can be told apart from "the
## editor drew something".
##
## Run with --cd-vsttest=<dir>[,filter]. Needs a real X display: the plugin
## draws into a child window and the pixels are read off the server.
class_name CdVstTest
extends RefCounted

const SETTLE_FRAMES := 120        ## generous: JUCE editors build their UI lazily
const MIN_INK := 0.02            ## fraction of pixels that must differ from the mode

var dir := ""
var main
var start := 0            ## skip this many, to pick up after a plugin took the host down
var results: Array = []


static func run(m, out_dir: String, filter: String, start: int = 0) -> int:
	var t := CdVstTest.new()
	t.main = m
	t.dir = out_dir
	t.start = start
	DirAccess.make_dir_recursive_absolute(out_dir)
	if not DirAccess.dir_exists_absolute(out_dir):
		t.dir = OS.get_user_data_dir().path_join("vsttest")
		DirAccess.make_dir_recursive_absolute(t.dir)
	return await t._run(filter)


func _run(filter: String) -> int:
	var wanted := []
	for entry in Plugins.vst3:
		if filter.is_empty() or String(entry.name).to_lower().contains(filter.to_lower()):
			wanted.append(entry)
	if start > 0:
		wanted = wanted.slice(mini(start, wanted.size()))
	print("vsttest: %d plugin%s, writing to %s" % [wanted.size(), "" if wanted.size() == 1 else "s", dir])
	var bad := 0
	var n := 0
	for entry in wanted:
		var r := await _one(entry)
		results.append(r)
		n += 1
		if not bool(r.ok):
			bad += 1
		var line := "%-6s %-42s %s" % [("ok" if r.ok else "FAIL"), String(entry.name), String(r.note)]
		print("  " + line)
		# Written as we go: a plugin that takes the host down with it should not
		# also take the results of everything before it.
		_append("%3d/%d  %s" % [start + n, start + wanted.size(), line])
	print("")
	print("vsttest: %d of %d drew correctly" % [wanted.size() - bad, wanted.size()])
	# One plugin per distinct bundle is enough for the awkward cases: what
	# matters there is the host's own bookkeeping, not the plugin's drawing.
	var reps := []
	var seen := {}
	for entry in wanted:
		var path := String(entry.path)
		if seen.has(path):
			continue
		seen[path] = true
		reps.append(entry)
	bad += await _reopen_checks(reps)
	bad += await _move_resize_checks(reps)
	bad += await _together_check(reps)
	return bad


## Moving and resizing the host window: the plugin's canvas has to follow, and
## a resizable plugin has to lay itself out again rather than keep drawing at
## its old size inside a window of the new one.
func _move_resize_checks(reps: Array) -> int:
	print("")
	print("--- moved and resized")
	var bad := 0
	for entry in reps:
		var name := String(entry.name)
		App.new_project()
		await main.get_tree().process_frame
		var ref := _instantiate(entry)
		for i in 8:
			await main.get_tree().process_frame
		var h: int = App.handle_for(ref)
		if h < 0 or not App.engine().plugin_has_editor(h):
			continue
		var win = main.open_plugin_window(ref)
		_stage(win)
		for i in SETTLE_FRAMES:
			await main.get_tree().process_frame
		var note := ""
		win.position = Vector2i(220, 140)
		for i in 25:
			await main.get_tree().process_frame
		_stage(win)
		for i in 15:
			await main.get_tree().process_frame
		var img: Image = App.engine().plugin_editor_grab(h)
		var top := int(win.TOOLBAR_H * win.content_scale_factor)
		if img == null or float(_ink(img).ink) < MIN_INK:
			note = "blank after the window moved"
		elif App.engine().plugin_editor_can_resize(h):
			var before := Vector2i(img.get_width(), img.get_height())
			win.size = Vector2i(before.x + 120, win.size.y + 90)
			for i in 30:
				await main.get_tree().process_frame
			_stage(win)
			for i in 15:
				await main.get_tree().process_frame
			var img2: Image = App.engine().plugin_editor_grab(h)
			if img2 == null or float(_ink(img2).ink) < MIN_INK:
				note = "blank after the window was resized"
			elif img2.get_width() == before.x and img2.get_height() == before.y:
				note = "canvas stayed %dx%d when the window grew" % [before.x, before.y]
			else:
				# The canvas and the window have to agree, or the plugin is
				# drawing into a rectangle that is not the one on screen.
				var want := Vector2i(win.size.x, win.size.y - top)
				if absi(img2.get_width() - want.x) > 2 or absi(img2.get_height() - want.y) > 2:
					note = "canvas %dx%d against a %dx%d window after resizing" % [
							img2.get_width(), img2.get_height(), want.x, want.y]
				elif float(_ink(img2).ink) < MIN_INK * 2.0:
					note = "mostly empty after resizing (%.1f%% ink)" % (float(_ink(img2).ink) * 100.0)
		var ok := note.is_empty()
		if not ok:
			bad += 1
		var line := "%-6s %-42s %s" % [("ok" if ok else "FAIL"), name,
				note if not ok else "followed the window"]
		print("  " + line)
		_append("move    " + line)
		main._close_plugin_window(ref)
		for i in 8:
			await main.get_tree().process_frame
	return bad


## Closing an editor and opening it again is where a host that hangs on to a
## dead view comes apart.
func _reopen_checks(reps: Array) -> int:
	print("")
	print("--- opened, closed and opened again")
	var bad := 0
	for entry in reps:
		var name := String(entry.name)
		App.new_project()
		await main.get_tree().process_frame
		var ref := _instantiate(entry)
		for i in 8:
			await main.get_tree().process_frame
		var h: int = App.handle_for(ref)
		if h < 0 or not App.engine().plugin_has_editor(h):
			continue
		var note := ""
		for round_i in 2:
			var win = main.open_plugin_window(ref)
			_stage(win)
			for i in SETTLE_FRAMES:
				await main.get_tree().process_frame
			_stage(win)
			for i in 12:
				await main.get_tree().process_frame
			var img: Image = App.engine().plugin_editor_grab(h)
			var ink := float(_ink(img).ink)
			print("        open %d: ink %.1f%%  %s" % [round_i + 1, ink * 100.0,
					App.engine().plugin_editor_debug(h)])
			if img == null or ink < MIN_INK:
				note = "blank on open %d" % (round_i + 1)
			main._close_plugin_window(ref)
			for i in 10:
				await main.get_tree().process_frame
		var ok := note.is_empty()
		if not ok:
			bad += 1
		var line := "%-6s %-42s %s" % [("ok" if ok else "FAIL"), name, note if not ok else "drew both times"]
		print("  " + line)
		_append("reopen  " + line)
	return bad


## Several editors up at once: each has its own X connection and its own event
## loop, and the host has to pump all of them.
func _together_check(reps: Array) -> int:
	print("")
	print("--- three editors open at once")
	var chosen := []
	for entry in reps:
		if chosen.size() >= 3:
			break
		chosen.append(entry)
	if chosen.size() < 2:
		return 0
	App.new_project()
	await main.get_tree().process_frame
	var refs := []
	for entry in chosen:
		refs.append(_instantiate(entry, refs.size()))
	for i in 10:
		await main.get_tree().process_frame
	var opened := []
	for i in refs.size():
		var h: int = App.handle_for(refs[i])
		if h >= 0 and App.engine().plugin_has_editor(h):
			main.open_plugin_window(refs[i])
			opened.append(i)
	for i in SETTLE_FRAMES + 30:
		await main.get_tree().process_frame
	var bad := 0
	for i in opened:
		var h2: int = App.handle_for(refs[i])
		# Each window is brought to the front in turn: with three of them open
		# they overlap, and only the top one can be read.
		var w2 = main._plugin_windows.get(JSON.stringify(refs[i]))
		_stage(w2)
		for f in 20:
			await main.get_tree().process_frame
		var img: Image = App.engine().plugin_editor_grab(h2)
		var ink := float(_ink(img).ink)
		var ok := img != null and ink >= MIN_INK
		if not ok:
			bad += 1
		var line := "%-6s %-42s %s" % [("ok" if ok else "FAIL"), String(chosen[i].name),
				("%.0f%% ink alongside the others" % (ink * 100.0)) if ok else "blank while others were open"]
		print("  " + line)
		_append("multi   " + line)
	for i in opened:
		main._close_plugin_window(refs[i])
	for i in 10:
		await main.get_tree().process_frame
	return bad


## Runs two beats of audio through the plugin offline and reports the peak.
## An effect is fed by a stock instrument on the same mixer track; an instrument
## plays a chord of its own.
func _render_through(entry: Dictionary, ref: Dictionary) -> Dictionary:
	if String(ref.get("kind", "")) == "insert":
		var src := App.project.add_channel("src",
				CdProject.plugin_dict("stock", "cd.ember", "", "Ember"), int(ref.track))
		App.sync_all()
		for k in [48, 55, 60]:
			App.add_note(0, src, 0.0, 1.8, k, 0.9)
	else:
		for k in [48, 55, 60]:
			App.add_note(0, int(ref.index), 0.0, 1.8, k, 0.9)
	Audio.engine.set_mode(Cd.Mode.PATTERN)
	var path := dir.path_join("audio.wav")
	if not Audio.engine.render(path, 0.0, 2.0, 0.5, 24, false):
		return {"ok": false, "note": "the render failed"}
	var peak := _wav_peak(path)
	if is_nan(peak):
		return {"ok": false, "note": "output was not a number"}
	return {"ok": true, "note": "peak %.3f" % peak}


func _wav_peak(path: String) -> float:
	if not FileAccess.file_exists(path):
		return NAN
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return NAN
	var data := f.get_buffer(f.get_length())
	f.close()
	if data.size() < 128:
		return NAN
	var peak := 0.0
	var i := 44
	while i + 2 < data.size():
		var v := data[i] | (data[i + 1] << 8) | (data[i + 2] << 16)
		if v & 0x800000:
			v -= 0x1000000
		peak = maxf(peak, absf(float(v) / 8388608.0))
		i += 3
	return peak


func _instantiate(entry: Dictionary, slot: int = 0) -> Dictionary:
	if bool(entry.get("instrument", false)):
		return {"kind": "channel", "index": App.add_vst3_channel(entry)}
	App.set_insert(1, slot, CdProject.plugin_dict("vst3", String(entry.cid), String(entry.path),
			String(entry.name)))
	return {"kind": "insert", "track": 1, "slot": slot}


## Puts the window somewhere predictable and on top, so what is read back is
## the plugin and nothing else.
func _stage(win: Window) -> void:
	if win == null or not is_instance_valid(win):
		return
	win.position = Vector2i(4, 4)
	win.move_to_foreground()


func _append(line: String) -> void:
	var path := dir.path_join("report.txt")
	var f := FileAccess.open(path, FileAccess.READ_WRITE) if FileAccess.file_exists(path) \
			else FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return
	f.seek_end()
	f.store_line(line)
	f.close()


func _one(entry: Dictionary) -> Dictionary:
	var name := String(entry.name)
	var out := {"name": name, "ok": false, "note": ""}
	var ref := {}
	# A fresh project each time, so nothing from the last plugin is left over.
	App.new_project()
	await main.get_tree().process_frame
	ref = _instantiate(entry)
	for i in 8:
		await main.get_tree().process_frame

	var h: int = App.handle_for(ref)
	if h < 0:
		out.note = "the plugin would not load"
		return out

	# Audio first: a plugin that crashes in process() never gets as far as its
	# interface, and this is the one place every installed plugin is run.
	var audio := _render_through(entry, ref)
	out["audio"] = audio
	if not bool(audio.ok):
		out.note = "audio: " + String(audio.note)
		return out

	if not App.engine().plugin_has_editor(h):
		out.ok = true
		out.note = "no editor of its own (generic panel), %s" % String(out.audio.note)
		return out

	var win = main.open_plugin_window(ref)
	if win == null:
		out.note = "no window"
		return out
	_stage(win)
	for i in SETTLE_FRAMES:
		await main.get_tree().process_frame
	# Reading pixels back reads the screen, so anything on top of the window --
	# a plugin's own "greetings" dialog, say -- would be read instead of it.
	_stage(win)
	for i in 12:
		await main.get_tree().process_frame
	if not win._attached:
		out.note = "the editor did not attach"
		main._close_plugin_window(ref)
		return out
	# The canvas is parked outside the window while the plugin builds itself,
	# and brought in when it is ready or when waiting has gone on too long.
	# Still parked by now means the user is looking at a spinner for good.
	if not App.engine().plugin_editor_showing(h):
		out.note = "the editor never came out of loading"
		main._close_plugin_window(ref)
		return out
	out["tries"] = win._attach_tries

	var img: Image = App.engine().plugin_editor_grab(h)
	var stats := _ink(img)
	var es: Vector2i = App.engine().plugin_editor_size(h)
	out["size"] = "%dx%d" % [es.x, es.y]
	if img != null:
		img.save_png(dir.path_join(_slug(name) + ".png"))
	# The container has to cover the whole window below Cadmium's strip, or the
	# plugin is drawing into an area the wrong shape.
	var want_w: int = win.size.x
	var want_h: int = win.size.y - int(win.TOOLBAR_H * win.content_scale_factor)
	if img == null:
		out.note = "nothing could be read back from the window"
	elif float(stats.ink) < MIN_INK:
		out.note = "%dx%d but only %.1f%% of it has any ink -- blank" % [
				img.get_width(), img.get_height(), float(stats.ink) * 100.0]
	elif absi(img.get_width() - want_w) > 2 or absi(img.get_height() - want_h) > 2:
		out.note = "drew %dx%d into a %dx%d window" % [
				img.get_width(), img.get_height(), want_w, want_h]
	else:
		out.ok = true
		out.note = "%dx%d, %.0f%% ink, %d colours, %s%s" % [img.get_width(), img.get_height(),
				float(stats.ink) * 100.0, int(stats.colours), String(out.audio.note),
				"" if int(out.get("tries", 0)) == 0 else ", attached %d times" % (int(out.tries) + 1)]
	if not bool(out.ok):
		# Geometry and map state of the container and the plugin's own window,
		# which is what tells a plugin that drew nothing from one that drew
		# somewhere we cannot see.
		out["debug"] = "win at %s %s  |  %s" % [str(win.position), str(win.size),
				App.engine().plugin_editor_debug(h)]
		print("         %s" % out.debug)
		_append("        " + String(out.debug))
	main._close_plugin_window(ref)
	for i in 6:
		await main.get_tree().process_frame
	return out


## How much of the window is not one flat colour, and how many distinct colours
## there are. A plugin that attached but never painted comes back as one colour
## covering everything.
func _ink(img: Image) -> Dictionary:
	if img == null:
		return {"ink": 0.0, "colours": 0}
	var counts := {}
	var step := maxi(1, int(sqrt(float(img.get_width() * img.get_height()) / 20000.0)))
	var n := 0
	for y in range(0, img.get_height(), step):
		for x in range(0, img.get_width(), step):
			var c := img.get_pixel(x, y)
			var key := (int(c.r8) >> 3) << 10 | (int(c.g8) >> 3) << 5 | (int(c.b8) >> 3)
			counts[key] = int(counts.get(key, 0)) + 1
			n += 1
	if n == 0:
		return {"ink": 0.0, "colours": 0}
	var top := 0
	for k in counts.keys():
		top = maxi(top, int(counts[k]))
	return {"ink": 1.0 - float(top) / float(n), "colours": counts.size()}


func _slug(s: String) -> String:
	var out := ""
	for ch in s.to_lower():
		out += ch if (ch >= "a" and ch <= "z") or (ch >= "0" and ch <= "9") else "_"
	return out
