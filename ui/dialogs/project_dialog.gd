class_name CdProjectDialog
extends Window
## The song's own settings. Preferences is the machine; this is the project,
## and everything set here is saved in the .cadmium file.
##
## Time settings for now: the MIDI resolution and the signature the bars are
## counted in. The layout is project_dialog.tscn; what goes in the drop-downs
## is here, so the lists and the code that reads them cannot drift apart.

## What a MIDI file can be written at. 480 is Cadmium's own, and the rest are
## the resolutions other sequencers hand out -- 96 is the one FL Studio starts
## with, so a project that came from there can be exported the way it arrived.
const TIMEBASES := [24, 48, 96, 120, 192, 240, 384, 480, 768, 960]

## The signatures worth having a name for. Anything else is still reachable
## with the two controls underneath.
const PRESETS := [[4, 4], [3, 4], [2, 4], [5, 4], [6, 4], [7, 4],
	[6, 8], [7, 8], [9, 8], [12, 8], [2, 2], [3, 8], [5, 8]]

## A denominator is a note length, so it is a power of two, not a number you
## count up through.
const DENOMINATORS := [1, 2, 4, 8, 16, 32]

@onready var _timebase: OptionButton = $Root/Col/TimebaseRow/Timebase
@onready var _preset: OptionButton = $Root/Col/PresetRow/Preset
@onready var _numerator: SpinBox = $Root/Col/NumeratorRow/Numerator
@onready var _denominator: OptionButton = $Root/Col/DenominatorRow/Denominator
@onready var _note: Label = $Root/Col/Note


func _ready() -> void:
	# A window is sized in pixels but laid out in scaled units.
	var sc := Settings.ui_scale()
	content_scale_factor = sc
	size = Vector2i(int(440.0 * sc), int(250.0 * sc))
	close_requested.connect(queue_free)

	for t in TIMEBASES:
		_timebase.add_item("%d" % t)
	_timebase.select(_nearest_timebase())
	_timebase.item_selected.connect(func(i: int):
		App.set_ppq(TIMEBASES[i])
		App.status.emit("MIDI files export at %d ticks per beat" % TIMEBASES[i]))

	# The preset row leads with what the song is already in, so the drop-down
	# is never showing a signature that is not the one in force.
	_preset.add_item("4/4")
	for p in PRESETS:
		_preset.add_item("%d/%d" % [p[0], p[1]])
	_preset.item_selected.connect(func(i: int):
		if i == 0:
			return
		var p: Array = PRESETS[i - 1]
		_apply(int(p[0]), int(p[1])))

	_numerator.value_changed.connect(func(v: float):
		_apply(int(v), _current_den()))

	for d in DENOMINATORS:
		_denominator.add_item("%d" % d)
	_denominator.item_selected.connect(func(i: int):
		_apply(int(_numerator.value), DENOMINATORS[i]))

	($Root/Col/Buttons/Close as Button).pressed.connect(queue_free)
	_fill()


## The controls from the project. Called after every change as well as on the
## way in, so the preset row and the two numbers always agree.
func _fill() -> void:
	_numerator.set_value_no_signal(clampf(float(App.project.sig_num), 1.0, 16.0))
	var di := DENOMINATORS.find(App.project.sig_den)
	_denominator.select(di if di >= 0 else DENOMINATORS.find(4))
	var sig := "%d/%d" % [App.project.sig_num, App.project.sig_den]
	_preset.set_item_text(0, sig)
	_preset.select(0)
	_note.text = ("Saved with the song. Bars are counted in %s, and MIDI exports "
			+ "at %d ticks per beat.") % [sig, App.project.ppq]


func _apply(num: int, den: int) -> void:
	App.set_time_sig(num, den)
	App.status.emit("Time signature %d/%d" % [App.project.sig_num, App.project.sig_den])
	_fill()


func _current_den() -> int:
	var i := _denominator.selected
	return DENOMINATORS[i] if i >= 0 and i < DENOMINATORS.size() else App.project.sig_den


## The entry for the project's resolution, or the closest one to it: an older
## song, or one an add-on set, is not obliged to hold a number from the list.
func _nearest_timebase() -> int:
	var best := 0
	for i in TIMEBASES.size():
		if absi(TIMEBASES[i] - App.project.ppq) < absi(TIMEBASES[best] - App.project.ppq):
			best = i
	return best
