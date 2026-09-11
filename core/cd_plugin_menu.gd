class_name CdPluginMenu
extends RefCounted
## The plugin list as a drop-down, the way a mixer slot offers one everywhere
## else: categories as submenus, favourites and recents at the top, and the
## searchable window still one entry away for when the list is the wrong shape
## for the question.
##
## It exists because opening a whole window to put a reverb on a channel is a
## lot of ceremony for a decision that takes one click.

const RECENT_KEY := "recent_plugins"
const SEARCH_ID := -2

## Everything the menu is showing, by the id it was added under. Held on the
## popup itself so it lives exactly as long as the menu does.
static func key_for(p: Dictionary) -> String:
	return String(p.get("cid", "")) if p.has("cid") else "stock:" + String(p.get("id", ""))


## Opens the menu at the pointer. `on_pick` is handed a plugin dictionary ready
## for the project, the same shape the picker window emits.
static func open(host: Node, effects_only: bool, on_pick: Callable) -> PopupMenu:
	var pm := PopupMenu.new()
	pm.name = "PluginMenu"
	host.add_child(pm)

	var entries: Array = []
	var cats: Dictionary = Plugins.categories(effects_only)
	var favourites: Array = Settings.get_value("favourite_plugins", [])
	var recent: Array = Settings.get_value(RECENT_KEY, [])

	var by_key := {}
	for cat in cats.keys():
		for p in cats[cat]:
			by_key[key_for(p)] = p

	var section := func(title: String, items: Array) -> void:
		if items.is_empty():
			return
		pm.add_separator(title)
		for p in items:
			entries.append(p)
			pm.add_item(String(p.get("name", "?")), entries.size() - 1)

	var favs := []
	for k in favourites:
		if by_key.has(String(k)):
			favs.append(by_key[String(k)])
	section.call("Favourites", favs)

	var recents := []
	for k in recent:
		if by_key.has(String(k)) and recents.size() < 8:
			recents.append(by_key[String(k)])
	section.call("Recent", recents)

	if not favs.is_empty() or not recents.is_empty():
		pm.add_separator()

	# One submenu per category. Godot wants the child in the tree before it can
	# be named as a submenu, and the name is what links the two.
	var n := 0
	for cat in cats.keys():
		var items: Array = cats[cat]
		if items.is_empty():
			continue
		var sub := PopupMenu.new()
		sub.name = "cat%d" % n
		n += 1
		for p in items:
			entries.append(p)
			sub.add_item(String(p.get("name", "?")), entries.size() - 1)
		sub.id_pressed.connect(func(id): _pick(host, effects_only, entries, id, on_pick))
		pm.add_child(sub)
		pm.add_submenu_item(String(cat), sub.name)

	if not Plugins.problems.is_empty():
		pm.add_separator()
		pm.add_item("%d plugin%s would not load" % [Plugins.problems.size(),
				"" if Plugins.problems.size() == 1 else "s"], SEARCH_ID - 1)
		pm.set_item_disabled(pm.item_count - 1, true)

	pm.add_separator()
	pm.add_item("Search all plugins...", SEARCH_ID)
	pm.id_pressed.connect(func(id): _pick(host, effects_only, entries, id, on_pick))
	pm.popup_hide.connect(func(): pm.queue_free(), CONNECT_DEFERRED)

	var at := DisplayServer.mouse_get_position()
	pm.popup(Rect2i(at, Vector2i(0, 0)))
	return pm


static func _pick(host: Node, effects_only: bool, entries: Array, id: int, on_pick: Callable) -> void:
	if id == SEARCH_ID:
		# The long way round, for when you want to read what everything is
		# rather than already know which one you are after. Opened a moment
		# later: this runs from inside the drop-down's own signal, with the
		# popup still closing, and a window opened underneath one that is
		# going away ends up behind the main window instead of in front of it.
		# A timer rather than a one-shot on the tree's own frame signal: the
		# timer holds itself alive, so the panel opens even if whatever the
		# menu was attached to is busy being rebuilt.
		var tree := host.get_tree()
		if tree == null:
			CdPluginPicker.open(host, effects_only, on_pick)
			return
		tree.create_timer(0.0).timeout.connect(func():
			if is_instance_valid(host) and host.is_inside_tree():
				CdPluginPicker.open(host, effects_only, on_pick))
		return
	if id < 0 or id >= entries.size():
		return
	var p: Dictionary = entries[id]
	var recent: Array = Settings.get_value(RECENT_KEY, [])
	var key := key_for(p)
	recent.erase(key)
	recent.push_front(key)
	while recent.size() > 12:
		recent.pop_back()
	Settings.set_value(RECENT_KEY, recent)
	var plug: Dictionary
	if p.has("cid"):
		plug = CdProject.plugin_dict("vst3", String(p.cid), String(p.path), String(p.name))
	else:
		plug = CdProject.plugin_dict("stock", String(p.id), "", String(p.name))
	on_pick.call(plug)
