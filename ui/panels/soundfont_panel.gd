extends CdDropZone
## The soundfont player's panel: the file, and the presets inside it.

var ref := {}
var params: Array = []

var _all: Array = []

@onready var _name: Label = $Col/Row/Name
@onready var _installed: MenuButton = $Col/Row/Installed
@onready var _load: Button = $Col/Row/Load
@onready var _search: LineEdit = $Col/Search
@onready var _list: ItemList = $Col/List


func _ready() -> void:
	kinds = PackedStringArray(["sf2"])
	extensions = PackedStringArray(["sf2", "sf3"])
	super()
	_load.icon = Icons.get_icon("open", 14)
	_load.pressed.connect(_browse)
	dropped.connect(_use)
	_search.text_changed.connect(func(_t): _fill())
	_list.item_selected.connect(_pick_preset)

	var fonts := Plugins.soundfonts()
	var pm := _installed.get_popup()
	for i in fonts.size():
		pm.add_item(String(fonts[i].name), i)
	if fonts.is_empty():
		pm.add_item("(none found)", -1)
	pm.id_pressed.connect(func(id):
		if id >= 0:
			_use(String(fonts[id].path)))

	var plug = App.plugin_for(ref)
	var path := String(plug.get("strings", {}).get("file", "")) if plug != null else ""
	if not path.is_empty():
		_name.text = path.get_file()
		_fill()


func _use(path: String) -> void:
	if not App.set_plugin_string(ref, "file", path):
		App.status.emit("Could not read %s" % path.get_file())
		return
	_name.text = path.get_file()
	_fill()
	App.status.emit("Loaded %s" % path.get_file())


func _pick_preset(i: int) -> void:
	var idx := int(_list.get_item_metadata(i))
	App.set_plugin_string(ref, "preset", str(idx))
	App.set_plugin_param(ref, 0, float(idx))
	App.status.emit("Preset %d" % idx)


func _fill() -> void:
	_list.clear()
	var h := App.handle_for(ref)
	if h < 0:
		return
	var text: String = App.engine().plugin_get_string(h, "presets")
	_all.clear()
	for line in text.split("\n"):
		if line.strip_edges().is_empty():
			continue
		var parts: PackedStringArray = line.split(":")
		if parts.size() < 4:
			continue
		_all.append({"index": int(parts[0]), "bank": int(parts[1]),
				"program": int(parts[2]), "name": ":".join(Array(parts).slice(3))})
	# The file's own order is arbitrary; banks and programs are what a player is
	# indexed by.
	_all.sort_custom(func(a, b):
		if int(a.bank) != int(b.bank):
			return int(a.bank) < int(b.bank)
		return int(a.program) < int(b.program))
	var filter := _search.text.to_lower()
	for p in _all:
		if not filter.is_empty() and not String(p.name).to_lower().contains(filter):
			continue
		_list.add_item("%03d:%03d  %s" % [int(p.bank), int(p.program), String(p.name)])
		_list.set_item_metadata(_list.item_count - 1, int(p.index))
	var cur := int(App.get_plugin_param(ref, 0))
	for i in _list.item_count:
		if int(_list.get_item_metadata(i)) == cur:
			_list.select(i)
			break


func _browse() -> void:
	var fd := FileDialog.new()
	fd.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	fd.access = FileDialog.ACCESS_FILESYSTEM
	fd.filters = PackedStringArray(["*.sf2, *.sf3 ; SoundFont"])
	# The desktop's own chooser when the platform offers one (the XDG portal on
	# Linux, the shell dialog on Windows); Godot's built-in is the fallback.
	fd.use_native_dialog = DisplayServer.has_feature(DisplayServer.FEATURE_NATIVE_DIALOG_FILE)
	fd.size = Vector2i(880, 600)
	add_child(fd)
	fd.file_selected.connect(func(p):
		_use(String(p))
		fd.queue_free())
	fd.canceled.connect(func(): fd.queue_free())
	fd.popup_centered()
