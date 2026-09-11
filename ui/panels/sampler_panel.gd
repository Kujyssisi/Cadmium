extends CdDropZone
## The sampler's panel: which file is loaded and what it looks like.

var ref := {}
var params: Array = []

@onready var _name: Label = $Col/Row/Name
@onready var _load: Button = $Col/Row/Load
@onready var _wave: CdWaveView = $Col/Wave


func _ready() -> void:
	kinds = PackedStringArray(["sample"])
	extensions = PackedStringArray(Cd.AUDIO_EXTS)
	super()
	_load.icon = Icons.get_icon("open", 14)
	_load.pressed.connect(_browse)
	dropped.connect(_use)
	_wave.ref = ref
	var plug = App.plugin_for(ref)
	var path := String(plug.get("strings", {}).get("sample", "")) if plug != null else ""
	if not path.is_empty():
		_name.text = path.get_file()


## Anything ffmpeg reads is turned into what the engine reads before it goes in.
func _use(path: String) -> void:
	var wav := Audio.to_engine_wav(path)
	if wav.is_empty():
		App.status.emit("Could not decode %s" % path.get_file())
		return
	if not App.set_plugin_string(ref, "sample", wav):
		App.status.emit("Could not load %s" % path.get_file())
		return
	_name.text = path.get_file()
	_wave.refresh()
	App.status.emit("Loaded %s" % path.get_file())


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
