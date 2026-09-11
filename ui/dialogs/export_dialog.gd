extends Window
## Render the song (or each mixer track) to disk. The render runs on a worker
## thread so the window keeps drawing its progress.

## The formats and the encoder live in CdExport, so the export window and the
## test that checks the formats can actually be written agree by construction.
const FORMATS := CdExport.FORMATS

## The entries in the range drop-down, so the code that reads it and the code
## that fills it cannot drift apart.
const RANGE_SONG := 0
const RANGE_PATTERN := 1
const RANGE_CLIPS := 2
const RANGE_MARK := 3

var _stems := false
var _thread: Thread
var _running := false


func configure(args: Dictionary) -> void:
	_stems = bool(args.get("stems", false))


@onready var _path: LineEdit = $Root/Col/PathRow/Path
@onready var _bits: OptionButton = $Root/Col/FormatRow/Bits
@onready var _range: OptionButton = $Root/Col/RangeRow/Range
@onready var _length: Label = $Root/Col/RangeRow/Length
@onready var _tail: SpinBox = $Root/Col/TailRow/Tail
@onready var _auto_tail: CheckBox = $Root/Col/TailRow/Auto
@onready var _norm: CheckBox = $Root/Col/TailRow/Normalise
@onready var _seamless: CheckBox = $Root/Col/LoopRow/Seamless
@onready var _loop_note: Label = $Root/Col/LoopRow/Note
@onready var _progress: ProgressBar = $Root/Col/Progress
@onready var _go: Button = $Root/Col/Buttons/Go


func _ready() -> void:
	title = "Export Stems" if _stems else "Export Audio"
	# A window is sized in pixels but laid out in scaled units.
	var sc := Settings.ui_scale()
	content_scale_factor = sc
	size = Vector2i(int(520.0 * sc), int(280.0 * sc))
	close_requested.connect(func(): if not _running: queue_free())

	($Root/Col/PathRow/Label as Label).text = "Folder" if _stems else "File"
	var base := String(Settings.get_value("last_export_dir", ""))
	if base.is_empty() or not DirAccess.dir_exists_absolute(base):
		base = Settings.exports_dir()
	_path.text = base if _stems else base.path_join(App.project.name + ".wav")
	_path.tooltip_text = "Where to write it. The extension follows the format."
	($Root/Col/PathRow/Browse as Button).pressed.connect(_browse)

	for f in FORMATS:
		_bits.add_item(String(f.name))
	_bits.select(clampi(int(Settings.get_value("export_format", 1)), 0, FORMATS.size() - 1))
	_bits.item_selected.connect(_on_format)
	_range.add_item("Whole song")
	_range.add_item("Current pattern")
	_range.add_item("Selected clips")
	_range.add_item("Marked region")
	_range.set_item_disabled(RANGE_MARK, not App.has_mark())
	# What was marked out on the timeline is nearly always what somebody came
	# here to export, so it is what is offered when there is one.
	_range.select(RANGE_MARK if App.has_mark()
			else (RANGE_SONG if App.mode() == Cd.Mode.SONG else RANGE_PATTERN))
	_range.item_selected.connect(func(_i): _update_note())

	_auto_tail.button_pressed = bool(Settings.get_value("export_auto_tail", true))
	_auto_tail.toggled.connect(func(on):
		_tail.editable = not on
		Settings.set_value("export_auto_tail", on))
	_tail.editable = not _auto_tail.button_pressed
	_seamless.toggled.connect(func(_on): _update_note())
	_update_note()
	_on_format(_bits.selected)

	($Root/Col/Buttons/Close as Button).pressed.connect(func(): if not _running: queue_free())
	_go.pressed.connect(_start)
	set_process(false)


## The extension follows the format, so the file that is written is the file
## the name says it is.
func _on_format(i: int) -> void:
	Settings.set_value("export_format", i)
	var f: Dictionary = FORMATS[i]
	if not _stems and not _path.text.strip_edges().is_empty():
		_path.text = "%s.%s" % [_path.text.get_basename(), String(f.ext)]
	_update_note()


## How long what is about to be written will be, in bars and in minutes and
## seconds -- the thing you check before starting a render, and the thing that
## says you picked the wrong range before you wait for it.
func _range_span() -> Vector2:
	match _range.selected:
		RANGE_PATTERN:
			return Vector2(0.0, float(App.project.patterns[App.current_pattern].length))
		RANGE_CLIPS:
			return _selection_span()
		RANGE_MARK:
			return App.mark_span() if App.has_mark() else Vector2.ZERO
		_:
			return Vector2(0.0, maxf(4.0, App.project.length_beats()))


func _length_note() -> String:
	var span := _range_span()
	var beats := span.y - span.x
	if beats <= 0.0:
		return "nothing selected"
	var sig := maxf(1.0, float(App.project.sig_num))
	return "%.4g bars, %s" % [beats / sig,
			Cd.format_seconds(beats * 60.0 / maxf(20.0, float(App.project.bpm)))]


func _update_note() -> void:
	_length.text = _length_note()
	if _seamless.button_pressed:
		_loop_note.text = "the tail is folded onto the start"
	elif _auto_tail.button_pressed:
		_loop_note.text = "tail runs until it goes quiet"
	else:
		_loop_note.text = ""
	var f: Dictionary = FORMATS[_bits.selected]
	if f.has("args") and _ffmpeg().is_empty():
		_loop_note.text = "ffmpeg not found -- only WAV can be written"


## ffmpeg, if there is one. Everything but WAV needs it.
func _ffmpeg() -> String:
	return CdExport.ffmpeg()


func _browse() -> void:
	var fd := FileDialog.new()
	fd.file_mode = FileDialog.FILE_MODE_OPEN_DIR if _stems else FileDialog.FILE_MODE_SAVE_FILE
	fd.access = FileDialog.ACCESS_FILESYSTEM
	# The desktop's own chooser when the platform offers one (the XDG portal on
	# Linux, the shell dialog on Windows); Godot's built-in is the fallback.
	fd.use_native_dialog = DisplayServer.has_feature(DisplayServer.FEATURE_NATIVE_DIALOG_FILE)
	fd.size = Vector2i(880, 600)
	if not _stems:
		var ext := String(FORMATS[_bits.selected].ext)
		fd.filters = PackedStringArray(["*.%s ; %s" % [ext, String(FORMATS[_bits.selected].name)]])
	add_child(fd)
	var pick := func(p):
		_path.text = p
		fd.queue_free()
	fd.file_selected.connect(pick)
	fd.dir_selected.connect(pick)
	fd.canceled.connect(func(): fd.queue_free())
	fd.popup_centered()


func _start() -> void:
	if _running:
		return
	var out := _path.text.strip_edges()
	if out.is_empty():
		App.status.emit("Choose where to write the file first")
		return
	Settings.set_value("last_export_dir", out.get_base_dir() if not _stems else out)
	var was_playing := Audio.playing()
	Audio.engine.stop()
	var start := 0.0
	var end := 0.0
	match _range.selected:
		RANGE_SONG:
			end = maxf(4.0, App.project.length_beats())
		RANGE_PATTERN:
			end = float(App.project.patterns[App.current_pattern].length)
			Audio.engine.set_mode(Cd.Mode.PATTERN)
		RANGE_MARK:
			# What was marked out on the timeline: the stretch that loops is
			# the stretch that gets written.
			if not App.has_mark():
				App.status.emit("Mark a stretch on the timeline first -- shift and drag the ruler")
				return
			var m := App.mark_span()
			start = m.x
			end = m.y
		_:
			# The part of the arrangement that is selected, which is how you
			# say "this eight bars, and make it loop".
			var span := _selection_span()
			if span == Vector2.ZERO:
				App.status.emit("Select some clips first, or choose another range")
				return
			start = span.x
			end = span.y
	var f: Dictionary = FORMATS[_bits.selected]
	var bits := int(f.bits)
	# Everything that is not written as a WAV is rendered as a float WAV first
	# and encoded from that, so the encoder is never given something that has
	# already been rounded to 24 bits.
	if f.has("args"):
		bits = 32
	var tail: float = -1.0 if _auto_tail.button_pressed else float(_tail.value)
	var norm := _norm.button_pressed
	var fold := _seamless.button_pressed
	_running = true
	_go.disabled = true
	set_process(true)
	App.status.emit("Rendering...")
	# The engine takes its own lock for the render, so a worker thread here
	# keeps the interface responsive without racing the audio thread.
	_thread = Thread.new()
	var stems := _stems
	var wav := out if not f.has("args") else _temp_wav(out)
	_thread.start(func():
		var ok: bool
		if stems:
			ok = Audio.engine.render_stems(out, start, end, tail, bits)
		else:
			ok = Audio.engine.render_loop(wav, start, end, tail, bits, norm, fold)
		if ok and f.has("args"):
			ok = _encode_all(stems, wav, out, f)
		call_deferred("_finished", ok, out, was_playing))


## Where the intermediate WAV goes: beside the file being written, so it is on
## the same drive and the encode does not copy across one.
func _temp_wav(out: String) -> String:
	return "%s.cadmium-render.wav" % out.get_basename()


## Encodes the render, or every stem in the folder, into the chosen format.
## Runs on the render thread; ffmpeg is a subprocess, so it blocks nothing else.
func _encode_all(stems: bool, wav: String, out: String, f: Dictionary) -> bool:
	var tool := _ffmpeg()
	if tool.is_empty():
		return false
	if not stems:
		var ok := _encode(tool, wav, out, f)
		DirAccess.remove_absolute(wav)
		return ok
	var d := DirAccess.open(out)
	if d == null:
		return false
	var all := true
	for name in d.get_files():
		if name.get_extension().to_lower() != "wav":
			continue
		var src := out.path_join(name)
		var dst := "%s.%s" % [src.get_basename(), String(f.ext)]
		if _encode(tool, src, dst, f):
			DirAccess.remove_absolute(src)
		else:
			all = false
	return all


func _encode(tool: String, src: String, dst: String, f: Dictionary) -> bool:
	return CdExport.encode(tool, src, dst, f)


## First beat to last beat of whatever is selected in the arrangement.
func _selection_span() -> Vector2:
	var lo := INF
	var hi := -INF
	for i in App.selected_clips:
		if i < 0 or i >= App.project.clips.size():
			continue
		var c: Dictionary = App.project.clips[i]
		lo = minf(lo, float(c.start))
		hi = maxf(hi, float(c.start) + float(c.length))
	if hi <= lo:
		return Vector2.ZERO
	return Vector2(float(lo), float(hi))


func _process(_dt: float) -> void:
	_progress.value = Audio.engine.render_progress()


func _finished(ok: bool, out: String, resume: bool) -> void:
	if _thread != null:
		_thread.wait_to_finish()
		_thread = null
	_running = false
	_go.disabled = false
	set_process(false)
	_progress.value = 1.0
	# The pattern range puts the engine into pattern mode to render; whatever
	# the rest of the program was doing is what it should go back to.
	Audio.engine.set_mode(App.mode())
	App.status.emit(("Exported %s" % out.get_file()) if ok
			else "Export failed" + (" -- ffmpeg is needed for that format" if _ffmpeg().is_empty() else ""))
	if resume:
		Audio.play(false)
	if ok:
		queue_free()
