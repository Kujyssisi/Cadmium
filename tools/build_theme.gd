extends SceneTree
## Builds res://themes/cadmium_theme.tres plus the 9-patch textures it uses.
##
## Two passes: the first writes res://themes/tex/*.png and stops (Godot has to
## import them), the second builds the theme. Run:
##   godot --headless --path <project> --script res://tools/build_theme.gd
##   godot --headless --path <project> --import
##   godot --headless --path <project> --script res://tools/build_theme.gd
##
## The look follows Source 2 Hammer: neutral grey, square corners, bevelled
## controls, dense metrics, red selection.

const OUT := "res://themes/cadmium_theme.tres"
const TEX := "res://themes/tex"

const WINDOW    := Color("#3f3f3f")
const PANEL     := Color("#454545")
const PANEL_ALT := Color("#4d4d4d")
const CAPTION   := Color("#565656")
const SUNKEN    := Color("#2b2b2b")
const WELL      := Color("#252525")
const RULE      := Color("#2a2a2a")
const BEVEL_HI  := Color("#6e6e6e")
const BEVEL_LO  := Color("#343434")
const TEXT      := Color("#e2e2e2")
const TEXT_DIM  := Color("#b4b4b4")
const TEXT_MUTE := Color("#8a8a8a")
const ACCENT    := Color("#e0483c")
const ACCENT_D  := Color("#a82f26")
const FOCUS     := Color("#4a90d9")
const BAD       := Color("#e06666")

const PATCH := 14      ## texture size
const MARGIN := 5      ## 9-patch margin

var theme := Theme.new()


func _initialize() -> void:
	var a := _write_textures()
	var b := _write_widget_icons()
	if a or b:
		print("Cadmium: wrote theme textures -- run --import, then this script again")
		quit()
		return
	_fonts()
	_panels()
	_buttons()
	_inputs()
	_lists()
	_bars()
	_popups()
	_misc()
	var err := ResourceSaver.save(theme, OUT)
	if err != OK:
		printerr("theme save failed: ", err)
	else:
		print("Cadmium: theme written to ", OUT)
	quit()


# ---------------------------------------------------------------------------
# 9-patch generation
# ---------------------------------------------------------------------------

## Returns true when textures had to be created (so the caller should stop).
func _write_textures() -> bool:
	DirAccess.make_dir_recursive_absolute(TEX)
	var specs := {
		"btn_normal":   [Color("#5f5f5f"), Color("#4a4a4a"), true,  RULE],
		"btn_hover":    [Color("#6d6d6d"), Color("#575757"), true,  RULE],
		"btn_pressed":  [Color("#3a3a3a"), Color("#464646"), false, RULE],
		"btn_disabled": [Color("#4a4a4a"), Color("#454545"), true,  Color("#383838")],
		"btn_accent":   [Color("#ee6a5c"), Color("#c8382c"), true,  Color("#7a1c15")],
		"btn_danger":   [Color("#a85050"), Color("#8a3c3c"), true,  Color("#5e2626")],
		"caption":      [Color("#5c5c5c"), Color("#4e4e4e"), true,  RULE],
		"panel":        [PANEL, PANEL, false, RULE],
		"panel_alt":    [PANEL_ALT, PANEL_ALT, false, RULE],
		"tab_active":   [Color("#565656"), Color("#484848"), true,  RULE],
		"tab_idle":     [Color("#3d3d3d"), Color("#373737"), false, RULE],
	}
	var made := false
	for name in specs.keys():
		var path := TEX.path_join(String(name) + ".png")
		if FileAccess.file_exists(path):
			continue
		var s: Array = specs[name]
		_bevel_image(s[0], s[1], bool(s[2]), s[3]).save_png(path)
		made = true
	# inset well (for text fields and lists)
	var well_path := TEX.path_join("well.png")
	if not FileAccess.file_exists(well_path):
		_inset_image(WELL).save_png(well_path)
		made = true
	var sunken_path := TEX.path_join("sunken.png")
	if not FileAccess.file_exists(sunken_path):
		_inset_image(SUNKEN).save_png(sunken_path)
		made = true
	return made


## Vertical gradient face with a top highlight, bottom shade and a hard border.
func _bevel_image(top: Color, bottom: Color, raised: bool, border: Color) -> Image:
	var img := Image.create_empty(PATCH, PATCH, false, Image.FORMAT_RGBA8)
	for y in PATCH:
		var t := float(y) / float(PATCH - 1)
		var c := top.lerp(bottom, t)
		for x in PATCH:
			img.set_pixel(x, y, c)
	for x in PATCH:
		img.set_pixel(x, 0, border)
		img.set_pixel(x, PATCH - 1, border)
	for y in PATCH:
		img.set_pixel(0, y, border)
		img.set_pixel(PATCH - 1, y, border)
	var hi := BEVEL_HI if raised else BEVEL_LO
	var lo := BEVEL_LO if raised else BEVEL_HI
	for x in range(1, PATCH - 1):
		img.set_pixel(x, 1, hi)
		img.set_pixel(x, PATCH - 2, lo)
	for y in range(1, PATCH - 1):
		img.set_pixel(1, y, img.get_pixel(1, y).lerp(hi, 0.5))
		img.set_pixel(PATCH - 2, y, img.get_pixel(PATCH - 2, y).lerp(lo, 0.5))
	return img


## Flat fill with an inset (dark top-left, light bottom-right) border.
func _inset_image(fill: Color) -> Image:
	var img := Image.create_empty(PATCH, PATCH, false, Image.FORMAT_RGBA8)
	img.fill(fill)
	for x in PATCH:
		img.set_pixel(x, 0, Color("#1c1c1c"))
		img.set_pixel(x, PATCH - 1, Color("#565656"))
	for y in PATCH:
		img.set_pixel(0, y, Color("#1c1c1c"))
		img.set_pixel(PATCH - 1, y, Color("#565656"))
	return img


# ---------------------------------------------------------------------------
# Widget icons (checks, radios, slider grabbers, arrows)
#
# These are drawn at their real pixel size rather than scaled from an SVG:
# Godot draws theme icons at texture size, and a crisp 1 px bevel is exactly the
# look the reference UI has.
# ---------------------------------------------------------------------------

func _px(w: int, h: int) -> Image:
	var img := Image.create_empty(w, h, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	return img


func _fill_rect(img: Image, x: int, y: int, w: int, h: int, c: Color) -> void:
	for yy in range(y, y + h):
		for xx in range(x, x + w):
			if xx >= 0 and yy >= 0 and xx < img.get_width() and yy < img.get_height():
				img.set_pixel(xx, yy, c)


func _frame_rect(img: Image, x: int, y: int, w: int, h: int, top: Color, bottom: Color) -> void:
	for xx in range(x, x + w):
		img.set_pixel(xx, y, top)
		img.set_pixel(xx, y + h - 1, bottom)
	for yy in range(y, y + h):
		img.set_pixel(x, yy, top)
		img.set_pixel(x + w - 1, yy, bottom)


func _line(img: Image, x0: int, y0: int, x1: int, y1: int, c: Color, thick: int = 1) -> void:
	var dx := absi(x1 - x0)
	var dy := -absi(y1 - y0)
	var sx := 1 if x0 < x1 else -1
	var sy := 1 if y0 < y1 else -1
	var err := dx + dy
	var x := x0
	var y := y0
	while true:
		_fill_rect(img, x, y, thick, thick, c)
		if x == x1 and y == y1:
			break
		var e2 := 2 * err
		if e2 >= dy:
			err += dy
			x += sx
		if e2 <= dx:
			err += dx
			y += sy


## Solid triangle pointing 0=down 1=up 2=right 3=left, filling the image.
func _triangle(img: Image, dir: int, c: Color) -> void:
	var w := img.get_width()
	var h := img.get_height()
	if dir <= 1:
		for row in h:
			var r := row if dir == 0 else (h - 1 - row)
			var inset := int(round(float(row) * float(w) * 0.5 / float(h)))
			_fill_rect(img, inset, r, maxi(w - inset * 2, 1), 1, c)
	else:
		for col in w:
			# dir 2 points right: the wide edge is at x=0, the point at x=w-1
			var cc := col if dir == 2 else (w - 1 - col)
			var inset := int(round(float(col) * float(h) * 0.5 / float(w)))
			_fill_rect(img, cc, inset, 1, maxi(h - inset * 2, 1), c)


func _check_box(on: bool, dim: bool) -> Image:
	var img := _px(18, 18)
	var face := Color("#232323") if not dim else Color("#3a3a3a")
	_fill_rect(img, 1, 2, 15, 15, face)
	_frame_rect(img, 1, 2, 15, 15, Color("#1a1a1a"), Color("#5e5e5e"))
	if on:
		var c := ACCENT if not dim else Color("#7a6640")
		_line(img, 4, 9, 7, 12, c, 2)
		_line(img, 7, 12, 13, 5, c, 2)
	return img


func _radio(on: bool, dim: bool) -> Image:
	var img := _px(18, 18)
	var face := Color("#232323") if not dim else Color("#3a3a3a")
	var cx := 8.5
	var cy := 9.5
	for y in 18:
		for x in 18:
			var d := Vector2(float(x) - cx, float(y) - cy).length()
			if d <= 7.0:
				img.set_pixel(x, y, face)
			if d > 6.0 and d <= 7.4:
				img.set_pixel(x, y, Color("#1a1a1a") if y < 9 else Color("#5e5e5e"))
	if on:
		var c := ACCENT if not dim else Color("#7a6640")
		for y in 18:
			for x in 18:
				if Vector2(float(x) - cx, float(y) - cy).length() <= 3.4:
					img.set_pixel(x, y, c)
	return img


## Bevelled handle, vertical for an HSlider.
func _grabber(w: int, h: int, hot: bool, dim: bool) -> Image:
	var img := _px(w, h)
	var top := Color("#6d6d6d") if hot else Color("#5f5f5f")
	var bot := Color("#4a4a4a")
	if dim:
		top = Color("#4a4a4a")
		bot = Color("#444444")
	for y in h:
		var t := float(y) / float(maxi(h - 1, 1))
		_fill_rect(img, 0, y, w, 1, top.lerp(bot, t))
	_frame_rect(img, 0, 0, w, h, RULE, RULE)
	for x in range(1, w - 1):
		img.set_pixel(x, 1, BEVEL_HI)
		img.set_pixel(x, h - 2, BEVEL_LO)
	if hot:
		var mid := h / 2
		_fill_rect(img, 2, mid - 1, w - 4, 1, ACCENT)
	return img


func _switch(on: bool, dim: bool) -> Image:
	var img := _px(34, 18)
	var track := Color("#232323") if not on else Color(ACCENT_D, 1.0)
	if dim:
		track = Color("#3a3a3a")
	_fill_rect(img, 1, 4, 32, 11, track)
	_frame_rect(img, 1, 4, 32, 11, Color("#1a1a1a"), Color("#5e5e5e"))
	var kx := 18 if on else 2
	var knob := _grabber(14, 16, false, dim)
	img.blend_rect(knob, Rect2i(0, 0, 14, 16), Vector2i(kx, 1))
	return img


func _arrow_img(w: int, h: int, dir: int, c: Color) -> Image:
	var img := _px(w, h)
	_triangle(img, dir, c)
	return img


func _cross(size: int, c: Color) -> Image:
	var img := _px(size, size)
	_line(img, 3, 3, size - 4, size - 4, c, 2)
	_line(img, size - 4, 3, 3, size - 4, c, 2)
	return img


func _updown() -> Image:
	var img := _px(12, 20)
	var up := _arrow_img(9, 6, 1, TEXT_DIM)
	var dn := _arrow_img(9, 6, 0, TEXT_DIM)
	img.blend_rect(up, Rect2i(0, 0, 9, 6), Vector2i(2, 3))
	img.blend_rect(dn, Rect2i(0, 0, 9, 6), Vector2i(2, 11))
	return img


func _write_widget_icons() -> bool:
	DirAccess.make_dir_recursive_absolute(TEX)
	var jobs := {
		"check_on": func() -> Image: return _check_box(true, false),
		"check_off": func() -> Image: return _check_box(false, false),
		"check_on_dim": func() -> Image: return _check_box(true, true),
		"check_off_dim": func() -> Image: return _check_box(false, true),
		"radio_on": func() -> Image: return _radio(true, false),
		"radio_off": func() -> Image: return _radio(false, false),
		"radio_on_dim": func() -> Image: return _radio(true, true),
		"radio_off_dim": func() -> Image: return _radio(false, true),
		"switch_on": func() -> Image: return _switch(true, false),
		"switch_off": func() -> Image: return _switch(false, false),
		"switch_on_dim": func() -> Image: return _switch(true, true),
		"switch_off_dim": func() -> Image: return _switch(false, true),
		"grab_h": func() -> Image: return _grabber(11, 19, false, false),
		"grab_h_hot": func() -> Image: return _grabber(11, 19, true, false),
		"grab_h_dim": func() -> Image: return _grabber(11, 19, false, true),
		"grab_v": func() -> Image: return _grabber(19, 11, false, false),
		"grab_v_hot": func() -> Image: return _grabber(19, 11, true, false),
		"arrow_dn": func() -> Image: return _arrow_img(11, 7, 0, TEXT_DIM),
		"arrow_rt": func() -> Image: return _arrow_img(7, 11, 2, TEXT_DIM),
		"arrow_dn_sm": func() -> Image: return _arrow_img(9, 6, 0, TEXT_DIM),
		"arrow_rt_sm": func() -> Image: return _arrow_img(6, 9, 2, TEXT_DIM),
		"arrow_lf_sm": func() -> Image: return _arrow_img(6, 9, 3, TEXT_DIM),
		"menu_check": func() -> Image: return _menu_check(),
		"menu_radio": func() -> Image: return _menu_radio(),
		"blank16": func() -> Image: return _px(16, 16),
		"clear_x": func() -> Image: return _cross(14, TEXT_MUTE),
		"tab_x": func() -> Image: return _cross(13, TEXT_DIM),
		"updown": func() -> Image: return _updown(),
		"tick": func() -> Image: return _tick(),
	}
	var made := false
	for name in jobs.keys():
		var path := TEX.path_join(String(name) + ".png")
		if FileAccess.file_exists(path):
			continue
		((jobs[name] as Callable).call() as Image).save_png(path)
		made = true
	return made


func _menu_check() -> Image:
	var img := _px(16, 16)
	_line(img, 3, 8, 6, 11, ACCENT, 2)
	_line(img, 6, 11, 12, 4, ACCENT, 2)
	return img


func _menu_radio() -> Image:
	var img := _px(16, 16)
	for y in 16:
		for x in 16:
			if Vector2(float(x) - 7.5, float(y) - 7.5).length() <= 3.6:
				img.set_pixel(x, y, ACCENT)
	return img


func _tick() -> Image:
	var img := _px(2, 5)
	img.fill(Color(1, 1, 1, 0.22))
	return img


func _ico(name: String) -> Texture2D:
	return load(TEX.path_join(name + ".png"))


func _tex(name: String, mh: int = 8, mv: int = 4) -> StyleBoxTexture:
	var s := StyleBoxTexture.new()
	s.texture = load(TEX.path_join(name + ".png"))
	s.set_texture_margin_all(MARGIN)
	s.content_margin_left = mh
	s.content_margin_right = mh
	s.content_margin_top = mv
	s.content_margin_bottom = mv
	return s


func _flat(bg: Color, border: int = 0, bc: Color = RULE, mh: int = 0, mv: int = 0) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = bg
	s.set_corner_radius_all(0)
	s.set_border_width_all(border)
	s.border_color = bc
	s.content_margin_left = mh
	s.content_margin_right = mh
	s.content_margin_top = mv
	s.content_margin_bottom = mv
	s.anti_aliasing = false
	return s


func _empty(mh: int = 0, mv: int = 0) -> StyleBoxEmpty:
	var s := StyleBoxEmpty.new()
	s.content_margin_left = mh
	s.content_margin_right = mh
	s.content_margin_top = mv
	s.content_margin_bottom = mv
	return s


# ---------------------------------------------------------------------------
func _fonts() -> void:
	var regular: Font = load("res://fonts/Roboto-Regular.ttf")
	var medium: Font = load("res://fonts/Roboto-Medium.ttf")
	var bold: Font = load("res://fonts/Roboto-Bold.ttf")
	var mono: Font = load("res://fonts/NotoSansMono-Regular.ttf")
	theme.default_font = regular
	theme.default_font_size = 12

	var variants := {
		"Header":       [bold, 13, TEXT],
		"SectionLabel": [medium, 11, TEXT_DIM],
		"DimLabel":     [regular, 11, TEXT_DIM],
		"MuteLabel":    [regular, 11, TEXT_MUTE],
		"MonoLabel":    [mono, 11, TEXT],
		"BigTime":      [mono, 15, ACCENT],
		"Caption":      [medium, 11, TEXT],
	}
	for name in variants.keys():
		var v: Array = variants[name]
		theme.add_type(name)
		theme.set_type_variation(name, "Label")
		theme.set_font("font", name, v[0])
		theme.set_font_size("font_size", name, v[1])
		theme.set_color("font_color", name, v[2])

	theme.set_color("font_color", "Label", TEXT)
	theme.set_color("font_outline_color", "Label", Color(0, 0, 0, 0))


func _panels() -> void:
	theme.set_stylebox("panel", "Panel", _flat(WINDOW))
	theme.set_stylebox("panel", "PanelContainer", _tex("panel", 0, 0))

	theme.add_type("Dock")
	theme.set_type_variation("Dock", "PanelContainer")
	theme.set_stylebox("panel", "Dock", _tex("panel", 0, 0))

	# A dialog is a window of its own: its content must not sit against the
	# frame the way a docked panel sits against its neighbours.
	theme.add_type("Dialog")
	theme.set_type_variation("Dialog", "PanelContainer")
	theme.set_stylebox("panel", "Dialog", _tex("panel", 12, 10))

	theme.add_type("DarkPanel")
	theme.set_type_variation("DarkPanel", "PanelContainer")
	theme.set_stylebox("panel", "DarkPanel", _tex("sunken", 0, 0))

	theme.add_type("Card")
	theme.set_type_variation("Card", "PanelContainer")
	theme.set_stylebox("panel", "Card", _tex("panel_alt", 5, 4))

	theme.add_type("CaptionBar")
	theme.set_type_variation("CaptionBar", "PanelContainer")
	theme.set_stylebox("panel", "CaptionBar", _tex("caption", 5, 2))

	theme.add_type("Toolbar")
	theme.set_type_variation("Toolbar", "PanelContainer")
	var tb := _flat(WINDOW, 0)
	tb.border_width_bottom = 1
	tb.border_color = RULE
	tb.content_margin_left = 4
	tb.content_margin_right = 4
	tb.content_margin_top = 3
	tb.content_margin_bottom = 3
	theme.set_stylebox("panel", "Toolbar", tb)

	theme.add_type("StatusBar")
	theme.set_type_variation("StatusBar", "PanelContainer")
	var sb := _flat(WINDOW, 0)
	sb.border_width_top = 1
	sb.border_color = RULE
	sb.content_margin_left = 6
	sb.content_margin_right = 6
	sb.content_margin_top = 2
	sb.content_margin_bottom = 2
	theme.set_stylebox("panel", "StatusBar", sb)


func _buttons() -> void:
	for t in ["Button", "MenuButton", "OptionButton"]:
		theme.set_stylebox("normal", t, _tex("btn_normal", 9, 4))
		theme.set_stylebox("hover", t, _tex("btn_hover", 9, 4))
		theme.set_stylebox("pressed", t, _tex("btn_pressed", 9, 4))
		theme.set_stylebox("disabled", t, _tex("btn_disabled", 9, 4))
		theme.set_stylebox("focus", t, _flat(Color(0, 0, 0, 0), 1, FOCUS, 9, 4))
		theme.set_color("font_color", t, TEXT)
		theme.set_color("font_hover_color", t, Color.WHITE)
		theme.set_color("font_pressed_color", t, ACCENT)
		theme.set_color("font_disabled_color", t, TEXT_MUTE)
		theme.set_color("font_focus_color", t, Color.WHITE)
		# Icons carry their own colour now, so they are not tinted -- only
		# brightened on hover and faded when disabled.
		theme.set_color("icon_normal_color", t, Color.WHITE)
		theme.set_color("icon_hover_color", t, Color(1.18, 1.18, 1.18))
		theme.set_color("icon_pressed_color", t, Color(1.1, 1.1, 1.1))
		theme.set_color("icon_disabled_color", t, Color(1, 1, 1, 0.32))
		theme.set_constant("h_separation", t, 5)
		theme.set_constant("icon_max_width", t, 18)
	theme.set_icon("arrow", "OptionButton", _ico("arrow_dn"))
	theme.set_constant("arrow_margin", "OptionButton", 4)
	theme.set_constant("modulate_arrow", "OptionButton", 1)

	theme.add_type("Flat")
	theme.set_type_variation("Flat", "Button")
	theme.set_stylebox("normal", "Flat", _empty(4, 3))
	theme.set_stylebox("hover", "Flat", _tex("btn_hover", 4, 3))
	theme.set_stylebox("pressed", "Flat", _tex("btn_pressed", 4, 3))
	theme.set_stylebox("disabled", "Flat", _empty(4, 3))
	theme.set_stylebox("focus", "Flat", _empty(4, 3))
	theme.set_color("font_color", "Flat", TEXT_DIM)
	theme.set_color("font_hover_color", "Flat", Color.WHITE)
	theme.set_color("font_pressed_color", "Flat", ACCENT)
	theme.set_color("icon_normal_color", "Flat", Color(1, 1, 1, 0.92))
	theme.set_color("icon_hover_color", "Flat", Color(1.2, 1.2, 1.2))
	theme.set_color("icon_pressed_color", "Flat", Color(1.1, 1.1, 1.1))
	theme.set_color("icon_disabled_color", "Flat", Color(1, 1, 1, 0.3))
	theme.set_constant("icon_max_width", "Flat", 17)

	theme.add_type("Micro")
	theme.set_type_variation("Micro", "Button")
	theme.set_stylebox("normal", "Micro", _empty(1, 1))
	theme.set_stylebox("hover", "Micro", _flat(Color(1, 1, 1, 0.10), 0, RULE, 1, 1))
	theme.set_stylebox("pressed", "Micro", _flat(Color(ACCENT, 0.22), 0, RULE, 1, 1))
	theme.set_stylebox("disabled", "Micro", _empty(1, 1))
	theme.set_stylebox("focus", "Micro", _empty(1, 1))
	theme.set_color("icon_normal_color", "Micro", Color(1, 1, 1, 0.85))
	theme.set_color("icon_hover_color", "Micro", Color(1.25, 1.25, 1.25))
	theme.set_color("icon_pressed_color", "Micro", Color(1.15, 1.15, 1.15))
	theme.set_constant("icon_max_width", "Micro", 14)

	theme.add_type("Accent")
	theme.set_type_variation("Accent", "Button")
	theme.set_stylebox("normal", "Accent", _tex("btn_accent", 10, 4))
	theme.set_stylebox("hover", "Accent", _tex("btn_accent", 10, 4))
	theme.set_stylebox("pressed", "Accent", _tex("btn_pressed", 10, 4))
	theme.set_stylebox("disabled", "Accent", _tex("btn_disabled", 10, 4))
	theme.set_color("font_color", "Accent", Color("#2a0d0a"))
	theme.set_color("font_hover_color", "Accent", Color("#000000"))
	theme.set_color("font_pressed_color", "Accent", ACCENT)
	theme.set_color("font_disabled_color", "Accent", TEXT_MUTE)
	# On the red button a colour icon turns to mud, so it reads as a silhouette.
	theme.set_color("icon_normal_color", "Accent", Color("#2a0d0a"))
	theme.set_color("icon_hover_color", "Accent", Color("#140504"))
	theme.set_color("icon_pressed_color", "Accent", Color("#2a0d0a"))
	theme.set_constant("icon_max_width", "Accent", 18)

	theme.add_type("Danger")
	theme.set_type_variation("Danger", "Button")
	theme.set_stylebox("normal", "Danger", _tex("btn_danger", 9, 4))
	theme.set_stylebox("hover", "Danger", _tex("btn_danger", 9, 4))
	theme.set_stylebox("pressed", "Danger", _tex("btn_pressed", 9, 4))
	theme.set_color("font_color", "Danger", Color("#ffe0e0"))

	theme.add_type("Chip")
	theme.set_type_variation("Chip", "Button")
	theme.set_stylebox("normal", "Chip", _tex("tab_idle", 8, 2))
	theme.set_stylebox("hover", "Chip", _tex("btn_hover", 8, 2))
	theme.set_stylebox("pressed", "Chip", _tex("tab_active", 8, 2))
	theme.set_color("font_color", "Chip", TEXT_DIM)
	theme.set_color("font_hover_color", "Chip", Color.WHITE)
	theme.set_color("font_pressed_color", "Chip", ACCENT)
	theme.set_font_size("font_size", "Chip", 11)

	theme.add_type("Transport")
	theme.set_type_variation("Transport", "Button")
	theme.set_stylebox("normal", "Transport", _tex("btn_normal", 8, 5))
	theme.set_stylebox("hover", "Transport", _tex("btn_hover", 8, 5))
	theme.set_stylebox("pressed", "Transport", _tex("btn_accent", 8, 5))
	theme.set_color("icon_normal_color", "Transport", Color.WHITE)
	theme.set_color("icon_hover_color", "Transport", Color(1.2, 1.2, 1.2))
	theme.set_color("icon_pressed_color", "Transport", Color("#2a0d0a"))
	theme.set_constant("icon_max_width", "Transport", 20)

	for t in ["CheckBox", "CheckButton"]:
		theme.set_stylebox("normal", t, _empty(3, 2))
		theme.set_stylebox("hover", t, _flat(Color(1, 1, 1, 0.06), 0, RULE, 3, 2))
		theme.set_stylebox("pressed", t, _empty(3, 2))
		theme.set_stylebox("focus", t, _empty(3, 2))
		theme.set_stylebox("disabled", t, _empty(3, 2))
		theme.set_color("font_color", t, TEXT_DIM)
		theme.set_color("font_hover_color", t, TEXT)
		theme.set_color("font_pressed_color", t, TEXT)
		theme.set_constant("h_separation", t, 6)
		theme.set_constant("check_v_offset", t, 0)

	theme.set_icon("checked", "CheckBox", _ico("check_on"))
	theme.set_icon("unchecked", "CheckBox", _ico("check_off"))
	theme.set_icon("checked_disabled", "CheckBox", _ico("check_on_dim"))
	theme.set_icon("unchecked_disabled", "CheckBox", _ico("check_off_dim"))
	theme.set_icon("radio_checked", "CheckBox", _ico("radio_on"))
	theme.set_icon("radio_unchecked", "CheckBox", _ico("radio_off"))
	theme.set_icon("radio_checked_disabled", "CheckBox", _ico("radio_on_dim"))
	theme.set_icon("radio_unchecked_disabled", "CheckBox", _ico("radio_off_dim"))

	for suffix in ["", "_mirrored"]:
		theme.set_icon("checked" + suffix, "CheckButton", _ico("switch_on"))
		theme.set_icon("unchecked" + suffix, "CheckButton", _ico("switch_off"))
		theme.set_icon("checked_disabled" + suffix, "CheckButton", _ico("switch_on_dim"))
		theme.set_icon("unchecked_disabled" + suffix, "CheckButton", _ico("switch_off_dim"))


func _inputs() -> void:
	for t in ["LineEdit", "TextEdit", "CodeEdit"]:
		theme.set_stylebox("normal", t, _tex("well", 6, 3))
		theme.set_stylebox("focus", t, _flat(Color(0, 0, 0, 0), 1, FOCUS, 6, 3))
		theme.set_stylebox("read_only", t, _tex("sunken", 6, 3))
		theme.set_color("font_color", t, TEXT)
		theme.set_color("font_placeholder_color", t, TEXT_MUTE)
		theme.set_color("font_selected_color", t, Color("#1c0908"))
		theme.set_color("caret_color", t, ACCENT)
		theme.set_color("selection_color", t, Color(ACCENT, 0.55))
		theme.set_color("background_color", t, WELL)

	theme.set_stylebox("panel", "SpinBox", _empty())
	theme.set_color("font_color", "SpinBox", TEXT)

	# A stylebox with no margins has no minimum size, so the track would not be
	# drawn at all -- give the groove and the fill an explicit height.
	theme.set_stylebox("slider", "HSlider", _flat(Color("#1d1d1d"), 1, Color("#131313"), 0, 3))
	theme.set_stylebox("grabber_area", "HSlider", _flat(ACCENT_D, 0, ACCENT_D, 0, 3))
	theme.set_stylebox("grabber_area_highlight", "HSlider", _flat(ACCENT, 0, ACCENT, 0, 3))
	theme.set_icon("grabber", "HSlider", _ico("grab_h"))
	theme.set_icon("grabber_highlight", "HSlider", _ico("grab_h_hot"))
	theme.set_icon("grabber_disabled", "HSlider", _ico("grab_h_dim"))
	theme.set_icon("tick", "HSlider", _ico("tick"))
	theme.set_constant("grabber_offset", "HSlider", 0)
	theme.set_constant("center_grabber", "HSlider", 0)

	theme.set_stylebox("slider", "VSlider", _flat(Color("#1d1d1d"), 1, Color("#131313"), 3, 0))
	theme.set_stylebox("grabber_area", "VSlider", _flat(ACCENT_D, 0, ACCENT_D, 3, 0))
	theme.set_stylebox("grabber_area_highlight", "VSlider", _flat(ACCENT, 0, ACCENT, 3, 0))
	theme.set_icon("grabber", "VSlider", _ico("grab_v"))
	theme.set_icon("grabber_highlight", "VSlider", _ico("grab_v_hot"))
	theme.set_icon("tick", "VSlider", _ico("tick"))

	theme.set_icon("updown", "SpinBox", _ico("updown"))
	theme.set_icon("clear", "LineEdit", _ico("clear_x"))


func _lists() -> void:
	for t in ["Tree", "ItemList"]:
		theme.set_stylebox("panel", t, _tex("well", 2, 2))
		theme.set_stylebox("focus", t, _flat(Color(0, 0, 0, 0), 1, FOCUS, 2, 2))
		theme.set_stylebox("selected", t, _flat(Color(ACCENT, 0.30), 1, ACCENT_D, 3, 2))
		theme.set_stylebox("selected_focus", t, _flat(Color(ACCENT, 0.42), 1, ACCENT, 3, 2))
		theme.set_stylebox("hovered", t, _flat(Color(1, 1, 1, 0.07), 0, RULE, 3, 2))
		theme.set_stylebox("cursor", t, _flat(Color(0, 0, 0, 0), 1, Color(ACCENT, 0.7), 3, 2))
		theme.set_stylebox("cursor_unfocused", t, _empty())
		theme.set_color("font_color", t, TEXT)
		theme.set_color("font_selected_color", t, Color.WHITE)
		theme.set_color("font_hovered_color", t, Color.WHITE)
		theme.set_color("guide_color", t, Color(1, 1, 1, 0.05))
	theme.set_stylebox("title_button_normal", "Tree", _tex("caption", 5, 3))
	theme.set_stylebox("title_button_hover", "Tree", _tex("btn_hover", 5, 3))
	theme.set_color("title_button_color", "Tree", TEXT_DIM)
	theme.set_icon("arrow", "Tree", _ico("arrow_dn_sm"))
	theme.set_icon("arrow_collapsed", "Tree", _ico("arrow_rt_sm"))
	theme.set_icon("arrow_collapsed_mirrored", "Tree", _ico("arrow_lf_sm"))
	theme.set_icon("checked", "Tree", _ico("check_on"))
	theme.set_icon("unchecked", "Tree", _ico("check_off"))
	theme.set_icon("select_arrow", "Tree", _ico("arrow_dn_sm"))
	theme.set_icon("updown", "Tree", _ico("updown"))
	theme.set_constant("item_margin", "Tree", 12)
	theme.set_constant("v_separation", "Tree", 2)
	theme.set_constant("v_separation", "ItemList", 2)
	theme.set_constant("h_separation", "ItemList", 2)


## A scroll bar is exactly as thick as its styleboxes claim to be, and these
## asked for nothing: every bar in the app was present, flagged visible, and
## zero pixels wide. The grabber still painted -- a StyleBoxTexture draws its
## 9-patch margins outside the rect -- so the horizontal ones looked real while
## having no hit area at all. The track sets the thickness across the bar, the
## grabber sets the shortest it may get along it.
const BAR := 6         ## half the thickness: a 12 unit bar
const GRAB := 7        ## half the shortest grabber, so it stays grabbable


func _bars() -> void:
	for t in ["HScrollBar", "VScrollBar"]:
		var vert: bool = t == "VScrollBar"
		var across: int = BAR if vert else 0
		var down: int = 0 if vert else BAR
		theme.set_stylebox("scroll", t, _flat(WELL, 1, RULE, across, down))
		theme.set_stylebox("scroll_focus", t, _flat(WELL, 1, FOCUS, across, down))
		var gh: int = BAR if vert else GRAB
		var gv: int = GRAB if vert else BAR
		# The grabber is cut from the button face, which is the same grey as the
		# panel behind it -- lifted here so the bar reads as a thumb in a groove
		# instead of a seam.
		var grab := _tex("btn_normal", gh, gv)
		grab.modulate_color = Color(1.34, 1.34, 1.34)
		var grab_hi := _tex("btn_hover", gh, gv)
		grab_hi.modulate_color = Color(1.22, 1.22, 1.22)
		theme.set_stylebox("grabber", t, grab)
		theme.set_stylebox("grabber_highlight", t, grab_hi)
		theme.set_stylebox("grabber_pressed", t, _tex("btn_accent", gh, gv))

	theme.set_stylebox("background", "ProgressBar", _tex("sunken", 0, 0))
	theme.set_stylebox("fill", "ProgressBar", _flat(ACCENT_D, 0, ACCENT_D, 0, 2))
	theme.set_color("font_color", "ProgressBar", TEXT)
	theme.set_font_size("font_size", "ProgressBar", 10)

	theme.set_stylebox("panel", "TabContainer", _tex("panel", 0, 0))
	# The tabs in a dialog hold rows of settings rather than whole panels, and
	# those must not sit against the frame. The main window's tabs keep the
	# flush panel: an arrangement is drawn edge to edge on purpose.
	theme.add_type("DialogTabs")
	theme.set_type_variation("DialogTabs", "TabContainer")
	theme.set_stylebox("panel", "DialogTabs", _tex("panel", 12, 10))
	theme.set_stylebox("tabbar_background", "TabContainer", _flat(Color("#383838")))
	for t in ["TabContainer", "TabBar"]:
		theme.set_stylebox("tab_selected", t, _tex("tab_active", 10, 3))
		theme.set_stylebox("tab_hovered", t, _tex("btn_hover", 10, 3))
		theme.set_stylebox("tab_unselected", t, _tex("tab_idle", 10, 3))
		theme.set_stylebox("tab_disabled", t, _tex("tab_idle", 10, 3))
		theme.set_color("font_selected_color", t, ACCENT)
		theme.set_color("font_unselected_color", t, TEXT_MUTE)
		theme.set_color("font_hovered_color", t, TEXT)
		theme.set_color("drop_mark_color", t, ACCENT)
		theme.set_constant("h_separation", t, 4)
		# Without this a tab icon draws at the texture's own size and towers over
		# the 11px label beside it.
		theme.set_constant("icon_max_width", t, 12)
		theme.set_font_size("font_size", t, 11)
		theme.set_icon("close", t, _ico("tab_x"))
		theme.set_icon("increment", t, _ico("arrow_rt_sm"))
		theme.set_icon("decrement", t, _ico("arrow_lf_sm"))
		theme.set_icon("increment_highlight", t, _ico("arrow_rt_sm"))
		theme.set_icon("decrement_highlight", t, _ico("arrow_lf_sm"))

	for t in ["HSplitContainer", "VSplitContainer"]:
		theme.set_constant("separation", t, 4)
		theme.set_constant("autohide", t, 0)
		theme.set_color("split_bar_background", t, RULE)


func _popups() -> void:
	theme.set_stylebox("panel", "PopupMenu", _tex("panel_alt", 3, 3))
	theme.set_stylebox("hover", "PopupMenu", _flat(Color(ACCENT, 0.32), 1, ACCENT_D, 5, 2))
	theme.set_color("font_color", "PopupMenu", TEXT)
	theme.set_color("font_hover_color", "PopupMenu", Color.WHITE)
	theme.set_color("font_accelerator_color", "PopupMenu", TEXT_MUTE)
	theme.set_color("font_disabled_color", "PopupMenu", TEXT_MUTE)
	theme.set_color("font_separator_color", "PopupMenu", TEXT_DIM)
	theme.set_constant("v_separation", "PopupMenu", 1)
	theme.set_constant("item_start_padding", "PopupMenu", 4)
	theme.set_constant("item_end_padding", "PopupMenu", 4)
	# Without a cap a menu item's icon draws at the texture's own size, which on
	# a 2x display is three times the height of the label beside it. Same reason
	# TabContainer needed one.
	theme.set_constant("icon_max_width", "PopupMenu", 16)
	theme.set_stylebox("separator", "PopupMenu", _flat(RULE))
	theme.set_icon("checked", "PopupMenu", _ico("menu_check"))
	theme.set_icon("unchecked", "PopupMenu", _ico("blank16"))
	theme.set_icon("checked_disabled", "PopupMenu", _ico("blank16"))
	theme.set_icon("unchecked_disabled", "PopupMenu", _ico("blank16"))
	theme.set_icon("radio_checked", "PopupMenu", _ico("menu_radio"))
	theme.set_icon("radio_unchecked", "PopupMenu", _ico("blank16"))
	theme.set_icon("radio_checked_disabled", "PopupMenu", _ico("blank16"))
	theme.set_icon("radio_unchecked_disabled", "PopupMenu", _ico("blank16"))
	theme.set_icon("submenu", "PopupMenu", _ico("arrow_rt_sm"))
	theme.set_icon("submenu_mirrored", "PopupMenu", _ico("arrow_lf_sm"))

	theme.set_stylebox("panel", "PopupPanel", _tex("panel_alt", 6, 6))

	theme.set_stylebox("embedded_border", "Window", _tex("panel", 0, 0))
	theme.set_stylebox("embedded_unfocused_border", "Window", _tex("panel", 0, 0))
	theme.set_color("title_color", "Window", TEXT)
	theme.set_constant("title_height", "Window", 26)
	theme.set_font_size("title_font_size", "Window", 12)

	theme.set_stylebox("panel", "AcceptDialog", _flat(PANEL, 0, RULE, 10, 10))
	theme.set_stylebox("panel", "TooltipPanel", _flat(Color("#2b2b2b"), 1, Color("#6a6a6a"), 7, 4))
	theme.set_color("font_color", "TooltipLabel", TEXT)
	theme.set_font_size("font_size", "TooltipLabel", 11)

	theme.set_stylebox("normal", "MenuBar", _empty(7, 4))
	theme.set_stylebox("hover", "MenuBar", _flat(Color(1, 1, 1, 0.10), 0, RULE, 7, 4))
	theme.set_stylebox("pressed", "MenuBar", _flat(Color(ACCENT, 0.28), 0, RULE, 7, 4))
	theme.set_stylebox("disabled", "MenuBar", _empty(7, 4))
	theme.set_color("font_color", "MenuBar", TEXT_DIM)
	theme.set_color("font_hovered_color", "MenuBar", Color.WHITE)
	theme.set_color("font_pressed_color", "MenuBar", ACCENT)
	theme.set_constant("h_separation", "MenuBar", 0)


func _misc() -> void:
	theme.set_stylebox("panel", "ScrollContainer", _empty())
	theme.set_stylebox("focus", "ScrollContainer", _empty())
	theme.set_constant("separation", "HSeparator", 6)
	theme.set_constant("separation", "VSeparator", 6)
	theme.set_stylebox("separator", "HSeparator", _flat(RULE))
	theme.set_stylebox("separator", "VSeparator", _flat(RULE))

	theme.set_color("font_color", "RichTextLabel", TEXT)
	theme.set_color("default_color", "RichTextLabel", TEXT)
	theme.set_stylebox("normal", "RichTextLabel", _empty())

	theme.set_color("font_color", "ColorPickerButton", TEXT)
	theme.set_stylebox("normal", "ColorPickerButton", _tex("btn_normal", 3, 3))
	theme.set_stylebox("hover", "ColorPickerButton", _tex("btn_hover", 3, 3))
	theme.set_stylebox("pressed", "ColorPickerButton", _tex("btn_pressed", 3, 3))
	theme.set_stylebox("focus", "ColorPickerButton", _empty())
