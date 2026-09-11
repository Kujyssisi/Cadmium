class_name CdMeter
extends Control
## Stereo level meter: filled bar is RMS, the bright line is peak, and the top
## square latches when anything clips until you click it.

@export var track := 0
@export var horizontal := false

var _peak_hold := Vector2.ZERO
var _hold_time := Vector2.ZERO
var _clipped := false
var _last_peak := Vector2.ZERO


func _ready() -> void:
	focus_mode = Control.FOCUS_NONE
	custom_minimum_size = Vector2(14, 60) if not horizontal else Vector2(80, 12)
	set_process(true)


func _process(dt: float) -> void:
	if not is_visible_in_tree():
		return
	var before := _peak_hold
	var p := Audio.peak(track)
	for i in 2:
		var v: float = p.x if i == 0 else p.y
		var hold: float = _peak_hold.x if i == 0 else _peak_hold.y
		var t: float = _hold_time.x if i == 0 else _hold_time.y
		if v >= hold:
			hold = v
			t = 0.9
		else:
			t -= dt
			if t <= 0.0:
				hold = maxf(v, hold - dt * 1.2)
		if i == 0:
			_peak_hold.x = hold
			_hold_time.x = t
		else:
			_peak_hold.y = hold
			_hold_time.y = t
	if p.x > 1.0 or p.y > 1.0:
		_clipped = true
	# A meter sitting at silence looks the same every frame, and there are
	# eighteen of them in the mixer alone.
	if before.distance_to(_peak_hold) > 0.0015 or _last_peak.distance_to(p) > 0.0015:
		_last_peak = p
		queue_redraw()


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		_clipped = false
		queue_redraw()


func _db_pos(db: float, length: float) -> float:
	# -60..+6 dB across the meter, non-linear so the top 12 dB gets room.
	return clampf(pow(clampf((db + 60.0) / 66.0, 0.0, 1.0), 1.6), 0.0, 1.0) * length


func _draw() -> void:
	var p := Audio.peak(track)
	var r := Audio.rms(track)
	draw_rect(Rect2(Vector2.ZERO, size), CdPalette.WELL)
	var clip_h := 4.0
	var chans := [[p.x, r.x, _peak_hold.x], [p.y, r.y, _peak_hold.y]]
	if horizontal:
		var h := (size.y - 1.0) / 2.0
		for i in 2:
			var y := i * (h + 1.0)
			var lvl: float = _db_pos(Cd.gain_to_db(chans[i][1]), size.x)
			var pk: float = _db_pos(Cd.gain_to_db(chans[i][0]), size.x)
			_bar_h(Rect2(0, y, lvl, h))
			if pk > 1.0:
				draw_rect(Rect2(pk - 1.0, y, 1.5, h), CdPalette.TEXT)
	else:
		var w := (size.x - 1.0) / 2.0
		var usable := size.y - clip_h - 2.0
		for i in 2:
			var x := i * (w + 1.0)
			var lvl: float = _db_pos(Cd.gain_to_db(chans[i][1]), usable)
			var pk: float = _db_pos(Cd.gain_to_db(chans[i][2]), usable)
			_bar_v(Rect2(x, size.y - lvl, w, lvl), usable)
			if pk > 1.0:
				draw_rect(Rect2(x, size.y - pk, w, 1.5), CdPalette.TEXT)
		draw_rect(Rect2(0, 0, size.x, clip_h), CdPalette.BAD if _clipped else CdPalette.SUNKEN)


func _bar_v(rect: Rect2, usable: float) -> void:
	# Three zones so the colour reads as loudness without a scale.
	var green_h := _db_pos(-12.0, usable)
	var amber_h := _db_pos(-3.0, usable)
	var base := size.y
	var top := rect.position.y
	var seg := func(from: float, to: float, c: Color):
		var y0 := base - to
		var y1 := base - from
		if y0 < top:
			y0 = top
		if y1 > y0:
			draw_rect(Rect2(rect.position.x, y0, rect.size.x, y1 - y0), c)
	seg.call(0.0, minf(green_h, rect.size.y), CdPalette.METER_LOW)
	if rect.size.y > green_h:
		seg.call(green_h, minf(amber_h, rect.size.y), CdPalette.METER_MID)
	if rect.size.y > amber_h:
		seg.call(amber_h, rect.size.y, CdPalette.METER_HIGH)


func _bar_h(rect: Rect2) -> void:
	var green_w := _db_pos(-12.0, size.x)
	var amber_w := _db_pos(-3.0, size.x)
	draw_rect(Rect2(rect.position, Vector2(minf(rect.size.x, green_w), rect.size.y)), CdPalette.METER_LOW)
	if rect.size.x > green_w:
		draw_rect(Rect2(Vector2(green_w, rect.position.y), Vector2(minf(rect.size.x, amber_w) - green_w, rect.size.y)), CdPalette.METER_MID)
	if rect.size.x > amber_w:
		draw_rect(Rect2(Vector2(amber_w, rect.position.y), Vector2(rect.size.x - amber_w, rect.size.y)), CdPalette.METER_HIGH)
