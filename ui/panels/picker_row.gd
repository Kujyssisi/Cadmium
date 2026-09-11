extends PanelContainer
## One line of the playlist's picker. Click to make it the one you are editing,
## drag it onto the arrangement to place it, right-click for the rest.
##
## The layout is picker_row.tscn; what the row stands for is set before it goes
## into the tree.

signal picked()
signal menu_requested(at: Vector2)

## "pattern", "sample" or "automation".
var kind := "pattern"
var index := 0
var label := ""
var detail := ""
var tint := Color(0.5, 0.5, 0.5)
var current := false
## The preview drawn behind the name: note blocks for a pattern, a waveform
## for an audio file, the curve for an automation lane. Worked out once, when
## the row is built, and thrown away with it.
var _preview: PackedVector2Array = PackedVector2Array()
var _preview_kind := ""

@onready var _chip: Control = $Row/Chip
@onready var _name: Label = $Row/Name
@onready var _detail: Label = $Row/Detail


func _ready() -> void:
	_build_preview()
	# The name sits over the preview, so it needs an edge to be read against.
	for l in [_name, _detail]:
		l.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.85))
		l.add_theme_constant_override("shadow_offset_x", 1)
		l.add_theme_constant_override("shadow_offset_y", 1)
		l.add_theme_constant_override("shadow_outline_size", 2)
	_name.text = label
	_detail.text = detail
	tooltip_text = "%s\nClick to select, drag onto the arrangement to place it" % label
	_chip.draw.connect(func():
		_chip.draw_rect(Rect2(Vector2.ZERO, _chip.size), tint))
	mouse_filter = Control.MOUSE_FILTER_STOP


func refresh(is_current: bool) -> void:
	if current == is_current:
		return
	current = is_current
	# The row that is current already says so with its background; putting the
	# name in the accent as well was accent text on an accent wash, over an
	# accent-coloured preview, and none of the three could be read.
	_name.add_theme_color_override("font_color", CdPalette.TEXT)
	queue_redraw()


func _draw() -> void:
	if current:
		draw_rect(Rect2(Vector2.ZERO, size), Color(CdPalette.ACCENT.r, CdPalette.ACCENT.g,
				CdPalette.ACCENT.b, 0.16))
	_draw_preview()


## A picture of what the thing actually is, behind its name -- which is how you
## find the drop you wrote three minutes ago among six patterns all called
## "Pattern 4". Drawn faintly: it is there to be recognised, not read.
func _draw_preview() -> void:
	if _preview.is_empty():
		return
	var pad := 3.0
	var box := Rect2(pad, pad, size.x - pad * 2.0, size.y - pad * 2.0)
	if box.size.x < 8.0 or box.size.y < 4.0:
		return
	var c := Color(1, 1, 1, 0.34) if current else Color(tint.r, tint.g, tint.b, 0.42)
	match _preview_kind:
		"notes":
			# Pairs of points: each is one note, as a start and an end on a row.
			for i in range(0, _preview.size() - 1, 2):
				var a: Vector2 = _preview[i]
				var b: Vector2 = _preview[i + 1]
				var x := box.position.x + a.x * box.size.x
				var w: float = maxf(1.0, (b.x - a.x) * box.size.x)
				var y := box.position.y + a.y * box.size.y
				draw_rect(Rect2(x, y, w, maxf(1.0, box.size.y * 0.12)), c)
		"wave":
			# Pairs again, this time the low and high of one column.
			for i in range(0, _preview.size() - 1, 2):
				var lo: Vector2 = _preview[i]
				var hi: Vector2 = _preview[i + 1]
				var x := box.position.x + lo.x * box.size.x
				var y0 := box.position.y + (0.5 - lo.y * 0.5) * box.size.y
				var y1 := box.position.y + (0.5 - hi.y * 0.5) * box.size.y
				draw_line(Vector2(x, y0), Vector2(x, maxf(y1, y0 + 1.0)), c, 1.0)
		"curve":
			var pts := PackedVector2Array()
			for p in _preview:
				pts.append(box.position + Vector2(p.x * box.size.x, (1.0 - p.y) * box.size.y))
			if pts.size() >= 2:
				draw_polyline(pts, c, 1.0)


func _build_preview() -> void:
	match kind:
		"pattern":
			_preview_kind = "notes"
			_preview = _pattern_preview()
		"sample":
			_preview_kind = "wave"
			_preview = _sample_preview()
		"automation":
			_preview_kind = "curve"
			_preview = _automation_preview()


## Every note as a start/end pair in 0..1, with the pitch range the pattern
## actually uses spread over the height -- a bass line and a hi-hat line both
## read as something rather than as a stripe at the edge.
func _pattern_preview() -> PackedVector2Array:
	var out := PackedVector2Array()
	if index < 0 or index >= App.project.patterns.size():
		return out
	var p: Dictionary = App.project.patterns[index]
	var notes: Array = p.get("notes", [])
	if notes.is_empty():
		return out
	var span: float = maxf(1.0, float(p.get("length", 16.0)))
	var lo := 127
	var hi := 0
	for n in notes:
		lo = mini(lo, int(n.key))
		hi = maxi(hi, int(n.key))
	if hi - lo < 11:
		# A narrow range would make one note fill the row; give it an octave.
		var mid := (hi + lo) / 2
		lo = maxi(0, mid - 6)
		hi = lo + 12
	var keys: float = maxf(1.0, float(hi - lo))
	var drawn := 0
	for n in notes:
		if drawn >= 256:
			break
		drawn += 1
		var x0: float = clampf(float(n.beat) / span, 0.0, 1.0)
		var x1: float = clampf((float(n.beat) + float(n.len)) / span, 0.0, 1.0)
		var y: float = clampf(1.0 - (float(int(n.key) - lo) / keys), 0.0, 1.0) * 0.88
		out.append(Vector2(x0, y))
		out.append(Vector2(maxf(x1, x0 + 0.01), y))
	return out


func _sample_preview() -> PackedVector2Array:
	var out := PackedVector2Array()
	if index < 0 or index >= App.project.assets.size():
		return out
	if float(App.engine().asset_seconds(index)) <= 0.0:
		return out
	# The whole file, as a fraction of itself: a sample shorter than a second
	# used to be asked for the first `secs` of itself and drew a sliver.
	var buckets := 48
	var peaks: PackedFloat32Array = App.engine().asset_peaks_range(index, 0.0, 1.0, buckets)
	var pairs: int = peaks.size() / 2
	for i in pairs:
		var x := (float(i) + 0.5) / float(pairs)
		out.append(Vector2(x, peaks[i * 2]))
		out.append(Vector2(x, peaks[i * 2 + 1]))
	return out


func _automation_preview() -> PackedVector2Array:
	var out := PackedVector2Array()
	if index < 0 or index >= App.project.automations.size():
		return out
	var a: Dictionary = App.project.automations[index]
	var pts: Array = a.get("points", [])
	if pts.is_empty():
		return out
	var last: float = maxf(0.001, float(pts[pts.size() - 1].beat))
	for p in pts:
		out.append(Vector2(clampf(float(p.beat) / last, 0.0, 1.0),
				clampf(float(p.value), 0.0, 1.0)))
	return out


func _gui_input(event: InputEvent) -> void:
	if not (event is InputEventMouseButton) or not event.pressed:
		return
	if event.button_index == MOUSE_BUTTON_LEFT:
		picked.emit()
		accept_event()
	elif event.button_index == MOUSE_BUTTON_RIGHT:
		menu_requested.emit(get_global_mouse_position())
		accept_event()


## The same payload the browser sends, so the arrangement already knows how to
## take it.
func _get_drag_data(_pos: Vector2) -> Variant:
	# Only during a real drag: a test that asks a row what it would offer is
	# not dragging anything, and Godot refuses a preview outside one.
	if get_viewport() != null and get_viewport().gui_is_dragging():
		var preview := Label.new()
		preview.text = "  %s  " % label
		var box := PanelContainer.new()
		box.theme_type_variation = "CaptionBar"
		box.add_child(preview)
		set_drag_preview(box)
	var data := {"cadmium": true, "kind": kind, "index": index, "label": label}
	if kind == "sample":
		data["path"] = String(App.project.assets[index].get("path", ""))
	return data
