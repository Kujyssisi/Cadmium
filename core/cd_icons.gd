## Cadmium's pictograms, as SVG source rather than files.
##
## Godot imports an .svg into a CompressedTexture2D whose pixels cannot be
## replaced, so a themed icon set built that way can never be recoloured. These
## are rasterised at the size they are actually drawn at, through
## Image.load_svg_from_string, and the accent colour is substituted first.
##
## `$A` is the primary (red by default), `$D` the dark outline, `$G` a grey fill,
## `$L` a light detail.
class_name CdIcons
extends RefCounted

const SVG := {
"play": '<path d="M7 4.4 19.6 12 7 19.6Z" fill="$A" stroke="$D" stroke-width="1.2" stroke-linejoin="round"/>',
"pause": '<rect x="6.5" y="4.5" width="4" height="15" fill="$A" stroke="$D" stroke-width="1.2"/><rect x="13.5" y="4.5" width="4" height="15" fill="$A" stroke="$D" stroke-width="1.2"/>',
"stop": '<rect x="5.5" y="5.5" width="13" height="13" fill="$G" stroke="$D" stroke-width="1.2"/>',
"record": '<circle cx="12" cy="12" r="6.5" fill="$A" stroke="$D" stroke-width="1.2"/>',
"loop": '<path d="M5 9h11l-3-3M19 15H8l3 3" fill="none" stroke="$A" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"/>',
"metronome": '<path d="M9.5 4h5l3.5 16H6Z" fill="$G" stroke="$D" stroke-width="1.2" stroke-linejoin="round"/><path d="M8 15h8" stroke="$D" stroke-width="1.2"/><path d="M12 18 17 7" stroke="$A" stroke-width="1.8" stroke-linecap="round"/>',
"rewind": '<path d="M11 12 19 6.5v11ZM4 12l7-5.5v11Z" fill="$G" stroke="$D" stroke-width="1.1" stroke-linejoin="round"/>',
"forward": '<path d="M13 12 5 6.5v11ZM20 12l-7-5.5v11Z" fill="$G" stroke="$D" stroke-width="1.1" stroke-linejoin="round"/>',
"skip_start": '<rect x="4" y="5" width="2.4" height="14" fill="$A"/><path d="M20 6.5v11L11 12Z" fill="$G" stroke="$D" stroke-width="1.1" stroke-linejoin="round"/>',
"panic": '<circle cx="12" cy="12" r="7.5" fill="none" stroke="$A" stroke-width="2"/><path d="M12 7.5v6M12 16h.01" stroke="$A" stroke-width="2.2" stroke-linecap="round"/>',

"rack": '<rect x="3.5" y="4.5" width="17" height="4" fill="$G" stroke="$D" stroke-width="1.1"/><rect x="3.5" y="10.5" width="17" height="4" fill="$A" stroke="$D" stroke-width="1.1"/><rect x="3.5" y="16.5" width="17" height="4" fill="$G" stroke="$D" stroke-width="1.1"/>',
"piano": '<rect x="3.5" y="5.5" width="17" height="13" fill="$L" stroke="$D" stroke-width="1.2"/><path d="M7.5 5.5v7h1.8v-7ZM11.6 5.5v7h1.8v-7ZM17 5.5v7h1.8v-7Z" fill="$D"/><path d="M8.5 5.5v13M13.5 5.5v13M18 5.5v13" stroke="$D" stroke-width="0.8"/>',
"playlist": '<rect x="3.5" y="4.5" width="17" height="15" fill="$G" stroke="$D" stroke-width="1.1"/><rect x="5" y="6.5" width="7" height="3" fill="$A"/><rect x="9" y="11" width="9" height="3" fill="$A" opacity="0.75"/><rect x="6" y="15.5" width="6" height="3" fill="$A" opacity="0.55"/>',
"mixer": '<path d="M6 4v16M12 4v16M18 4v16" stroke="$D" stroke-width="1.4"/><rect x="3.6" y="12" width="4.8" height="3.2" fill="$A" stroke="$D" stroke-width="1"/><rect x="9.6" y="7" width="4.8" height="3.2" fill="$A" stroke="$D" stroke-width="1"/><rect x="15.6" y="14" width="4.8" height="3.2" fill="$A" stroke="$D" stroke-width="1"/>',
"browser": '<path d="M3.5 6.5h6l1.6 2h9.4v11h-17Z" fill="$G" stroke="$D" stroke-width="1.2" stroke-linejoin="round"/><path d="M3.5 12h17" stroke="$D" stroke-width="0.9"/>',
"plugin": '<rect x="5.5" y="8.5" width="13" height="11" fill="$G" stroke="$D" stroke-width="1.2"/><path d="M9 8.5V5M15 8.5V5" stroke="$A" stroke-width="2" stroke-linecap="round"/><circle cx="12" cy="14" r="2.6" fill="$A" stroke="$D" stroke-width="1"/>',
"wave": '<path d="M3 12h2l1.5-5 2 10 2-13 2 16 2-11 1.5 5H21" fill="none" stroke="$A" stroke-width="1.6" stroke-linejoin="round" stroke-linecap="round"/>',
"automation": '<path d="M3.5 18C7 18 8 7 12 7s5 11 8.5 11" fill="none" stroke="$A" stroke-width="1.8"/><circle cx="12" cy="7" r="2" fill="$A" stroke="$D" stroke-width="1"/><circle cx="3.5" cy="18" r="1.6" fill="$G" stroke="$D" stroke-width="1"/>',
"note": '<path d="M10 17.5V6l8-2v11" fill="none" stroke="$D" stroke-width="1.3"/><ellipse cx="7.5" cy="17.5" rx="3.2" ry="2.4" fill="$A" stroke="$D" stroke-width="1.1"/><ellipse cx="15.5" cy="15" rx="3.2" ry="2.4" fill="$A" stroke="$D" stroke-width="1.1"/>',

"synth": '<rect x="3.5" y="6.5" width="17" height="11" rx="1" fill="$G" stroke="$D" stroke-width="1.2"/><circle cx="8" cy="10.5" r="1.8" fill="$A"/><circle cx="13" cy="10.5" r="1.8" fill="$A"/><path d="M6 15h12" stroke="$L" stroke-width="1.4"/><rect x="16.5" y="8.7" width="2.4" height="3.6" fill="$L"/>',
"drum": '<ellipse cx="12" cy="8" rx="8" ry="3.2" fill="$L" stroke="$D" stroke-width="1.1"/><path d="M4 8v7c0 1.8 3.6 3.2 8 3.2s8-1.4 8-3.2V8" fill="$A" stroke="$D" stroke-width="1.1"/>',
"sampler": '<rect x="3.5" y="5.5" width="17" height="13" fill="$G" stroke="$D" stroke-width="1.2"/><path d="M5.5 12h2l1-3 1.5 6 1.5-8 1.5 10 1.5-5h4" fill="none" stroke="$A" stroke-width="1.4"/>',
"fx": '<circle cx="8" cy="12" r="4.5" fill="none" stroke="$A" stroke-width="1.8"/><circle cx="16" cy="12" r="4.5" fill="none" stroke="$L" stroke-width="1.8"/>',
"eq": '<path d="M4 20V9M10 20V4M16 20v-9M4 9h.01" stroke="$L" stroke-width="1.6"/><path d="M4 20V9M10 20V4M16 20v-9" stroke="$L" stroke-width="1.6"/><circle cx="4" cy="9" r="2" fill="$A"/><circle cx="10" cy="4.5" r="2" fill="$A"/><circle cx="16" cy="11" r="2" fill="$A"/><path d="M20 20V6" stroke="$L" stroke-width="1.6"/><circle cx="20" cy="6" r="2" fill="$A"/>',
"midi": '<circle cx="12" cy="12" r="8.5" fill="$G" stroke="$D" stroke-width="1.2"/><circle cx="12" cy="7.5" r="1.3" fill="$A"/><circle cx="8" cy="9.5" r="1.3" fill="$A"/><circle cx="16" cy="9.5" r="1.3" fill="$A"/><circle cx="7" cy="14" r="1.3" fill="$A"/><circle cx="17" cy="14" r="1.3" fill="$A"/>',
"vst": '<rect x="3.5" y="5.5" width="17" height="13" rx="1" fill="$G" stroke="$D" stroke-width="1.2"/><path d="M6.5 9 9 15l2.5-6" fill="none" stroke="$A" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"/><path d="M13.5 9h4M15.5 9v6" stroke="$A" stroke-width="1.8" stroke-linecap="round"/>',
"soundfont": '<path d="M6 18.5V6l12-2.2v12.5" fill="none" stroke="$D" stroke-width="1.3"/><ellipse cx="5" cy="18.5" rx="2.6" ry="2" fill="$A" stroke="$D" stroke-width="1"/><ellipse cx="17" cy="16.3" rx="2.6" ry="2" fill="$A" stroke="$D" stroke-width="1"/><path d="M6 9.5 18 7.3" stroke="$D" stroke-width="1.3"/>',

"pencil": '<path d="m4 20 1-4.2L15.6 5.2l3.2 3.2L8.2 19Z" fill="$A" stroke="$D" stroke-width="1.1" stroke-linejoin="round"/>',
"eraser": '<path d="m4.5 15.5 7-7 6 6-4 4h-5.5Z" fill="$L" stroke="$D" stroke-width="1.2" stroke-linejoin="round"/><path d="M11.5 8.5 15 5l6 6-3.5 3.5" fill="$A" stroke="$D" stroke-width="1.2" stroke-linejoin="round"/>',
"select": '<path d="M6 3.5 18.5 12 13 13.2l3 6-2.6 1.3-3-6L6 18Z" fill="$G" stroke="$D" stroke-width="1.1" stroke-linejoin="round"/>',
"slice": '<path d="M5 20 19 4" stroke="$A" stroke-width="2" stroke-linecap="round"/><path d="M9 4v16" stroke="$L" stroke-width="1.2" stroke-dasharray="2 2"/>',
"magnet": '<path d="M6 18V11a6 6 0 0 1 12 0v7h-4v-7a2 2 0 0 0-4 0v7Z" fill="$G" stroke="$D" stroke-width="1.2" stroke-linejoin="round"/><path d="M6 18h4M14 18h4" stroke="$A" stroke-width="2.4"/>',
"zoom_in": '<circle cx="10.5" cy="10.5" r="6" fill="none" stroke="$L" stroke-width="1.8"/><path d="M15 15 20 20" stroke="$L" stroke-width="2" stroke-linecap="round"/><path d="M8 10.5h5M10.5 8v5" stroke="$A" stroke-width="1.8" stroke-linecap="round"/>',
"zoom_out": '<circle cx="10.5" cy="10.5" r="6" fill="none" stroke="$L" stroke-width="1.8"/><path d="M15 15 20 20" stroke="$L" stroke-width="2" stroke-linecap="round"/><path d="M8 10.5h5" stroke="$A" stroke-width="1.8" stroke-linecap="round"/>',

"new": '<path d="M6 3.5h8L18.5 8v12.5h-13Z" fill="$G" stroke="$D" stroke-width="1.2" stroke-linejoin="round"/><path d="M13.5 3.5V8h5" fill="none" stroke="$D" stroke-width="1.1"/><path d="M12 11v6M9 14h6" stroke="$A" stroke-width="1.8" stroke-linecap="round"/>',
"open": '<path d="M3 19V6h6l1.6 2H21v3H3" fill="$G" stroke="$D" stroke-width="1.2" stroke-linejoin="round"/><path d="M3 19 6 11h18l-3 8Z" fill="$A" stroke="$D" stroke-width="1.2" stroke-linejoin="round"/>',
"save": '<path d="M4.5 4.5h12L19.5 7.5v12h-15Z" fill="$G" stroke="$D" stroke-width="1.2" stroke-linejoin="round"/><rect x="7.5" y="4.5" width="7" height="5" fill="$A" stroke="$D" stroke-width="1"/><rect x="7" y="12.5" width="10" height="7" fill="$L" stroke="$D" stroke-width="1"/>',
"export": '<path d="M12 3.5v10M8 10l4 4 4-4" fill="none" stroke="$A" stroke-width="1.9" stroke-linecap="round" stroke-linejoin="round"/><path d="M4.5 15v5h15v-5" fill="none" stroke="$L" stroke-width="1.7" stroke-linejoin="round"/>',
"undo": '<path d="M9 7 4.5 11.5 9 16" fill="none" stroke="$A" stroke-width="1.9" stroke-linecap="round" stroke-linejoin="round"/><path d="M4.5 11.5H14a5 5 0 0 1 0 10h-3" fill="none" stroke="$L" stroke-width="1.7" stroke-linecap="round"/>',
"redo": '<path d="m15 7 4.5 4.5L15 16" fill="none" stroke="$A" stroke-width="1.9" stroke-linecap="round" stroke-linejoin="round"/><path d="M19.5 11.5H10a5 5 0 0 0 0 10h3" fill="none" stroke="$L" stroke-width="1.7" stroke-linecap="round"/>',
"copy": '<rect x="4.5" y="4.5" width="11" height="13" fill="$L" stroke="$D" stroke-width="1.1"/><rect x="8.5" y="7.5" width="11" height="13" fill="$G" stroke="$D" stroke-width="1.1"/>',
"paste": '<rect x="5.5" y="5.5" width="13" height="15" fill="$G" stroke="$D" stroke-width="1.2"/><rect x="8.5" y="3" width="7" height="4" fill="$A" stroke="$D" stroke-width="1.1"/>',
"delete": '<path d="M6 7.5h12l-1 12.5H7Z" fill="$G" stroke="$D" stroke-width="1.2" stroke-linejoin="round"/><path d="M4.5 7.5h15M9.5 5h5v2.5h-5Z" fill="$A" stroke="$D" stroke-width="1.1"/>',
"add": '<path d="M12 5v14M5 12h14" stroke="$A" stroke-width="2.6" stroke-linecap="round"/>',
"remove": '<path d="M5 12h14" stroke="$A" stroke-width="2.6" stroke-linecap="round"/>',
"close": '<path d="m6 6 12 12M18 6 6 18" stroke="$L" stroke-width="2.2" stroke-linecap="round"/>',
"check": '<path d="m5 12.5 4.5 4.5L19 7" fill="none" stroke="$A" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round"/>',
"search": '<circle cx="10.5" cy="10.5" r="6" fill="none" stroke="$L" stroke-width="1.9"/><path d="m15 15 5 5" stroke="$A" stroke-width="2.2" stroke-linecap="round"/>',
"settings": '<circle cx="12" cy="12" r="3.2" fill="$A" stroke="$D" stroke-width="1.1"/><path d="M12 3v3M12 18v3M3 12h3M18 12h3M5.6 5.6 7.8 7.8M16.2 16.2l2.2 2.2M18.4 5.6 16.2 7.8M7.8 16.2l-2.2 2.2" stroke="$L" stroke-width="1.8" stroke-linecap="round"/>',
"power": '<path d="M12 4v8" stroke="$A" stroke-width="2.2" stroke-linecap="round"/><path d="M7.5 7a6.5 6.5 0 1 0 9 0" fill="none" stroke="$L" stroke-width="1.9" stroke-linecap="round"/>',
"solo": '<path d="M15.5 7.5a4 4 0 1 0-3.5 6 4 4 0 1 1-3.5 6" fill="none" stroke="$A" stroke-width="2.1" stroke-linecap="round"/>',
"mute": '<path d="M4.5 9.5h3.5L13 5v14l-5-4.5H4.5Z" fill="$G" stroke="$D" stroke-width="1.2" stroke-linejoin="round"/><path d="m16 9.5 5 5M21 9.5l-5 5" stroke="$A" stroke-width="2" stroke-linecap="round"/>',
"volume": '<path d="M4.5 9.5h3.5L13 5v14l-5-4.5H4.5Z" fill="$G" stroke="$D" stroke-width="1.2" stroke-linejoin="round"/><path d="M16 9a4.5 4.5 0 0 1 0 6M18.5 6.5a8 8 0 0 1 0 11" fill="none" stroke="$A" stroke-width="1.7" stroke-linecap="round"/>',
"link": '<path d="M10 14a4 4 0 0 1 0-5.6l2.5-2.5a4 4 0 0 1 5.6 5.6L16.5 13" fill="none" stroke="$A" stroke-width="1.9" stroke-linecap="round"/><path d="M14 10a4 4 0 0 1 0 5.6L11.5 18a4 4 0 0 1-5.6-5.6L7.5 11" fill="none" stroke="$L" stroke-width="1.9" stroke-linecap="round"/>',
"dice": '<rect x="4.5" y="4.5" width="15" height="15" rx="2" fill="$G" stroke="$D" stroke-width="1.2"/><circle cx="8.5" cy="8.5" r="1.5" fill="$A"/><circle cx="12" cy="12" r="1.5" fill="$A"/><circle cx="15.5" cy="15.5" r="1.5" fill="$A"/>',
"folder": '<path d="M3.5 6.5h6l1.6 2h9.4v11h-17Z" fill="$A" stroke="$D" stroke-width="1.2" stroke-linejoin="round"/>',
"file_audio": '<path d="M6 3.5h8L18.5 8v12.5h-13Z" fill="$G" stroke="$D" stroke-width="1.2" stroke-linejoin="round"/><path d="M13.5 3.5V8h5" fill="none" stroke="$D" stroke-width="1.1"/><path d="M8 15h1.5l1-2.5 1.5 5 1.5-6.5 1.2 4H16" fill="none" stroke="$A" stroke-width="1.3"/>',
"chevron_down": '<path d="m6 9.5 6 6 6-6" fill="none" stroke="$L" stroke-width="2.1" stroke-linecap="round" stroke-linejoin="round"/>',
"chevron_up": '<path d="m6 14.5 6-6 6 6" fill="none" stroke="$L" stroke-width="2.1" stroke-linecap="round" stroke-linejoin="round"/>',
"chevron_left": '<path d="m14.5 6-6 6 6 6" fill="none" stroke="$L" stroke-width="2.1" stroke-linecap="round" stroke-linejoin="round"/>',
"chevron_right": '<path d="m9.5 6 6 6-6 6" fill="none" stroke="$L" stroke-width="2.1" stroke-linecap="round" stroke-linejoin="round"/>',
"grid": '<path d="M4 4h16v16H4Z" fill="none" stroke="$L" stroke-width="1.4"/><path d="M4 9.3h16M4 14.6h16M9.3 4v16M14.6 4v16" stroke="$L" stroke-width="0.9"/><rect x="9.3" y="9.3" width="5.3" height="5.3" fill="$A" opacity="0.85"/>',
"keyboard": '<rect x="2.5" y="7.5" width="19" height="9" rx="1" fill="$G" stroke="$D" stroke-width="1.1"/><path d="M5.5 7.5v5.5M8.5 7.5v5.5M12 7.5v5.5M15.5 7.5v5.5M18.5 7.5v5.5" stroke="$D" stroke-width="0.9"/><rect x="6.6" y="7.5" width="1.8" height="4" fill="$A"/><rect x="13.4" y="7.5" width="1.8" height="4" fill="$A"/>',
"time": '<circle cx="12" cy="12" r="8" fill="none" stroke="$L" stroke-width="1.7"/><path d="M12 7.5V12l3.5 2" fill="none" stroke="$A" stroke-width="1.9" stroke-linecap="round" stroke-linejoin="round"/>',
"cpu": '<rect x="6.5" y="6.5" width="11" height="11" fill="$G" stroke="$D" stroke-width="1.2"/><rect x="9.5" y="9.5" width="5" height="5" fill="$A"/><path d="M9 6.5V3.5M12 6.5V3.5M15 6.5V3.5M9 20.5v-3M12 20.5v-3M15 20.5v-3M6.5 9h-3M6.5 12h-3M6.5 15h-3M20.5 9h-3M20.5 12h-3M20.5 15h-3" stroke="$L" stroke-width="1.3"/>',
}

## Colour slots, filled from the palette at rasterise time.
## `size` is the size the icon occupies in the interface. `oversample` is how
## many real pixels each of those is worth: the interface is drawn through a
## content scale factor, so an icon rasterised at its nominal size is blown up
## before it reaches the screen and looks soft. Rasterising at the true device
## size and then telling the texture to *measure* as the nominal size gives a
## glyph that is the same size on screen and actually sharp.
static func render(name: String, accent: Color, size: int = 16, oversample: float = 1.0) -> Texture2D:
	var body: String = SVG.get(name, SVG["close"])
	body = body.replace("$A", "#" + accent.to_html(false))
	# The three neutral inks follow the interface's secondary colour, or an
	# icon stays grey on a blue interface while everything around it moves.
	body = body.replace("$D", "#" + CdPalette.INK_DARK.to_html(false))
	body = body.replace("$G", "#" + CdPalette.INK_MID.to_html(false))
	body = body.replace("$L", "#" + CdPalette.INK_LIGHT.to_html(false))
	var svg := '<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24">%s</svg>' % body
	var img := Image.new()
	var px := maxi(size, int(round(float(size) * maxf(1.0, oversample))))
	if img.load_svg_from_string(svg, float(px) / 24.0) != OK:
		return null
	_centre(img)
	var tex := ImageTexture.create_from_image(img)
	if px != size:
		# Layout and drawing both go by this, so the extra pixels buy detail
		# rather than a bigger icon.
		tex.set_size_override(Vector2i(size, size))
	return tex


## Shifts a rasterised glyph so its ink sits in the middle of its square.
##
## These are drawn as paths in a 24-unit box, and a shape that reads as centred
## to the eye that drew it rarely is: `undo` sits six pixels low at 64, `play`
## three and a half to the right. In a row of small square buttons that is the
## difference between tidy and not, and fixing it here fixes every glyph at once
## rather than nudging sixty-five path strings.
static func _centre(img: Image) -> void:
	var w := img.get_width()
	var h := img.get_height()
	var x0 := w
	var y0 := h
	var x1 := -1
	var y1 := -1
	for y in h:
		for x in w:
			if img.get_pixel(x, y).a > 0.06:
				if x < x0: x0 = x
				if x > x1: x1 = x
				if y < y0: y0 = y
				if y > y1: y1 = y
	if x1 < 0:
		return
	var dx := int(round(float(w) * 0.5 - float(x0 + x1 + 1) * 0.5))
	var dy := int(round(float(h) * 0.5 - float(y0 + y1 + 1) * 0.5))
	# Never shift a glyph off its own square: some of them fill it edge to edge.
	dx = clampi(dx, -x0, w - 1 - x1)
	dy = clampi(dy, -y0, h - 1 - y1)
	if dx == 0 and dy == 0:
		return
	var moved := Image.create(w, h, false, img.get_format())
	moved.fill(Color(0, 0, 0, 0))
	moved.blit_rect(img, Rect2i(x0, y0, x1 - x0 + 1, y1 - y0 + 1), Vector2i(x0 + dx, y0 + dy))
	img.copy_from(moved)


static func names() -> Array:
	return SVG.keys()
