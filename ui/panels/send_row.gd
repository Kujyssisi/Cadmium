extends HBoxContainer
## One send from a mixer strip. The layout is send_row.tscn; which send it is
## comes from `bind`, and every change goes back through App.

var track := 0
var index := 0

@onready var _dest: OptionButton = $Dest
@onready var _amount: CdKnob = $Amount
@onready var _sidechain: CdLed = $Sidechain


func _ready() -> void:
	($Number as Label).text = str(index + 1)
	_sidechain.on_color = CdPalette.WARN
	Cd.compact(_dest, "OptionButton", 4.0)

	var send: Dictionary = App.project.mixer[track].sends[index]
	_dest.add_item("(off)")
	_dest.set_item_metadata(0, -1)
	for d in App.project.mixer.size():
		if d == track:
			continue
		_dest.add_item(String(App.project.mixer[d].name))
		_dest.set_item_metadata(_dest.item_count - 1, d)
	for i in _dest.item_count:
		if int(_dest.get_item_metadata(i)) == int(send.dest):
			_dest.select(i)
	_amount.set_value_silent(float(send.amount))
	_sidechain.on = bool(send.sidechain)

	_dest.item_selected.connect(func(_i): _apply())
	_amount.value_changed.connect(func(_v): _apply())
	_sidechain.toggled_state.connect(func(_o): _apply())


## Values only, for a rack that is being updated rather than rebuilt.
func refresh() -> void:
	if track >= App.project.mixer.size():
		return
	var send: Dictionary = App.project.mixer[track].sends[index]
	for i in _dest.item_count:
		if int(_dest.get_item_metadata(i)) == int(send.dest):
			_dest.select(i)
	_amount.set_value_silent(float(send.amount))
	_sidechain.on = bool(send.sidechain)


func _apply() -> void:
	var send: Dictionary = App.project.mixer[track].sends[index]
	App.set_send(track, index, int(_dest.get_item_metadata(_dest.selected)), _amount.value,
			bool(send.get("pre", false)), _sidechain.on)
