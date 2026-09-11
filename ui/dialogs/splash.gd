class_name CdSplash
extends Window
## The window Cadmium starts behind: the mark, the name and what it is doing.
##
## The bar is not a guess. Each stage is marked as it actually finishes -- the
## interface is built, the instruments and effects are catalogued, the first
## frame is on screen -- and the bar slides towards whatever has been reached
## rather than jumping, so a fast machine still shows something rather than a
## flash. It closes itself once the work is done and it has been up long
## enough to read, and a click or a key closes it there and then.

## How far along each stage counts as. Startup is quick enough that a real
## measurement of it would be a blur, so what these mark is order, not time.
const STAGES := {
	"start": 0.06,
	"interface": 0.45,
	"plugins": 0.8,
	"ready": 1.0,
}

## Long enough to read the name on it, short enough not to be in the way.
const MIN_SECONDS := 1.3
## A scan that never reports back does not hold the splash up for ever.
const PATIENCE := 6.0
const FADE := 0.22

var _target := 0.0
var _shown := 0.0
var _up := 0.0
var _closing := false
## The two things worth waiting for: the interface has drawn, and the list of
## instruments and effects has been built. Both, and the splash is done.
var _drawn := false
var _catalogued := false

@onready var _bar: ProgressBar = $Root/Pad/Col/Bar
@onready var _stage: Label = $Root/Pad/Col/Stage
@onready var _name: Label = $Root/Pad/Col/Head/Words/Name
@onready var _version: Label = $Root/Pad/Col/Head/Words/Version
@onready var _panel: PanelContainer = $Root


## Puts one up straight away, before the caller gets on with starting. Returns
## null where there is no screen to put it on -- a headless run, or one of the
## test hooks -- so the caller can go on without checking for a display itself.
static func open(host: Node) -> CdSplash:
	if DisplayServer.get_name() == "headless":
		return null
	var splash: CdSplash = preload("res://ui/dialogs/splash.tscn").instantiate()
	host.add_child(splash)
	splash.popup_centered()
	return splash


func _ready() -> void:
	# A window is sized in pixels but laid out in scaled units.
	var sc := Settings.ui_scale()
	content_scale_factor = sc
	size = Vector2i(int(480.0 * sc), int(210.0 * sc))
	_name.add_theme_color_override("font_color", CdPalette.ACCENT)
	_dress_bar()
	_version.text = "Version %s" % ProjectSettings.get_setting("application/config/version", "1.0")
	_bar.value = 0.0
	step("start", "Starting up")
	# The catalogue is built a frame or two in, and until it is there are no
	# instruments to put on a channel. That is worth waiting for.
	if not Plugins.catalog_changed.is_connected(_on_catalog):
		Plugins.catalog_changed.connect(_on_catalog)
	set_process(true)


## The theme fills a progress bar in the dimmed accent, which is right for a
## readout in the corner of a busy window and too dark for the one thing on
## screen while Cadmium starts. This one is filled in the accent itself, over a
## well dark enough to show how far along it is.
func _dress_bar() -> void:
	var trough := StyleBoxFlat.new()
	trough.bg_color = CdPalette.WELL
	trough.border_color = CdPalette.BEVEL_LO
	trough.set_border_width_all(1)
	trough.set_corner_radius_all(5)
	var fill := StyleBoxFlat.new()
	fill.bg_color = CdPalette.ACCENT
	fill.set_corner_radius_all(5)
	_bar.add_theme_stylebox_override("background", trough)
	_bar.add_theme_stylebox_override("fill", fill)


func _on_catalog() -> void:
	_catalogued = true
	step("plugins", "Instruments and effects ready")
	_settle()


## Marks a stage done. Unknown names simply set the text, so a caller can say
## what it is doing without having to add to STAGES.
func step(stage: String, text: String) -> void:
	if _closing:
		return
	_target = maxf(_target, float(STAGES.get(stage, _target)))
	_stage.text = text


## The interface has drawn a frame. The splash still holds for the rest of its
## minimum time, so this is not a flash of a window on a quick machine, and it
## still waits on the plugin catalogue if that has not arrived yet.
func done() -> void:
	_drawn = true
	_settle()


func _settle() -> void:
	if _drawn and _catalogued:
		step("ready", "Ready")


func _process(dt: float) -> void:
	_up += dt
	# Towards the target rather than at it: a bar that jumps reads as broken.
	_shown = move_toward(_shown, _target, maxf(0.35, absf(_target - _shown) * 4.0) * dt)
	_bar.value = _shown
	if _closing:
		return
	# A scan that never came back is not a reason to sit on the song.
	if _up > PATIENCE:
		step("ready", "Ready")
	if _up >= MIN_SECONDS and _target >= 1.0 and _shown >= 0.999:
		_close()


func _input(event: InputEvent) -> void:
	# Somewhere to click when you have read it and want on with it.
	if event is InputEventKey and event.pressed:
		_close()
	elif event is InputEventMouseButton and event.pressed:
		_close()


func _close() -> void:
	if _closing:
		return
	_closing = true
	set_process(false)
	var fade := create_tween()
	fade.tween_property(_panel, "modulate:a", 0.0, FADE)
	fade.tween_callback(queue_free)
