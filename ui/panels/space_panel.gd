extends CdDropZone
## The convolution reverb's panel: the impulse it is folding the signal into,
## and the tail that makes.

var ref := {}
var params: Array = []

@onready var _name: Label = $Col/Row/Name
@onready var _load: Button = $Col/Row/Load
@onready var _clear: Button = $Col/Row/Clear
@onready var _view: CdVerbView = $Col/View


func _ready() -> void:
	kinds = PackedStringArray(["sample"])
	extensions = PackedStringArray(Cd.AUDIO_EXTS)
	super()
	_load.icon = Icons.get_icon("open", 14)
	_load.pressed.connect(_browse)
	_clear.pressed.connect(_reset)
	dropped.connect(_use)
	_view.ref = ref
	_view.params = params
	var plug = App.plugin_for(ref)
	var path := String(plug.get("strings", {}).get("ir", "")) if plug != null else ""
	if not path.is_empty():
		_name.text = path.get_file()


## Whatever ffmpeg reads becomes the impulse; the engine only reads wav.
func _use(path: String) -> void:
	var wav := Audio.to_engine_wav(path)
	if wav.is_empty():
		App.status.emit("Could not decode %s" % path.get_file())
		return
	if not App.set_plugin_string(ref, "ir", wav):
		App.status.emit("Could not load %s" % path.get_file())
		return
	_name.text = path.get_file()
	App.status.emit("Impulse %s" % path.get_file())


func _reset() -> void:
	App.set_plugin_string(ref, "ir", "")
	_name.text = "built-in plate - drop a wav here to use your own"
	App.status.emit("Back to the built-in plate")


func _browse() -> void:
	var fd := FileDialog.new()
	fd.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	fd.access = FileDialog.ACCESS_FILESYSTEM
	fd.filters = PackedStringArray([Cd.AUDIO_FILTER])
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
