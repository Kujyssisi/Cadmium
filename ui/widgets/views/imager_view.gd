class_name CdImagerView
extends Control
## Where the stereo image actually is: a goniometer of the last few hundred
## samples, plus the correlation between the channels.

var ref := {}
var params: Array = []
var _pts := PackedFloat32Array()
var _corr := 0.0

func _ready() -> void:
	custom_minimum_size.y = 190
	set_process(true)

func _process(_dt: float) -> void:
	if not is_visible_in_tree():
		return
	var h: int = App.handle_for(ref)
	if h < 0:
		return
	_pts = App.engine().plugin_aux(h, 0, 512)
	var c: PackedFloat32Array = App.engine().plugin_aux(h, 1, 1)
	if c.size() == 1:
		_corr = c[0]
	queue_redraw()

func _draw() -> void:
	var font := get_theme_default_font()
	draw_rect(Rect2(Vector2.ZERO, size), CdPalette.WELL)
	var centre := Vector2(size.x * 0.5, (size.y - 22.0) * 0.5 + 4.0)
	var radius: float = minf(size.x, size.y - 26.0) * 0.44
	# The frame: mono is the vertical line, out of phase is horizontal.
	draw_line(centre - Vector2(0, radius), centre + Vector2(0, radius), CdPalette.RULE_DARK, 1.0)
	draw_line(centre - Vector2(radius, 0), centre + Vector2(radius, 0), CdPalette.RULE_DARK, 1.0)
	draw_arc(centre, radius, 0.0, TAU, 48, CdPalette.RULE_DARK, 1.0)
	draw_string(font, Vector2(centre.x + 4, centre.y - radius + 2), "M",
			HORIZONTAL_ALIGNMENT_LEFT, -1, 8, CdPalette.TEXT_DIM)
	draw_string(font, Vector2(centre.x + radius - 10, centre.y - 4), "R",
			HORIZONTAL_ALIGNMENT_LEFT, -1, 8, CdPalette.TEXT_DIM)
	draw_string(font, Vector2(centre.x - radius + 3, centre.y - 4), "L",
			HORIZONTAL_ALIGNMENT_LEFT, -1, 8, CdPalette.TEXT_DIM)

	var n := _pts.size() / 2
	if n > 1:
		# One colour per *segment*, and two points for each -- Godot wants the
		# points array to be twice the colours. Handing it one colour per point
		# failed the check and drew nothing at all, so the goniometer has been
		# an empty circle since it was written.
		var dots := PackedVector2Array()
		var cols := PackedColorArray()
		var prev := Vector2.ZERO
		for i in n:
			var l := _pts[i * 2]
			var r := _pts[i * 2 + 1]
			# Rotated 45 degrees: mid goes up, side goes across, which is
			# how a goniometer is read.
			var x := (l - r) * 0.7071
			var y := (l + r) * 0.7071
			var at := centre + Vector2(x, -y) * radius
			if i > 0:
				dots.append(prev)
				dots.append(at)
				# Newer samples brighter, so the shape has a direction.
				var age := float(i) / float(n)
				cols.append(Color(CdPalette.ACCENT.r, CdPalette.ACCENT.g, CdPalette.ACCENT.b,
						0.15 + age * 0.75))
			prev = at
		if not cols.is_empty():
			draw_multiline_colors(dots, cols)

	var bar := Rect2(8.0, size.y - 16.0, size.x - 16.0, 8.0)
	draw_rect(bar, CdPalette.PANEL)
	var mid := bar.position.x + bar.size.x * 0.5
	var x2 := mid + bar.size.x * 0.5 * float(_corr)
	draw_rect(Rect2(minf(mid, x2), bar.position.y, absf(x2 - mid), bar.size.y),
			CdPalette.GOOD if _corr >= 0.0 else CdPalette.BAD)
	draw_line(Vector2(mid, bar.position.y), Vector2(mid, bar.end.y), CdPalette.TEXT_DIM, 1.0)
	draw_string(font, Vector2(8, size.y - 20), "correlation %+.2f" % _corr,
			HORIZONTAL_ALIGNMENT_LEFT, -1, 9, CdPalette.TEXT_MUTE)
