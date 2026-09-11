class_name CdCrash
extends RefCounted
## Reports left behind when Cadmium stops unexpectedly.
##
## A host that loads other people's code cannot be crash-proof: a plugin that
## writes over memory takes the process with it. What Cadmium can do is say
## what it was doing at the time -- which plugin was being opened, most of all
## -- and leave that where it can be read afterwards rather than vanishing.
##
## The reports themselves are written by the engine from a signal handler, so
## they survive the kind of stop that never reaches any code up here.

const DIR := "crashes"


static func dir() -> String:
	var d := OS.get_user_data_dir().path_join(DIR)
	DirAccess.make_dir_recursive_absolute(d)
	return d


## Names the reports written by the copy of Cadmium whose whole job is to open
## plugins and find out whether they can be opened. Those crashes are contained
## on purpose -- they take a scan down and nothing else -- so they are kept and
## can be read, but they are never announced as the program having fallen over.
const SCAN_PREFIX := "cadmium-scan"


## Arms the handler and says where to write. Called once, at startup.
static func arm(prefix: String = "cadmium-crash") -> void:
	if Audio.engine == null:
		return
	Audio.engine.crash_init(dir(), "Cadmium %s (%s)" % [
			ProjectSettings.get_setting("application/config/version", "?"), OS.get_name()],
			prefix)


## What Cadmium is doing, in a few words, in case it stops while doing it.
static func note(what: String) -> void:
	if Audio.engine != null:
		Audio.engine.crash_note(what)


## The reports there are, newest first.
static func list() -> Array:
	var out := []
	var d := DirAccess.open(dir())
	if d == null:
		return out
	for f in d.get_files():
		if not String(f).ends_with(".log"):
			continue
		var path := dir().path_join(String(f))
		out.append({"name": String(f), "path": path,
				"scan": String(f).begins_with(SCAN_PREFIX),
				"when": FileAccess.get_modified_time(path)})
	out.sort_custom(func(a, b): return int(a.when) > int(b.when))
	return out


static func read(path: String) -> String:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	var text := f.get_as_text()
	f.close()
	return text


## The one line worth showing without opening the whole report: what it was
## doing when it stopped.
static func doing(path: String) -> String:
	for line in read(path).split("\n"):
		if String(line).begins_with("doing"):
			return String(line).substr(5).strip_edges()
	return ""


static func remove(path: String) -> void:
	DirAccess.remove_absolute(path)


## Anything written since the last time Cadmium was started. That is the one
## worth saying out loud, because it is the one that happened to whoever is
## reading.
static func since_last_run() -> Array:
	var last := int(Settings.get_value("last_run_unix", 0))
	var out := []
	for r in list():
		# A plugin that fell over while being examined is reported by the scan,
		# which knows what to do about it; it is not what "Cadmium stopped
		# unexpectedly" means.
		if int(r.when) >= last and not bool(r.get("scan", false)):
			out.append(r)
	return out


static func mark_run() -> void:
	Settings.set_value("last_run_unix", int(Time.get_unix_time_from_system()))
