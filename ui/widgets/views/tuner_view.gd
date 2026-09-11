class_name CdTunerView
extends Control
## What note is coming in, and how far off it is. The note is big because that
## is the thing you look at while both hands are busy; the strip under it is
## fifty cents either way, with the middle marked.

var ref := {}
var params: Array = []

var _hz := 0.0
var _note := -1.0
var _cents := 0.0
var _conf := 0.0

const NAMES := ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]


func _ready() -> void:
	custom_minimum_size.y = 168
	set_process(true)


func _process(_dt: float) -> void:
	if not is_visible_in_tree():
		return
	var h: int = App.handle_for(ref)
	if h < 0:
		return
	var a: PackedFloat32Array = App.engine().plugin_aux(h, 0, 4)
	if a.size() == 4:
		_hz = a[0]
		_note = a[1]
		_cents = a[2]
		_conf = a[3]
	queue_redraw()


func _draw() -> void:
	var font := get_theme_default_font()
	draw_rect(Rect2(Vector2.ZERO, size), CdPalette.WELL)
	var listening := _conf > 0.6 and _note >= 0.0
	var name := "--"
	var octave := ""
	if listening:
		var n := int(_note)
		name = NAMES[((n % 12) + 12) % 12]
		octave = str(int(floor(float(n) / 12.0)) - 1)
	# In tune is within five cents, which is as close as an ear cares.
	var good: bool = listening and absf(_cents) < 5.0
	var col: Color = CdPalette.GOOD if good else (CdPalette.TEXT if listening else CdPalette.TEXT_MUTE)
	draw_string(font, Vector2(0, size.y * 0.44), name, HORIZONTAL_ALIGNMENT_CENTER,
			size.x, 54, col)
	if listening:
		draw_string(font, Vector2(size.x * 0.5 + 40.0, size.y * 0.44 - 22.0), octave,
				HORIZONTAL_ALIGNMENT_LEFT, -1, 16, CdPalette.TEXT_DIM)
		draw_string(font, Vector2(0, size.y * 0.44 + 18.0),
				"%.1f Hz" % _hz, HORIZONTAL_ALIGNMENT_CENTER, size.x, 10,
				CdPalette.TEXT_DIM)
	else:
		draw_string(font, Vector2(0, size.y * 0.44 + 18.0), "play a note",
				HORIZONTAL_ALIGNMENT_CENTER, size.x, 10, CdPalette.TEXT_MUTE)

	var strip := Rect2(16, size.y - 40.0, size.x - 32.0, 22.0)
	draw_rect(strip, CdPalette.PANEL)
	for c in [-50, -25, 0, 25, 50]:
		var x: float = strip.position.x + strip.size.x * (float(c) + 50.0) / 100.0
		var tall: bool = c == 0
		draw_line(Vector2(x, strip.position.y + (0.0 if tall else 6.0)),
				Vector2(x, strip.end.y - (0.0 if tall else 6.0)),
				CdPalette.TEXT_DIM if tall else CdPalette.RULE_DARK, 1.0)
	if listening:
		var t: float = clampf((_cents + 50.0) / 100.0, 0.0, 1.0)
		var nx: float = strip.position.x + strip.size.x * t
		draw_rect(Rect2(nx - 2.0, strip.position.y - 3.0, 4.0, strip.size.y + 6.0),
				CdPalette.GOOD if good else CdPalette.ACCENT)
		draw_string(font, Vector2(strip.position.x, strip.end.y + 12.0),
				"%+.0f cents" % _cents, HORIZONTAL_ALIGNMENT_CENTER, strip.size.x,
				9, CdPalette.TEXT_DIM)
