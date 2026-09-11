class_name CdAutomationWindow
extends Window
## One automation lane, drawn big enough to work on.
##
## The playlist edits a lane through whatever clip happens to be showing it,
## which is fine for a nudge and hopeless for drawing a shape: the clip is an
## inch tall and the curve is squeezed into it. This is the same lane on its
## own, with room -- bars across, the lane's range up the side, and points you
## can put where you mean to.
##
## What it holds besides the curve is what the lane itself is: whether it is
## on, the range it works over, and whether it forces its control to the curve
## or adds the curve to whatever the control is set to.

const MODES := ["Forced", "Additive"]
const MODE_HELP := [
	"The control is held at the curve.",
	"The curve is added to whatever the control was set to.",
]
## The knobs across the top: the ends of the lane's own range.
const KNOBS := [
	{"key": "lo", "label": "MIN"},
	{"key": "hi", "label": "MAX"},
]
const RULER_H := 16.0
const PAD := 8.0

var lane := -1

var _knobs := {}
## What the graph is showing: how many beats across, and from where. The lane
## can be far longer than the shape in it -- a clip covering the whole song --
## so it has to be possible to get closer to the part being worked on.
var _bars := 0.0                 ## 0 = the whole lane
var _from := 0.0
var _drag := -1                  ## the point being moved
var _tension := -1               ## the segment whose curve is being bent
var _tension_from := 0.0
var _tension_y := 0.0

@onready var _view: Control = $Root/Col/Editor/View
@onready var _on: CheckBox = $Root/Col/Head/On
@onready var _mode: OptionButton = $Root/Col/Head/ModeCol/Mode
@onready var _links: VBoxContainer = $Root/Col/Target/TargetCol/Links
@onready var _note: Label = $Root/Col/Foot/Note


func configure(args: Dictionary) -> void:
	lane = int(args.get("lane", -1))


func _ready() -> void:
	var sc := Settings.ui_scale()
	content_scale_factor = sc
	size = Vector2i(int(720.0 * sc), int(480.0 * sc))
	close_requested.connect(queue_free)
	($Root/Col/Foot/Close as Button).pressed.connect(queue_free)
	($Root/Col/Foot/Flat as Button).pressed.connect(_flatten)
	($Root/Col/Target/TargetCol/Row/Add as Button).pressed.connect(_add_link)

	for entry in KNOBS:
		var k := CdKnob.new()
		k.label = String(entry.label)
		k.knob_size = 26.0
		k.custom_minimum_size = Vector2(52, 52)
		k.value_changed.connect(func(v): _range_changed(String(entry.key), v))
		$Root/Col/Head/Knobs.add_child(k)
		_knobs[String(entry.key)] = k
	for m in MODES:
		_mode.add_item(m)
	Cd.compact(_mode, "OptionButton", 4.0)
	_mode.item_selected.connect(func(i):
		App.set_automation_prop(lane, "mode", i, "Automation mode")
		_note.text = MODE_HELP[i])
	_on.toggled.connect(func(v): App.set_automation_prop(lane, "on", v, "Automation on"))

	_view.draw.connect(_draw_curve)
	_view.gui_input.connect(_editor_input)
	_view.mouse_filter = Control.MOUSE_FILTER_STOP
	App.automation_changed.connect(_refresh)
	App.automation_tick.connect(_view.queue_redraw)
	_refresh()


func _input(event: InputEvent) -> void:
	Shortcuts.feed(event, get_viewport())


func _lane() -> Dictionary:
	if lane < 0 or lane >= App.project.automations.size():
		return {}
	return App.project.automations[lane]


func _refresh() -> void:
	var a := _lane()
	if a.is_empty():
		queue_free()
		return
	title = "Automation - %s" % String(a.get("name", "lane"))
	_on.set_pressed_no_signal(bool(a.get("on", true)))
	var mode := clampi(int(a.get("mode", Cd.AutoMode.FORCED)), 0, MODES.size() - 1)
	_mode.select(mode)
	_note.text = MODE_HELP[mode]
	var lo := float(a.get("lo", 0.0))
	var hi := float(a.get("hi", 1.0))
	# The knobs move over the same ground as the lane itself, with room either
	# side so a range can be widened as well as narrowed.
	var span: float = maxf(0.001, hi - lo)
	for key in _knobs.keys():
		var k: CdKnob = _knobs[key]
		k.minimum = lo - span
		k.maximum = hi + span
		k.set_value_silent(float(a.get(key, 0.0)))
	_fill_links()
	_view.queue_redraw()


## One row per control the lane drives: what it is, a button to open it, and --
## for everything after the first -- one to take it off again. The first is the
## lane's own target and stays; a lane driving nothing is a lane to delete.
func _fill_links() -> void:
	for child in _links.get_children():
		child.queue_free()
	var links := App.automation_links(lane)
	for i in links.size():
		var link: Dictionary = links[i]
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 6)
		var what := Label.new()
		what.text = _link_name(link)
		what.clip_text = true
		what.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		what.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		row.add_child(what)
		var show := Button.new()
		show.text = "Show it"
		show.focus_mode = Control.FOCUS_NONE
		show.pressed.connect(func(): _show_link(link))
		Cd.compact(show, "Button", 4.0)
		row.add_child(show)
		if i > 0:
			var drop := Button.new()
			drop.text = "x"
			drop.focus_mode = Control.FOCUS_NONE
			drop.tooltip_text = "Stop driving this one"
			drop.pressed.connect(func(): App.remove_automation_link(lane, i))
			Cd.compact(drop, "Button", 4.0)
			row.add_child(drop)
		_links.add_child(row)


func _link_name(link: Dictionary) -> String:
	var d := App.tweak_describe(link)
	return String(d.get("name", "")) if not d.is_empty() else "a control that is not there any more"


func _add_link() -> void:
	CdTargetMenu.open(self, func(entry):
		App.add_automation_link(lane, int(entry.target), entry.ref, int(entry.a), int(entry.b)))


func _show_link(link: Dictionary) -> void:
	var target := int(link.get("target", 0))
	if target == Cd.AutoTarget.PLUGIN:
		App.request_plugin_window(link.get("ref", {}))
	elif target in [Cd.AutoTarget.SAMPLE_VOL, Cd.AutoTarget.SAMPLE_PAN,
			Cd.AutoTarget.SAMPLE_PITCH, Cd.AutoTarget.SAMPLE_SPEED]:
		CdSampleWindow.open(self, int(link.get("a", 0)))
	else:
		App.status.emit(_link_name(link))


func _range_changed(key: String, v: float) -> void:
	var a := _lane()
	if a.is_empty():
		return
	# The two ends cannot cross: a range of nothing draws nothing and means
	# nothing.
	var lo := float(a.get("lo", 0.0))
	var hi := float(a.get("hi", 1.0))
	if key == "lo":
		v = minf(v, hi - 0.001)
	else:
		v = maxf(v, lo + 0.001)
	App.set_automation_prop(lane, key, v, "Automation range")


func _flatten() -> void:
	var a := _lane()
	if a.is_empty():
		return
	var pts: Array = a.get("points", [])
	var v: float = float(pts[0].get("value", 0.0)) if not pts.is_empty() else float(a.get("lo", 0.0))
	App.snapshot("Flatten automation")
	App.set_automation_points(lane, [{"beat": 0.0, "value": v, "curve": 0.0}])


# ---------------------------------------------------------------------------
# The graph
# ---------------------------------------------------------------------------
## How many beats the editor shows: the curve, the clips that play it, and a
## bar of room after the last point so there is somewhere to draw next.
func _length() -> float:
	var a := _lane()
	var last := 4.0
	for p in a.get("points", []):
		last = maxf(last, float(p.get("beat", 0.0)))
	for c in App.project.clips:
		if int(c.type) == Cd.ClipType.AUTOMATION and int(c.index) == lane:
			last = maxf(last, float(c.get("offset", 0.0)) + float(c.length))
	return ceilf((last + 4.0) / 4.0) * 4.0


## What is on screen right now, in beats.
func _span() -> float:
	return _length() if _bars <= 0.0 else clampf(_bars, 1.0, _length())


func _body() -> Rect2:
	return Rect2(PAD, RULER_H, maxf(8.0, _view.size.x - PAD * 2.0),
			maxf(8.0, _view.size.y - RULER_H - PAD))


func _beat_x(beat: float) -> float:
	var b := _body()
	return b.position.x + b.size.x * clampf((beat - _from) / maxf(0.001, _span()), 0.0, 1.0)


func _x_beat(x: float) -> float:
	var b := _body()
	return _from + clampf((x - b.position.x) / maxf(1.0, b.size.x), 0.0, 1.0) * _span()


## Closer in or further out, around the pointer, the way every other view in
## the program zooms.
func _zoom(by: float, at_x: float) -> void:
	var held := _x_beat(at_x)
	var span := _span()
	_bars = clampf((span if _bars > 0.0 else _length()) * by, 1.0, _length())
	# The beat under the pointer stays under the pointer.
	var b := _body()
	var t := clampf((at_x - b.position.x) / maxf(1.0, b.size.x), 0.0, 1.0)
	_from = clampf(held - _span() * t, 0.0, maxf(0.0, _length() - _span()))
	_view.queue_redraw()


func _value_y(v: float) -> float:
	var a := _lane()
	var lo := float(a.get("lo", 0.0))
	var hi := float(a.get("hi", 1.0))
	var t := clampf((v - lo) / maxf(0.0001, hi - lo), 0.0, 1.0)
	var b := _body()
	return b.end.y - b.size.y * t


func _y_value(y: float) -> float:
	var a := _lane()
	var lo := float(a.get("lo", 0.0))
	var hi := float(a.get("hi", 1.0))
	var b := _body()
	var t := clampf((b.end.y - y) / maxf(1.0, b.size.y), 0.0, 1.0)
	return lo + t * (hi - lo)


func _point_at(pos: Vector2) -> int:
	var pts: Array = _lane().get("points", [])
	var best := -1
	var best_d := 12.0
	for i in pts.size():
		var d := Vector2(_beat_x(float(pts[i].beat)), _value_y(float(pts[i].value))).distance_to(pos)
		if d < best_d:
			best_d = d
			best = i
	return best


## Which segment the pointer is over, for bending it.
func _segment_at(pos: Vector2) -> int:
	var pts: Array = _lane().get("points", [])
	for i in range(pts.size() - 1):
		if pos.x >= _beat_x(float(pts[i].beat)) and pos.x <= _beat_x(float(pts[i + 1].beat)):
			return i
	return -1


func _draw_curve() -> void:
	var a := _lane()
	if a.is_empty():
		return
	var b := _body()
	var font := get_theme_default_font()
	_view.draw_rect(Rect2(Vector2.ZERO, _view.size), CdPalette.VIEWPORT)

	# Bars across, and the lane's range up the side.
	var span := _span()
	var bar := 4.0
	var beat := floorf(_from / bar) * bar
	while beat <= _from + span:
		var x := _beat_x(beat)
		var line := int(beat / bar) % 4 == 0
		_view.draw_line(Vector2(x, RULER_H), Vector2(x, b.end.y),
				CdPalette.RULE_LIGHT if line else CdPalette.RULE_DARK, 1.0)
		_view.draw_string(font, Vector2(x + 3.0, RULER_H - 4.0), "%d" % (int(beat / bar) + 1),
				HORIZONTAL_ALIGNMENT_LEFT, 40.0, 9, CdPalette.TEXT_MUTE)
		beat += bar
	for i in 5:
		var y := b.position.y + b.size.y * float(i) / 4.0
		_view.draw_line(Vector2(b.position.x, y), Vector2(b.end.x, y),
				CdPalette.RULE_DARK, 1.0)
	var lo := float(a.get("lo", 0.0))
	var hi := float(a.get("hi", 1.0))
	var kind := int(_target_kind(a))
	_view.draw_string(font, Vector2(b.position.x + 2.0, b.position.y + 10.0),
			Cd.format_param(hi, kind, ""), HORIZONTAL_ALIGNMENT_LEFT, 90.0, 9, CdPalette.TEXT_MUTE)
	_view.draw_string(font, Vector2(b.position.x + 2.0, b.end.y - 3.0),
			Cd.format_param(lo, kind, ""), HORIZONTAL_ALIGNMENT_LEFT, 90.0, 9, CdPalette.TEXT_MUTE)

	# The curve, and the ground under it, so a lane reads at a glance the way
	# it does on a clip.
	var steps := maxi(16, int(b.size.x / 3.0))
	var line_pts := PackedVector2Array()
	for s in steps + 1:
		var at := _from + span * float(s) / float(steps)
		line_pts.append(Vector2(_beat_x(at), _value_y(App.automation_value(lane, at))))
	if line_pts.size() > 1:
		var fill := PackedVector2Array(line_pts)
		fill.append(Vector2(b.end.x, b.end.y))
		fill.append(Vector2(b.position.x, b.end.y))
		_view.draw_colored_polygon(fill, Color(CdPalette.ACCENT.r, CdPalette.ACCENT.g,
				CdPalette.ACCENT.b, 0.16))
		_view.draw_polyline(line_pts, CdPalette.ACCENT, 1.8, true)

	# The points.
	var pts: Array = a.get("points", [])
	for i in pts.size():
		var pb := float(pts[i].beat)
		if pb < _from - 0.001 or pb > _from + span + 0.001:
			continue
		var at := Vector2(_beat_x(pb), _value_y(float(pts[i].value)))
		var held := i == _drag
		_view.draw_circle(at, 6.0 if held else 4.5, Color(0, 0, 0, 0.6))
		_view.draw_circle(at, 4.0 if held else 3.0,
				CdPalette.ACCENT if held else Color(1, 1, 1, 0.92))

	# Where the lane stands right now, while the song plays.
	var live := App.live_automation_value(lane)
	if not is_nan(live):
		var y := _value_y(live)
		_view.draw_line(Vector2(b.position.x, y), Vector2(b.end.x, y), Color(1, 1, 1, 0.25), 1.0)
		var head := Audio.position()
		for c in App.project.clips:
			if int(c.type) != Cd.ClipType.AUTOMATION or int(c.index) != lane:
				continue
			if head < float(c.start) or head >= float(c.start) + float(c.length):
				continue
			var hx := _beat_x(head - float(c.start) + float(c.get("offset", 0.0)))
			_view.draw_line(Vector2(hx, RULER_H), Vector2(hx, b.end.y), CdPalette.PLAYHEAD, 1.4)
			_view.draw_circle(Vector2(hx, y), 3.4, Color(1, 1, 1, 0.95))
			break


func _target_kind(a: Dictionary) -> int:
	var d := App.tweak_describe({"target": int(a.get("target", 0)), "ref": a.get("ref", {}),
			"a": int(a.get("a", 0)), "b": int(a.get("b", 0))})
	return int(d.get("kind", Cd.ParamKind.FLOAT)) if not d.is_empty() else Cd.ParamKind.FLOAT


# ---------------------------------------------------------------------------
func _editor_input(event: InputEvent) -> void:
	var a := _lane()
	if a.is_empty():
		return
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.pressed and mb.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]:
			var closer: bool = mb.button_index == MOUSE_BUTTON_WHEEL_UP
			if mb.shift_pressed:
				# Sideways, for when the shape is somewhere else entirely.
				_from = clampf(_from + _span() * (-0.15 if closer else 0.15), 0.0,
						maxf(0.0, _length() - _span()))
				_view.queue_redraw()
			else:
				_zoom(0.8 if closer else 1.25, mb.position.x)
			return
		if mb.button_index == MOUSE_BUTTON_RIGHT and mb.pressed:
			var hit := _point_at(mb.position)
			if hit >= 0:
				var pts: Array = (a.points as Array).duplicate(true)
				if pts.size() > 1:
					pts.remove_at(hit)
					App.snapshot("Remove automation point")
					App.set_automation_points(lane, pts)
			_view.queue_redraw()
			return
		if mb.button_index != MOUSE_BUTTON_LEFT:
			return
		if not mb.pressed:
			_drag = -1
			_tension = -1
			return
		var on_point := _point_at(mb.position)
		if on_point >= 0:
			if mb.double_click:
				# Straightens the segment after it, which is the quickest way
				# out of a shape that has been bent too far.
				var flat: Array = (a.points as Array).duplicate(true)
				flat[on_point]["curve"] = 0.0
				App.set_automation_points(lane, flat)
			App.snapshot("Move automation point")
			_drag = on_point
			_view.queue_redraw()
			return
		# Shift on a segment bends it; anywhere else adds a point.
		var seg := _segment_at(mb.position)
		if mb.shift_pressed and seg >= 0:
			App.snapshot("Bend automation")
			_tension = seg
			_tension_from = float((a.points as Array)[seg].get("curve", 0.0))
			_tension_y = mb.position.y
			return
		var pts2: Array = (a.points as Array).duplicate(true)
		var added := {"beat": _snap(_x_beat(mb.position.x)), "value": _y_value(mb.position.y),
				"curve": 0.0}
		pts2.append(added)
		pts2.sort_custom(func(x, y): return float(x.beat) < float(y.beat))
		App.snapshot("Add automation point")
		App.set_automation_points(lane, pts2)
		for i in pts2.size():
			if pts2[i] == added:
				_drag = i
		_view.queue_redraw()
	elif event is InputEventMouseMotion:
		var mm := event as InputEventMouseMotion
		if _drag >= 0:
			var pts: Array = (a.points as Array).duplicate(true)
			if _drag >= pts.size():
				_drag = -1
				return
			var moving: Dictionary = pts[_drag]
			moving["beat"] = maxf(0.0, _snap(_x_beat(mm.position.x)))
			_from = clampf(_from, 0.0, maxf(0.0, _length() - _span()))
			moving["value"] = _y_value(mm.position.y)
			pts.sort_custom(func(x, y): return float(x.beat) < float(y.beat))
			App.set_automation_points(lane, pts)
			for i in pts.size():
				if pts[i] == moving:
					_drag = i
			_view.queue_redraw()
		elif _tension >= 0:
			var pts2: Array = (a.points as Array).duplicate(true)
			if _tension >= pts2.size():
				_tension = -1
				return
			var d := (_tension_y - mm.position.y) / 60.0
			pts2[_tension]["curve"] = clampf(_tension_from + d, -1.0, 1.0)
			App.set_automation_points(lane, pts2)
			_view.queue_redraw()


func _snap(beat: float) -> float:
	var snap := App.snap_beats()
	return Cd.snap_beat(beat, snap) if snap > 0.0 else beat


## One call from anywhere: `CdAutomationWindow.open(self, lane)`.
static func open(host: Node, index: int) -> Window:
	for w in host.get_tree().root.get_children():
		if w is CdAutomationWindow and (w as CdAutomationWindow).lane == index:
			w.grab_focus()
			return w
	var win = preload("res://ui/dialogs/automation_window.tscn").instantiate()
	win.lane = index
	host.get_tree().root.add_child(win)
	win.show()
	Cd.place_window(win, host)
	return win
