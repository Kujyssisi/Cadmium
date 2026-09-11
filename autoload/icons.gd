extends Node
## Icon cache. CdIcons rasterises SVG source at the size it will really occupy
## on screen -- nominal size times the interface scale -- and the texture is
## told to measure as the nominal size, so icons stay put and stay sharp.
## One texture per (name, size), and the texture object is kept for the life of
## the program: when a colour changes the pixels are redrawn *into* it, so every
## button already holding it repaints itself. Throwing the cache away instead
## left every icon on screen in the old colour until whatever set it happened to
## set it again -- which for the transport and the menu bar was never.

var _cache := {}
## What each cached texture was made from, so it can be made again in another
## colour without anyone having to ask for it.
var _recipe := {}
var _oversample := 0.0


## Device pixels per interface pixel. Read once: changing the interface scale
## asks for a restart anyway, and this is called for every icon.
func oversample() -> float:
	if _oversample <= 0.0:
		# Twice the interface scale, floored at 2. A 16 px glyph rasterised at
		# 16 px is 16 px of detail however sharp the screen is; rasterising at
		# 32 and letting it land on 16 gives clean diagonals and curves, and
		# leaves headroom for the places that draw an icon slightly larger than
		# its nominal box (a theme icon_max_width, an aspect-keeping
		# TextureRect). Past 4x the downscale starts losing detail again.
		_oversample = clampf(Settings.ui_scale() * 2.0, 2.0, 4.0)
	return _oversample


func get_icon(name: String, size: int = 16) -> Texture2D:
	return _cached(name, size, "", CdPalette.ACCENT)


## A neutral (accent-free) variant, for rows where a red glyph would read as a
## warning rather than an ornament.
func get_grey(name: String, size: int = 16) -> Texture2D:
	return _cached(name, size, "grey:", CdPalette.tint_neutral(Color("#b8bcc0"), CdPalette.SECONDARY))


## The texture for one icon, made once and repainted in place afterwards.
func _cached(name: String, size: int, prefix: String, ink: Color) -> Texture2D:
	var key := "%s%s@%d" % [prefix, name, size]
	var hit = _cache.get(key)
	if hit != null:
		return hit
	var tex := CdIcons.render(name, ink, size, oversample())
	if tex != null:
		_cache[key] = tex
		_recipe[key] = [name, size, prefix]
	return tex


## Redraws every icon that has been handed out, in place. Nothing has to be
## asked for again: the buttons are holding these very textures.
func repaint() -> void:
	_oversample = 0.0
	for key in _cache.keys():
		var tex = _cache[key]
		var r: Array = _recipe.get(key, [])
		if r.is_empty() or not (tex is ImageTexture):
			continue
		var ink: Color = CdPalette.ACCENT if String(r[2]).is_empty() \
				else CdPalette.tint_neutral(Color("#b8bcc0"), CdPalette.SECONDARY)
		var fresh := CdIcons.render(String(r[0]), ink, int(r[1]), oversample())
		if fresh is ImageTexture:
			var img: Image = (fresh as ImageTexture).get_image()
			if img != null:
				(tex as ImageTexture).set_image(img)
				(tex as ImageTexture).set_size_override(Vector2i(int(r[1]), int(r[1])))


func clear_cache() -> void:
	repaint()


func has(name: String) -> bool:
	return CdIcons.SVG.has(name)
