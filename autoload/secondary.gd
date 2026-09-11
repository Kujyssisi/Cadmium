extends Node
## The interface's other colour: everything that is not the accent.
##
## The theme is drawn in greys -- panels, wells, bevels, the text -- and this
## moves all of them together, keeping how light or dark each one was and
## giving them the hue and saturation of whatever was picked. Pick a grey and
## nothing changes; pick a blue and the whole interface is blue with the accent
## still sitting on top of it.
##
## It is the mirror of Accent, and deliberately separate: the accent is matched
## by exact value against the ramp the theme was baked with, while a neutral is
## recognised by having almost no colour in it at all.

signal secondary_changed(color: Color)

## Anything less colourful than this counts as a neutral and gets moved.
const NEUTRAL_S := 0.16

var _applied := CdPalette.SECONDARY_DEFAULT
## The theme as it was baked, so every change starts from the original rather
## than tinting an already tinted interface.
var _base_colors := {}
var _base_boxes := {}
var _base_textures := {}


func _ready() -> void:
	var want := Color(String(Settings.get_value("secondary", "#454545")))
	if not want.is_equal_approx(CdPalette.SECONDARY_DEFAULT):
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
	if color.is_equal_approx(_applied):
		return
	_applied = color
	CdPalette.set_secondary(color)
	var theme := ThemeDB.get_project_theme()
	if theme != null:
		_remember(theme)
		_retint(theme, color)
	Icons.clear_cache()
	# Controls wearing a tightened copy of a theme style have to be given a
	# fresh copy: theirs was made from the colours as they were.
	Cd.recompact()
	if save:
		Settings.set_value("secondary", "#" + color.to_html(false))
	secondary_changed.emit(color)


## The theme's own colours, kept once so that every later change is applied to
## what was baked rather than to the last tint.
func _remember(theme: Theme) -> void:
	if not _base_colors.is_empty():
		return
	for type_name in theme.get_type_list():
		for cname in theme.get_color_list(type_name):
			_base_colors["%s/%s" % [type_name, cname]] = theme.get_color(cname, type_name)
		for sname in theme.get_stylebox_list(type_name):
			var sb := theme.get_stylebox(sname, type_name)
			var key := "%s/%s" % [type_name, sname]
			if sb is StyleBoxFlat:
				_base_boxes[key] = [sb.bg_color, sb.border_color]
			elif sb is StyleBoxTexture:
				_base_boxes[key] = [(sb as StyleBoxTexture).modulate_color, Color.WHITE]


func _retint(theme: Theme, color: Color) -> void:
	var touched := _hold(theme)
	for type_name in theme.get_type_list():
		for cname in theme.get_color_list(type_name):
			var key := "%s/%s" % [type_name, cname]
			if _base_colors.has(key):
				theme.set_color(cname, type_name, _tint(_base_colors[key], color))
		for sname in theme.get_stylebox_list(type_name):
			var key := "%s/%s" % [type_name, sname]
			var sb := theme.get_stylebox(sname, type_name)
			if sb is StyleBoxFlat and _base_boxes.has(key):
				sb.bg_color = _tint(_base_boxes[key][0], color)
				sb.border_color = _tint(_base_boxes[key][1], color)
			elif sb is StyleBoxTexture and _base_boxes.has(key):
				# Multiplied rather than repainted: the panel textures are grey,
				# and grey times a colour is that colour at the same relative
				# brightness. Rewriting several thousand pixels for every frame
				# of a colour picker being dragged is what made this crawl.
				var t := (sb as StyleBoxTexture)
				if String(t.texture.resource_path if t.texture else "").contains("accent"):
					continue      # the accent's own ramp; Accent owns that one
				var base_mod: Color = _base_boxes[key][0]
				var m := _modulate(color)
				t.modulate_color = Color(base_mod.r * m.r, base_mod.g * m.g,
						base_mod.b * m.b, base_mod.a)
	_release(theme, touched)


## A neutral moves; anything with colour in it -- the accent's ramp, the
## meters, the record light -- is left exactly where it was.
func _tint(c: Color, sec: Color) -> Color:
	if c.a < 0.004 or c.s > NEUTRAL_S:
		return c
	var t := CdPalette.tint_neutral(c, sec)
	return Color(t.r, t.g, t.b, c.a)


## What to multiply a grey texture by so it comes out at the secondary's hue
## and saturation, keeping how light it was.
func _modulate(sec: Color) -> Color:
	var ref := CdPalette.SECONDARY_DEFAULT.v
	var lift: float = clampf(sec.v / maxf(0.01, ref), 0.0, 4.0)
	if sec.s < 0.005:
		return Color(lift, lift, lift, 1.0)
	var hue := Color.from_hsv(sec.h, sec.s, 1.0, 1.0)
	# Averaged back to one, so a saturated tint does not also darken everything.
	var mean: float = maxf(0.001, (hue.r + hue.g + hue.b) / 3.0)
	return Color(hue.r / mean * lift, hue.g / mean * lift, hue.b / mean * lift, 1.0)


func _tint_texture(base: Image, sec: Color) -> ImageTexture:
	var img: Image = base.duplicate()
	if img.is_compressed():
		img.decompress()
	for y in img.get_height():
		for x in img.get_width():
			var c: Color = img.get_pixel(x, y)
			if c.a < 0.004 or c.s > NEUTRAL_S:
				continue
			img.set_pixel(x, y, Color(CdPalette.tint_neutral(c, sec), c.a))
	return ImageTexture.create_from_image(img)


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
