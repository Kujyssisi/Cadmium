extends HBoxContainer
## One row of the layers dialog: a channel, how far to shift it, how hard to
## play it. The layout is layer_row.tscn.

signal changed()

var index := 0

@onready var check: CheckBox = $Check
@onready var semi: SpinBox = $Transpose
@onready var gain: HSlider = $Level


func bind(channel_name: String, existing) -> void:
	if not is_node_ready():
		await ready
	check.text = channel_name
	check.button_pressed = existing != null
	semi.value = float(existing.get("transpose", 0)) if existing != null else 0.0
	gain.value = float(existing.get("gain", 1.0)) if existing != null else 1.0
	_readout(gain.value)


func _ready() -> void:
	gain.value_changed.connect(_readout)
	# Applied live, so you hear the stack while you build it.
	check.toggled.connect(func(_o): changed.emit())
	semi.value_changed.connect(func(_v): changed.emit())
	gain.drag_ended.connect(func(moved): if moved: changed.emit())


func _readout(v: float) -> void:
	($Readout as Label).text = "%d%%" % int(round(v * 100.0))
