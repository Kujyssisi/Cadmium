extends CdDropZone
## Prism's panel: what picture it is playing, and the picture itself.

var ref := {}
var params: Array = []

@onready var _name: Label = $Col/Row/Name
@onready var _load: Button = $Col/Row/Load
@onready var _view: CdPrismView = $Col/View


func _ready() -> void:
	kinds = PackedStringArray(["image"])
	extensions = PackedStringArray(Cd.IMAGE_EXTS)
	super()
	_load.icon = Icons.get_icon("open", 14)
	_load.pressed.connect(_browse)
	dropped.connect(_use)
	_view.ref = ref
	_view.params = params
	var plug = App.plugin_for(ref)
	var path := String(plug.get("strings", {}).get("image", "")) if plug != null else ""
	if not path.is_empty():
		_name.text = path.get_file()
		_view.set_image(path)


func _use(path: String) -> void:
	if not App.load_plugin_image(ref, path):
		App.status.emit("Could not read %s" % path.get_file())
		return
	_name.text = path.get_file()
	_view.set_image(path)
	App.status.emit("Loaded %s" % path.get_file())


func _browse() -> void:
	var fd := FileDialog.new()
	fd.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	fd.access = FileDialog.ACCESS_FILESYSTEM
	fd.filters = PackedStringArray([Cd.IMAGE_FILTER])
	fd.use_native_dialog = DisplayServer.has_feature(DisplayServer.FEATURE_NATIVE_DIALOG_FILE)
	fd.size = Vector2i(880, 600)
	add_child(fd)
	fd.file_selected.connect(func(picked):
		_use(String(picked))
		fd.queue_free())
	fd.canceled.connect(func(): fd.queue_free())
	fd.popup_centered()
