extends Node
## The catalogue: stock processors reported by the engine, VST3 bundles found on
## disk, and the soundfonts and samples the browser offers.

signal catalog_changed()

const VST3_CACHE := "user://vst3_cache.json"

var stock: Array = []            ## engine descriptors
var vst3: Array = []             ## {path, cid, name, vendor, category, instrument}
var scanning := false

## Where soundfonts are kept, per platform. The engine finds VST3s itself; this
## is only for the ones Cadmium's own player loads.
const SF2_DIRS_UNIX := [
	"/usr/share/soundfonts", "/usr/share/sounds/sf2", "/usr/share/sounds/sf3",
]
const SF2_DIRS_WINDOWS := [
	"C:/soundfonts", "C:/Program Files/Common Files/SoundFonts",
]


func _ready() -> void:
	await get_tree().process_frame
	refresh_stock()
	_load_vst3_cache()
	# Whatever was being opened when Cadmium last stopped is what stopped it.
	# The scan works this out for itself, but the scan is not what runs when a
	# project full of plugins is opened, and losing a session to the same
	# plugin twice is not something anybody should have to do.
	# Entries written by an earlier rule that blamed a plugin for the program
	# stopping at all -- being killed from a task manager, a force quit, the
	# machine going down -- rather than for crashing. That was not evidence of
	# anything, and it refused plugins that had done nothing wrong.
	var known := _broken()
	var freed := false
	for path in known.keys():
		if String(known[path]) == BLAMED_WITHOUT_EVIDENCE:
			known.erase(path)
			freed = true
	if freed:
		_set_broken(known)
	var died := _crashed_on()
	if not died.is_empty():
		var marker_time := _probing_time()
		_clear_probing()
		# Only if it actually crashed. A plugin is refused for the rest of time
		# on the strength of this, so "the program is not running any more" is
		# not enough: there has to be a report saying it fell over, written at
		# about the moment this plugin was being opened.
		if _crash_around(marker_time):
			known[died] = "it stopped Cadmium while it was being opened"
			_set_broken(known)
			App.status.emit("%s stopped Cadmium last time -- it will not be opened again"
					% died.get_file())
	# Nothing has ever been scanned on a fresh install, and a plugin folder
	# nobody has looked in reads exactly like an empty one: the first run does
	# the walk itself rather than waiting to be asked.
	if _is_a_job():
		# This copy of Cadmium was started to do one thing and stop -- open a
		# list of plugins somewhere the main program cannot be hurt, run a test,
		# render a file. It must never start a scan of its own accord, because
		# a scan starts copies of Cadmium: one that scanned would start copies
		# that scanned, and each of those would start more. That is a machine
		# filling up with Cadmium until it runs out of memory, and it is why
		# nothing here happens automatically in a job.
		return
	if not FileAccess.file_exists(VST3_CACHE):
		App.status.emit("Looking for VST3 plugins...")
		var n: int = await rescan_vst3()
		App.status.emit("Found %d VST3 plugin%s" % [n, "" if n == 1 else "s"])
	elif _unchecked() > 0:
		# A library last looked at by a version that opened plugins differently.
		# Each is opened once now, somewhere it cannot do any harm, so the ones
		# that fall over are known before somebody puts one on a channel -- and
		# the ones an older version wrote off get another go, because the
		# reason they would not open may well be the thing that changed.
		forget_broken_vst3()
		App.status.emit("Checking %d plugin%s..."
				% [_unchecked(), "" if _unchecked() == 1 else "s"])
		var n: int = await rescan_vst3()
		App.status.emit("%d VST3 plugin%s ready" % [n, "" if n == 1 else "s"])


## Whether this copy of Cadmium was started to do a job and stop, rather than
## to be used. Anything that starts another copy has to ask.
func _is_a_job(args: PackedStringArray = OS.get_cmdline_user_args()) -> bool:
	for a in args:
		if String(a).begins_with("--cd-"):
			return true
	return false


## Whether this copy is the one that opens plugins to find out whether they can
## be opened. That one, above all, must never start another.
func _is_a_scan(args: PackedStringArray = OS.get_cmdline_user_args()) -> bool:
	for a in args:
		if String(a).begins_with("--cd-vstscan"):
			return true
	return false


## Plugins in the library that no version has actually opened. See PROBE_MARK.
func _unchecked() -> int:
	var n := 0
	for p in vst3:
		if int(p.get("probed", 0)) < PROBE_MARK:
			n += 1
	return n


func refresh_stock() -> void:
	if Audio.engine == null:
		return
	stock = Audio.engine.stock_plugins()
	catalog_changed.emit()


## The copy of a hosted plugin installed on *this* machine, for a project that
## was saved on another one.
##
## A project records where a plugin was when it was saved, and that is not where
## it is on anybody else's machine -- least of all on another operating system,
## where the same plugin is a bundle of a different shape in a different place.
## The VST3 class id is the same everywhere for the same plugin, so that is what
## a project is really pointing at and the path is only a hint. Without this, a
## Linux project opened on Windows found none of its instruments and every
## hosted channel went silent: "it sounded nothing like mine".
##
## Returns the catalogue entry, or {} when the plugin is genuinely not installed.
func locate_vst3(cid: String, path: String, plugin_name: String = "") -> Dictionary:
	# Where it says it is, if that is where it is. Same machine, nothing to do.
	# A VST3 is a folder on Linux and may be a single file on Windows, so both
	# count as "it is where it says it is".
	if not path.is_empty() and (FileAccess.file_exists(path) or DirAccess.dir_exists_absolute(path)):
		for e in vst3:
			if String(e.get("path", "")) == path:
				return e
	var want_cid := cid.strip_edges().to_lower()
	if not want_cid.is_empty():
		for e in vst3:
			if String(e.get("cid", "")).strip_edges().to_lower() == want_cid:
				return e
	# Failing that, the bundle's own file name -- "Vital.vst3" is "Vital.vst3"
	# on both systems even when nothing around it is.
	var want_file := path.get_file().to_lower()
	if not want_file.is_empty():
		for e in vst3:
			if String(e.get("path", "")).get_file().to_lower() == want_file:
				return e
	# And last, what it calls itself. Weakest of the three, because two plugins
	# may share a name, but better than a silent channel.
	var want_name := plugin_name.strip_edges().to_lower()
	if not want_name.is_empty():
		for e in vst3:
			if String(e.get("name", "")).strip_edges().to_lower() == want_name:
				return e
	return {}


func stock_by_id(id: String) -> Dictionary:
	for p in stock:
		if String(p.id) == id:
			return p
	return {}


func instruments() -> Array:
	var out := []
	for p in stock:
		if bool(p.instrument):
			out.append(p)
	for p in vst3:
		if bool(p.get("instrument", false)):
			out.append(p)
	return out


func effects() -> Array:
	var out := []
	for p in stock:
		if not bool(p.instrument):
			out.append(p)
	for p in vst3:
		if not bool(p.get("instrument", false)):
			out.append(p)
	return out


func categories(effects_only: bool) -> Dictionary:
	var out := {}
	for p in stock:
		if effects_only == bool(p.instrument):
			continue
		var c := String(p.category)
		if not out.has(c):
			out[c] = []
		out[c].append(p)
	if not vst3.is_empty():
		var key := "VST3"
		out[key] = []
		for p in vst3:
			if effects_only == bool(p.get("instrument", false)):
				continue
			out[key].append(p)
		if out[key].is_empty():
			out.erase(key)
	return out


# ---------------------------------------------------------------------------
# VST3
# ---------------------------------------------------------------------------
func vst3_dirs() -> PackedStringArray:
	var extra: Array = Settings.get_value("vst3_dirs", [])
	var dirs := PackedStringArray()
	if Audio.engine != null:
		dirs = Audio.engine.vst3_dirs()
	for d in extra:
		if not dirs.has(String(d)):
			dirs.append(String(d))
	return dirs


## Bundles that took the process down while they were being opened, and the
## one that is being opened right now. A plugin that crashes on load used to
## take the whole scan with it, and the next start would open it again and
## crash again, so nothing was ever found. Now the marker survives the crash
## and the bundle is skipped and reported instead.
const VST3_PROBING := "user://vst3_probing.txt"
const VST3_BROKEN := "user://vst3_broken.json"

## How thoroughly a cached entry was checked. Until this existed, a scan read a
## bundle's class list out of its factory and never created anything, so a
## plugin that falls over while it is being *opened* -- which is a different
## thing entirely, and the thing that actually happens -- was written into the
## cache as perfectly fine. It then took Cadmium down every time somebody put
## it on a channel, and the scan never looked at it again because its file had
## not changed. Entries from before now carry no mark and are opened again, in
## a process of their own, once each.
## Raised whenever Cadmium changes how it opens plugins, which is also when a
## plugin that could not be opened before deserves another go: the list of ones
## that would not open is forgotten at the same time.
const PROBE_MARK := 2

signal scan_progress(done: int, total: int, name: String)

var problems: Array = []      ## {path, name, error} for bundles that would not load


## The reason string an earlier version wrote when it blamed a plugin for the
## program not being there any more. Recognised so those can be dropped.
const BLAMED_WITHOUT_EVIDENCE := "it stopped Cadmium the last time it was opened"


## When the marker naming the plugin being opened was written.
func _probing_time() -> int:
	if not FileAccess.file_exists(VST3_PROBING):
		return 0
	return int(FileAccess.get_modified_time(ProjectSettings.globalize_path(VST3_PROBING)))


## Whether Cadmium actually left a crash report from around then. A process
## that was killed leaves the marker and no report, and being killed is not a
## thing to hold against a plugin.
func _crash_around(when: int) -> bool:
	if when <= 0:
		return false
	for r in CdCrash.list():
		# The scan's own reports are contained crashes of a different process.
		if bool(r.get("scan", false)):
			continue
		if int(r.when) >= when - 10:
			return true
	return false


func _mark_probing(path: String) -> void:
	var f := FileAccess.open(VST3_PROBING, FileAccess.WRITE)
	if f != null:
		f.store_string(path)
		f.close()


func _clear_probing() -> void:
	if FileAccess.file_exists(VST3_PROBING):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(VST3_PROBING))


## The bundle that was open when Cadmium last stopped, if it never got to say
## it had finished with it.
func _crashed_on() -> String:
	if not FileAccess.file_exists(VST3_PROBING):
		return ""
	var f := FileAccess.open(VST3_PROBING, FileAccess.READ)
	if f == null:
		return ""
	var p := f.get_as_text().strip_edges()
	f.close()
	return p


## Whether a plugin has already been found to fall over on the way up, and
## what happened. The scan writes this list; the rest of the program reads it
## so that a project full of a plugin that cannot be opened says so instead of
## trying it again.
## Called either side of opening a plugin for real, so that a crash inside one
## is pinned on it rather than on nothing in particular. See _ready().
func mark_opening(path: String) -> void:
	_mark_probing(path)


func done_opening() -> void:
	_clear_probing()


func is_broken(path: String) -> bool:
	return _broken().has(path)


func broken_reason(path: String) -> String:
	return String(_broken().get(path, "it would not open"))


func _broken() -> Dictionary:
	if not FileAccess.file_exists(VST3_BROKEN):
		return {}
	var f := FileAccess.open(VST3_BROKEN, FileAccess.READ)
	if f == null:
		return {}
	var parsed = JSON.parse_string(f.get_as_text())
	f.close()
	return parsed if typeof(parsed) == TYPE_DICTIONARY else {}


func _set_broken(d: Dictionary) -> void:
	var f := FileAccess.open(VST3_BROKEN, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(d, "\t"))
		f.close()


## Forgets the list of bundles that crashed the scanner, so a plugin that has
## since been fixed or reinstalled gets another chance.
## Gives one plugin another chance, rather than the whole list. Offered from the
## window of the plugin that was refused, which is where somebody actually finds
## out that it was.
func forgive(path: String) -> void:
	var known := _broken()
	if not known.has(path):
		return
	known.erase(path)
	_set_broken(known)


func forget_broken_vst3() -> void:
	if FileAccess.file_exists(VST3_BROKEN):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(VST3_BROKEN))


## A bundle's fingerprint, so an unchanged one is taken from the cache instead
## of being opened again. Opening two hundred plugin libraries is what made a
## rescan take the best part of a minute.
func _stamp(path: String) -> String:
	var t := FileAccess.get_modified_time(path)
	if t == 0:
		# A bundle is a folder: its own timestamp does not move when the module
		# inside it is replaced, so the module is what gets fingerprinted.
		for sub in ["Contents/x86_64-linux", "Contents/x86_64-win", "Contents/x86_64-win64"]:
			var d := DirAccess.open(path.path_join(sub))
			if d == null:
				continue
			for f in d.get_files():
				t = maxi(t, int(FileAccess.get_modified_time(path.path_join(sub).path_join(f))))
	else:
		return "%d" % t
	return "%d" % t


## Walks the plugin folders and opens each bundle once. Yields between bundles,
## so the window keeps drawing and a progress line can be shown; unchanged
## bundles come straight from the cache, which makes a repeat scan instant.
func rescan_vst3(force: bool = false) -> int:
	if Audio.engine == null:
		return 0
	# A second request while one is running waits for it rather than being
	# dropped: the caller asked how many there are and deserves an answer.
	while scanning:
		await get_tree().process_frame
	scanning = true
	var known := {}
	if not force:
		for p in vst3:
			var key := "%s|%s" % [String(p.get("path", "")), String(p.get("stamp", ""))]
			if not known.has(key):
				known[key] = []
			known[key].append(p)

	var broken := _broken()
	# Whatever was open when the process last died is what killed it.
	var died_on := _crashed_on()
	if not died_on.is_empty():
		broken[died_on] = "crashed Cadmium while it was being opened"
		_set_broken(broken)
		_clear_probing()

	var bundles: PackedStringArray = Audio.engine.vst3_bundles(vst3_dirs())
	var found: Array = []
	var trouble: Array = []
	## The ones nobody has opened yet, which are the ones that can go wrong.
	var fresh: Array = []
	var i := 0
	for b in bundles:
		i += 1
		var path := String(b)
		var name := path.get_file()
		scan_progress.emit(i, bundles.size(), name)
		if broken.has(path):
			trouble.append({"path": path, "name": name, "error": String(broken[path])})
			continue
		var stamp := _stamp(path)
		var key := "%s|%s" % [path, stamp]
		var cached: Array = known.get(key, [])
		var checked := not cached.is_empty()
		for p in cached:
			if int(p.get("probed", 0)) < PROBE_MARK:
				checked = false
		if checked:
			for p in cached:
				if String(p.get("error", "")).is_empty():
					found.append(p)
				else:
					trouble.append(p)
			continue
		fresh.append(path)

	# The new ones are opened in a process of their own, so a plugin that falls
	# over on the way up takes that process down rather than this one. See
	# _probe_apart.
	if not fresh.is_empty():
		var report := await _probe_apart(fresh, broken)
		for entry in report.found:
			found.append(entry)
		for entry in report.trouble:
			trouble.append(entry)

	Audio.engine.vst3_release_scanned()
	vst3 = found
	problems = trouble
	scanning = false
	_save_vst3_cache()
	catalog_changed.emit()
	return vst3.size()


## Opens a list of plugins somewhere else and brings back what it found.
##
## Each is created, initialised and taken down again -- the same thing that
## happens when one goes on a channel -- in a Cadmium started with
## --cd-vstscan. If that process dies, the results file says which plugin it
## was on: that one gets one more go on its own -- plugins from one maker share
## a runtime, and the one that fell over is often not the one at fault -- and
## is written off only if it falls over alone as well. The rest are picked up
## again in a new process. It takes several goes to get through a folder with
## several bad plugins in it, and it never takes the program down.
func _probe_apart(paths: Array, broken: Dictionary) -> Dictionary:
	var found := []
	var trouble := []
	var todo := paths.duplicate()
	var rounds := 0
	## The ones already given a second go on their own. See below.
	var retried := {}
	while not todo.is_empty() and rounds < paths.size() + 8:
		rounds += 1
		var before := todo.size()
		var result := await _run_probe(todo)
		for entry in result.found:
			found.append(entry)
		for entry in result.trouble:
			trouble.append(entry)
		if not bool(result.get("spawned", true)):
			# No child could be started at all: fall back to opening them here,
			# which is what happened before there was a way to do it elsewhere.
			for path in todo:
				_mark_probing(String(path))
				for e in Audio.engine.scan_vst3_bundle(String(path)):
					var entry: Dictionary = e
					entry["stamp"] = _stamp(String(path))
					# Nothing better is available on a machine where no second
					# process can be started; marked so the whole library is
					# not opened again at every start.
					entry["probed"] = PROBE_MARK
					if String(entry.get("error", "")).is_empty():
						found.append(entry)
					else:
						trouble.append(entry)
				_clear_probing()
				await get_tree().process_frame
			break

		var next: Array = result.left
		var died := String(result.get("died_on", ""))
		if died.is_empty() and next.size() >= before:
			# The child stopped without managing to say where it had got to.
			# Somebody has to be blamed for that or this same list is started
			# again for ever -- which is what a folder of crash reports five
			# seconds apart, and a spinning cursor that never stops, is.
			died = String(todo[0])
			next = next.filter(func(p): return String(p) != died)

		if not died.is_empty():
			var write_off := true
			if before > 1 and not retried.has(died):
				# It may well not have been this plugin's doing. Plugins from
				# one maker share a runtime -- Kilohearts' HeartCore, Waves,
				# NI -- and one already started up in a process can bring the
				# next one down with it. So it gets one more go with nothing
				# else in the process, and is only written off if it falls over
				# on its own too.
				retried[died] = true
				var second := await _run_probe([died])
				for entry in second.found:
					found.append(entry)
				for entry in second.trouble:
					trouble.append(entry)
				write_off = not (String(second.get("died_on", "")).is_empty()
						and not second.found.is_empty())
			if write_off:
				broken[died] = "crashed while it was being opened"
				_set_broken(broken)
				trouble.append({"path": died, "name": died.get_file(),
						"error": "crashed while it was being opened"})
		todo = next
	return {"found": found, "trouble": trouble}


## One run of the child. Returns what it managed before it stopped, what it was
## opening if it stopped early, and what is left to try.
func _run_probe(todo: Array) -> Dictionary:
	if _is_a_scan():
		# The belt to the braces above: the copy of Cadmium whose whole job is
		# to open plugins never starts another one, whatever asked it to. One
		# that did would start copies that started copies.
		return {"found": [], "trouble": [], "left": todo, "spawned": false}
	var dir := OS.get_user_data_dir()
	var in_path := dir.path_join("vstscan_in.txt")
	var out_path := dir.path_join("vstscan_out.jsonl")
	var f := FileAccess.open(in_path, FileAccess.WRITE)
	if f == null:
		return {"found": [], "trouble": [], "left": todo, "spawned": false}
	for p in todo:
		f.store_line(String(p))
	f.close()
	if FileAccess.file_exists(out_path):
		DirAccess.remove_absolute(out_path)

	var exe := OS.get_executable_path()
	var args := PackedStringArray()
	# Run from source and the executable is Godot itself, which needs telling
	# where the project is; an exported build is the program.
	if OS.has_feature("editor") or exe.get_file().to_lower().begins_with("godot"):
		args.append_array(["--path", ProjectSettings.globalize_path("res://")])
	args.append_array(["--headless", "--audio-driver", "Dummy", "--",
			"--cd-vstscan=%s,%s" % [in_path, out_path]])
	var pid := OS.create_process(exe, args)
	if pid <= 0:
		return {"found": [], "trouble": [], "left": todo, "spawned": false}

	# Given as long as it needs, within reason: a big library instrument can
	# take a minute to come up the first time, and there is a whole folder of
	# them to get through.
	var deadline := Time.get_ticks_msec() + 120000 + 60000 * todo.size()
	while OS.is_process_running(pid):
		if Time.get_ticks_msec() > deadline:
			OS.kill(pid)
			break
		scan_progress.emit(0, todo.size(), _probe_now(out_path).get_file())
		await get_tree().create_timer(0.1).timeout
	return _read_probe(out_path, todo)


func _probe_now(out_path: String) -> String:
	var seen := _read_probe(out_path, [])
	return String(seen.get("died_on", ""))


## What the child wrote: every result it finished, what it was opening when it
## stopped, and everything after that.
func _read_probe(out_path: String, todo: Array) -> Dictionary:
	var found := []
	var trouble := []
	var probing := ""
	var done := {}
	var f := FileAccess.open(out_path, FileAccess.READ)
	if f != null:
		while not f.eof_reached():
			var line := f.get_line().strip_edges()
			if line.is_empty():
				continue
			var parsed = JSON.parse_string(line)
			if typeof(parsed) != TYPE_DICTIONARY:
				continue
			if parsed.has("probing"):
				probing = String(parsed.probing)
			elif parsed.has("path"):
				probing = ""
				done[String(parsed.path)] = true
				for e in parsed.get("entries", []):
					var entry: Dictionary = e
					entry["stamp"] = _stamp(String(parsed.path))
					entry["probed"] = PROBE_MARK
					if String(entry.get("error", "")).is_empty():
						found.append(entry)
					else:
						trouble.append(entry)
		f.close()
	var left := []
	var past := false
	for p in todo:
		var path := String(p)
		if done.has(path) or path == probing:
			past = true
			continue
		if past or not done.has(path):
			left.append(path)
	return {"found": found, "trouble": trouble, "left": left, "died_on": probing, "spawned": true}


func _load_vst3_cache() -> void:
	if not FileAccess.file_exists(VST3_CACHE):
		return
	var f := FileAccess.open(VST3_CACHE, FileAccess.READ)
	if f == null:
		return
	var parsed = JSON.parse_string(f.get_as_text())
	f.close()
	if typeof(parsed) == TYPE_DICTIONARY and parsed.has("plugins"):
		vst3 = parsed["plugins"]
		problems = parsed.get("problems", [])
		catalog_changed.emit()


func _save_vst3_cache() -> void:
	var f := FileAccess.open(VST3_CACHE, FileAccess.WRITE)
	if f == null:
		return
	f.store_string(JSON.stringify({
		"scanned": Time.get_datetime_string_from_system(),
		"plugins": vst3,
		"problems": problems,
	}, "\t"))
	f.close()


func vst3_by_cid(cid: String) -> Dictionary:
	for p in vst3:
		if String(p.cid) == cid:
			return p
	return {}


# ---------------------------------------------------------------------------
# Soundfonts and samples
# ---------------------------------------------------------------------------
func soundfonts() -> Array:
	var windows := OS.get_name() == "Windows"
	var dirs: Array = (SF2_DIRS_WINDOWS if windows else SF2_DIRS_UNIX).duplicate()
	dirs.append(OS.get_data_dir().path_join("soundfonts"))
	var home := Cd.home_dir()
	if not home.is_empty():
		if windows:
			dirs.append(home.path_join("Documents/SoundFonts"))
		else:
			dirs.append(home.path_join(".local/share/soundfonts"))
			dirs.append(home.path_join(".config/aimusicstudio/soundfonts"))
	# Beside the application, so a folder of soundfonts can travel with it.
	dirs.append(OS.get_executable_path().get_base_dir().path_join("soundfonts"))
	for d in Settings.get_value("sf2_dirs", []):
		dirs.append(String(d))
	var out := []
	var seen := {}
	for d in dirs:
		_collect(d, ["sf2", "sf3"], out, seen, 2)
	out.sort_custom(func(a, b): return String(a.name).nocasecmp_to(String(b.name)) < 0)
	return out


func samples(extra_dir: String = "") -> Array:
	var dirs := []
	if not extra_dir.is_empty():
		dirs.append(extra_dir)
	for d in Settings.get_value("sample_dirs", []):
		dirs.append(String(d))
	var out := []
	var seen := {}
	for d in dirs:
		_collect(d, Cd.AUDIO_EXTS, out, seen, 3)
	out.sort_custom(func(a, b): return String(a.name).nocasecmp_to(String(b.name)) < 0)
	return out


func _collect(dir: String, exts: Array, out: Array, seen: Dictionary, depth: int) -> void:
	if depth <= 0 or dir.is_empty():
		return
	var d := DirAccess.open(dir)
	if d == null:
		return
	d.list_dir_begin()
	var f := d.get_next()
	while not f.is_empty():
		if f.begins_with("."):
			f = d.get_next()
			continue
		var full := dir.path_join(f)
		if d.current_is_dir():
			_collect(full, exts, out, seen, depth - 1)
		elif exts.has(f.get_extension().to_lower()) and not seen.has(full):
			seen[full] = true
			out.append({"name": f, "path": full, "dir": dir})
		f = d.get_next()
	d.list_dir_end()
