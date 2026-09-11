class_name CdSynthView
extends Control
## An instrument's envelope and filter, drawn from its own parameters. Named
## after what synths actually call them, so one panel serves every one of them.

var ref := {}
var params: Array = []
var _index := {}

## The names instruments actually give these, so one panel serves all of them.
const ENV_A := ["attack", "amp_a", "a", "env_a"]
const ENV_D := ["decay", "amp_d", "d", "env_d"]
const ENV_S := ["sustain", "amp_s", "s", "env_s"]
const ENV_R := ["release", "amp_r", "r", "env_r"]
const CUT := ["cut", "cutoff", "f_cut", "flt_cut", "filter_cut"]
const RES := ["res", "reso", "f_res", "flt_res", "filter_res"]
const FTYPE := ["flt_type", "f_mode", "flt_mode", "type", "mode"]


## Whether this plugin has anything for the panel to draw. A synth with no
## filter and no envelope gets no panel rather than an empty pair of headings.
static func fits(params_in: Array) -> bool:
	for p in params_in:
		var id := String(p.get("id", ""))
		if id in ENV_A or id in CUT:
			return true
	return false

func _ready() -> void:
	custom_minimum_size.y = 96
	set_process(true)

func _process(_dt: float) -> void:
	if is_visible_in_tree():
		queue_redraw()

func _p(names: Array, fallback := 0.0) -> float:
	if _index.is_empty():
		for k in params.size():
			_index[String(params[k].id)] = int(params[k].index)
	for n in names:
		if _index.has(n):
			return App.get_plugin_param(ref, int(_index[n]))
	return fallback

## The filter type is a choice list whose numbering differs between
## instruments, so read the label rather than the number.
func _choice(names: Array) -> String:
	if _index.is_empty():
		for k in params.size():
			_index[String(params[k].id)] = int(params[k].index)
	for n in names:
		if not _index.has(n):
			continue
		var idx := int(_index[n])
		for pm in params:
			if int(pm.index) != idx:
				continue
			var opts := String(pm.get("choices", "")).split("|")
			var v := int(App.get_plugin_param(ref, idx))
			if v >= 0 and v < opts.size():
				return String(opts[v]).to_lower()
	return ""

func _has(names: Array) -> bool:
	if _index.is_empty():
		for k in params.size():
			_index[String(params[k].id)] = int(params[k].index)
	for n in names:
		if _index.has(n):
			return true
	return false

func _draw() -> void:
	var font := get_theme_default_font()
	draw_rect(Rect2(Vector2.ZERO, size), CdPalette.WELL)
	var has_env := _has(ENV_A)
	var has_flt := _has(CUT)
	# Whichever of the two this instrument has gets the room; if it has both
	# they share it.
	if has_env and has_flt:
		var half := size.x * 0.5
		_draw_env(Rect2(4, 14, half - 8.0, size.y - 22.0), font)
		_draw_filter(Rect2(half + 4.0, 14, half - 8.0, size.y - 22.0), font)
	elif has_env:
		_draw_env(Rect2(4, 14, size.x - 8.0, size.y - 22.0), font)
	elif has_flt:
		_draw_filter(Rect2(4, 14, size.x - 8.0, size.y - 22.0), font)

## Attack, decay, sustain, release as the shape they make.
func _draw_env(r: Rect2, font: Font) -> void:
	draw_string(font, Vector2(r.position.x, 11), "ENVELOPE", HORIZONTAL_ALIGNMENT_LEFT,
			r.size.x, 8, CdPalette.TEXT_MUTE)
	var a := _p(ENV_A, 0.01)
	var d := _p(ENV_D, 0.2)
	var s := _p(ENV_S, 0.7)
	var rel := _p(ENV_R, 0.3)
	# Laid out in proportion, so a long release does not squash the attack
	# into nothing.
	var total: float = maxf(0.05, a + d + rel + 0.35)
	var x0 := r.position.x
	var x_a := x0 + r.size.x * (a / total)
	var x_d := x_a + r.size.x * (d / total)
	var x_s := x_d + r.size.x * (0.35 / total)
	var x_r := r.end.x
	var base := r.end.y
	var top := r.position.y
	var pts := PackedVector2Array([
		Vector2(x0, base), Vector2(x_a, top),
		Vector2(x_d, base - (base - top) * s), Vector2(x_s, base - (base - top) * s),
		Vector2(x_r, base)])
	# Duplicated corners are what a zero-length stage produces, and a polygon
	# with two points in the same place cannot be triangulated.
	var fill := PackedVector2Array()
	for pt in pts:
		if fill.is_empty() or fill[fill.size() - 1].distance_to(pt) > 0.01:
			fill.append(pt)
	if fill.size() >= 3 and fill[fill.size() - 1].distance_to(Vector2(x0, base)) > 0.01:
		fill.append(Vector2(x0, base))
	if fill.size() >= 3 and Cd.has_area(fill):
		draw_colored_polygon(fill, Color(CdPalette.ACCENT.r, CdPalette.ACCENT.g,
				CdPalette.ACCENT.b, 0.18))
	draw_polyline(pts, CdPalette.ACCENT, 1.4, true)
	draw_line(Vector2(x0, base), Vector2(x_r, base), CdPalette.RULE_DARK, 1.0)

## Where the filter is and how hard it is resonating.
func _draw_filter(r: Rect2, font: Font) -> void:
	draw_string(font, Vector2(r.position.x, 11), "FILTER", HORIZONTAL_ALIGNMENT_LEFT,
			r.size.x, 8, CdPalette.TEXT_MUTE)
	var cut := _p(CUT, 1000.0)
	var res := _p(RES, 0.3)
	var label := _choice(FTYPE)
	var mode := 0
	if label.begins_with("high"):
		mode = 3
	elif label.begins_with("band"):
		mode = 2
	draw_line(Vector2(r.position.x, r.end.y), Vector2(r.end.x, r.end.y),
			CdPalette.RULE_DARK, 1.0)
	var pts := PackedVector2Array()
	var steps := 64
	for i in steps + 1:
		var t := float(i) / float(steps)
		# Twenty hertz to twenty thousand, the way a frequency axis is read.
		var hz: float = 20.0 * pow(1000.0, t)
		var g := _response(hz, cut, res, mode)
		var y: float = r.end.y - r.size.y * clampf(0.5 + g * 0.5, 0.0, 1.0)
		pts.append(Vector2(r.position.x + r.size.x * t, y))
	draw_polyline(pts, CdPalette.ACCENT, 1.4, true)
	# Where the corner sits, so the number and the picture agree.
	var ct: float = clampf(log(maxf(20.0, cut) / 20.0) / log(1000.0), 0.0, 1.0)
	var cx := r.position.x + r.size.x * ct
	draw_line(Vector2(cx, r.position.y), Vector2(cx, r.end.y),
			Color(1, 1, 1, 0.18), 1.0)
	draw_string(font, Vector2(r.position.x, r.end.y - 2.0),
			Cd.format_param(cut, Cd.ParamKind.HZ), HORIZONTAL_ALIGNMENT_RIGHT,
			r.size.x, 8, CdPalette.TEXT_DIM)

## A rough magnitude, enough to read the shape: -1 is well down, +1 is a
## resonant peak.
func _response(hz: float, cut: float, res: float, mode: int) -> float:
	var w: float = hz / maxf(20.0, cut)
	var peak: float = res * 1.6 * exp(-pow(log(maxf(0.01, w)) * 2.2, 2.0))
	match mode:
		3:      # high pass
			return clampf(-1.0 / (1.0 + w * w * 4.0) * 2.0 + 1.0 + peak, -1.0, 1.0)
		2:      # band pass
			return clampf(peak + 1.0 / (1.0 + pow(log(maxf(0.01, w)) * 1.6, 2.0)) - 0.5, -1.0, 1.0)
		_:      # low pass
			return clampf(1.0 - w * w / (1.0 + w * w) * 2.0 + peak, -1.0, 1.0)
