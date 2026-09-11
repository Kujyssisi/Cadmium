class_name CdPluginPicker
extends Window
## Picking an effect or an instrument: type to search, or walk the categories.
##
## Every place that used to open a long PopupMenu opens this instead, because a
## menu with sixty entries and a VST3 folder underneath is not something you can
## read quickly.

signal chosen(plugin: Dictionary)

const RECENT_KEY := "recent_plugins"
const RECENT_MAX := 12

var effects_only := true
var _entries: Array = []          ## what the list is currently showing
var _category := ""               ## "" is everything
var _favourites: Array = []


func configure(args: Dictionary) -> void:
	effects_only = bool(args.get("effects", true))


@onready var _search: LineEdit = $Root/Col/Search
@onready var _cats: ItemList = $Root/Col/Split/Categories
@onready var _list: ItemList = $Root/Col/Split/List
@onready var _detail: Label = $Root/Col/Detail


func _ready() -> void:
	title = "Add Effect" if effects_only else "Choose Instrument"
	# A window is sized in pixels but laid out in scaled units.
	var sc := Settings.ui_scale()
	content_scale_factor = sc
	size = Vector2i(int(700.0 * sc), int(520.0 * sc))
	close_requested.connect(queue_free)
	_favourites = Settings.get_value("favourite_plugins", [])

	_search.placeholder_text = "Search %s..." % ("effects" if effects_only else "instruments")
	_search.right_icon = Icons.get_icon("search", 14)
	_search.text_changed.connect(func(_t): _refill())
	_search.gui_input.connect(_search_input)

	_cats.item_selected.connect(func(i):
		_category = String(_cats.get_item_metadata(i))
		_refill())
	_list.item_activated.connect(_accept)
	_list.item_selected.connect(_show_detail)
	_list.gui_input.connect(_list_input)

	($Root/Col/Buttons/Cancel as Button).pressed.connect(queue_free)
	var add: Button = $Root/Col/Buttons/Add
	add.text = "Add" if effects_only else "Use"
	add.pressed.connect(func():
		_accept(_list.get_selected_items()[0] if not _list.get_selected_items().is_empty() else -1))

	_fill_categories()
	_refill()
	_search.grab_focus()


func _fill_categories() -> void:
	_cats.clear()
	_cats.add_item("All")
	_cats.set_item_metadata(0, "")
	if not _favourites.is_empty():
		_cats.add_item("Favourites")
		_cats.set_item_metadata(_cats.item_count - 1, "\tfav")
	var recent: Array = Settings.get_value(RECENT_KEY, [])
	if not recent.is_empty():
		_cats.add_item("Recent")
		_cats.set_item_metadata(_cats.item_count - 1, "\trecent")
	for cat in Plugins.categories(effects_only).keys():
		_cats.add_item(String(cat))
		_cats.set_item_metadata(_cats.item_count - 1, String(cat))
	_cats.select(0)


func _key_for(p: Dictionary) -> String:
	return String(p.get("cid", "")) if p.has("cid") else "stock:" + String(p.get("id", ""))


func _refill() -> void:
	var query := _search.text.strip_edges().to_lower()
	var cats := Plugins.categories(effects_only)
	_entries.clear()
	var wanted: Array = []
	if _category == "\tfav":
		for cat in cats.keys():
			for p in cats[cat]:
				if _favourites.has(_key_for(p)):
					wanted.append(p)
	elif _category == "\trecent":
		var recent: Array = Settings.get_value(RECENT_KEY, [])
		for key in recent:
			for cat in cats.keys():
				for p in cats[cat]:
					if _key_for(p) == String(key):
						wanted.append(p)
	elif _category.is_empty():
		for cat in cats.keys():
			for p in cats[cat]:
				wanted.append(p)
	else:
		for p in cats.get(_category, []):
			wanted.append(p)

	_list.clear()
	for p in wanted:
		var name := String(p.get("name", ""))
		var vendor := String(p.get("vendor", ""))
		var cat := String(p.get("category", ""))
		if not query.is_empty():
			var hay := (name + " " + vendor + " " + cat).to_lower()
			if not hay.contains(query):
				continue
		var fav := _favourites.has(_key_for(p))
		var label := ("* " if fav else "") + name
		if p.has("cid"):
			label += "   [VST3]"
		_list.add_item(label, Icons.get_icon("vst" if p.has("cid") else ("fx" if effects_only else "wave"), 14))
		_list.set_item_tooltip(_list.item_count - 1, "%s\n%s%s" % [name, cat, ("  -  " + vendor) if not vendor.is_empty() else ""])
		_entries.append(p)
	if _list.item_count > 0:
		_list.select(0)
		_show_detail(0)
	else:
		_detail.text = "Nothing matches \"%s\"" % _search.text


func _show_detail(i: int) -> void:
	if i < 0 or i >= _entries.size():
		return
	var p: Dictionary = _entries[i]
	var bits := [String(p.get("category", ""))]
	if not String(p.get("vendor", "")).is_empty():
		bits.append(String(p.get("vendor")))
	if p.has("path"):
		bits.append(String(p.path).get_file())
	_detail.text = "  -  ".join(bits)


## Typing in the search box drives the list, so the arrow keys and Enter have to
## reach it from there.
func _search_input(event: InputEvent) -> void:
	if not (event is InputEventKey) or not event.pressed:
		return
	var k := event as InputEventKey
	match k.keycode:
		KEY_DOWN, KEY_UP:
			if _list.item_count == 0:
				return
			var sel: int = _list.get_selected_items()[0] if not _list.get_selected_items().is_empty() else 0
			sel = clampi(sel + (1 if k.keycode == KEY_DOWN else -1), 0, _list.item_count - 1)
			_list.select(sel)
			_list.ensure_current_is_visible()
			_show_detail(sel)
			_search.accept_event()
		KEY_ENTER, KEY_KP_ENTER:
			if _list.item_count > 0:
				_accept(_list.get_selected_items()[0] if not _list.get_selected_items().is_empty() else 0)
			_search.accept_event()
		KEY_ESCAPE:
			queue_free()


func _list_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_RIGHT:
		var i := _list.get_item_at_position(event.position, true)
		if i < 0 or i >= _entries.size():
			return
		var key := _key_for(_entries[i])
		if _favourites.has(key):
			_favourites.erase(key)
		else:
			_favourites.append(key)
		Settings.set_value("favourite_plugins", _favourites)
		_fill_categories()
		_refill()


func _accept(i: int) -> void:
	if i < 0 or i >= _entries.size():
		return
	var p: Dictionary = _entries[i]
	var recent: Array = Settings.get_value(RECENT_KEY, [])
	var key := _key_for(p)
	recent.erase(key)
	recent.push_front(key)
	while recent.size() > RECENT_MAX:
		recent.pop_back()
	Settings.set_value(RECENT_KEY, recent)
	var plug: Dictionary
	if p.has("cid"):
		plug = CdProject.plugin_dict("vst3", String(p.cid), String(p.path), String(p.name))
	else:
		plug = CdProject.plugin_dict("stock", String(p.id), "", String(p.name))
	chosen.emit(plug)
	queue_free()


## One call from anywhere: `CdPluginPicker.open(self, true, func(p): ...)`.
static func open(host: Node, effects: bool, on_pick: Callable) -> Window:
	# One at a time: asking for it twice should bring the one that is up to the
	# front rather than stack another behind it.
	for existing in host.get_tree().root.get_children():
		if existing is CdPluginPicker and existing.effects_only == effects:
			Cd.place_window(existing, host)
			return existing
	var w = preload("res://ui/dialogs/plugin_picker.tscn").instantiate()
	w.effects_only = effects
	host.get_tree().root.add_child(w)
	w.chosen.connect(on_pick)
	# Said rather than assumed: a Window added to the tree is shown by default,
	# but one opened from a closing popup can be left behind the main window,
	# and a panel nobody can see reads as a menu entry that does nothing.
	w.show()
	Cd.place_window(w, host)
	w.grab_focus()
	return w
