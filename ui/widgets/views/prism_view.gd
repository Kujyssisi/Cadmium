class_name CdPrismView
extends Control
## The picture Prism is playing, with the scan line where it has got to. What
## you see is what you are hearing: left to right is time, up is pitch.

var ref := {}
var params: Array = []
var _tex: Texture2D = null
var _pos := 0.0
var _cols := 0
var _bands := 0

func _ready() -> void:
	custom_minimum_size.y = 168
	set_process(true)

func set_image(path: String) -> void:
	_tex = null
	if path.is_empty():
		queue_redraw()
		return
	var img := Image.new()
	if img.load(path) != OK:
		queue_redraw()
		return
	# Shown the right way up: the picture is played as it looks.
	_tex = ImageTexture.create_from_image(img)
	queue_redraw()

func _process(_dt: float) -> void:
	if not is_visible_in_tree():
		return
	var h: int = App.handle_for(ref)
	if h < 0:
		return
	var a: PackedFloat32Array = App.engine().plugin_aux(h, 0, 3)
	if a.size() == 3:
		_pos = a[0]
		_cols = int(a[1])
		_bands = int(a[2])
		queue_redraw()

func _draw() -> void:
	var font := get_theme_default_font()
	var r := Rect2(Vector2.ZERO, size)
	draw_rect(r, CdPalette.WELL)
	if _tex == null:
		draw_string(font, Vector2(10, size.y * 0.5), "load a picture to play it",
				HORIZONTAL_ALIGNMENT_LEFT, size.x - 20, 11, CdPalette.TEXT_DIM)
		return
	draw_texture_rect(_tex, r, false, Color(1, 1, 1, 0.92))
	# Pitch guides at the octaves the range covers.
	var octaves := _octaves()
	if octaves > 0.5:
		for o in range(1, int(octaves) + 1):
			var y := size.y * (1.0 - float(o) / octaves)
			draw_line(Vector2(0, y), Vector2(size.x, y), Color(1, 1, 1, 0.14), 1.0)
	var x := size.x * clampf(_pos, 0.0, 1.0)
	draw_line(Vector2(x, 0), Vector2(x, size.y), CdPalette.ACCENT, 1.5)
	draw_string(font, Vector2(6, size.y - 5), "%d bands  %d columns" % [_bands, _cols],
			HORIZONTAL_ALIGNMENT_LEFT, size.x, 9, Color(1, 1, 1, 0.6))

func _octaves() -> float:
	for k in params.size():
		if String(params[k].id) == "octaves":
			return App.get_plugin_param(ref, int(params[k].index))
	return 6.0
