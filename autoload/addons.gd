extends Node
## Add-ons: a folder of scripts that add things to Cadmium without being part
## of it.
##
## One folder per add-on with an addon.gd inside, either shipped with Cadmium
## (res://addons) or dropped in by hand (user://addons). Each one says what it
## is called and what it can do, and what it can do turns up in the Tools menu.
## They can be switched off in Preferences without being deleted.

signal changed()

const BUILT_IN := "res://addons"
const USER_DIR := "user://addons"

## {id, name, description, path, script, instance, enabled}
var list: Array = []


func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(USER_DIR))
	reload()


func reload() -> void:
	list.clear()
	var off: Array = Settings.get_value("addons_off", [])
	for root in [BUILT_IN, USER_DIR]:
		var d := DirAccess.open(root)
		if d == null:
			continue
		for folder in d.get_directories():
			var path := "%s/%s/addon.gd" % [root, folder]
			if not ResourceLoader.exists(path) and not FileAccess.file_exists(path):
				continue
			var scr = load(path)
			if scr == null:
				push_warning("Cadmium: %s would not load" % path)
				continue
			var inst = scr.new()
			var entry := {
				"id": folder,
				"name": String(inst.get("NAME")) if inst.get("NAME") != null else folder,
				"description": String(inst.get("DESCRIPTION")) if inst.get("DESCRIPTION") != null else "",
				"path": path,
				"built_in": root == BUILT_IN,
				"instance": inst,
				"enabled": not off.has(folder),
			}
			list.append(entry)
	changed.emit()


func set_enabled(id: String, on: bool) -> void:
	var off: Array = Settings.get_value("addons_off", [])
	off.erase(id)
	if not on:
		off.append(id)
	Settings.set_value("addons_off", off)
	for e in list:
		if String(e.id) == id:
			e.enabled = on
	changed.emit()


## Everything the enabled add-ons offer, as {addon, id, label} for a menu.
func actions() -> Array:
	var out := []
	for e in list:
		if not bool(e.enabled) or e.instance == null:
			continue
		if not (e.instance as Object).has_method("actions"):
			continue
		for a in e.instance.actions():
			out.append({"addon": String(e.id), "id": String(a.get("id", "")),
					"label": String(a.get("label", "?"))})
	return out


## Runs one of them. `main` is handed over so an add-on can reach the
## interface -- open a dialog, put something on the timeline.
func run(addon_id: String, action_id: String, main: Node) -> void:
	for e in list:
		if String(e.id) != addon_id or not bool(e.enabled) or e.instance == null:
			continue
		if (e.instance as Object).has_method("run"):
			e.instance.run(action_id, main)
		return
