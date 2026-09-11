class_name CdLed
extends Control
## The small square lamp used for mute, solo and bypass. A toggle button styled
## by the theme would read as a button; a lamp reads as state.

signal toggled_state(on: bool)

@export var on := true:
	set(v):
		on = v
		queue_redraw()
@export var on_color := CdPalette.ACCENT
@export var off_color := Color("#3a3a3a")
@export var letter := ""


func _ready() -> void:
	focus_mode = Control.FOCUS_NONE
	custom_minimum_size = Vector2(16, 16)
	mouse_filter = Control.MOUSE_FILTER_STOP


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		on = not on
		toggled_state.emit(on)
		accept_event()


func _draw() -> void:
	var r := Rect2(Vector2(1, 1), size - Vector2(2, 2))
	draw_rect(r, CdPalette.WELL)
	var c := on_color if on else off_color
	draw_rect(r.grow(-2.0), c)
	if on:
		# A faint halo sells the lamp as lit without a shader.
		draw_rect(r.grow(-1.0), Color(c.r, c.g, c.b, 0.35), false, 1.0)
	draw_rect(r, CdPalette.BEVEL_LO, false, 1.0)
	if not letter.is_empty():
		var font := get_theme_default_font()
		var fs := 8
		var w := font.get_string_size(letter, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
		draw_string(font, Vector2((size.x - w) * 0.5, size.y * 0.5 + 3.0), letter,
				HORIZONTAL_ALIGNMENT_LEFT, -1, fs,
				CdPalette.WELL if on else CdPalette.TEXT_MUTE)
