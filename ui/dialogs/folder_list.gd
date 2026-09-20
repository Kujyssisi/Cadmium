extends PanelContainer
## A list of folders bound to one setting, with buttons to add and remove.
## The layout is folder_list.tscn; `bind` says which setting it edits.

var _key := ""

@onready var _list: ItemList = $Col/List
@onready var _head: Label = $Col/Head
@onready var _hint: Label = $Col/Hint


func bind(title: String, key: String, hint: String) -> void:
	_key = key
	if is_node_ready():
		_apply(title, hint)
	else:
		ready.connect(func(): _apply(title, hint), CONNECT_ONE_SHOT)


func _apply(title: String, hint: String) -> void:
	_head.text = title.to_upper()
	_hint.text = hint
	_fill()


func _ready() -> void:
	var add: Button = $Col/Row/Add
	add.icon = Icons.get_icon("folder", 14)
	add.pressed.connect(_add)
	($Col/Row/Remove as Button).pressed.connect(_remove)


func _fill() -> void:
	_list.clear()
	for d in Settings.get_value(_key, []):
		_list.add_item(String(d))


func _add() -> void:
	var fd := FileDialog.new()
	fd.file_mode = FileDialog.FILE_MODE_OPEN_DIR
	fd.access = FileDialog.ACCESS_FILESYSTEM
	# The desktop's own chooser when the platform offers one (the XDG portal on
	# Linux, the shell dialog on Windows); Godot's built-in is the fallback.
	fd.use_native_dialog = DisplayServer.has_feature(DisplayServer.FEATURE_NATIVE_DIALOG_FILE)
	fd.size = Vector2i(880, 600)
	add_child(fd)
	fd.dir_selected.connect(func(p):
		add_folder(String(p))
		fd.queue_free())
	fd.canceled.connect(func(): fd.queue_free())
	fd.popup_centered()


## Adding one, apart from the chooser that picked it -- so what the button does
## is something a test can do too.
func add_folder(path: String) -> bool:
	if path.is_empty():
		return false
	var arr: Array = Settings.get_value(_key, [])
	if arr.has(path):
		return false
	arr.append(path)
	Settings.set_value(_key, arr)
	_fill()
	Plugins.catalog_changed.emit()
	return true


func remove_folder(path: String) -> bool:
	var arr: Array = Settings.get_value(_key, [])
	if not arr.has(path):
		return false
	arr.erase(path)
	Settings.set_value(_key, arr)
	_fill()
	Plugins.catalog_changed.emit()
	return true


func folders() -> Array:
	return Settings.get_value(_key, [])


func _remove() -> void:
	var sel := _list.get_selected_items()
	if sel.is_empty():
		return
	var arr: Array = Settings.get_value(_key, [])
	remove_folder(String(arr[sel[0]]) if sel[0] < arr.size() else "")
