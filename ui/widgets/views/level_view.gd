class_name CdLevelView
extends Control
## What is coming out of the utility: the two sides as meters, the pan and width
## as a picture of where the stereo image is, and the correlation, which is the
## number that says whether it will survive being folded to mono.

var ref := {}
var params: Array = []

var _l := 0.0
var _r := 0.0
var _corr := 1.0
var _index := {}


func _ready() -> void:
	custom_minimum_size.y = 126
	set_process(true)


func _process(_dt: float) -> void:
	if not is_visible_in_tree():
		return
	var h: int = App.handle_for(ref)
	if h < 0:
		return
	var a: PackedFloat32Array = App.engine().plugin_aux(h, 0, 3)
	if a.size() == 3:
		_l = a[0]
		_r = a[1]
		_corr = a[2]
	queue_redraw()


func _draw() -> void:
	var font := get_theme_default_font()
	draw_rect(Rect2(Vector2.ZERO, size), CdPalette.WELL)
	var half := size.x * 0.5
	_meters(Rect2(10, 16, half - 20.0, size.y - 32.0), font)
	_image(Rect2(half + 4.0, 16, half - 16.0, size.y - 32.0), font)


func _meters(r: Rect2, font: Font) -> void:
	draw_string(font, Vector2(r.position.x, r.position.y - 4.0), "OUTPUT",
			HORIZONTAL_ALIGNMENT_LEFT, r.size.x, 8, CdPalette.TEXT_MUTE)
	var names := ["L", "R"]
	var vals := [_l, _r]
	for i in 2:
		var bar := Rect2(r.position.x + 14.0, r.position.y + float(i) * 22.0, r.size.x - 20.0, 14.0)
		draw_rect(bar, CdPalette.PANEL)
		var db: float = Cd.gain_to_db(maxf(float(vals[i]), 0.00001))
		var t: float = clampf((db + 60.0) / 60.0, 0.0, 1.0)
		if t > 0.002:
			draw_rect(Rect2(bar.position, Vector2(bar.size.x * t, bar.size.y)),
					CdPalette.BAD if float(vals[i]) >= 1.0 else CdPalette.ACCENT)
		draw_string(font, Vector2(r.position.x, bar.end.y - 3.0), String(names[i]),
				HORIZONTAL_ALIGNMENT_LEFT, 12.0, 9, CdPalette.TEXT_DIM)
	var peak: float = maxf(_l, _r)
	draw_string(font, Vector2(r.position.x, r.end.y - 2.0),
			"peak %s" % Cd.format_param(Cd.gain_to_db(maxf(peak, 0.00001)), Cd.ParamKind.DB),
			HORIZONTAL_ALIGNMENT_LEFT, r.size.x, 9, CdPalette.TEXT_DIM)


func _image(r: Rect2, font: Font) -> void:
	draw_string(font, Vector2(r.position.x, r.position.y - 4.0), "IMAGE",
			HORIZONTAL_ALIGNMENT_LEFT, r.size.x, 8, CdPalette.TEXT_MUTE)
	var box := Rect2(r.position.x, r.position.y, r.size.x, r.size.y - 18.0)
	draw_rect(box, CdPalette.PANEL)
	var mid := box.get_center()
	draw_line(Vector2(mid.x, box.position.y), Vector2(mid.x, box.end.y),
			CdPalette.RULE_DARK, 1.0)
	# Pan slides the block, width stretches it: what you set, drawn.
	var pan: float = clampf(_p("pan", 0.0), -1.0, 1.0)
	var width: float = clampf(_p("width", 1.0) * 0.5, 0.0, 1.0)
	var cx: float = mid.x + pan * box.size.x * 0.42
	var w: float = maxf(3.0, width * box.size.x * 0.8)
	draw_rect(Rect2(cx - w * 0.5, box.position.y + 6.0, w, box.size.y - 12.0),
			Color(CdPalette.ACCENT.r, CdPalette.ACCENT.g, CdPalette.ACCENT.b, 0.30))
	draw_line(Vector2(cx, box.position.y + 4.0), Vector2(cx, box.end.y - 4.0),
			CdPalette.ACCENT, 1.4)
	# Correlation: +1 folds to mono untouched, 0 is wide, below 0 will cancel.
	var col: Color = CdPalette.GOOD if _corr > 0.3 else (CdPalette.BAD if _corr < 0.0 else CdPalette.TEXT)
	draw_string(font, Vector2(r.position.x, r.end.y - 2.0),
			"correlation %+.2f" % _corr, HORIZONTAL_ALIGNMENT_LEFT, r.size.x, 9, col)


func _p(id: String, fallback: float) -> float:
	if _index.is_empty():
		for k in params.size():
			_index[String(params[k].id)] = int(params[k].index)
	if _index.has(id):
		return App.get_plugin_param(ref, int(_index[id]))
	return fallback
