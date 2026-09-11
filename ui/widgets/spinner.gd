class_name CdSpinner
extends Control
## A turning arc, for the moments where something is being loaded and there is
## nothing useful to say about how far along it is -- a hosted plugin building
## its own interface, mostly. It runs on its own clock rather than the frame
## count, so it turns at the same speed whatever the interface is doing.

@export var radius := 18.0
@export var thickness := 3.0
@export var arc := 0.7            ## how much of the circle is drawn, 0..1
@export var turns_per_second := 0.8

var _t := 0.0


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	if custom_minimum_size == Vector2.ZERO:
		custom_minimum_size = Vector2(radius * 2.0 + 8.0, radius * 2.0 + 8.0)
	set_process(true)


func _process(dt: float) -> void:
	if not is_visible_in_tree():
		return
	_t += dt
	queue_redraw()


func _draw() -> void:
	var mid := size * 0.5
	var from := _t * turns_per_second * TAU
	# The track behind it, so the gap does not read as a broken circle.
	draw_arc(mid, radius, 0.0, TAU, 48, Color(1, 1, 1, 0.08), thickness, true)
	draw_arc(mid, radius, from, from + TAU * arc, 48, CdPalette.ACCENT, thickness, true)
