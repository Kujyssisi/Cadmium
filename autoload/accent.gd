extends Node
## Repoints the interface's primary colour.
##
## tools/build_theme.gd bakes the accent into the Theme as a handful of exact
## values plus one 9-patch texture, so this rewrites by *exact match* against
## that ramp rather than by hue. Hue matching is what Comotion does, but here
## the accent is already red and the danger button, the record light and the
## clip colours are red too -- they must stay put.

signal accent_changed(color: Color)

## The values tools/build_theme.gd writes, in the order they are derived.
const RAMP := [
	Color("#e0483c"),   # ACCENT
	Color("#a82f26"),   # ACCENT_D  (pressed / filled)
	Color("#2a0d0a"),   # text on an accented ground
	Color("#140504"),
	Color("#1c0908"),
	Color("#ffe0e0"),   # danger button label
]
const EPS := 0.004

var _applied := CdPalette.ACCENT_DEFAULT


func _ready() -> void:
	var want := Color(String(Settings.get_value("accent", "#e0483c")))
	if not want.is_equal_approx(CdPalette.ACCENT_DEFAULT):
		apply(want, false)


## For a colour picker being dragged: the last colour asked for is applied a
## few times a second rather than on every frame. Retinting a whole theme and
## every icon in it is not something to do sixty times a second.
const SETTLE := 0.09
var _pending: Color = Color.BLACK
var _waiting := false

func apply_soon(color: Color) -> void:
	_pending = color
	if _waiting:
		return
	_waiting = true
	get_tree().create_timer(SETTLE).timeout.connect(func():
		_waiting = false
		apply(_pending))


func apply(color: Color, save: bool = true) -> void:
	color = Color(color.r, color.g, color.b, 1.0)
	# A ColorPicker echoes back whatever it is told; without this early-out the
	# accent drifts a shade lighter on every frame the picker is open.
	if color.is_equal_approx(_applied):
		return
	_applied = color
	CdPalette.set_accent(color)
	var theme := ThemeDB.get_project_theme()
	if theme != null:
		_retint_theme(theme, color)
	Icons.clear_cache()
	# Controls wearing a tightened copy of a theme style have to be given a
	# fresh copy: theirs was made from the colours as they were.
	Cd.recompact()
	if save:
		Settings.set_value("accent", "#" + color.to_html(false))
	accent_changed.emit(color)


func _new_ramp(color: Color) -> Array:
	var base := RAMP[0]
	var out := []
	for entry in RAMP:
		# Keep each step's relationship to the base, move the hue and take the
		# base's saturation as the new reference.
		var c: Color = entry
		var h := color.h + (c.h - base.h)
		var s := clampf(c.s * (color.s / maxf(0.001, base.s)), 0.0, 1.0)
		var v := clampf(c.v * (color.v / maxf(0.001, base.v)), 0.0, 1.0)
		out.append(Color.from_hsv(fposmod(h, 1.0), s, v, c.a))
	return out


func _map(c: Color, ramp: Array) -> Color:
	for i in RAMP.size():
		var r: Color = RAMP[i]
		if absf(c.r - r.r) < EPS and absf(c.g - r.g) < EPS and absf(c.b - r.b) < EPS:
			var n: Color = ramp[i]
			return Color(n.r, n.g, n.b, c.a)
	return c


func _retint_theme(theme: Theme, color: Color) -> void:
	var ramp := _new_ramp(color)
	# Every write to a theme tells the whole interface to lay itself out again,
	# and there are hundreds of writes in here: without holding those back, one
	# colour change costs a second of the program doing nothing else.
	var touched := _hold(theme)
	for type_name in theme.get_type_list():
		for cname in theme.get_color_list(type_name):
			var c := theme.get_color(cname, type_name)
			var m := _map(c, ramp)
			if not m.is_equal_approx(c):
				theme.set_color(cname, type_name, m)
		for sname in theme.get_stylebox_list(type_name):
			var sb := theme.get_stylebox(sname, type_name)
			if sb is StyleBoxFlat:
				sb.bg_color = _map(sb.bg_color, ramp)
				sb.border_color = _map(sb.border_color, ramp)
				sb.shadow_color = _map(sb.shadow_color, ramp)
			elif sb is StyleBoxTexture:
				sb.modulate_color = _map(sb.modulate_color, ramp)
				_retint_texture(sb, color)
	_release(theme, touched)


## The accent 9-patch is a whole red ramp baked into pixels; the file name is
## what identifies it, because its darkest shades are indistinguishable by hue
## from the danger button's.
func _retint_texture(sb: StyleBoxTexture, color: Color) -> void:
	var tex := sb.texture
	if tex == null or not String(tex.resource_path).contains("accent"):
		return
	var img := tex.get_image()
	if img == null:
		return
	img = img.duplicate()
	if img.is_compressed():
		img.decompress()
	var base := RAMP[0]
	for y in img.get_height():
		for x in img.get_width():
			var c := img.get_pixel(x, y)
			if c.a < 0.01 or c.s < 0.12:
				continue
			var h := fposmod(color.h + (c.h - base.h), 1.0)
			var s := clampf(c.s * (color.s / maxf(0.001, base.s)), 0.0, 1.0)
			var v := clampf(c.v * (color.v / maxf(0.001, base.v)), 0.0, 1.0)
			img.set_pixel(x, y, Color.from_hsv(h, s, v, c.a))
	sb.texture = ImageTexture.create_from_image(img)


## Theme edits come in hundreds at a time, and each one on its own would tell
## every control in the program to lay itself out again. These hold the news
## back until the whole change is made, and then tell everyone once.
func _hold(theme: Theme) -> Array:
	var boxes := []
	theme.set_block_signals(true)
	for type_name in theme.get_type_list():
		for sname in theme.get_stylebox_list(type_name):
			var sb := theme.get_stylebox(sname, type_name)
			if sb != null and not sb.is_blocking_signals():
				sb.set_block_signals(true)
				boxes.append(sb)
	return boxes


func _release(theme: Theme, boxes: Array) -> void:
	for sb in boxes:
		sb.set_block_signals(false)
	theme.set_block_signals(false)
	theme.emit_changed()
