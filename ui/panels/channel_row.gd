extends HBoxContainer
## One channel in the rack. The layout is channel_row.tscn; `bind` says which
## channel it shows, and everything that depends on that is set from there.

signal menu_requested(index: int, event: InputEvent)
signal layers_requested(index: int)
signal route_requested(index: int)

var index := 0
var steps := 16

@onready var _colour: ColorRect = $Head/Row/Colour
@onready var _mute: CdLed = $Head/Row/Mute
@onready var _name: Button = $Head/Row/Name
@onready var _pan: CdKnob = $Head/Row/Pan
@onready var _vol: CdKnob = $Head/Row/Volume
@onready var _layers: Button = $Head/Row/Layers
@onready var _activity = $Head/Row/Activity
@onready var _route: Button = $Head/Row/Route
@onready var _steps = $Steps


func _ready() -> void:
	_mute.on_color = CdPalette.GOOD
	_activity.channel = index
	_steps.channel = index
	_steps.steps = steps
	_mute.toggled_state.connect(func(on):
		App.set_channel_prop(index, "mute", not on, "Mute channel"))
	_name.pressed.connect(func():
		App.select_channel(index)
		App.toggle_plugin_window({"kind": "channel", "index": index}))
	_name.gui_input.connect(func(e): menu_requested.emit(index, e))
	_pan.auto_ref = {"target": Cd.AutoTarget.CHANNEL_PAN, "ref": {}, "a": index, "b": 0}
	_vol.auto_ref = {"target": Cd.AutoTarget.CHANNEL_VOL, "ref": {}, "a": index, "b": 0}
	_pan.value_changed.connect(func(v): App.set_channel_prop(index, "pan", v))
	_pan.edit_finished.connect(func(): App.project.dirty = true)
	_vol.value_changed.connect(func(v): App.set_channel_prop(index, "vol", v))
	_layers.pressed.connect(func(): layers_requested.emit(index))
	_route.pressed.connect(func(): route_requested.emit(index))
	refresh()


## Reads the channel again. Called when it is built and whenever it changes.
func refresh() -> void:
	if index >= App.project.channels.size():
		return
	var ch: Dictionary = App.project.channels[index]
	_colour.color = CdPalette.track_color(int(ch.get("color", index)))
	_mute.on = not bool(ch.mute)
	_name.text = String(ch.name)
	_name.icon = Icons.get_icon(_icon_for(ch), 14)
	_name.tooltip_text = "%s\nClick to open the instrument, right-click for channel options" % \
			String(ch.plugin.get("name", ""))
	_pan.set_value_silent(float(ch.pan))
	_vol.set_value_silent(float(ch.vol))
	_route.text = "%02d" % int(ch.mixer)
	# A channel that drives others says so, since its own sound may be off.
	var count := int((ch.get("layers", []) as Array).size())
	_layers.visible = count > 0
	if count > 0:
		_layers.text = "L%d" % count
		_layers.tooltip_text = "Also plays %d other channel%s - click to edit" % [
				count, "" if count == 1 else "s"]


func _icon_for(ch: Dictionary) -> String:
	var id := String(ch.plugin.get("id", ""))
	if String(ch.plugin.get("kind", "stock")) == "vst3":
		return "vst"
	match id:
		"cd.pulse":
			return "drum"
		"cd.sampler":
			return "sampler"
		"cd.soundfont":
			return "soundfont"
		_:
			return "synth"
