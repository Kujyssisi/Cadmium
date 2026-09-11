class_name CdVocoderView
extends Control
## The vocoder's bands, each as tall as the voice going into it is loud in that
## band. This is the whole of what a vocoder does, so it is the whole display.

var ref := {}
var params: Array = []

var _bands := PackedFloat32Array()


func _ready() -> void:
	custom_minimum_size.y = 130
	set_process(true)


func _process(_dt: float) -> void:
	if not is_visible_in_tree():
		return
	var h: int = App.handle_for(ref)
	if h < 0:
		return
	var a: PackedFloat32Array = App.engine().plugin_aux(h, 0, 26)
	if a.size() > 1:
		_bands = a
	queue_redraw()


func _draw() -> void:
	var font := get_theme_default_font()
	draw_rect(Rect2(Vector2.ZERO, size), CdPalette.WELL)
	var r := Rect2(10, 16, size.x - 20.0, size.y - 38.0)
	draw_rect(r, CdPalette.PANEL)
	draw_string(font, Vector2(r.position.x, r.position.y - 4.0), "BANDS",
			HORIZONTAL_ALIGNMENT_LEFT, r.size.x, 8, CdPalette.TEXT_MUTE)
	if _bands.size() < 2:
		draw_string(font, Vector2(0, r.get_center().y),
				"send something into this channel to shape the carrier",
				HORIZONTAL_ALIGNMENT_CENTER, size.x, 9, CdPalette.TEXT_MUTE)
		return
	var n := int(_bands[0])
	if n < 1:
		return
	var bw: float = r.size.x / float(n)
	var quiet := true
	for b in n:
		var v: float = clampf(_bands[b + 1], 0.0, 1.0)
		if v > 0.01:
			quiet = false
		var bar := Rect2(r.position.x + float(b) * bw + 1.0, r.end.y - r.size.y * v,
				bw - 2.0, r.size.y * v)
		draw_rect(bar, CdPalette.ACCENT)
	# The bands run from 110 Hz to 7.5 kHz, which is where speech lives.
	draw_string(font, Vector2(r.position.x, r.end.y + 13.0),
			"110 Hz to 7.5 kHz over %d bands" % n, HORIZONTAL_ALIGNMENT_LEFT,
			r.size.x * 0.6, 9, CdPalette.TEXT_DIM)
	if quiet:
		draw_string(font, Vector2(0, r.get_center().y), "no voice coming in",
				HORIZONTAL_ALIGNMENT_CENTER, size.x, 9, CdPalette.TEXT_MUTE)
