class_name CdFxSlot
extends PanelContainer
## One layer of a mixer strip's effect stack.
##
## Drag it by the grip to move it up or down the chain, click the arrow to fold
## out the first few controls without opening the plugin's own window, and use
## the lamp to switch it in and out while you listen.

signal menu_requested(slot: int)

const QUICK_MAX := 6

var track := 0
var slot := 0
var plug = null

var _quick: GridContainer
var _knobs := {}


@onready var _col: VBoxContainer = $Col
@onready var _grip: Label = $Col/Head/Grip
@onready var _power: CdLed = $Col/Head/Power
@onready var _expander: Button = $Col/Head/Expander
@onready var _name_btn: Button = $Col/Head/Name
@onready var _wet: CdKnob = $Col/Head/Wet


func _ready() -> void:
	# The row is fx_slot.tscn; which slot it is and which plugin sits in it are
	# set before it goes into the tree.
	_grip.text = str(slot + 1)
	_power.on = plug != null and not bool(plug.get("bypass", false))
	_power.off_color = Color("#333333")
	_power.toggled_state.connect(func(on):
		if plug != null:
			App.set_insert_flag(track, slot, "bypass", not on))

	_expander.icon = Icons.get_icon("chevron_down" if _expanded() else "chevron_right", 10)
	Cd.icon_button(_expander, 16.0)
	_expander.disabled = plug == null
	_expander.pressed.connect(_toggle_expand)

	_name_btn.text = String(plug.get("name", "fx"))
	_name_btn.icon = Icons.get_icon("vst" if String(plug.get("kind", "")) == "vst3" else "fx", 12)
	_name_btn.tooltip_text = "Click to open or close %s, right-click for more" % String(plug.get("name", ""))
	Cd.compact(_name_btn, "Button", 4.0)
	_name_btn.pressed.connect(func(): App.toggle_plugin_window(_ref()))
	_name_btn.gui_input.connect(func(e):
		if e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_RIGHT:
			menu_requested.emit(slot))

	_wet.value = float(plug.get("wet", 1.0))
	_wet.value_changed.connect(func(v): App.set_insert_flag(track, slot, "wet", v))

	if _expanded():
		_build_quick()


func _ref() -> Dictionary:
	return {"kind": "insert", "track": track, "slot": slot}


func _expanded() -> bool:
	return plug != null and bool(plug.get("expanded", false))


func _toggle_expand() -> void:
	if plug == null:
		return
	plug["expanded"] = not _expanded()
	_expander.icon = Icons.get_icon("chevron_down" if _expanded() else "chevron_right", 10)
	if _expanded():
		_build_quick()
	elif _quick != null:
		_quick.queue_free()
		_quick = null
		_knobs.clear()


## The first handful of parameters, which for Cadmium's own effects are the ones
## worth reaching for: cutoff before oversampling, drive before dry/wet trim.
func _build_quick() -> void:
	if _quick != null:
		return
	var params: Array = App.plugin_params(_ref())
	if params.is_empty():
		return
	_quick = GridContainer.new()
	_quick.columns = 4
	_quick.add_theme_constant_override("h_separation", 0)
	_quick.add_theme_constant_override("v_separation", 0)
	_col.add_child(_quick)
	var n := 0
	for i in params.size():
		var p: Dictionary = params[i]
		if int(p.get("kind", Cd.ParamKind.FLOAT)) == Cd.ParamKind.BOOL:
			continue
		var k := CdKnob.new()
		k.knob_size = 22.0
		k.show_label = true
		k.setup(p, App.get_plugin_param(_ref(), int(p.get("index", i))))
		k.custom_minimum_size = Vector2(44, 44)
		var idx := int(p.get("index", i))
		k.value_changed.connect(func(v): App.set_plugin_param(_ref(), idx, v))
		_quick.add_child(k)
		_knobs[idx] = k
		n += 1
		if n >= QUICK_MAX:
			break


## The values on an existing row, for when the chain has not changed shape and
## the rack is left standing rather than built again.
func refresh() -> void:
	if plug == null:
		return
	_power.on = not bool(plug.get("bypass", false))
	_wet.set_value_silent(float(plug.get("wet", 1.0)))
	refresh_values()


func refresh_values() -> void:
	for idx in _knobs.keys():
		var k: CdKnob = _knobs[idx]
		k.set_value_silent(App.get_plugin_param(_ref(), int(idx)))


# --- reordering by drag -----------------------------------------------------
func _get_drag_data(_pos: Vector2) -> Variant:
	if plug == null:
		return null
	var preview := Label.new()
	preview.text = "  %s  " % String(plug.get("name", "fx"))
	preview.theme_type_variation = "Header"
	var box := PanelContainer.new()
	box.theme_type_variation = "CaptionBar"
	box.add_child(preview)
	set_drag_preview(box)
	return {"cd_fx": true, "track": track, "slot": slot}


func _can_drop_data(_pos: Vector2, data: Variant) -> bool:
	return data is Dictionary and data.get("cd_fx", false) and int(data.get("track", -1)) == track \
			and int(data.get("slot", -1)) != slot


func _drop_data(_pos: Vector2, data: Variant) -> void:
	App.move_insert(track, int(data.slot), slot)
