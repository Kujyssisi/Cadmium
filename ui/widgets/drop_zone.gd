class_name CdDropZone
extends PanelContainer
## A panel you can drop a file onto.
##
## Two kinds of drop arrive here. One is a file dragged in from the desktop,
## which the window reports; the other is an entry dragged out of Cadmium's own
## browser, which goes through the usual control drag. Both end at the same
## signal, so whatever is listening only has to know about a path.

signal dropped(path: String)

## Browser entry kinds this zone will take ("sample", "sf2", ...). Empty means
## it takes none of them and only listens for files from the desktop.
var kinds: PackedStringArray = PackedStringArray()
## Lower-case extensions, without the dot. Empty takes anything.
var extensions: PackedStringArray = PackedStringArray()

var _hot := false


func _ready() -> void:
	var w := get_window()
	if w != null and not w.files_dropped.is_connected(_on_files):
		w.files_dropped.connect(_on_files)


func accepts(path: String) -> bool:
	if extensions.is_empty():
		return true
	return path.get_extension().to_lower() in extensions


## A file from the desktop lands on whichever zone the pointer is over -- the
## window reports the drop, not the control under it, so we work that out.
func _on_files(files: PackedStringArray) -> void:
	if files.is_empty() or not is_visible_in_tree():
		return
	if not get_global_rect().has_point(get_global_mouse_position()):
		return
	for f in files:
		if accepts(f):
			dropped.emit(f)
			return
	App.status.emit("%s is not a file this takes" % String(files[0]).get_file())


func _can_drop_data(_pos: Vector2, data: Variant) -> bool:
	var ok := typeof(data) == TYPE_DICTIONARY and bool(data.get("cadmium", false)) \
			and String(data.get("kind", "")) in kinds and accepts(String(data.get("path", "")))
	if ok != _hot:
		_hot = ok
		queue_redraw()
	return ok


func _drop_data(_pos: Vector2, data: Variant) -> void:
	_hot = false
	queue_redraw()
	dropped.emit(String(data.get("path", "")))


func _notification(what: int) -> void:
	if what == NOTIFICATION_DRAG_END and _hot:
		_hot = false
		queue_redraw()


func _draw() -> void:
	if _hot:
		draw_rect(Rect2(Vector2.ZERO, size), CdPalette.ACCENT, false, 2.0)
