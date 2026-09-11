class_name CdLayersDialog
extends Window
## Stacking instruments: tick the channels this one should play alongside
## itself, and give each a transpose and a level.
##
## A piano plus strings a fifth up, or a kick doubled with a sub an octave down,
## is one pattern driving several channels instead of copies you have to keep
## in step by hand.

var channel := 0
var _rows := {}
var _self_check: CheckBox


func configure(args: Dictionary) -> void:
	channel = int(args.get("channel", 0))


func _ready() -> void:
	var cname := String(App.project.channels[channel].name) if channel < App.project.channels.size() else "Channel"
	title = "Layers — %s" % cname
	# A window is sized in pixels but laid out in scaled units.
	var sc := Settings.ui_scale()
	content_scale_factor = sc
	size = Vector2i(int(660.0 * sc), int(470.0 * sc))
	close_requested.connect(queue_free)

	($Root/Col/Intro as Label).text = ("Notes played on %s are sent to every channel ticked "
			+ "below, shifted and levelled as set here.") % cname
	_self_check = $Root/Col/SelfCheck
	_self_check.button_pressed = bool(App.project.channels[channel].get("layer_only", false))

	var list: VBoxContainer = $Root/Col/Scroll/List
	var existing := {}
	for l in App.channel_layers(channel):
		existing[int(l.get("channel", -1))] = l
	for i in App.project.channels.size():
		if i == channel:
			continue
		list.add_child(_row(i, existing.get(i, null)))

	($Root/Col/Buttons/Done as Button).pressed.connect(func():
		_apply()
		queue_free())


func _row(i: int, existing) -> Control:
	var row = preload("res://ui/dialogs/layer_row.tscn").instantiate()
	row.index = i
	row.bind(String(App.project.channels[i].name), existing)
	row.changed.connect(_apply)
	_rows[i] = row
	return row


func _apply() -> void:
	var layers := []
	for i in _rows.keys():
		var r = _rows[i]
		if not r.check.button_pressed:
			continue
		layers.append({"channel": int(i), "transpose": int(r.semi.value), "gain": float(r.gain.value)})
	App.set_channel_layers(channel, layers, _self_check.button_pressed)
