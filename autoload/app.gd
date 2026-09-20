extends Node
## The project, the undo stack, and the bridge that keeps the C++ engine holding
## exactly what the editor thinks it holds.
##
## Panels never touch the engine directly: they call the editing methods here,
## which mutate the project, push the affected part to the engine and emit the
## signal the other panels listen on.

signal project_loaded()
signal channels_changed()
signal patterns_changed()
signal pattern_selected(index: int)
signal playlist_changed()
signal mixer_changed()
signal selection_changed()
signal automation_changed()
signal title_changed()
signal status(message: String)
signal open_plugin(ref: Dictionary)
## The same click again: what is open closes. Clicking the name of a plugin
## that is already in front of you means you want it gone.
signal toggle_plugin(ref: Dictionary)
## A plugin is about to stop existing. Anything holding on to it -- an open
## window, most of all -- has to let go before the engine lets go of it.
signal plugin_destroyed(handle: int)
## A sample has been changed: it sounds different, it may be a different
## length, and anything drawing it is drawing something out of date.
signal sample_changed(index: int)
## What a click on an empty piece of timeline puts down has changed.
signal paint_item_changed(kind: String, index: int)
## A control was moved: which one, so the toolbar can hold on to it.
signal tweaked(entry: Dictionary)

var project := CdProject.new()

## Live engine handles, parallel to the project's own arrays.
var channel_handles: Array = []
var insert_handles := {}          # "track:slot" -> handle
var _identity := {}               # handle -> identity string
## What each live plugin has already been given: its state blob, its strings
## and its parameters. Handing a plugin back something it already has is not
## free -- giving a VST3 its own state is a full patch reload, which for a big
## sampler is seconds of work to change nothing -- and it used to happen on
## every edit anywhere in the project. It is also wrong: a patch chosen in the
## plugin's own window would be undone by the next unrelated change.
var _applied := {}                # handle -> {state, strings, params}
## Plugins whose state may have moved since it was last read back. Reading it
## is the expensive half of an undo snapshot, and a plugin nobody has touched
## has nothing new to say.
var _state_dirty := {}            # handle -> true
## What a project asked for and this machine did not have, and what was found
## somewhere other than where the project said. Filled in while a project is
## being brought up and reported once, rather than as a run of status lines
## that scroll past before anyone reads them.
var _missing: Array[String] = []
var _relocated: Array[String] = []

var current_pattern := 0
var current_channel := 0
var current_mixer := 1
var selected_notes: Array = []    # indices into the current pattern's notes
var selected_clips: Array = []
var snap := "1/16"
var tool := Cd.Tool.DRAW

## Notes and clips copied from the editors, kept as plain data so a paste can
## survive an undo or a project reload.
var clipboard_notes: Array = []
var clipboard_clips: Array = []

var recording := false
var _rec_open := {}     # "source|key" -> beat where it started
var _live := {}         # "source|key" -> the channel it was started on
## A MIDI keyboard is hardware, not part of any window, so its notes
## survive the window losing focus when every other source's do not.
const LIVE_MIDI := "midi"

var _undo: Array = []
var _redo: Array = []
const UNDO_LIMIT := 128
var _suspend_sync := false
## How many batches are open. An import adds a thousand things and the
## interface should hear about that once, at the end: told a thousand times, it
## spends the whole import rebuilding itself and runs Godot's message queue
## out of room.
var _batch := 0


## Set once the first project exists, so anything started from the command line
## can wait rather than racing the autoload's own setup.
var initialized := false


func _ready() -> void:
	snap = String(Settings.get_value("snap", "1/16"))
	# Made at startup rather than the first time a dialog opens, so there is
	# somewhere obvious to put things before you go looking for it.
	Settings.projects_dir()
	set_process(true)
	await get_tree().process_frame
	new_project()
	initialized = true


func _process(dt: float) -> void:
	_autosave_tick(dt)
	_live_watchdog(dt)
	# Automated controls follow what is driving them, but only while something
	# is actually being driven and only while the song plays: a stopped song
	# moves nothing, and a project with no automation in it costs nothing here.
	var playing := Audio.playing()
	# A take starts when the transport does and ends when it stops, so what
	# was sung lines up with what it was sung over.
	if playing != _was_playing:
		if playing:
			start_take()
		else:
			finish_take()
	if not _auto_index.is_empty() and (playing or _was_playing):
		_auto_clock += dt
		# One more tick after the song stops, so anything showing where a lane
		# had got to can put itself away rather than freezing at its last
		# position.
		if _auto_clock >= AUTO_TICK or not playing:
			_auto_clock = 0.0
			automation_tick.emit()
	_was_playing = playing


## How long the whole application has to have been out of focus before a note
## still sounding counts as a lost key-up. A window reports focus off for a
## moment at all sorts of times that are nothing to do with the user leaving --
## a menu opening over it, a compositor handing a surface across, a plugin's
## window coming up -- and cutting off a note somebody is still holding down is
## a much worse fault than one that hangs on for half a second after alt-tab.
const UNFOCUSED_GRACE := 0.5
var _unfocused_for := 0.0


## Nothing can be held down in a window that is not there any more, so a note
## still sounding when the application loses focus is a lost key-up: alt-tab
## away mid-chord, or a plugin's own window taking the keyboard, and the note
## used to drone forever.
func _live_watchdog(dt: float) -> void:
	var focused := false
	for w in DisplayServer.get_window_list():
		if DisplayServer.window_is_focused(w):
			focused = true
			break
	# A mouse button still down is somebody still holding the note, and the
	# control that started it is watching the button itself. A typing key is
	# not the same case: once the keyboard has gone elsewhere -- a plugin's own
	# window, another application -- the release is delivered there and Cadmium
	# never hears it, which is exactly how a note gets stuck for good.
	_watchdog_tick(dt, focused, Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT))


## The rule on its own, away from the window manager, so it can be put to the
## test rather than guessed at.
func _watchdog_tick(dt: float, focused: bool, held: bool) -> void:
	if _live.is_empty() or focused or held:
		_unfocused_for = 0.0
		return
	_unfocused_for += dt
	if _unfocused_for < UNFOCUSED_GRACE:
		return
	_unfocused_for = 0.0
	# A MIDI keyboard is not part of this window and keeps playing while the
	# window is in the background; everything else was being held with a mouse
	# or a key that this window can no longer hear released.
	for id in _live.keys():
		var parts := String(id).rsplit("|", true, 1)
		if parts.size() == 2 and parts[0] != LIVE_MIDI:
			live_note_off(int(parts[1]), parts[0])


# ---------------------------------------------------------------------------
# Project lifecycle
# ---------------------------------------------------------------------------
func new_project() -> void:
	_release_all_plugins()
	if engine() != null:
		engine().forget_audio()
	project = CdProject.new()
	current_pattern = 0
	current_channel = 0
	current_mixer = 1
	selected_notes.clear()
	selected_clips.clear()
	_undo.clear()
	_redo.clear()
	sync_all()
	_emit(project_loaded)
	_emit(title_changed)


# ---------------------------------------------------------------------------
# Autosave
#
# A copy beside the project rather than over it: an autosave that overwrites
# what you have open is a way to lose an hour's work to a bad edit. An unsaved
# project goes to user:// so there is still something to come back to.
# ---------------------------------------------------------------------------
var _autosave_t := 0.0
var _autosave_note := ""


func autosave_path() -> String:
	if not project.path.is_empty():
		return project.path.get_basename() + ".autosave.cadmium"
	return Settings.autosave_dir().path_join("untitled.autosave.cadmium")


func _autosave_tick(dt: float) -> void:
	var minutes := float(Settings.get_value("autosave_minutes", 5))
	if minutes <= 0.0 or not project.dirty:
		_autosave_t = 0.0
		return
	_autosave_t += dt
	if _autosave_t < minutes * 60.0:
		return
	_autosave_t = 0.0
	var path := autosave_path()
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	_capture_plugin_state()
	# The project stays "dirty" and keeps its own name: this is a safety net,
	# not a save. project.save() claims the file it wrote as the project's own.
	var was_dirty := project.dirty
	var saved_path := project.path
	var saved_name := project.name
	if project.save(path) == OK:
		status.emit("Autosaved to %s" % path.get_file())
	project.path = saved_path
	project.name = saved_name
	project.dirty = was_dirty


func save_project(path: String) -> Error:
	_capture_plugin_state(true)
	var err := project.save(path)
	if err == OK:
		Settings.push_recent(path)
		status.emit("Saved %s" % path.get_file())
		_emit(title_changed)
	return err


func load_project(path: String) -> Error:
	# Loading a project loads every plugin in it, which is where a bad one
	# stops everything: the report should say which project it was on.
	CdCrash.note("opening the project %s" % path.get_file())
	_release_all_plugins()
	if engine() != null:
		engine().forget_audio()
	var err := project.load_from(path)
	if err != OK:
		status.emit("Could not open %s" % path.get_file())
		return err
	current_pattern = 0
	current_channel = 0
	selected_notes.clear()
	selected_clips.clear()
	_undo.clear()
	_redo.clear()
	sync_all()
	Settings.push_recent(path)
	_emit(project_loaded)
	_emit(title_changed)
	status.emit("Opened %s" % path.get_file())
	# And then, over the top of that, anything the project wanted that this
	# machine has not got. A project that came from somebody else is exactly
	# when this matters and exactly when nobody thinks to check.
	report_missing()
	return OK


func title() -> String:
	return "%s%s - Cadmium" % ["*" if project.dirty else "", project.name]


# ---------------------------------------------------------------------------
# Undo
# ---------------------------------------------------------------------------
## Held back while a batch is open; see `_batch`.
func _emit(sig: Signal) -> void:
	if _batch == 0:
		sig.emit()


## Everything between these two is one change as far as the interface is
## concerned. Undo sees one step as well: an import is not a thousand things
## to take back one at a time.
func begin_batch(label: String = "") -> void:
	if _batch == 0:
		if not label.is_empty():
			snapshot(label)
		_suspend_sync = true
	_batch += 1


func end_batch() -> void:
	_batch = maxi(0, _batch - 1)
	if _batch > 0:
		return
	_suspend_sync = false
	sync_all()
	project_loaded.emit()
	title_changed.emit()


func snapshot(label: String) -> void:
	_capture_plugin_state()
	_undo.append({"label": label, "data": project.to_dict()})
	if _undo.size() > UNDO_LIMIT:
		_undo.pop_front()
	_redo.clear()
	project.dirty = true
	_emit(title_changed)


func undo() -> void:
	if _undo.is_empty():
		status.emit("Nothing to undo")
		return
	var entry: Dictionary = _undo.pop_back()
	_redo.append({"label": entry.label, "data": project.to_dict()})
	project.from_dict(entry.data)
	project.dirty = true
	_restore()
	status.emit("Undo %s" % entry.label)


func redo() -> void:
	if _redo.is_empty():
		status.emit("Nothing to redo")
		return
	var entry: Dictionary = _redo.pop_back()
	_undo.append({"label": entry.label, "data": project.to_dict()})
	project.from_dict(entry.data)
	project.dirty = true
	_restore()
	status.emit("Redo %s" % entry.label)


func undo_label() -> String:
	return String(_undo[-1].label) if not _undo.is_empty() else ""


func redo_label() -> String:
	return String(_redo[-1].label) if not _redo.is_empty() else ""


func _restore() -> void:
	current_pattern = clampi(current_pattern, 0, maxi(0, project.patterns.size() - 1))
	current_channel = clampi(current_channel, 0, maxi(0, project.channels.size() - 1))
	selected_notes.clear()
	selected_clips.clear()
	sync_all()
	_emit(project_loaded)
	_emit(title_changed)


# ---------------------------------------------------------------------------
# Engine sync
# ---------------------------------------------------------------------------
func engine() -> Variant:
	return Audio.engine


func sync_all() -> void:
	if engine() == null or _suspend_sync:
		return
	# What follows fills these in. They describe the sync that is about to
	# happen, not every one since the program started.
	_missing.clear()
	_relocated.clear()
	push_transport()
	_sync_plugins()
	push_channels()
	push_mixer()
	push_patterns()
	push_samples()
	push_playlist()
	push_automation()


## A file a project points at, as it is on *this* machine.
##
## A project records absolute paths, and an absolute path is a fact about one
## computer. Sending a project to somebody else -- or to another operating
## system -- makes every one of them wrong. The file is looked for where the
## project says first, and then where a file of that name plausibly is: beside
## the project, in the usual folders next to it, and under this machine's home
## instead of the one that saved it.
##
## Returns "" when it genuinely is not here.
func find_file(path: String) -> String:
	if path.is_empty():
		return ""
	if FileAccess.file_exists(path):
		return path
	var name := path.get_file()
	if name.is_empty():
		return ""
	var roots: Array[String] = []
	if not project.path.is_empty():
		var beside := project.path.get_base_dir()
		roots.append_array([beside, beside.path_join("Samples"), beside.path_join("Audio"),
				beside.path_join("Content")])
	roots.append_array([Settings.projects_dir(), Settings.projects_dir().path_join("Samples")])
	for root in roots:
		var candidate := root.path_join(name)
		if FileAccess.file_exists(candidate):
			return candidate
	# The same path under this machine's home rather than the one that saved it:
	# "/home/someone/Music/kick.wav" and "C:/Users/Someone/Music/kick.wav" are
	# the same file to everyone but the filesystem.
	var tail := _below_home(path)
	if not tail.is_empty():
		var candidate := Cd.home_dir().path_join(tail)
		if FileAccess.file_exists(candidate):
			return candidate
	return ""


## The part of a path below whichever home directory it was written under, or ""
## if it does not look like one.
func _below_home(path: String) -> String:
	var norm := path.replace("\\", "/")
	for marker in ["/home/", "/Users/"]:
		var at := norm.find(marker)
		if at < 0:
			continue
		var rest := norm.substr(at + marker.length())
		var slash := rest.find("/")
		if slash > 0:
			return rest.substr(slash + 1)
	return ""


## Says, once, what a project asked for that this machine did not have. Quietly
## losing an instrument is the thing that makes a project sound wrong somewhere
## else, and the one thing that makes it obvious is being told.
func report_missing() -> void:
	var moved := _unique(_relocated)
	var gone := _unique(_missing)
	if not moved.is_empty():
		print("Cadmium: found where this machine keeps them: %s" % ", ".join(moved))
	if gone.is_empty():
		if not moved.is_empty():
			status.emit("Opened. %d thing%s found where this machine keeps %s" % [
					moved.size(), "" if moved.size() == 1 else "s",
					"it" if moved.size() == 1 else "them"])
		return
	print("Cadmium: this project wanted things that are not on this machine:")
	for m in gone:
		print("  - %s" % m)
	status.emit("%d thing%s in this project %s not on this machine: %s" % [
			gone.size(), "" if gone.size() == 1 else "s",
			"is" if gone.size() == 1 else "are",
			", ".join(gone.slice(0, 4)) + ("..." if gone.size() > 4 else "")])


static func _unique(items: Array) -> Array:
	var seen := {}
	var out := []
	for i in items:
		if not seen.has(String(i)):
			seen[String(i)] = true
			out.append(String(i))
	return out


func push_transport() -> void:
	var e = engine()
	if e == null:
		return
	e.set_bpm(project.bpm)
	e.set_time_sig(project.sig_num, project.sig_den)
	e.set_current_pattern(current_pattern)
	e.set_metronome(bool(Settings.get_value("metronome", false)))


## One place to let go of a plugin, so nothing is left behind pointing at a
## handle the engine has already reused.
func _destroy_plugin(handle: int) -> void:
	if handle < 0:
		return
	# Announced first, while everything still lines up: a window that finds out
	# afterwards is a window pointing at a plugin that is not there, or worse,
	# at whichever one took its place.
	plugin_destroyed.emit(handle)
	engine().destroy_plugin(handle)
	_identity.erase(handle)
	_applied.erase(handle)
	_state_dirty.erase(handle)


## Says that a plugin's own state may have moved: its window is open, or
## something has written to it. Only these get read back on the next snapshot.
func touch_plugin(handle: int) -> void:
	if handle >= 0:
		_state_dirty[handle] = true


func _identity_of(plug) -> String:
	if plug == null or typeof(plug) != TYPE_DICTIONARY:
		return ""
	if String(plug.get("kind", "stock")) == "vst3":
		return "vst3|%s|%s" % [plug.get("path", ""), plug.get("id", "")]
	return "stock|%s" % plug.get("id", "")


## Creates or reuses one engine instance per plugin in the project. Reuse is
## what makes undo cheap: restoring a snapshot must not reload a VST3.
func _sync_plugins() -> void:
	var e = engine()
	channel_handles.resize(project.channels.size())
	for i in project.channels.size():
		var plug: Dictionary = project.channels[i].plugin
		channel_handles[i] = _ensure_plugin(channel_handles[i] if channel_handles[i] != null else -1, plug)
	var wanted := {}
	for t in project.mixer.size():
		var inserts: Array = project.mixer[t].inserts
		for s in inserts.size():
			var key := "%d:%d" % [t, s]
			var plug = inserts[s]
			if plug == null:
				if insert_handles.has(key):
					_destroy_plugin(int(insert_handles[key]))
					insert_handles.erase(key)
				continue
			wanted[key] = true
			var prev: int = int(insert_handles.get(key, -1))
			insert_handles[key] = _ensure_plugin(prev, plug)
	for key in insert_handles.keys():
		if not wanted.has(key):
			_destroy_plugin(int(insert_handles[key]))
			insert_handles.erase(key)


func _ensure_plugin(handle: int, plug: Dictionary) -> int:
	var e = engine()
	var want := _identity_of(plug)
	if handle >= 0 and String(_identity.get(handle, "")) == want:
		_apply_plugin_data(handle, plug)
		return handle
	if handle >= 0:
		_destroy_plugin(handle)
	var h := -1
	if String(plug.get("kind", "stock")) == "vst3":
		var path := String(plug.get("path", ""))
		var cid := String(plug.get("id", ""))
		var label := String(plug.get("name", path.get_file()))
		# Where this machine keeps it, which is not where the machine that saved
		# the project kept it. The class id is what the project is really
		# pointing at; see Plugins.locate_vst3.
		var here := Plugins.locate_vst3(cid, path, label)
		if not here.is_empty():
			if String(here.path) != path:
				_relocated.append(label)
			path = String(here.path)
			if not String(here.get("cid", "")).is_empty():
				cid = String(here.cid)
		elif not (FileAccess.file_exists(path) or DirAccess.dir_exists_absolute(path)):
			# Not in the catalogue and not where the project says either. That is
			# the only case that means "not installed".
			_missing.append("%s (plugin)" % label)
			status.emit("%s is not installed here" % label)
			return -1
		# Otherwise the catalogue simply has not been scanned yet -- it is a
		# cache, and it is empty until the first scan -- so the path the project
		# recorded is still the best thing to try, exactly as it used to be.
		# One that has already taken the program down once is not tried again:
		# the scan opens plugins somewhere they cannot do that, and what it
		# learned there is worth remembering here.
		if Plugins.is_broken(path):
			status.emit("%s will not open -- %s" % [label, Plugins.broken_reason(path)])
			_missing.append("%s (plugin will not open)" % label)
			return -1
		# So that a plugin which takes the program down on the way up is known
		# to have done it, and is not tried again on the next start.
		Plugins.mark_opening(path)
		h = e.create_vst3(path, cid)
		Plugins.done_opening()
		if h < 0:
			status.emit("Could not load %s" % label)
			_missing.append("%s (plugin would not load)" % label)
	else:
		h = e.create_plugin(String(plug.get("id", "")))
	if h < 0:
		return -1
	_identity[h] = want
	# A handle number can be reused; nothing from the last owner may carry over.
	_applied.erase(h)
	_state_dirty.erase(h)
	_apply_plugin_data(h, plug)
	return h


## The plugin settings that hold a path to a file rather than a value: a
## sampler's sample, a SoundFont player's bank, a convolver's impulse response,
## Prism's picture. All of them need relinking when a project moves machine.
const PATH_STRINGS := ["sample", "file", "ir", "image"]


## Brings a live plugin up to what the project says it should be -- and only
## the parts of it that have actually moved. See `_applied`.
func _apply_plugin_data(handle: int, plug: Dictionary) -> void:
	var e = engine()
	if handle < 0:
		return
	if not _applied.has(handle):
		_applied[handle] = {"state": "", "strings": {}, "params": {}}
	var done: Dictionary = _applied[handle]
	var strings: Dictionary = done["strings"]
	for key in plug.get("strings", {}).keys():
		var val := String(plug["strings"][key])
		# Several of these are file paths -- a sample, a soundfont, an impulse
		# response, a picture -- and a path from another machine points at
		# nothing here. Relinked rather than handed over to fail silently.
		if String(key) in PATH_STRINGS and not val.is_empty():
			var found := find_file(val)
			if found.is_empty():
				_missing.append("%s (%s for %s)" % [val.get_file(), String(key),
						String(plug.get("name", "plugin"))])
			else:
				if found != val:
					_relocated.append(found.get_file())
				val = found
		if strings.has(String(key)) and String(strings[String(key)]) == val:
			continue
		strings[String(key)] = val
		e.plugin_set_string(handle, String(key), val)
		# A picture is a file the engine cannot read; it has to be decoded here
		# and handed over as data whenever the project is loaded or synced.
		if String(key) == "image" and not val.is_empty() and FileAccess.file_exists(val):
			_reload_plugin_image(handle, val)
	# A hosted plugin's state is its own complete account of itself, and it
	# beats the parameter list stored beside it. The two disagree more often
	# than not: a patch chosen inside a plugin moves everything it has at once,
	# while the list here only ever gets what the plugin bothers to report back,
	# and several -- Vital among them -- report nothing at all for a preset
	# change. Both go into the file; the one written last is what comes back.
	# It used to be the list, so every value left over from the patch before was
	# stamped over the one that was saved. That is "I saved it, opened it again
	# and the preset was different".
	var state := String(plug.get("state", ""))
	var restored := false
	if not state.is_empty():
		if String(done["state"]) == state:
			restored = true                       # already in it, from an earlier sync
		else:
			restored = bool(e.plugin_set_string(handle, "state", state))
			if restored:
				done["state"] = state
	var params: Dictionary = done["params"]
	for key in plug.get("params", {}).keys():
		var idx := int(key)
		var v := float(plug["params"][key])
		if params.has(idx) and is_equal_approx(float(params[idx]), v):
			continue
		# Noted as written either way, so that a later sync does not come back
		# and do it -- but only actually sent when there was no state to say
		# otherwise. A plugin with no state (a stock one, or one imported from
		# an FL project) is still set up entirely from this list, and so is one
		# whose state would not load.
		params[idx] = v
		if not restored:
			e.plugin_set_param(handle, idx, v)
	# Preset values written by name before the descriptor was known.
	var pending: Dictionary = plug.get("pending_named", {})
	if not pending.is_empty():
		var descr: Array = e.plugin_params(handle)
		for p in descr:
			if pending.has(String(p.id)):
				var v := float(pending[String(p.id)])
				e.plugin_set_param(handle, int(p.index), v)
				plug["params"][str(int(p.index))] = v
				_applied[handle]["params"][int(p.index)] = v
		plug.erase("pending_named")


## `force` reads every hosted plugin's state back whatever it has been doing;
## without it, only the ones that have been touched are asked. Saving a file
## and copying an effect are worth the full price -- they are rare, and a stale
## patch written to disk is not something the user can undo.
func _capture_plugin_state(force: bool = false) -> void:
	var e = engine()
	if e == null:
		return
	for i in project.channels.size():
		if i < channel_handles.size():
			_capture_one(int(channel_handles[i]), project.channels[i].plugin, force)
	for key in insert_handles.keys():
		var parts := String(key).split(":")
		var t := int(parts[0])
		var s := int(parts[1])
		if t < project.mixer.size():
			var plug = project.mixer[t].inserts[s]
			if plug != null:
				_capture_one(int(insert_handles[key]), plug, force)


func _capture_one(handle: int, plug: Dictionary, force: bool = false) -> void:
	if handle < 0 or plug == null:
		return
	if String(plug.get("kind", "stock")) != "vst3":
		return
	# Asking a plugin for its state is the expensive half of a snapshot, and a
	# plugin that nobody has opened or written to has not moved since the last
	# one. It is also the only one that can have moved behind our back.
	#
	# A plugin with its own interface up is always asked, whether or not it has
	# said anything: a patch chosen from a plugin's own browser moves everything
	# it holds and several report none of it, so "nothing was reported" is not
	# the same as "nothing moved". It is the only way its state can change at
	# all, and it is cheap enough at a user's pace -- Vital, the biggest of them
	# at 233 KB, answers in 1.2 ms.
	var open_now: bool = engine().plugin_editor_open(handle)
	if not force and not open_now and not _state_dirty.has(handle) \
			and not String(plug.get("state", "")).is_empty():
		return
	var state: String = engine().plugin_get_string(handle, "state")
	plug["state"] = state
	_state_dirty.erase(handle)
	# What came back is what the plugin is holding, so it must not be sent
	# back to it as though it were a change.
	if _applied.has(handle):
		_applied[handle]["state"] = state


## Whatever was being held is not being held any more once the channels it was
## playing into are gone, and the book-keeping has to go with them.
func _release_all_plugins() -> void:
	_live.clear()
	_rec_open.clear()
	var e = engine()
	if e == null:
		return
	for h in channel_handles:
		if h != null and int(h) >= 0:
			_destroy_plugin(int(h))
	for key in insert_handles.keys():
		_destroy_plugin(int(insert_handles[key]))
	channel_handles.clear()
	insert_handles.clear()
	_identity.clear()
	_applied.clear()
	_state_dirty.clear()


func push_channels() -> void:
	var e = engine()
	while e.channel_count() > project.channels.size():
		e.remove_channel(e.channel_count() - 1)
	while e.channel_count() < project.channels.size():
		e.add_channel("channel")
	for i in project.channels.size():
		var c: Dictionary = project.channels[i]
		e.set_channel_name(i, String(c.name))
		e.set_channel_instrument(i, int(channel_handles[i]) if i < channel_handles.size() else -1)
		e.set_channel(i, float(c.vol), float(c.pan), bool(c.mute), bool(c.solo), int(c.mixer), int(c.transpose))
		var layers := []
		for l in c.get("layers", []):
			var target := int(l.get("channel", -1))
			if target < 0 or target >= project.channels.size() or target == i:
				continue
			layers.append([target, int(l.get("transpose", 0)), float(l.get("gain", 1.0))])
		e.set_channel_layers(i, layers, bool(c.get("layer_only", false)))


func push_mixer() -> void:
	var e = engine()
	e.set_mixer_count(project.mixer.size())
	for t in project.mixer.size():
		var m: Dictionary = project.mixer[t]
		e.set_mixer_name(t, String(m.name))
		e.set_mixer(t, float(m.vol), float(m.pan), bool(m.mute), bool(m.solo), int(m.route))
		var sends: Array = m.sends
		for s in sends.size():
			var snd: Dictionary = sends[s]
			e.set_send(t, s, int(snd.dest), float(snd.amount), bool(snd.pre), bool(snd.sidechain))
		for s in (m.inserts as Array).size():
			var key := "%d:%d" % [t, s]
			var h := int(insert_handles.get(key, -1))
			e.set_insert(t, s, h)
			var plug = m.inserts[s]
			if plug != null:
				e.set_insert_flags(t, s, bool(plug.get("bypass", false)), float(plug.get("wet", 1.0)))
	# Which strip is listening to the machine's input travels with the mixer:
	# a project saved with a vocoder set up comes back set up.
	push_input()


func push_patterns() -> void:
	var e = engine()
	for i in project.patterns.size():
		push_pattern(i)
	e.set_current_pattern(current_pattern)


func push_pattern(index: int) -> void:
	if index < 0 or index >= project.patterns.size():
		return
	var p: Dictionary = project.patterns[index]
	var flat := PackedFloat32Array()
	for n in p.notes:
		# A muted note stays in the pattern and out of the engine.
		if bool(n.get("mute", false)):
			continue
		flat.append_array([float(n.ch), float(n.beat), float(n.len), float(n.key), float(n.vel),
				float(n.get("pan", 0.0)), float(n.get("fine", 0.0))])
	engine().set_pattern(index, flat, float(p.length))


func push_playlist() -> void:
	var flat := PackedFloat32Array()
	for c in project.clips:
		flat.append_array([
			float(c.type), float(c.index), float(c.track), float(c.start), float(c.length),
			float(c.get("offset", 0.0)), float(c.get("gain", 1.0)),
			1.0 if bool(c.get("mute", false)) else 0.0, float(c.get("pitch", 0.0)),
		])
	engine().set_playlist(flat)
	# With nothing marked the transport loops over the whole song, and the song
	# just changed length. Without this it kept wrapping at whatever the end
	# was when the loop was last worked out, so anything added past there was
	# never reached -- and stopping and starting again did not help, because
	# neither of those works the loop out either.
	_push_loop()


## Controls that something is automating, by a key made from what they are.
## Rebuilt whenever the automation lanes change, so a knob can ask "is anything
## driving me?" without walking the list every frame.
var _auto_index := {}
## Ticks while the song plays so that automated controls follow along. Thirty a
## second is smooth enough for a knob and cheap enough that a window full of
## them costs nothing; the widgets themselves do nothing when they are not on
## screen.
signal automation_tick()

## The marked stretch of the arrangement changed, or went away.
signal mark_changed()
const AUTO_TICK := 1.0 / 30.0
var _auto_clock := 0.0
var _was_playing := false


## Built from the fields rather than from the dictionary as written: a plugin
## reference that has been through a saved file comes back with its keys in
## whatever order the file had them, and two spellings of the same reference
## must not be two different controls.
static func auto_key(target: int, ref: Dictionary, a: int, b: int) -> String:
	if target == Cd.AutoTarget.PLUGIN:
		return "0|%s|%d|%d|%d|%d" % [String(ref.get("kind", "")), int(ref.get("index", -1)),
				int(ref.get("track", -1)), int(ref.get("slot", -1)), b]
	return "%d|%d|%d" % [target, a, b]


## Which lane is driving this control, or -1 if none is.
func automated_lane(target: int, ref: Dictionary, a: int = 0, b: int = 0) -> int:
	return int(_auto_index.get(auto_key(target, ref, a, b), -1))


## What a control stands at now, read as cheaply as it can be: this runs for
## every automated control on screen, thirty times a second.
func control_value(target: int, ref: Dictionary, a: int = 0, b: int = 0) -> float:
	match target:
		Cd.AutoTarget.PLUGIN:
			return get_plugin_param(ref, b)
		Cd.AutoTarget.MIXER_VOL:
			return float(project.mixer[a].vol) if a < project.mixer.size() else 0.0
		Cd.AutoTarget.MIXER_PAN:
			return float(project.mixer[a].pan) if a < project.mixer.size() else 0.0
		Cd.AutoTarget.CHANNEL_VOL:
			return float(project.channels[a].vol) if a < project.channels.size() else 0.0
		Cd.AutoTarget.CHANNEL_PAN:
			return float(project.channels[a].pan) if a < project.channels.size() else 0.0
		Cd.AutoTarget.TEMPO:
			return float(project.bpm)
		Cd.AutoTarget.SEND:
			if a < project.mixer.size() and b < (project.mixer[a].sends as Array).size():
				return float(project.mixer[a].sends[b].amount)
		Cd.AutoTarget.SAMPLE_VOL:
			return float(sample_settings(a).get("gain", 1.0))
		Cd.AutoTarget.SAMPLE_PAN:
			return float(sample_settings(a).get("pan", 0.0))
		Cd.AutoTarget.SAMPLE_PITCH:
			return float(sample_live(a).pitch)
		Cd.AutoTarget.SAMPLE_SPEED:
			return float(sample_live(a).speed)
	return 0.0


func _rebuild_auto_index() -> void:
	_auto_index.clear()
	for i in project.automations.size():
		# Every control the lane drives, not only the first: all of them are
		# being held by it and all of them should say so.
		for link in automation_links(i):
			_auto_index[auto_key(int(link.target), link.get("ref", {}), int(link.a),
					int(link.b))] = i


## Everything one lane drives: the control it was made for, and anything since
## linked to it. The first entry is the lane's own target, kept in the lane
## itself so a project written before links existed still reads.
func automation_links(index: int) -> Array:
	if index < 0 or index >= project.automations.size():
		return []
	var au: Dictionary = project.automations[index]
	var out := [{"target": int(au.get("target", Cd.AutoTarget.PLUGIN)), "ref": au.get("ref", {}),
			"a": int(au.get("a", 0)), "b": int(au.get("b", 0)),
			"base": float(au.get("base", 0.0))}]
	for link in au.get("links", []):
		out.append(link)
	return out


## Another control on the same lane: one shape, one clip, several things
## moving together.
func add_automation_link(index: int, target: int, ref: Dictionary, a: int, b: int) -> bool:
	if index < 0 or index >= project.automations.size():
		return false
	var key := auto_key(target, ref, a, b)
	for link in automation_links(index):
		if auto_key(int(link.target), link.get("ref", {}), int(link.a), int(link.b)) == key:
			status.emit("That control is already on this lane")
			return false
	snapshot("Link automation")
	var au: Dictionary = project.automations[index]
	if not au.has("links"):
		au["links"] = []
	au["links"].append({"target": target, "ref": ref.duplicate(), "a": a, "b": b,
			"base": control_value(target, ref, a, b)})
	project.dirty = true
	push_automation()
	_emit(automation_changed)
	return true


## Takes one off. The lane's own target is entry zero and stays: a lane has to
## drive something, and a lane driving nothing is a lane to delete.
func remove_automation_link(index: int, which: int) -> void:
	if index < 0 or index >= project.automations.size() or which < 1:
		return
	var au: Dictionary = project.automations[index]
	var links: Array = au.get("links", [])
	if which - 1 >= links.size():
		return
	snapshot("Unlink automation")
	links.remove_at(which - 1)
	project.dirty = true
	push_automation()
	_emit(automation_changed)


func push_automation() -> void:
	_rebuild_auto_index()
	var e = engine()
	for i in project.automations.size():
		var a: Dictionary = project.automations[i]
		var target := int(a.get("target", Cd.AutoTarget.PLUGIN))
		var pa := int(a.get("a", 0))
		var pb := int(a.get("b", 0))
		if target == Cd.AutoTarget.PLUGIN:
			pa = handle_for(a.get("ref", {}))
		var pts := PackedFloat32Array()
		for p in a.get("points", []):
			pts.append_array([float(p.beat), float(p.value), float(p.get("curve", 0.0))])
		# Every control the lane drives, as target, a, b and the value that
		# control was set to by hand -- which an additive lane rides on top of.
		var flat := PackedFloat32Array()
		for link in automation_links(i):
			var lt := int(link.target)
			var la := int(link.a)
			if lt == Cd.AutoTarget.PLUGIN:
				la = handle_for(link.get("ref", {}))
			flat.append_array([float(lt), float(la), float(int(link.b)), float(link.get("base", 0.0))])
		e.set_automation_links(i, flat, pts, int(a.get("mode", Cd.AutoMode.FORCED)),
				bool(a.get("on", true)))


## Resolves a plugin reference -- {"kind":"channel","index":i} or
## {"kind":"insert","track":t,"slot":s} -- to a live engine handle.
func handle_for(ref: Dictionary) -> int:
	if ref.is_empty():
		return -1
	if String(ref.get("kind", "")) == "channel":
		var i := int(ref.get("index", -1))
		return int(channel_handles[i]) if i >= 0 and i < channel_handles.size() else -1
	if String(ref.get("kind", "")) == "insert":
		return int(insert_handles.get("%d:%d" % [int(ref.get("track", 0)), int(ref.get("slot", 0))], -1))
	return -1


func plugin_for(ref: Dictionary) -> Variant:
	if String(ref.get("kind", "")) == "channel":
		var i := int(ref.get("index", -1))
		if i >= 0 and i < project.channels.size():
			return project.channels[i].plugin
	elif String(ref.get("kind", "")) == "insert":
		var t := int(ref.get("track", 0))
		var s := int(ref.get("slot", 0))
		if t >= 0 and t < project.mixer.size():
			return project.mixer[t].inserts[s]
	return null


# ---------------------------------------------------------------------------
# Editing — transport
# ---------------------------------------------------------------------------
func set_bpm(v: float) -> void:
	project.bpm = clampf(v, 20.0, 400.0)
	project.dirty = true
	engine().set_bpm(project.bpm)
	note_tweak(Cd.AutoTarget.TEMPO, {}, 0, 0)
	_emit(title_changed)


func set_time_sig(num: int, den: int) -> void:
	project.sig_num = clampi(num, 1, 16)
	project.sig_den = clampi(den, 1, 32)
	project.dirty = true
	engine().set_time_sig(project.sig_num, project.sig_den)
	# Where the bar lines fall, in every view that draws them.
	_emit(playlist_changed)
	_emit(patterns_changed)
	_emit(title_changed)


## The resolution MIDI files are written at. Nothing in the editor is measured
## in ticks, so this only ever reaches an exported file -- but it is the song's,
## not the machine's, which is why it is kept in the project.
func set_ppq(value: int) -> void:
	project.ppq = clampi(value, 24, 960)
	project.dirty = true
	_emit(title_changed)


var loop_enabled := true


func set_mode(mode: int) -> void:
	engine().set_mode(mode)
	if mode == Cd.Mode.SONG:
		_push_loop()
	Audio.transport_changed.emit()


## Off means the song plays once and stops at the end instead of wrapping.
func set_loop_enabled(on: bool) -> void:
	loop_enabled = on
	_push_loop()


# ---------------------------------------------------------------------------
# The marked stretch of the arrangement
# ---------------------------------------------------------------------------
## Whether a stretch of the arrangement is marked out.
func has_mark() -> bool:
	return project.mark_b > project.mark_a + 0.0001


## The marked stretch, or the whole song when nothing is marked.
func mark_span() -> Vector2:
	if has_mark():
		return Vector2(project.mark_a, project.mark_b)
	return Vector2(0.0, maxf(4.0, project.length_beats()))


## Marks a stretch out. Given the two ends in either order, since it is drawn
## by dragging and dragging goes both ways.
func set_mark(a: float, b: float) -> void:
	var lo := maxf(0.0, minf(a, b))
	var hi := maxf(0.0, maxf(a, b))
	if hi - lo < 0.0001:
		clear_mark()
		return
	project.mark_a = lo
	project.mark_b = hi
	project.dirty = true
	_push_loop()
	mark_changed.emit()


func clear_mark() -> void:
	if not has_mark():
		return
	project.mark_a = 0.0
	project.mark_b = 0.0
	project.dirty = true
	_push_loop()
	mark_changed.emit()


## What the transport loops over: the marked stretch if there is one, the whole
## song if there is not.
func _push_loop() -> void:
	var span := mark_span()
	engine().set_loop(span.x, maxf(span.x + 0.25, span.y), loop_enabled)


## A pattern plus its notes, selected and ready to edit — the fast way to build
## a variation of something that already works.
func duplicate_pattern(index: int) -> int:
	return clone_pattern(index)


func mode() -> int:
	return engine().get_mode()


## What painting on the timeline puts down: FL picks up whatever was last
## clicked -- a pattern, a sample, an automation clip -- and draws that, so
## placing a second copy of something never means going to find it again.
## Along with what to draw, how the one you picked up was set: its length, how
## far into the file it starts, its level and its pitch. Drawing after clicking
## a clip gives you that clip again, not a default one.
var paint_item := {"kind": "pattern", "index": 0, "props": {}}


func set_paint_item(kind: String, index: int, props: Dictionary = {}) -> void:
	var same := String(paint_item.get("kind", "")) == kind \
			and int(paint_item.get("index", -1)) == index
	if same and paint_item.get("props", {}) == props:
		return
	paint_item = {"kind": kind, "index": index, "props": props.duplicate()}
	paint_item_changed.emit(kind, index)


## The same thing, checked: what was picked up may since have been deleted, and
## a pattern is what the timeline falls back to.
func current_paint_item() -> Dictionary:
	var kind := String(paint_item.get("kind", "pattern"))
	var index := int(paint_item.get("index", 0))
	var counts := {"pattern": project.patterns.size(), "sample": project.assets.size(),
			"automation": project.automations.size()}
	if not counts.has(kind) or index < 0 or index >= int(counts[kind]):
		return {"kind": "pattern", "index": current_pattern, "props": {}}
	return {"kind": kind, "index": index, "props": paint_item.get("props", {})}


## Puts one of the song's own things on the timeline at its natural length.
## Everywhere that places a clip from a name rather than from a drag comes
## through here -- the picker, the playlist's brush -- so they cannot disagree
## about how long a sample is or what a clip is called.
func place_item(kind: String, index: int, track: int, beat: float,
		props: Dictionary = {}) -> int:
	var length := 0.0
	var extra := {}
	match kind:
		"pattern":
			if index < 0 or index >= project.patterns.size():
				return -1
			length = float(project.patterns[index].length)
		"sample":
			if index < 0 or index >= project.assets.size():
				return -1
			# As long as the sample sounds for, which is shorter than the
			# sample when it is being played faster than it was recorded.
			length = asset_length_beats_by_index(index) / sample_rate_mul(index)
			extra["name"] = String(project.assets[index].get("name", "audio"))
		"automation":
			if index < 0 or index >= project.automations.size():
				return -1
			length = maxf(4.0, project.length_beats())
		_:
			return -1
	# How the one that was picked up was set. Its position is not part of it --
	# that is where you are putting it.
	for key in props.keys():
		if key == "length":
			length = maxf(0.0625, float(props[key]))
		elif key not in ["start", "track", "type", "index"]:
			extra[key] = props[key]
	return add_clip(CLIP_OF.get(kind, Cd.ClipType.PATTERN), index, track, beat, length, extra)


## What each of the picker's kinds is on the timeline.
const CLIP_OF := {"pattern": Cd.ClipType.PATTERN, "sample": Cd.ClipType.AUDIO,
		"automation": Cd.ClipType.AUTOMATION}


func select_pattern(index: int) -> void:
	if index < 0 or index >= project.patterns.size():
		return
	current_pattern = index
	selected_notes.clear()
	set_paint_item("pattern", index)
	engine().set_current_pattern(index)
	pattern_selected.emit(index)
	_emit(selection_changed)


func select_channel(index: int) -> void:
	if index < 0 or index >= project.channels.size():
		return
	current_channel = index
	_emit(selection_changed)


func select_mixer(track: int) -> void:
	current_mixer = clampi(track, 0, project.mixer.size() - 1)
	_emit(selection_changed)


func snap_beats() -> float:
	return float(Cd.SNAPS.get(snap, 0.25))


func set_snap(s: String) -> void:
	snap = s
	Settings.set_value("snap", s)
	_emit(selection_changed)


# ---------------------------------------------------------------------------
# Editing — channels
# ---------------------------------------------------------------------------
func add_channel(plug: Dictionary, name: String = "") -> int:
	snapshot("Add channel")
	var n := name
	if n.is_empty():
		n = String(plug.get("name", "Channel"))
	var idx := project.add_channel(n, plug)
	sync_all()
	_emit(channels_changed)
	select_channel(idx)
	return idx


func add_stock_channel(id: String) -> int:
	var d := Plugins.stock_by_id(id)
	var plug := CdProject.plugin_dict("stock", id, "", String(d.get("name", id)))
	return add_channel(plug, String(d.get("name", id)))


func add_vst3_channel(entry: Dictionary) -> int:
	var plug := CdProject.plugin_dict("vst3", String(entry.cid), String(entry.path), String(entry.name))
	return add_channel(plug, String(entry.name))


func remove_channel(index: int) -> void:
	if index < 0 or index >= project.channels.size():
		return
	snapshot("Remove channel")
	project.remove_channel(index)
	if index < channel_handles.size():
		_destroy_plugin(int(channel_handles[index]))
		channel_handles.remove_at(index)
	current_channel = clampi(current_channel, 0, maxi(0, project.channels.size() - 1))
	sync_all()
	_emit(channels_changed)
	_emit(patterns_changed)


func move_channel(from: int, to: int) -> void:
	if from == to or from < 0 or to < 0 or from >= project.channels.size() or to >= project.channels.size():
		return
	snapshot("Reorder channels")
	var c = project.channels[from]
	project.channels.remove_at(from)
	project.channels.insert(to, c)
	var h = channel_handles[from]
	channel_handles.remove_at(from)
	channel_handles.insert(to, h)
	var remap := func(ch: int) -> int:
		if ch == from:
			return to
		if from < to and ch > from and ch <= to:
			return ch - 1
		if from > to and ch >= to and ch < from:
			return ch + 1
		return ch
	for p in project.patterns:
		for n in p.notes:
			n.ch = remap.call(int(n.ch))
	for chan in project.channels:
		for l in chan.get("layers", []):
			l["channel"] = remap.call(int(l.get("channel", -1)))
	current_channel = to
	sync_all()
	_emit(channels_changed)
	_emit(patterns_changed)


## The layers a channel drives. Each entry is {channel, transpose, gain}.
func set_channel_layers(index: int, layers: Array, layer_only: bool) -> void:
	if index < 0 or index >= project.channels.size():
		return
	snapshot("Change layers")
	project.channels[index]["layers"] = layers.duplicate(true)
	project.channels[index]["layer_only"] = layer_only
	project.dirty = true
	push_channels()
	_emit(channels_changed)


func channel_layers(index: int) -> Array:
	if index < 0 or index >= project.channels.size():
		return []
	return project.channels[index].get("layers", [])


## Everything a muted clip was playing stops now, rather than ringing on until
## its note-off would have arrived. That is what "muting only takes effect when
## the note ends" was.
func silence_clip(index: int) -> void:
	if index < 0 or index >= project.clips.size():
		return
	var c: Dictionary = project.clips[index]
	if int(c.type) != Cd.ClipType.PATTERN:
		return
	var pi := int(c.index)
	if pi < 0 or pi >= project.patterns.size():
		return
	var done := {}
	for n in project.patterns[pi].notes:
		var ch := int(n.ch)
		if done.has(ch):
			continue
		done[ch] = true
		engine().stop_channel(ch)


func silence_track(track: int) -> void:
	for i in project.clips.size():
		if int(project.clips[i].track) == track:
			silence_clip(i)


func set_channel_prop(index: int, key: String, value, undo_label: String = "") -> void:
	if index < 0 or index >= project.channels.size():
		return
	if not undo_label.is_empty():
		snapshot(undo_label)
	project.channels[index][key] = value
	project.dirty = true
	if key == "vol" or key == "pan":
		note_tweak(Cd.AutoTarget.CHANNEL_VOL if key == "vol" else Cd.AutoTarget.CHANNEL_PAN,
				{}, index, 0)
	var c: Dictionary = project.channels[index]
	if key == "name":
		engine().set_channel_name(index, String(value))
	else:
		engine().set_channel(index, float(c.vol), float(c.pan), bool(c.mute), bool(c.solo),
				int(c.mixer), int(c.transpose))
		if key == "mute" and bool(value):
			engine().stop_channel(index)
	_emit(channels_changed)


func replace_channel_plugin(index: int, plug: Dictionary) -> void:
	if index < 0 or index >= project.channels.size():
		return
	snapshot("Change instrument")
	project.channels[index].plugin = plug
	if String(project.channels[index].name).is_empty():
		project.channels[index].name = String(plug.get("name", "Channel"))
	sync_all()
	_emit(channels_changed)


# ---------------------------------------------------------------------------
# Editing — patterns and notes
# ---------------------------------------------------------------------------
func add_pattern(name: String = "") -> int:
	snapshot("Add pattern")
	var i := project.add_pattern(name)
	push_pattern(i)
	_emit(patterns_changed)
	select_pattern(i)
	return i


func clone_pattern(index: int) -> int:
	if index < 0 or index >= project.patterns.size():
		return -1
	snapshot("Clone pattern")
	var src: Dictionary = project.patterns[index]
	var copy := src.duplicate(true)
	copy.name = String(src.name) + " copy"
	copy.color = project.patterns.size()
	project.patterns.append(copy)
	push_pattern(project.patterns.size() - 1)
	_emit(patterns_changed)
	select_pattern(project.patterns.size() - 1)
	return project.patterns.size() - 1


func remove_pattern(index: int) -> void:
	if project.patterns.size() <= 1 or index < 0 or index >= project.patterns.size():
		return
	snapshot("Remove pattern")
	project.patterns.remove_at(index)
	var keep := []
	for c in project.clips:
		if int(c.type) == Cd.ClipType.PATTERN:
			if int(c.index) == index:
				continue
			if int(c.index) > index:
				c.index = int(c.index) - 1
		keep.append(c)
	project.clips = keep
	current_pattern = clampi(current_pattern, 0, project.patterns.size() - 1)
	push_patterns()
	push_playlist()
	_emit(patterns_changed)
	_emit(playlist_changed)


func set_pattern_prop(index: int, key: String, value, undo_label := "") -> void:
	if index < 0 or index >= project.patterns.size():
		return
	if not undo_label.is_empty():
		snapshot(undo_label)
	project.patterns[index][key] = value
	project.dirty = true
	push_pattern(index)
	_emit(patterns_changed)


func add_note(pattern: int, channel: int, beat: float, length: float, key: int, vel: float) -> int:
	if pattern < 0 or pattern >= project.patterns.size():
		return -1
	var notes: Array = project.patterns[pattern].notes
	notes.append({
		"ch": channel, "beat": maxf(0.0, beat), "len": maxf(0.03125, length),
		"key": clampi(key, 0, 127), "vel": clampf(vel, 0.0, 1.0),
		# Per-note expression, edited in the piano roll's control lane.
		"pan": 0.0, "fine": 0.0,
	})
	project.dirty = true
	push_pattern(pattern)
	_emit(patterns_changed)
	return notes.size() - 1


func remove_notes(pattern: int, indices: Array) -> void:
	if pattern < 0 or pattern >= project.patterns.size():
		return
	var notes: Array = project.patterns[pattern].notes
	var sorted := indices.duplicate()
	sorted.sort()
	sorted.reverse()
	for i in sorted:
		if i >= 0 and i < notes.size():
			notes.remove_at(i)
	project.dirty = true
	push_pattern(pattern)
	_emit(patterns_changed)


func update_note(pattern: int, index: int, fields: Dictionary) -> void:
	if pattern < 0 or pattern >= project.patterns.size():
		return
	var notes: Array = project.patterns[pattern].notes
	if index < 0 or index >= notes.size():
		return
	for k in fields.keys():
		notes[index][k] = fields[k]
	project.dirty = true
	push_pattern(pattern)


func note_edit_done(pattern: int) -> void:
	push_pattern(pattern)
	_emit(patterns_changed)


## The channel rack's step grid: one sixteenth per step, on the pattern's own
## channel row, using the channel's root key.
func toggle_step(pattern: int, channel: int, step: int) -> void:
	if pattern < 0 or pattern >= project.patterns.size():
		return
	var beat := float(step) * Cd.STEP
	var notes: Array = project.patterns[pattern].notes
	var root := int(project.channels[channel].get("root", 60)) if channel < project.channels.size() else 60
	for i in notes.size():
		var n: Dictionary = notes[i]
		if int(n.ch) == channel and absf(float(n.beat) - beat) < 0.001:
			snapshot("Clear step")
			notes.remove_at(i)
			push_pattern(pattern)
			_emit(patterns_changed)
			return
	snapshot("Set step")
	add_note(pattern, channel, beat, Cd.STEP, root, float(Settings.get_value("velocity", 0.78)))


func step_state(pattern: int, channel: int, step: int) -> Dictionary:
	if pattern < 0 or pattern >= project.patterns.size():
		return {}
	var beat := float(step) * Cd.STEP
	for n in project.patterns[pattern].notes:
		if int(n.ch) == channel and absf(float(n.beat) - beat) < 0.001:
			return n
	return {}


## Every live note goes through here, so arming record is the only difference
## between auditioning and writing.
##
## The channel a note started on is remembered rather than looked up again when
## it stops. Selecting another channel while a key is held used to send the
## note-off to the newly selected one, and the first channel then droned until
## the next panic -- the same for the octave buttons, for anything that moves
## focus, and for a plugin window opening over the top.
##
## `source` names who is holding the note down -- the typing keyboard, a mouse
## on some keyboard widget, a piano-roll drag -- so one of them can let go of
## everything it owns without touching the others.
func live_note_on(key: int, vel: float, source: String = "kbd") -> void:
	if project.channels.is_empty():
		return
	var id := "%s|%d" % [source, key]
	if _live.has(id):
		live_note_off(key, source)
	_live[id] = current_channel
	engine().note_on(current_channel, key, vel)
	if recording and engine().is_playing():
		_rec_open[id] = _record_beat()


func live_note_off(key: int, source: String = "kbd") -> void:
	if project.channels.is_empty():
		return
	var id := "%s|%d" % [source, key]
	# An unknown note is still stopped: better a redundant note-off than one
	# that never arrives because the bookkeeping got out of step.
	var ch: int = int(_live.get(id, current_channel))
	_live.erase(id)
	engine().note_off(ch, key)
	if not _rec_open.has(id):
		return
	var start: float = _rec_open[id]
	_rec_open.erase(id)
	var length: float = maxf(snap_beats() if snap_beats() > 0.0 else 0.125, _record_beat() - start)
	add_note(current_pattern, ch, start, length, key,
			float(Settings.get_value("velocity", 0.78)))
	status.emit("Recorded %s" % Cd.note_name(key))


## Releases everything one source is holding. Widgets call this when they lose
## the mouse, and the typing keyboard when the window goes away.
func live_source_off(source: String) -> void:
	var prefix := source + "|"
	for id in _live.keys():
		if String(id).begins_with(prefix):
			live_note_off(int(String(id).substr(prefix.length())), source)


func live_notes_held() -> int:
	return _live.size()


## The last resort, and what the panic command runs: let go of every live note
## and tell the engine to silence whatever is left over from the sequencer too.
func live_all_off() -> void:
	for id in _live.keys():
		var parts := String(id).rsplit("|", true, 1)
		if parts.size() == 2:
			live_note_off(int(parts[1]), parts[0])
	_live.clear()
	_rec_open.clear()
	if engine() != null:
		engine().panic()


func _record_beat() -> float:
	var beat: float = engine().get_position()
	if mode() == Cd.Mode.PATTERN:
		beat = fmod(beat, maxf(0.25, float(project.patterns[current_pattern].length)))
	var s := snap_beats()
	return Cd.snap_beat(beat, s) if s > 0.0 else beat


func set_recording(on: bool) -> void:
	recording = on
	_rec_open.clear()
	if on:
		snapshot("Record")
	# Arming record with a strip listening to the machine's input means a take
	# as well as notes: the moment the transport rolls, what comes in is kept.
	# Armed mid-song, it starts from here rather than waiting for the next pass.
	if on:
		start_take()
	elif engine() != null and engine().record_armed():
		finish_take()
	var voice := input_track() >= 0
	if on:
		status.emit("Recording armed - press play%s" % (
				", and whatever comes into %s is kept" % _track_name(input_track())
				if voice else " and play notes while the transport runs"))
	else:
		status.emit("Recording off")


# ---------------------------------------------------------------------------
# The machine's own audio input
# ---------------------------------------------------------------------------
## Which mixer strip is listening to the input, or -1 for none. One at a time:
## there is one input device, and a voice can only be in one place at once.
func input_track() -> int:
	for t in project.mixer.size():
		if bool(project.mixer[t].get("input", false)):
			return t
	return -1


func _track_name(t: int) -> String:
	if t < 0 or t >= project.mixer.size():
		return "nothing"
	return String(project.mixer[t].get("name", "Insert %d" % t))


## Points the input at one strip, or takes it off the one that has it. The
## microphone is only held open while a strip is actually listening.
func set_input_track(track: int, on: bool) -> void:
	var was := input_track()
	if on and track == was:
		return
	if not on and track != was:
		return
	for t in project.mixer.size():
		project.mixer[t]["input"] = on and t == track
	project.dirty = true
	if not on and engine() != null and engine().record_armed():
		finish_take()
	push_input()
	var want := input_track()
	if on and want < 0:
		status.emit("No audio input: %s" % Audio.input_problem)
		mixer_changed.emit()
		return
	mixer_changed.emit()
	if want >= 0:
		status.emit("%s is listening to the input -- mute it to stop hearing yourself"
				% _track_name(want))
	else:
		status.emit("Input off")


## What the engine should be doing with the input, from what the project says:
## the device open only while a strip is listening, and the engine pointed at
## that strip. Called on load and whenever the arming moves.
func push_input() -> void:
	var e = engine()
	if e == null:
		return
	var want := input_track()
	if want >= 0 and not Audio.input_on:
		if not Audio.set_input_enabled(true):
			for t in project.mixer.size():
				project.mixer[t]["input"] = false
			want = -1
	elif want < 0 and Audio.input_on:
		Audio.set_input_enabled(false)
	e.set_input(want, float(Settings.get_value("input_gain", 1.0)))


## Begins a take, if one is wanted: record armed, a strip listening, and the
## transport rolling. Called when the transport starts.
func start_take() -> void:
	var e = engine()
	if e == null or not recording or input_track() < 0 or e.record_armed():
		return
	if not e.is_playing():
		return
	e.clear_take()
	e.arm_record(true)
	status.emit("Recording %s" % _track_name(input_track()))


## Ends one: the audio goes to a file, the file becomes one of the project's
## samples, and the sample goes on the timeline where it was played.
func finish_take() -> void:
	var e = engine()
	if e == null or not e.record_armed():
		return
	var track := input_track()
	var beat: float = e.take_start_beat()
	e.arm_record(false)
	e.pump_take()
	var secs: float = e.take_seconds()
	if secs < 0.1:
		e.clear_take()
		return
	var dir := ProjectSettings.globalize_path(Audio.CACHE_DIR)
	DirAccess.make_dir_recursive_absolute(dir)
	var stamp := Time.get_datetime_string_from_system(false, true).replace(":", "-")
	var path := dir.path_join("take_%s.wav" % stamp)
	if not e.write_take(path, 24):
		e.clear_take()
		status.emit("The take could not be written to %s" % dir)
		return
	e.clear_take()
	# One step to take back, and one rebuild of the panels rather than three.
	begin_batch("Record audio")
	var index := add_audio_asset(path)
	if index < 0:
		end_batch()
		return
	project.assets[index]["name"] = "Take %s" % stamp
	# A take plays back through the strip it was recorded on, so whatever was
	# on that strip while it was sung is still on it when it is played.
	if track > 0:
		set_sample_setting(index, "mixer", track)
	var length := asset_length_beats_by_index(index)
	var lane := _free_lane(beat, length)
	add_clip(Cd.ClipType.AUDIO, index, lane, beat, length,
			{"name": String(project.assets[index]["name"])})
	end_batch()
	sample_changed.emit(index)
	status.emit("Recorded %.1f s onto %s" % [secs, String(project.tracks[lane].get("name", "a track"))])


## A playlist track with nothing on it over the stretch a take needs, so a
## second pass does not land on top of the first.
func _free_lane(beat: float, length: float) -> int:
	for t in project.tracks.size():
		var clear := true
		for c in project.clips:
			if int(c.track) != t:
				continue
			if float(c.start) < beat + length and beat < float(c.start) + float(c.length):
				clear = false
				break
		if clear:
			return t
	return 0


# ---------------------------------------------------------------------------
# Clipboard
# ---------------------------------------------------------------------------
func copy_notes(indices: Array) -> int:
	clipboard_notes.clear()
	var notes := project.pattern_notes(current_pattern)
	var first := INF
	for i in indices:
		if int(i) < 0 or int(i) >= notes.size():
			continue
		first = minf(first, float(notes[int(i)].beat))
	for i in indices:
		if int(i) < 0 or int(i) >= notes.size():
			continue
		var n: Dictionary = (notes[int(i)] as Dictionary).duplicate()
		n["beat"] = float(n.beat) - first        # stored relative to the earliest
		clipboard_notes.append(n)
	return clipboard_notes.size()


func cut_notes(indices: Array) -> void:
	if indices.is_empty():
		return
	snapshot("Cut notes")
	copy_notes(indices)
	remove_notes(current_pattern, indices)
	selected_notes.clear()


## Pastes onto the current channel at `beat`, and selects what landed so it can
## be moved straight away.
func paste_notes(beat: float) -> Array:
	if clipboard_notes.is_empty():
		return []
	snapshot("Paste notes")
	var added := []
	for n in clipboard_notes:
		added.append(add_note(current_pattern, current_channel, beat + float(n.beat),
				float(n.len), int(n.key), float(n.vel)))
	selected_notes = added
	note_edit_done(current_pattern)
	return added


## Pulls note starts onto the snap grid. Strength 1 is dead on the grid, lower
## keeps some of the original feel.
## Whole patterns up or down. Every note in them moves by the same number of
## semitones, so a part written in one key is playable in another without being
## drawn again -- and since it is the pattern that moves, every clip of it in
## the arrangement moves with it.
##
## Notes that would fall off either end of the keyboard stay where they are
## rather than piling up on the last key, which is what silently ruins a part
## that gets transposed too far and then back again.
func transpose_patterns(indices: Array, semis: int) -> int:
	if indices.is_empty() or semis == 0:
		return 0
	snapshot("Transpose %+d" % semis)
	var moved := 0
	for p in indices:
		var pi := int(p)
		if pi < 0 or pi >= project.patterns.size():
			continue
		for n in project.patterns[pi].notes:
			var want := int(n.key) + semis
			if want < 0 or want > 127:
				continue
			n["key"] = want
			moved += 1
		push_pattern(pi)
	project.dirty = true
	_emit(patterns_changed)
	_emit(selection_changed)
	return moved


## Which patterns the arrangement's selection is of -- what "transpose the
## patterns I picked" means when the picking was done with clips.
func selected_pattern_indices() -> Array:
	var out := []
	for i in selected_clips:
		var ci := int(i)
		if ci < 0 or ci >= project.clips.size():
			continue
		var c: Dictionary = project.clips[ci]
		if int(c.type) == Cd.ClipType.PATTERN and not out.has(int(c.index)):
			out.append(int(c.index))
	if out.is_empty() and current_pattern < project.patterns.size():
		out.append(current_pattern)
	return out


func quantize_notes(indices: Array, strength: float = 1.0, lengths: bool = false) -> int:
	var snap_v := snap_beats()
	if snap_v <= 0.0 or indices.is_empty():
		return 0
	snapshot("Quantize")
	var notes := project.pattern_notes(current_pattern)
	var n_done := 0
	for i in indices:
		var idx := int(i)
		if idx < 0 or idx >= notes.size():
			continue
		var n: Dictionary = notes[idx]
		var want := Cd.snap_beat(float(n.beat), snap_v)
		var fields := {"beat": lerpf(float(n.beat), want, clampf(strength, 0.0, 1.0))}
		if lengths:
			fields["len"] = maxf(snap_v, Cd.snap_beat(float(n.len), snap_v))
		update_note(current_pattern, idx, fields)
		n_done += 1
	note_edit_done(current_pattern)
	return n_done


## A copy of the selection placed immediately after it, on the same channels.
## The copy ends up selected, so pressing it again keeps extending the run.
func duplicate_notes(indices: Array) -> int:
	if indices.is_empty():
		return 0
	var notes := project.pattern_notes(current_pattern)
	var first := INF
	var last := -INF
	for i in indices:
		var idx := int(i)
		if idx < 0 or idx >= notes.size():
			continue
		first = minf(first, float(notes[idx].beat))
		last = maxf(last, float(notes[idx].beat) + float(notes[idx].len))
	if not is_finite(first):
		return 0
	# Round the shift up to the grid so a duplicate lands in time rather than
	# butted against a ragged ending.
	var span := maxf(snap_beats(), Cd.snap_beat(last - first, maxf(snap_beats(), 0.25)))
	snapshot("Duplicate notes")
	var added := []
	for i in indices:
		var idx2 := int(i)
		if idx2 < 0 or idx2 >= notes.size():
			continue
		var n: Dictionary = notes[idx2]
		added.append(add_note(current_pattern, int(n.ch), float(n.beat) + span,
				float(n.len), int(n.key), float(n.vel)))
	selected_notes = added
	note_edit_done(current_pattern)
	return added.size()


func duplicate_clips(indices: Array) -> int:
	if indices.is_empty():
		return 0
	var first := INF
	var last := -INF
	for i in indices:
		var idx := int(i)
		if idx < 0 or idx >= project.clips.size():
			continue
		first = minf(first, float(project.clips[idx].start))
		last = maxf(last, float(project.clips[idx].start) + float(project.clips[idx].length))
	if not is_finite(first):
		return 0
	var span := maxf(0.25, last - first)
	snapshot("Duplicate clips")
	var added := []
	for i in indices:
		var idx2 := int(i)
		if idx2 < 0 or idx2 >= project.clips.size():
			continue
		var c: Dictionary = (project.clips[idx2] as Dictionary).duplicate(true)
		c["start"] = float(c.start) + span
		added.append(add_clip(int(c.type), int(c.index), int(c.track),
				float(c.start), float(c.length), c))
	selected_clips = added
	clip_edit_done()
	return added.size()


func copy_clips(indices: Array) -> int:
	clipboard_clips.clear()
	var first := INF
	for i in indices:
		if int(i) >= 0 and int(i) < project.clips.size():
			first = minf(first, float(project.clips[int(i)].start))
	for i in indices:
		if int(i) < 0 or int(i) >= project.clips.size():
			continue
		var c: Dictionary = (project.clips[int(i)] as Dictionary).duplicate()
		c["start"] = float(c.start) - first
		clipboard_clips.append(c)
	return clipboard_clips.size()


func cut_clips(indices: Array) -> void:
	if indices.is_empty():
		return
	copy_clips(indices)
	remove_clips(indices)


func paste_clips(beat: float, track_offset: int = 0) -> Array:
	if clipboard_clips.is_empty():
		return []
	snapshot("Paste clips")
	var added := []
	for c in clipboard_clips:
		var copy: Dictionary = (c as Dictionary).duplicate()
		copy["start"] = beat + float(c.start)
		copy["track"] = clampi(int(c.track) + track_offset, 0, project.tracks.size() - 1)
		added.append(add_clip(int(copy.type), int(copy.index), int(copy.track),
				float(copy.start), float(copy.length), copy))
	selected_clips = added
	clip_edit_done()
	return added


# ---------------------------------------------------------------------------
# Editing — playlist
# ---------------------------------------------------------------------------
func add_clip(type: int, index: int, track: int, start: float, length: float, extra := {}) -> int:
	snapshot("Add clip")
	var clip := {
		"type": type, "index": index, "track": track, "start": maxf(0.0, start),
		"length": maxf(0.25, length), "offset": 0.0, "gain": 1.0, "mute": false, "pitch": 0.0,
	}
	for k in extra.keys():
		clip[k] = extra[k]
	project.clips.append(clip)
	project.dirty = true
	push_playlist()
	_emit(playlist_changed)
	return project.clips.size() - 1


## `undoable` off for a gesture that takes its own snapshot once and then keeps
## deleting -- rubbing clips out with the right button held is one undo step,
## not one per clip that went under the pointer.
func remove_clips(indices: Array, undoable := true) -> void:
	if indices.is_empty():
		return
	if undoable:
		snapshot("Remove clips")
	var sorted := indices.duplicate()
	sorted.sort()
	sorted.reverse()
	for i in sorted:
		if i >= 0 and i < project.clips.size():
			project.clips.remove_at(i)
	selected_clips.clear()
	project.dirty = true
	push_playlist()
	_emit(playlist_changed)


func update_clip(index: int, fields: Dictionary) -> void:
	if index < 0 or index >= project.clips.size():
		return
	for k in fields.keys():
		project.clips[index][k] = fields[k]
	project.dirty = true
	push_playlist()


func clip_edit_done() -> void:
	push_playlist()
	_emit(playlist_changed)


func add_audio_asset(path: String) -> int:
	var wav := Audio.to_engine_wav(path)
	if wav.is_empty():
		status.emit("Could not read %s" % path.get_file())
		return -1
	for i in project.assets.size():
		if String(project.assets[i].path) == path:
			return i
	# Every sample in the project carries its own sampler settings, the way FL
	# gives an audio clip a channel of its own.
	project.assets.append({"path": path, "wav": wav, "name": path.get_file(),
			"sampler": default_sample_settings()})
	var index := project.assets.size() - 1
	# The project's numbering is the one clips are written in terms of, so the
	# engine is told which slot rather than asked for one. A clip pointing at
	# the wrong audio is not a small fault.
	engine().set_audio(index, wav)
	engine().set_sample_settings(index, sample_settings(index))
	project.dirty = true
	return index


## The whole file's length in beats, for an asset already registered. Used to
## work out which part of a file a clip is showing.
## How long a loaded asset is, in beats. Asked of the engine, which is holding
## the samples: the drawing code calls this for every audio clip on every frame,
## and the path through ffprobe made a timeline with a few long files on it run
## at sixteen frames a second.
## What a freshly added sample is set to: nothing done to it at all.
func default_sample_settings() -> Dictionary:
	return {"gain": 1.0, "pan": 0.0, "pitch": 0.0, "stretch": 1.0, "mode": 0,
		"normalize": false, "reverse": false, "remove_dc": false, "polarity": false,
		"swap_stereo": false, "fade_stereo": false, "start": 0.0, "length": 1.0,
		"fade_in": 0.0, "fade_out": 0.0, "trim_db": -100.0, "mixer": -1}


## The channel that plays one of the project's samples, made if it is not there
## yet. This is what FL calls an audio clip channel: a sample you can put on the
## timeline is also a sample you can play from the piano roll.
func channel_for_asset(index: int) -> int:
	if index < 0 or index >= project.assets.size():
		return current_channel
	for i in project.channels.size():
		if int(project.channels[i].get("asset", -1)) == index:
			return i
	var a: Dictionary = project.assets[index]
	var plug := CdProject.plugin_dict("stock", "cd.sampler", "", String(a.get("name", "Sample")))
	plug["strings"]["sample"] = String(a.get("wav", a.get("path", "")))
	var i := add_channel(plug, String(a.get("name", "Sample")))
	project.channels[i]["asset"] = index
	channels_changed.emit()
	return i


## The same clips, a different file. Everything the sample is set to stays put.
func replace_asset(index: int, path: String) -> bool:
	if index < 0 or index >= project.assets.size():
		return false
	var wav := Audio.to_engine_wav(path)
	if wav.is_empty():
		status.emit("Could not read %s" % path.get_file())
		return false
	snapshot("Replace sample")
	var was := asset_length_beats_by_index(index)
	var a: Dictionary = project.assets[index]
	a["path"] = path
	a["wav"] = wav
	a["name"] = path.get_file()
	project.dirty = true
	# Straight into the slot it already occupies, then told what it is set to.
	# This used to register by path and hope the engine gave the same number
	# back, with a reload as the fallback when it did not.
	engine().set_audio(index, wav)
	engine().set_sample_settings(index, sample_settings(index))
	_refit_clips(index, was)
	push_playlist()
	playlist_changed.emit()
	sample_changed.emit(index)
	return true


## The sampler settings of one of the project's samples.
func sample_settings(index: int) -> Dictionary:
	if index < 0 or index >= project.assets.size():
		return default_sample_settings()
	var a: Dictionary = project.assets[index]
	if not a.has("sampler"):
		a["sampler"] = default_sample_settings()
	return a["sampler"]


## What a sample is being played at right now, as opposed to what is worked
## into the audio: semitones up or down and a speed multiplier, both the way a
## record does it. These are the two that can be automated, because they are
## the two that can change while the sample is sounding.
func sample_live(index: int) -> Dictionary:
	if index < 0 or index >= project.assets.size():
		return {"pitch": 0.0, "speed": 1.0}
	var a: Dictionary = project.assets[index]
	if not a.has("live"):
		a["live"] = {"pitch": 0.0, "speed": 1.0}
	return a["live"]


func set_sample_live(index: int, key: String, value: float) -> void:
	if index < 0 or index >= project.assets.size():
		return
	var live: Dictionary = sample_live(index)
	live[key] = value
	project.dirty = true
	engine().set_sample_live(index, float(live.pitch), float(live.speed))
	note_tweak(Cd.AutoTarget.SAMPLE_PITCH if key == "pitch" else Cd.AutoTarget.SAMPLE_SPEED,
			{}, index, 0)


## Changes one of them and has the engine work the sample out again. The clips
## that play it are re-measured: a stretched or trimmed sample is a different
## length, and a clip drawn to the old one would run off the end of it.
func set_sample_setting(index: int, key: String, value, undo_label: String = "") -> void:
	if index < 0 or index >= project.assets.size():
		return
	if not undo_label.is_empty():
		snapshot(undo_label)
	# How long it was, so the clips that were as long as the sample can stay
	# that way: stretching a sample and leaving its clips the old length would
	# play half of it, or leave a gap after it.
	var was := asset_length_beats_by_index(index)
	var s: Dictionary = sample_settings(index)
	s[key] = value
	project.dirty = true
	engine().set_sample_settings(index, s)
	_refit_clips(index, was)
	push_playlist()
	playlist_changed.emit()
	sample_changed.emit(index)


## Stretching a sample stretches its clips on the timeline by the same amount.
## Twice as long a sample is twice as long a clip, and a clip that played the
## second half of it still plays the second half -- so what you hear is what
## the arrangement shows, rather than a clip running off the end of its own
## audio or leaving a gap after it.
func _refit_clips(index: int, was: float) -> void:
	var now := asset_length_beats_by_index(index)
	if now <= 0.0 or was <= 0.0 or absf(now - was) < 0.0001:
		return
	var scale := now / was
	for c in project.clips:
		if int(c.type) != Cd.ClipType.AUDIO or int(c.index) != index:
			continue
		c["length"] = maxf(0.0625, float(c.length) * scale)
		if float(c.get("offset", 0.0)) > 0.0:
			c["offset"] = float(c.offset) * scale


## Every sample the project uses, into the engine, with its settings. A project
## that has just been loaded has a list of samples and an engine that has never
## heard of them; registering by path is idempotent, so this is also what keeps
## the two in step on every later sync.
func push_samples() -> void:
	var e = engine()
	if e == null:
		return
	for i in project.assets.size():
		var a: Dictionary = project.assets[i]
		var wav := String(a.get("wav", ""))
		if wav.is_empty() or not FileAccess.file_exists(wav):
			# The decoded copy lives in a cache folder on the machine that made
			# it, so a project from elsewhere never has one. Go back to the
			# original, wherever that is here.
			var src := find_file(String(a.get("path", "")))
			if src.is_empty():
				wav = ""
			else:
				wav = Audio.to_engine_wav(src)
				if src != String(a.get("path", "")):
					_relocated.append(src.get_file())
			a["wav"] = wav
		# Into the slot the project says, rather than wherever the engine would
		# have put it. A clip points at a sample by number, so a sample that is
		# missing -- or one that happens to be the same file as another -- must
		# not renumber the rest: the clips would then play the wrong audio.
		e.set_audio(i, wav)
		if wav.is_empty():
			_missing.append("%s (sample)" % String(a.get("name", a.get("path", "?"))).get_file())
		e.set_sample_settings(i, sample_settings(i))
		var live: Dictionary = sample_live(i)
		e.set_sample_live(i, float(live.pitch), float(live.speed))


func asset_length_beats_by_index(index: int) -> float:
	if index < 0 or index >= project.assets.size():
		return 0.0
	var secs := float(engine().asset_seconds(index))
	if secs > 0.0:
		return maxf(0.25, secs * project.bpm / 60.0)
	return asset_length_beats(String(project.assets[index].get("path", "")))


func asset_length_beats(path: String) -> float:
	var info := Audio.audio_info(path)
	var secs := float(info.get("duration", 0.0))
	return maxf(0.25, secs * project.bpm / 60.0)


## How fast a sample is being played right now, as a multiplier: the pitch and
## speed an automation lane can move, the way a record does it. What the
## stretching modes do is worked into the audio itself and is already counted
## in how long the sample is.
func sample_rate_mul(index: int) -> float:
	var live: Dictionary = sample_live(index)
	return pow(2.0, float(live.pitch) / 12.0) * maxf(0.02, float(live.speed))


## The same for one clip, with the clip's own pitch on top: beats of the file
## per beat of the arrangement. A clip read twice as fast gets through twice as
## much of its sample in the same stretch of the timeline, and the waveform
## drawn on it has to say so -- otherwise the picture stretches to fill the
## clip while the sound stops half way along it.
func clip_rate(c: Dictionary) -> float:
	return sample_rate_mul(int(c.get("index", -1))) \
			* pow(2.0, float(c.get("pitch", 0.0)) / 12.0)


## How much of a clip actually has audio under it, in beats from its start: the
## whole clip, or as far as the sample reaches at the rate it is being read.
## `total` is how long the whole sample is in beats, for callers that have
## already asked -- the timeline asks for every clip it draws, every frame.
func clip_sounded_beats(c: Dictionary, total: float = -1.0) -> float:
	if total < 0.0:
		total = asset_length_beats_by_index(int(c.get("index", -1)))
	if total <= 0.0:
		return 0.0
	var left: float = maxf(0.0, total - float(c.get("offset", 0.0)))
	return clampf(left / maxf(0.0001, clip_rate(c)), 0.0, float(c.get("length", 0.0)))


# ---------------------------------------------------------------------------
# Editing — mixer
# ---------------------------------------------------------------------------
func set_mixer_prop(track: int, key: String, value, undo_label := "") -> void:
	if track < 0 or track >= project.mixer.size():
		return
	if not undo_label.is_empty():
		snapshot(undo_label)
	project.mixer[track][key] = value
	project.dirty = true
	if key == "vol" or key == "pan":
		note_tweak(Cd.AutoTarget.MIXER_VOL if key == "vol" else Cd.AutoTarget.MIXER_PAN,
				{}, track, 0)
	var m: Dictionary = project.mixer[track]
	if key == "name":
		engine().set_mixer_name(track, String(value))
	else:
		engine().set_mixer(track, float(m.vol), float(m.pan), bool(m.mute), bool(m.solo), int(m.route))
	_emit(mixer_changed)


func set_send(track: int, index: int, dest: int, amount: float, pre: bool, sidechain: bool) -> void:
	if track < 0 or track >= project.mixer.size() or index < 0:
		return
	var all: Array = project.mixer[track].sends
	while index >= all.size():
		all.append({"dest": -1, "amount": 0.0, "pre": false, "sidechain": false})
	var s: Dictionary = project.mixer[track].sends[index]
	s.dest = dest
	s.amount = amount
	s.pre = pre
	s.sidechain = sidechain
	project.dirty = true
	engine().set_send(track, index, dest, amount, pre, sidechain)
	note_tweak(Cd.AutoTarget.SEND, {}, track, index)
	_emit(mixer_changed)


## Every track feeding this one's sidechain input -- what a compressor's
## external detector and a vocoder's modulator are actually reading.
func sidechain_sources(dest: int) -> Array:
	var out := []
	for t in project.mixer.size():
		for snd in project.mixer[t].sends:
			if int(snd.dest) == dest and bool(snd.get("sidechain", false)) \
					and float(snd.amount) > 0.0001:
				out.append(t)
				break
	return out


## Makes `from` feed `to`'s sidechain, reusing whatever send already points
## that way and taking the first free one otherwise. Pre-fader on purpose: a
## modulator is usually a track you have muted so you hear the vocoder rather
## than the voice, and a post-fader send from a muted track carries nothing.
func set_sidechain(from: int, to: int, on: bool = true) -> bool:
	if from < 0 or to < 0 or from >= project.mixer.size() or to >= project.mixer.size():
		return false
	if from == to:
		status.emit("A strip cannot feed its own sidechain")
		return false
	var sends: Array = project.mixer[from].sends
	for i in sends.size():
		var snd: Dictionary = sends[i]
		if int(snd.dest) == to and bool(snd.get("sidechain", false)):
			set_send(from, i, to if on else -1, 1.0 if on else 0.0, true, on)
			return true
	if not on:
		return false
	for i in sends.size():
		if int(sends[i].dest) < 0:
			set_send(from, i, to, 1.0, true, true)
			return true
	sends.append({"dest": -1, "amount": 0.0, "pre": false, "sidechain": false})
	set_send(from, sends.size() - 1, to, 1.0, true, true)
	return true


## Everything a voice needs to reach a vocoder in one go: a strip listening to
## the machine's input, muted so you do not hear yourself twice, feeding this
## one's sidechain. Returns the strip the input landed on.
func wire_input_to(dest: int) -> int:
	var track := input_track()
	if track < 0 and _free_strip(dest) < 0:
		status.emit("No free mixer track to put the input on")
		return -1
	snapshot("Voice in")
	if track < 0:
		# A strip that is not carrying anything, so arming it costs nothing.
		track = _free_strip(dest)
		if String(project.mixer[track].name) == "Insert %d" % track:
			project.mixer[track]["name"] = "Voice"
			engine().set_mixer_name(track, "Voice")
		set_input_track(track, true)
		if input_track() != track:
			return -1
	# Muted, because what should be heard is the vocoder and not the voice.
	set_mixer_prop(track, "mute", true)
	set_sidechain(track, dest, true)
	status.emit("%s is listening to your input and feeding the vocoder on %s"
			% [_track_name(track), _track_name(dest)])
	return track


## A mixer track with nothing on it: no channels, no clips, no effects, and not
## the one asking.
func _free_strip(besides: int) -> int:
	var used := {}
	for c in project.channels:
		used[int(c.mixer)] = true
	for a in project.assets:
		var m := int((a.get("sampler", {}) as Dictionary).get("mixer", -1))
		if m >= 0:
			used[m] = true
	for t in range(1, project.mixer.size()):
		if t == besides or used.has(t):
			continue
		var busy := false
		for p in project.mixer[t].inserts:
			if p != null:
				busy = true
		for snd in project.mixer[t].sends:
			if int(snd.dest) >= 0:
				busy = true
		if not busy:
			return t
	return -1


## Another row in the arrangement. Twelve is where a new song starts, not where
## it has to stay.
func add_track(name: String = "") -> int:
	snapshot("Add track")
	var i := project.tracks.size()
	project.tracks.append({"name": name if not name.is_empty() else "Track %d" % (i + 1),
			"height": 46.0, "mute": false, "color": i})
	project.dirty = true
	_emit(playlist_changed)
	return i


## A row, and everything on it. Only ever from the end, so the clips that stay
## keep the rows they were on.
func remove_track(index: int = -1) -> bool:
	if project.tracks.size() <= 1:
		status.emit("The last track cannot go")
		return false
	var last := project.tracks.size() - 1
	if index >= 0 and index != last:
		status.emit("Only the last track can be removed")
		return false
	var doomed := []
	for i in project.clips.size():
		if int(project.clips[i].track) == last:
			doomed.append(i)
	snapshot("Remove track")
	if not doomed.is_empty():
		remove_clips(doomed)
	project.tracks.remove_at(last)
	project.dirty = true
	push_playlist()
	_emit(playlist_changed)
	return true


## One more strip on the end. There is no ceiling: how many a song wants is
## the song's business, and the engine sizes itself to what it is given.
func add_mixer_track(name: String = "") -> int:
	snapshot("Add mixer track")
	var i := project.mixer.size()
	var m: Dictionary = project.new_mixer_track(i)
	if not name.is_empty():
		m["name"] = name
	project.mixer.append(m)
	project.dirty = true
	sync_all()
	_emit(mixer_changed)
	return i


## Only ever the last one, and only when nothing is using it: everything else
## in the song refers to tracks by number, and renumbering them behind a song's
## back is how a mix quietly comes apart.
func remove_mixer_track() -> bool:
	var last := project.mixer.size() - 1
	if last <= 0:
		status.emit("The master is the only track left")
		return false
	for c in project.channels:
		if int(c.mixer) == last:
			status.emit("%s is still playing into %s" % [String(c.name),
					String(project.mixer[last].name)])
			return false
	for t in project.mixer.size():
		if t == last:
			continue
		var m: Dictionary = project.mixer[t]
		if int(m.route) == last:
			status.emit("%s is still routed into it" % String(m.name))
			return false
		for snd in m.sends:
			if int(snd.dest) == last and float(snd.amount) > 0.0:
				status.emit("%s still sends to it" % String(m.name))
				return false
	if not (project.mixer[last].inserts as Array).all(func(x): return x == null):
		status.emit("%s still has effects on it" % String(project.mixer[last].name))
		return false
	snapshot("Remove mixer track")
	project.mixer.remove_at(last)
	current_mixer = clampi(current_mixer, 0, project.mixer.size() - 1)
	project.dirty = true
	sync_all()
	_emit(mixer_changed)
	return true


## Everywhere this track's audio goes: its main output first, then anything it
## sends to. This is what the routing lines under the mixer draw.
func routes_of(track: int) -> Array:
	if track < 0 or track >= project.mixer.size():
		return []
	var out := []
	var m: Dictionary = project.mixer[track]
	if int(m.route) >= 0:
		out.append(int(m.route))
	for snd in m.sends:
		if int(snd.dest) >= 0 and float(snd.amount) > 0.0 and not out.has(int(snd.dest)):
			out.append(int(snd.dest))
	return out


## Turns a route from one track into another on or off, the way clicking the
## socket under a strip does in FL. The first destination a track gets is its
## main output; the ones after that are sends.
func set_route(from: int, to: int, on: bool) -> void:
	if from <= 0 or from >= project.mixer.size() or to < 0 or to >= project.mixer.size():
		return
	if from == to:
		return
	var m: Dictionary = project.mixer[from]
	var sends: Array = m.sends
	if on:
		if int(m.route) == to:
			return
		for snd in sends:
			if int(snd.dest) == to and float(snd.amount) > 0.0:
				return
		snapshot("Route")
		if int(m.route) < 0:
			m["route"] = to
		else:
			var free := -1
			for i in sends.size():
				if int(sends[i].dest) < 0 or float(sends[i].amount) <= 0.0:
					free = i
					break
			if free < 0:
				sends.append({"dest": -1, "amount": 0.0, "pre": false, "sidechain": false})
				free = sends.size() - 1
			sends[free] = {"dest": to, "amount": 0.8, "pre": false, "sidechain": false}
	else:
		snapshot("Route")
		if int(m.route) == to:
			m["route"] = -1
		for i in sends.size():
			if int(sends[i].dest) == to:
				sends[i] = {"dest": -1, "amount": 0.0, "pre": false, "sidechain": false}
	project.dirty = true
	push_mixer()
	_emit(mixer_changed)


func set_insert(track: int, slot: int, plug) -> void:
	if track < 0 or track >= project.mixer.size():
		return
	snapshot("Insert effect" if plug != null else "Remove effect")
	project.mixer[track].inserts[slot] = plug
	project.dirty = true
	sync_all()
	_emit(mixer_changed)


## Taking an effect out closes the gap behind it, so the chain stays a stack
## with nothing to step over.
func remove_insert(track: int, slot: int) -> void:
	if track < 0 or track >= project.mixer.size():
		return
	var inserts: Array = project.mixer[track].inserts
	if slot < 0 or slot >= inserts.size() or inserts[slot] == null:
		return
	snapshot("Remove effect")
	inserts.remove_at(slot)
	inserts.append(null)
	_shift_insert_handles(track, slot)
	project.dirty = true
	sync_all()
	_emit(mixer_changed)


## Handles are keyed by slot, so closing the gap in the chain has to move them
## down with the plugins. Without this every plugin below the one removed is
## destroyed and loaded again -- for a big sampler, seconds of work to change
## nothing about it.
func _shift_insert_handles(track: int, from_slot: int) -> void:
	var n: int = (project.mixer[track].inserts as Array).size()
	_destroy_plugin(int(insert_handles.get("%d:%d" % [track, from_slot], -1)))
	for s in range(from_slot, n):
		var key := "%d:%d" % [track, s]
		var next_key := "%d:%d" % [track, s + 1]
		if s + 1 < n and insert_handles.has(next_key):
			insert_handles[key] = insert_handles[next_key]
			insert_handles.erase(next_key)
		else:
			insert_handles.erase(key)


## Copies an effect, its settings and its plugin state, to the first free slot
## on another strip.
func copy_insert(track: int, slot: int, dest: int) -> void:
	if track < 0 or track >= project.mixer.size() or dest < 0 or dest >= project.mixer.size():
		return
	var plug = project.mixer[track].inserts[slot]
	if plug == null:
		return
	_capture_one(handle_for({"kind": "insert", "track": track, "slot": slot}), plug, true)
	var target: Array = project.mixer[dest].inserts
	var free := -1
	for i in target.size():
		if target[i] == null:
			free = i
			break
	if free < 0:
		status.emit("%s has no free effect slot" % String(project.mixer[dest].name))
		return
	snapshot("Copy effect")
	target[free] = plug.duplicate(true)
	project.dirty = true
	sync_all()
	_emit(mixer_changed)
	status.emit("Copied %s to %s" % [String(plug.get("name", "effect")), String(project.mixer[dest].name)])


func clear_inserts(track: int) -> void:
	if track < 0 or track >= project.mixer.size():
		return
	snapshot("Clear effects")
	var inserts: Array = project.mixer[track].inserts
	for i in inserts.size():
		inserts[i] = null
	project.dirty = true
	sync_all()
	_emit(mixer_changed)


## Undoes a mute-and-solo session in one go, on both the mixer and the channels.
func clear_mutes() -> void:
	snapshot("Clear mutes")
	for m in project.mixer:
		m["mute"] = false
		m["solo"] = false
	for c in project.channels:
		c["mute"] = false
		c["solo"] = false
	project.dirty = true
	push_mixer()
	push_channels()
	_emit(mixer_changed)
	_emit(channels_changed)


func move_insert(track: int, from: int, to: int) -> void:
	if track < 0 or track >= project.mixer.size() or from == to:
		return
	snapshot("Move effect")
	var inserts: Array = project.mixer[track].inserts
	var plug = inserts[from]
	inserts.remove_at(from)
	inserts.insert(to, plug)
	# Handles are keyed by slot, so they have to move with the plugins.
	var moved := {}
	for s in inserts.size():
		moved["%d:%d" % [track, s]] = null
	var keys := []
	for key in insert_handles.keys():
		if String(key).begins_with("%d:" % track):
			keys.append(key)
	var handles := []
	keys.sort()
	for key in keys:
		handles.append(insert_handles[key])
		insert_handles.erase(key)
	if from < handles.size():
		var h = handles[from]
		handles.remove_at(from)
		handles.insert(mini(to, handles.size()), h)
	for s in handles.size():
		insert_handles["%d:%d" % [track, s]] = handles[s]
	push_mixer()
	_emit(mixer_changed)


func set_insert_flag(track: int, slot: int, key: String, value) -> void:
	var plug = project.mixer[track].inserts[slot]
	if plug == null:
		return
	plug[key] = value
	project.dirty = true
	engine().set_insert_flags(track, slot, bool(plug.get("bypass", false)), float(plug.get("wet", 1.0)))
	_emit(mixer_changed)


# ---------------------------------------------------------------------------
# Editing — plugin parameters
# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# Last tweaked
# ---------------------------------------------------------------------------
## How many moved controls are remembered. One is what the toolbar holds; the
## rest are what "make automation clips for the last few things I touched" is
## made of.
const TWEAK_MEMORY := 8
## Newest first. Each entry is {target, ref, a, b, key} -- the same shape
## add_automation takes, so a clip can be made from one without asking
## anything else.
var last_tweaked: Array = []


## Records that a control moved. Deliberately cheap: no name, no range and no
## descriptor lookup, because this runs for every frame of a knob being
## dragged. What it is called is worked out later, in tweak_describe().
func note_tweak(target: int, ref: Dictionary, a: int, b: int) -> void:
	var key := "%d|%s|%d|%d|%d|%d" % [target, String(ref.get("kind", "")),
			int(ref.get("index", -1)), int(ref.get("track", -1)), int(ref.get("slot", -1)), b]
	if not last_tweaked.is_empty() and String(last_tweaked[0].get("key", "")) == key:
		# Already the one being held: no list surgery, but the toolbar still
		# wants to follow the value while the knob is being dragged.
		tweaked.emit(last_tweaked[0])
		return
	for i in last_tweaked.size():
		if String(last_tweaked[i].get("key", "")) == key:
			last_tweaked.remove_at(i)
			break
	last_tweaked.push_front({"target": target, "ref": ref.duplicate(), "a": a, "b": b, "key": key})
	while last_tweaked.size() > TWEAK_MEMORY:
		last_tweaked.pop_back()
	tweaked.emit(last_tweaked[0])


## What a remembered control is called, what it ranges over and where it is
## now. Empty if it has gone away -- the plugin was removed, the strip deleted.
func tweak_describe(entry: Dictionary) -> Dictionary:
	var target := int(entry.get("target", Cd.AutoTarget.PLUGIN))
	var a := int(entry.get("a", 0))
	var b := int(entry.get("b", 0))
	var ref: Dictionary = entry.get("ref", {})
	match target:
		Cd.AutoTarget.PLUGIN:
			var h := handle_for(ref)
			if h < 0:
				return {}
			var p: Dictionary = engine().plugin_param(h, b)
			if p.is_empty():
				return {}
			var plug = plugin_for(ref)
			var owner := String(plug.get("name", "Plugin")) if plug != null else "Plugin"
			return {"name": "%s: %s" % [owner, String(p.name)], "short": String(p.name),
					"owner": owner, "lo": float(p.min), "hi": float(p.max),
					"default": float(p.get("default", 0.0)), "kind": int(p.kind),
					"choices": String(p.choices), "skew": float(p.get("skew", 1.0)),
					"value": get_plugin_param(ref, b)}
		Cd.AutoTarget.MIXER_VOL, Cd.AutoTarget.MIXER_PAN:
			if a < 0 or a >= project.mixer.size():
				return {}
			var vol := target == Cd.AutoTarget.MIXER_VOL
			var m: Dictionary = project.mixer[a]
			return {"name": "%s: %s" % [String(m.name), "Volume" if vol else "Pan"],
					"short": "Volume" if vol else "Pan", "owner": String(m.name),
					"lo": 0.0 if vol else -1.0, "hi": 1.0, "default": 0.8 if vol else 0.0,
					"kind": Cd.ParamKind.GAIN if vol else Cd.ParamKind.PCT, "choices": "",
					"skew": 1.0, "value": float(m.vol if vol else m.pan)}
		Cd.AutoTarget.CHANNEL_VOL, Cd.AutoTarget.CHANNEL_PAN:
			if a < 0 or a >= project.channels.size():
				return {}
			var cvol := target == Cd.AutoTarget.CHANNEL_VOL
			var c: Dictionary = project.channels[a]
			return {"name": "%s: %s" % [String(c.name), "Volume" if cvol else "Pan"],
					"short": "Volume" if cvol else "Pan", "owner": String(c.name),
					"lo": 0.0 if cvol else -1.0, "hi": 1.0, "default": 0.8 if cvol else 0.0,
					"kind": Cd.ParamKind.GAIN if cvol else Cd.ParamKind.PCT, "choices": "",
					"skew": 1.0, "value": float(c.vol if cvol else c.pan)}
		Cd.AutoTarget.TEMPO:
			return {"name": "Tempo", "short": "Tempo", "owner": "Transport",
					"lo": 40.0, "hi": 240.0, "default": 120.0, "kind": Cd.ParamKind.FLOAT,
					"choices": "", "skew": 1.0, "value": float(project.bpm)}
		Cd.AutoTarget.SAMPLE_PITCH, Cd.AutoTarget.SAMPLE_SPEED:
			if a < 0 or a >= project.assets.size():
				return {}
			var is_pitch := target == Cd.AutoTarget.SAMPLE_PITCH
			var pa: Dictionary = project.assets[a]
			var plive := sample_live(a)
			return {"name": "%s: %s" % [String(pa.get("name", "sample")),
					"Pitch" if is_pitch else "Speed"],
					"short": "Pitch" if is_pitch else "Speed",
					"owner": String(pa.get("name", "sample")),
					"lo": -24.0 if is_pitch else 0.25, "hi": 24.0 if is_pitch else 4.0,
					"default": 0.0 if is_pitch else 1.0,
					"kind": Cd.ParamKind.SEMI if is_pitch else Cd.ParamKind.FLOAT,
					"choices": "", "skew": 1.0,
					"value": float(plive.pitch if is_pitch else plive.speed)}
		Cd.AutoTarget.SAMPLE_VOL, Cd.AutoTarget.SAMPLE_PAN:
			if a < 0 or a >= project.assets.size():
				return {}
			var svol := target == Cd.AutoTarget.SAMPLE_VOL
			var asset: Dictionary = project.assets[a]
			var sset := sample_settings(a)
			return {"name": "%s: %s" % [String(asset.get("name", "sample")),
					"Volume" if svol else "Pan"],
					"short": "Volume" if svol else "Pan",
					"owner": String(asset.get("name", "sample")),
					"lo": 0.0 if svol else -1.0, "hi": 2.0 if svol else 1.0,
					"default": 1.0 if svol else 0.0,
					"kind": Cd.ParamKind.PCT, "choices": "", "skew": 1.0,
					"value": float(sset.get("gain" if svol else "pan", 0.0))}
		Cd.AutoTarget.SEND:
			if a < 0 or a >= project.mixer.size() or b < 0 or b >= 4:
				return {}
			var ms: Dictionary = project.mixer[a]
			return {"name": "%s: Send %d" % [String(ms.name), b + 1], "short": "Send %d" % (b + 1),
					"owner": String(ms.name), "lo": 0.0, "hi": 1.0, "default": 0.0,
					"kind": Cd.ParamKind.PCT, "choices": "", "skew": 1.0,
					"value": float(ms.sends[b].amount)}
	return {}


## Moves a remembered control from somewhere else -- the toolbar knob.
func set_tweak_value(entry: Dictionary, v: float) -> void:
	var target := int(entry.get("target", Cd.AutoTarget.PLUGIN))
	var a := int(entry.get("a", 0))
	var b := int(entry.get("b", 0))
	match target:
		Cd.AutoTarget.PLUGIN:
			set_plugin_param(entry.get("ref", {}), b, v)
		Cd.AutoTarget.MIXER_VOL:
			set_mixer_prop(a, "vol", v)
		Cd.AutoTarget.MIXER_PAN:
			set_mixer_prop(a, "pan", v)
		Cd.AutoTarget.CHANNEL_VOL:
			set_channel_prop(a, "vol", v)
		Cd.AutoTarget.CHANNEL_PAN:
			set_channel_prop(a, "pan", v)
		Cd.AutoTarget.TEMPO:
			set_bpm(v)
		Cd.AutoTarget.SAMPLE_PITCH:
			set_sample_live(a, "pitch", v)
		Cd.AutoTarget.SAMPLE_SPEED:
			set_sample_live(a, "speed", v)
		Cd.AutoTarget.SAMPLE_VOL:
			set_sample_setting(a, "gain", v)
		Cd.AutoTarget.SAMPLE_PAN:
			set_sample_setting(a, "pan", v)
		Cd.AutoTarget.SEND:
			if a < project.mixer.size() and b < 4:
				var snd: Dictionary = project.mixer[a].sends[b]
				set_send(a, b, int(snd.dest), v, bool(snd.get("pre", false)),
						bool(snd.get("sidechain", false)))


## An automation lane and a clip on the timeline for a remembered control, at
## its current value. Returns the automation index, or -1 if the control has
## gone.
func automation_from_tweak(entry: Dictionary, track: int = 0) -> int:
	var d := tweak_describe(entry)
	if d.is_empty():
		return -1
	var idx := add_automation(String(d.name), int(entry.get("target", 0)), entry.get("ref", {}),
			int(entry.get("a", 0)), int(entry.get("b", 0)), float(d.lo), float(d.hi))
	add_clip(Cd.ClipType.AUTOMATION, idx, track, 0.0, maxf(4.0, project.length_beats()))
	return idx


## An automation clip for a control, put somewhere it can be seen: the first
## playlist track with nothing at the start of the song, or a new one if every
## track is busy. Right-clicking a fader should not mean hunting for the lane
## afterwards.
func automate(target: int, ref: Dictionary, a: int = 0, b: int = 0) -> int:
	var entry := {"target": target, "ref": ref, "a": a, "b": b}
	var span: float = maxf(4.0, project.length_beats())
	var track := -1
	for t in project.tracks.size():
		var busy := false
		for c in project.clips:
			if int(c.track) == t and float(c.start) < span:
				busy = true
				break
		if not busy:
			track = t
			break
	if track < 0:
		add_track()
		track = project.tracks.size() - 1
	var idx := automation_from_tweak(entry, track)
	if idx >= 0:
		var d := tweak_describe(entry)
		status.emit("Automating %s" % String(d.get("name", "control")))
	return idx


func set_plugin_param(ref: Dictionary, index: int, value: float) -> void:
	var h := handle_for(ref)
	var plug = plugin_for(ref)
	if h < 0 or plug == null:
		return
	engine().plugin_set_param(h, index, value)
	note_tweak(Cd.AutoTarget.PLUGIN, ref, 0, index)
	plug["params"][str(index)] = value
	if _applied.has(h):
		_applied[h]["params"][index] = value
	touch_plugin(h)
	project.dirty = true


func get_plugin_param(ref: Dictionary, index: int) -> float:
	var h := handle_for(ref)
	return float(engine().plugin_get_param(h, index)) if h >= 0 else 0.0


## Decodes a picture and hands it to Prism as bands x columns of brightness,
## plus a left/right balance per cell taken from the colour. Godot has the image
## readers; the engine does not, and should not.
func _reload_plugin_image(handle: int, path: String, bands: int = 128, cols: int = 256) -> void:
	var data := _image_data(path, bands, cols)
	if not data.is_empty():
		engine().plugin_set_data(handle, "image", data)


## The picture as bands x columns of brightness, then the same many left/right
## balances. Empty if the file will not read.
func _image_data(path: String, bands: int, cols: int) -> PackedFloat32Array:
	var img := Image.new()
	if img.load(path) != OK:
		return PackedFloat32Array()
	img.resize(maxi(8, cols), maxi(8, bands), Image.INTERPOLATE_LANCZOS)
	var w := img.get_width()
	var h := img.get_height()
	var data := PackedFloat32Array()
	data.resize(3 + w * h * 2)
	data[0] = float(w)
	data[1] = float(h)
	data[2] = 1.0
	for y in h:
		# The top row of the picture is the highest partial, the way a
		# spectrogram is drawn.
		var band := h - 1 - y
		for x in w:
			var c := img.get_pixel(x, y)
			data[3 + band * w + x] = clampf(c.r * 0.3 + c.g * 0.59 + c.b * 0.11, 0.0, 1.0)
			var span: float = maxf(0.0001, c.r + c.b)
			data[3 + w * h + band * w + x] = clampf((c.b - c.r) / span, -1.0, 1.0)
	return data


func load_plugin_image(ref: Dictionary, path: String, bands: int = 128, cols: int = 256) -> bool:
	var data := _image_data(path, bands, cols)
	if data.is_empty():
		status.emit("Could not read %s" % path.get_file())
		return false
	var h_idx := handle_for(ref)
	if h_idx < 0 or not engine().plugin_set_data(h_idx, "image", data):
		return false
	set_plugin_string(ref, "image", path)
	status.emit("Prism is playing %s, %d bands across %d columns" % [
			path.get_file(), int(data[1]), int(data[0])])
	return true


func set_plugin_string(ref: Dictionary, key: String, value: String) -> bool:
	var h := handle_for(ref)
	var plug = plugin_for(ref)
	if h < 0 or plug == null:
		return false
	var ok: bool = engine().plugin_set_string(h, key, value)
	if ok:
		# A stock plugin is created without one of these -- only the hosted and
		# sample-playing paths used to set a string at all, and both made it on
		# the way in. Anything with settings of its own reaches here now.
		if not plug.has("strings"):
			plug["strings"] = {}
		plug["strings"][key] = value
		if _applied.has(h):
			if not _applied[h].has("strings"):
				_applied[h]["strings"] = {}
			_applied[h]["strings"][key] = value
		touch_plugin(h)
		project.dirty = true
	return ok


func plugin_params(ref: Dictionary) -> Array:
	var h := handle_for(ref)
	return engine().plugin_params(h) if h >= 0 else []


func plugin_info(ref: Dictionary) -> Dictionary:
	var h := handle_for(ref)
	return engine().plugin_info(h) if h >= 0 else {}


## For the click that opens a plugin from a row or a slot: pressing it again
## puts the window away, the way every panel toggle in the program does.
func toggle_plugin_window(ref: Dictionary) -> void:
	touch_plugin(handle_for(ref))
	toggle_plugin.emit(ref)


func request_plugin_window(ref: Dictionary) -> void:
	# A window that is open is a plugin that may be about to change its own
	# state without telling anyone, so its state gets read back from now on.
	touch_plugin(handle_for(ref))
	open_plugin.emit(ref)


# ---------------------------------------------------------------------------
# Editing — automation
# ---------------------------------------------------------------------------
func add_automation(name: String, target: int, ref: Dictionary, a: int, b: int, lo: float, hi: float) -> int:
	snapshot("Add automation")
	var value := 0.0
	if target == Cd.AutoTarget.PLUGIN:
		value = get_plugin_param(ref, b)
	elif target == Cd.AutoTarget.MIXER_VOL and a < project.mixer.size():
		value = float(project.mixer[a].vol)
	project.automations.append({
		"name": name, "target": target, "ref": ref, "a": a, "b": b,
		"lo": lo, "hi": hi, "mode": Cd.AutoMode.FORCED, "on": true, "base": value,
		"points": [{"beat": 0.0, "value": value, "curve": 0.0},
				{"beat": 4.0, "value": value, "curve": 0.0}],
	})
	project.dirty = true
	push_automation()
	_emit(automation_changed)
	return project.automations.size() - 1


## Takes a lane out of the song, with the clips that played it, and renumbers
## the clips that pointed past it. Lives here rather than in the panel that
## offers it: it is a change to the project, and more than one panel offers it.
## What a lane is producing at the playhead right now, or NAN when nothing of
## it is playing. The engine writes automated values into its own copy of the
## mixer rather than into the project, so a control that wants to follow along
## asks the curve rather than the project.
func live_automation_value(lane: int) -> float:
	if lane < 0 or lane >= project.automations.size() or mode() != Cd.Mode.SONG:
		return NAN
	var beat := Audio.position()
	for c in project.clips:
		if int(c.type) != Cd.ClipType.AUTOMATION or int(c.index) != lane:
			continue
		if bool(c.get("mute", false)):
			continue
		if beat < float(c.start) or beat >= float(c.start) + float(c.length):
			continue
		return automation_value(lane, beat - float(c.start) + float(c.get("offset", 0.0)))
	return NAN


func remove_automation(index: int) -> void:
	if index < 0 or index >= project.automations.size():
		return
	snapshot("Remove automation")
	var doomed := []
	for i in project.clips.size():
		var c: Dictionary = project.clips[i]
		if int(c.type) == Cd.ClipType.AUTOMATION and int(c.index) == index:
			doomed.append(i)
	remove_clips(doomed)
	project.automations.remove_at(index)
	for c in project.clips:
		if int(c.type) == Cd.ClipType.AUTOMATION and int(c.index) > index:
			c["index"] = int(c.index) - 1
	project.dirty = true
	sync_all()
	_emit(automation_changed)
	_emit(playlist_changed)


## One of a lane's own settings: whether it is on, whether it forces the
## control or adds to it, and the range it works over.
func set_automation_prop(index: int, key: String, value, label: String = "") -> void:
	if index < 0 or index >= project.automations.size():
		return
	if not label.is_empty():
		snapshot(label)
	var au: Dictionary = project.automations[index]
	au[key] = value
	if key == "mode" and int(value) == Cd.AutoMode.ADDITIVE:
		# Whatever each control is set to now is what the curve is added to.
		au["base"] = control_value(int(au.get("target", 0)), au.get("ref", {}),
				int(au.get("a", 0)), int(au.get("b", 0)))
		for link in au.get("links", []):
			link["base"] = control_value(int(link.target), link.get("ref", {}),
					int(link.a), int(link.b))
	project.dirty = true
	push_automation()
	_emit(automation_changed)


func set_automation_points(index: int, points: Array) -> void:
	if index < 0 or index >= project.automations.size():
		return
	project.automations[index].points = points
	project.dirty = true
	push_automation()
	_emit(automation_changed)


func automation_value(index: int, beat: float) -> float:
	if index < 0 or index >= project.automations.size():
		return 0.0
	var pts: Array = project.automations[index].points
	if pts.is_empty():
		return 0.0
	if beat <= float(pts[0].beat):
		return float(pts[0].value)
	if beat >= float(pts[-1].beat):
		return float(pts[-1].value)
	for i in range(pts.size() - 1):
		var a: Dictionary = pts[i]
		var b: Dictionary = pts[i + 1]
		if beat >= float(a.beat) and beat <= float(b.beat):
			var t := (beat - float(a.beat)) / maxf(0.0001, float(b.beat) - float(a.beat))
			var curve := float(a.get("curve", 0.0))
			if curve > 0.001:
				t = pow(t, 1.0 + curve * 3.0)
			elif curve < -0.001:
				t = 1.0 - pow(1.0 - t, 1.0 - curve * 3.0)
			return lerpf(float(a.value), float(b.value), t)
	return float(pts[-1].value)
