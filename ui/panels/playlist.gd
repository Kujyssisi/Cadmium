extends Control
## Playlist: pattern, audio and automation clips laid out in song time.
##
## Same canvas approach as the piano roll -- one Control that draws the ruler,
## the track headers and every clip, so nothing can drift out of alignment.

const HEAD_W := 128.0
const RULER_H := 22.0
## Song overview strip above the ruler: the whole arrangement at a glance, with
## the playhead and the part of it you are looking at.
const MAP_H := 26.0

var px_per_beat := 24.0
var scroll_beat := 0.0
var scroll_y := 0.0

var _drag := ""
var _drag_clip := -1
var _drag_from := Vector2.ZERO
var _pan_from := Vector2.ZERO   ## scroll position when a middle-button pan began
var _peak_cache := {}           ## view key -> waveform, see _wave_lines
var _drag_origin := {}
var _band := Rect2()
var _hover_clip := -1
## The automation point being dragged: the clip it belongs to and its index in
## that automation's point list.
var _auto_clip := -1
var _auto_point := -1
## Rubbing clips out with the right button held: whether this gesture has taken
## its undo step yet, and where the pointer was when it was last sampled.
var _erased := false
var _erase_last := Vector2.ZERO
## Where a scrub wants the playhead. Applied once a frame rather than once per
## motion event: moving the playhead stops every note, retriggers what the new
## position is inside of, and takes the audio thread's lock to do it, and a
## mouse reporting a thousand times a second asked for all of that a thousand
## times a second. That is what made dragging the playhead so laggy.
var _scrub_to := -1.0
## Where a shift-drag on the ruler started, in beats.
var _mark_from := 0.0


func _ready() -> void:
	theme_type_variation = "Dock"
	focus_mode = Control.FOCUS_CLICK
	mouse_filter = Control.MOUSE_FILTER_STOP
	clip_contents = true
	App.playlist_changed.connect(queue_redraw)
	App.sample_changed.connect(_forget_sample)
	App.patterns_changed.connect(queue_redraw)
	App.project_loaded.connect(queue_redraw)
	App.selection_changed.connect(queue_redraw)
	set_process(true)


func _process(_dt: float) -> void:
	_guard_drag()
	if _scrub_to >= 0.0:
		Audio.seek(_scrub_to)
		_scrub_to = -1.0
		queue_redraw()
	if not Audio.playing():
		return
	if bool(Settings.get_value("follow_playhead", true)) and App.mode() == Cd.Mode.SONG:
		var beat := Audio.position()
		var visible_beats := (size.x - HEAD_W) / px_per_beat
		if beat < scroll_beat or beat > scroll_beat + visible_beats * 0.9:
			scroll_beat = maxf(0.0, beat - visible_beats * 0.1)
	queue_redraw()


## Same guard as the piano roll: a button released outside the window still
## ends the drag.
func _guard_drag() -> void:
	if _drag == "autopoint" and not Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		_drag = ""
		_auto_clip = -1
		_auto_point = -1
	if _drag.is_empty():
		return
	if Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT) or Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT):
		return
	if _drag == "select":
		_finish_band(false)
	elif _drag in ["move", "resize", "resize_left"]:
		App.clip_edit_done()
	_drag = ""
	_band = Rect2()
	queue_redraw()


func _track_h(i: int) -> float:
	return float(App.project.tracks[i].get("height", 46.0)) if i < App.project.tracks.size() else 46.0


func _map_rect() -> Rect2:
	return Rect2(HEAD_W, 0, maxf(0.0, size.x - HEAD_W), MAP_H)


func _song_span() -> float:
	return maxf(16.0, App.project.length_beats() + 8.0)


func _track_y(i: int) -> float:
	var y := RULER_H + MAP_H - scroll_y
	for t in mini(i, App.project.tracks.size()):
		y += _track_h(t)
	return y


## The strip under the last track header, which adds another one.
func _add_track_rect() -> Rect2:
	var n := App.project.tracks.size()
	var y := _track_y(n)
	return Rect2(0, y, HEAD_W, 20.0)


func _track_at(y: float) -> int:
	var acc := RULER_H + MAP_H - scroll_y
	for i in App.project.tracks.size():
		var h := _track_h(i)
		if y >= acc and y < acc + h:
			return i
		acc += h
	return -1


## The marked stretch tinted over the arrangement, so it is obvious what is
## going to loop and what "Marked region" is going to export.
func _draw_mark() -> void:
	if not App.has_mark():
		return
	var span := App.mark_span()
	var x0 := maxf(HEAD_W, _beat_to_x(span.x))
	var x1 := minf(size.x, _beat_to_x(span.y))
	if x1 <= x0:
		return
	var top := MAP_H + RULER_H
	draw_rect(Rect2(x0, top, x1 - x0, size.y - top),
			Color(CdPalette.ACCENT.r, CdPalette.ACCENT.g, CdPalette.ACCENT.b, 0.07))
	for x in [x0, x1]:
		draw_line(Vector2(x, top), Vector2(x, size.y),
				Color(CdPalette.ACCENT.r, CdPalette.ACCENT.g, CdPalette.ACCENT.b, 0.55), 1.0)


## And a solid bar of it in the ruler itself, which is where it was drawn and
## where it can be taken away again.
func _draw_mark_bar() -> void:
	if not App.has_mark():
		return
	var span := App.mark_span()
	var x0 := maxf(HEAD_W, _beat_to_x(span.x))
	var x1 := minf(size.x, _beat_to_x(span.y))
	if x1 <= x0:
		return
	draw_rect(Rect2(x0, MAP_H + RULER_H - 4.0, x1 - x0, 3.0), CdPalette.ACCENT)


## Said once, when the drag ends, rather than on every pixel of it.
func _announce_mark() -> void:
	if not App.has_mark():
		return
	var span := App.mark_span()
	var sig := maxf(1.0, float(App.project.sig_num))
	App.status.emit("Marked %s (%.2g bars) -- loops, and exports as the marked region"
			% [Cd.format_seconds((span.y - span.x) * 60.0 / maxf(20.0, float(App.project.bpm))),
			(span.y - span.x) / sig])


func _beat_to_x(b: float) -> float:
	return HEAD_W + (b - scroll_beat) * px_per_beat


func _x_to_beat(x: float) -> float:
	return scroll_beat + (x - HEAD_W) / px_per_beat


## Matches the piano roll: a grab strip that scales with the clip instead of a
## fixed sliver.
func _edge_zone(r: Rect2) -> float:
	return clampf(r.size.x * 0.25, 6.0, 16.0)


## Whether the pointer is on one of a clip's ends rather than in the middle.
func _on_edge(clip: int, pos: Vector2) -> bool:
	if clip < 0 or clip >= App.project.clips.size():
		return false
	var r := _clip_rect(App.project.clips[clip])
	var zone := _edge_zone(r)
	return pos.x > r.end.x - zone or pos.x < r.position.x + zone


func _clip_rect(c: Dictionary) -> Rect2:
	var t := int(c.track)
	return Rect2(_beat_to_x(float(c.start)), _track_y(t) + 1.0,
			maxf(4.0, float(c.length) * px_per_beat), _track_h(t) - 2.0)


## The part of an automation clip its curve is drawn in -- the title strip
## along the top is left alone, so the clip can still be picked up and moved.
func _auto_body(r: Rect2) -> Rect2:
	return Rect2(r.position + Vector2(1.0, 12.0), r.size - Vector2(2.0, 13.0))


## Where a point sits on screen. `beat` is measured from the start of the
## automation, which the clip may be showing an offset part of.
func _auto_point_pos(c: Dictionary, body: Rect2, pt: Dictionary) -> Vector2:
	var a: Dictionary = App.project.automations[int(c.index)]
	var lo := float(a.get("lo", 0.0))
	var hi := float(a.get("hi", 1.0))
	var t := clampf((float(pt.get("value", 0.0)) - lo) / maxf(0.0001, hi - lo), 0.0, 1.0)
	var beat := float(c.start) + float(pt.get("beat", 0.0)) - float(c.get("offset", 0.0))
	return Vector2(_beat_to_x(beat), body.end.y - body.size.y * t)


## The point under the pointer, or -1. Generous on purpose: these are small.
func _auto_point_at(ci: int, pos: Vector2) -> int:
	var c: Dictionary = App.project.clips[ci]
	var body := _auto_body(_clip_rect(c))
	var pts: Array = App.project.automations[int(c.index)].points
	var best := -1
	var best_d := 9.0
	for i in pts.size():
		var d := _auto_point_pos(c, body, pts[i]).distance_to(pos)
		if d < best_d:
			best_d = d
			best = i
	return best


## Turns a position on the clip into a point on its automation.
func _auto_point_from(ci: int, pos: Vector2) -> Dictionary:
	var c: Dictionary = App.project.clips[ci]
	var a: Dictionary = App.project.automations[int(c.index)]
	var body := _auto_body(_clip_rect(c))
	var lo := float(a.get("lo", 0.0))
	var hi := float(a.get("hi", 1.0))
	var t := clampf((body.end.y - pos.y) / maxf(1.0, body.size.y), 0.0, 1.0)
	var beat := _x_to_beat(pos.x) - float(c.start) + float(c.get("offset", 0.0))
	var snap := App.snap_beats()
	if snap > 0.0:
		beat = Cd.snap_beat(beat, snap)
	# Kept inside the stretch of the automation this clip is showing. Dragging a
	# point past either end used to put it somewhere with nothing drawn, where
	# it could not be seen, moved or deleted again.
	var from := float(c.get("offset", 0.0))
	beat = clampf(beat, from, from + float(c.length))
	return {"beat": maxf(0.0, beat), "value": lo + t * (hi - lo), "curve": 0.0}


func _is_automation(ci: int) -> bool:
	if ci < 0 or ci >= App.project.clips.size():
		return false
	var c: Dictionary = App.project.clips[ci]
	return int(c.type) == Cd.ClipType.AUTOMATION and int(c.index) < App.project.automations.size()


## Writes the list back sorted, since everything that reads it walks it in time
## order and a dragged point does cross its neighbours.
func _auto_commit(ci: int, pts: Array, keep: Dictionary) -> int:
	pts.sort_custom(func(x, y): return float(x.beat) < float(y.beat))
	App.set_automation_points(int(App.project.clips[ci].index), pts)
	for i in pts.size():
		if pts[i] == keep:
			return i
	return -1


## Every clip between where the pointer was last sampled and where it is now.
## A mouse moving quickly jumps tens of pixels between events, and a clip that
## fell in the gap would survive being dragged straight through.
func _erase_along(to: Vector2) -> void:
	var steps := maxi(1, int(_erase_last.distance_to(to) / 4.0))
	for s in steps + 1:
		var p := _erase_last.lerp(to, float(s) / float(steps))
		# Clips can sit on top of one another; take them all, but never loop
		# on a removal that did not happen.
		for _n in 16:
			var hit := _clip_at(p)
			if hit < 0:
				break
			if not _erased:
				_erased = true
				App.snapshot("Erase clips")
			App.remove_clips([hit], false)
	_erase_last = to
	if _erased:
		queue_redraw()


func _clip_at(pos: Vector2) -> int:
	for i in range(App.project.clips.size() - 1, -1, -1):
		if _clip_rect(App.project.clips[i]).has_point(pos):
			return i
	return -1


# ---------------------------------------------------------------------------
func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		_button(event)
	elif event is InputEventMouseMotion:
		_motion(event)
	elif event is InputEventKey and event.pressed:
		if event.keycode == KEY_DELETE:
			delete_selection()
		elif event.keycode in [KEY_B, KEY_D] and event.ctrl_pressed:
			duplicate_selection()


func _button(mb: InputEventMouseButton) -> void:
	var pos := mb.position
	var snap := maxf(App.snap_beats(), 0.0)

	if mb.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN] and mb.pressed:
		var dir := 1.0 if mb.button_index == MOUSE_BUTTON_WHEEL_UP else -1.0
		if mb.ctrl_pressed:
			var anchor := _x_to_beat(pos.x)
			px_per_beat = clampf(px_per_beat * (1.12 if dir > 0 else 1.0 / 1.12), 2.0, 200.0)
			scroll_beat = maxf(0.0, anchor - (pos.x - HEAD_W) / px_per_beat)
		elif mb.shift_pressed:
			scroll_beat = maxf(0.0, scroll_beat - dir * 240.0 / px_per_beat)
		else:
			scroll_y = maxf(0.0, scroll_y - dir * 48.0)
		accept_event()
		queue_redraw()
		return

	# Middle button pans, from anywhere, as in the piano roll.
	if mb.button_index == MOUSE_BUTTON_MIDDLE:
		if mb.pressed:
			_drag = "pan"
			_drag_from = pos
			_pan_from = Vector2(scroll_beat, scroll_y)
		else:
			_drag = ""
		accept_event()
		return

	if pos.y < MAP_H and pos.x > HEAD_W:
		if mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT:
			_scroll_from_map(pos.x)
			_drag = "map"
			accept_event()
		elif not mb.pressed:
			_drag = ""
		return

	if pos.y < RULER_H + MAP_H:
		if mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT:
			# Double-click takes the mark away again.
			if mb.double_click:
				if App.has_mark():
					App.clear_mark()
					App.status.emit("Mark cleared")
				_drag = ""
				queue_redraw()
				accept_event()
				return
			# Shift and drag marks a stretch out: what loops, and what the
			# export window offers as "Marked region".
			if mb.shift_pressed:
				_mark_from = maxf(0.0, Cd.snap_beat(_x_to_beat(pos.x), snap))
				App.clear_mark()
				_drag = "mark"
				queue_redraw()
				accept_event()
				return
			App.set_mode(Cd.Mode.SONG)
			_scrub_to = maxf(0.0, Cd.snap_beat(_x_to_beat(pos.x), snap))
			_drag = "scrub"
			accept_event()
		elif not mb.pressed:
			if _drag == "mark":
				_announce_mark()
			_drag = ""
		return

	if pos.x < HEAD_W:
		if mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT \
				and _add_track_rect().has_point(pos):
			var i := App.add_track()
			App.status.emit("Added %s" % String(App.project.tracks[i].name))
			queue_redraw()
			accept_event()
			return
		var t := _track_at(pos.y)
		if t >= 0 and mb.pressed:
			if mb.button_index == MOUSE_BUTTON_LEFT:
				App.project.tracks[t].mute = not bool(App.project.tracks[t].get("mute", false))
				_mute_track(t)
			elif mb.button_index == MOUSE_BUTTON_RIGHT:
				_track_menu(t)
			queue_redraw()
			accept_event()
		return

	if mb.button_index == MOUSE_BUTTON_RIGHT:
		if mb.pressed:
			var hit := _clip_at(pos)
			# On an automation curve the right button takes away a point, not
			# the whole clip -- deleting the clip you were editing on a misclick
			# is not a trade anyone wants.
			if _is_automation(hit):
				var pi := _auto_point_at(hit, pos)
				if pi >= 0:
					App.snapshot("Delete automation point")
					var pts: Array = App.project.automations[int(App.project.clips[hit].index)].points.duplicate(true)
					pts.remove_at(pi)
					_auto_commit(hit, pts, {})
					accept_event()
					queue_redraw()
					return
			if hit >= 0 and mb.ctrl_pressed:
				_clip_menu(hit)
				accept_event()
				return
			# Held down, the right button rubs out everything it is dragged
			# over, starting with whatever it landed on. One gesture, one undo
			# step, however many clips go.
			_drag = "erase"
			_erased = false
			_erase_last = pos
			_erase_along(pos)
			accept_event()
		else:
			_drag = ""
		return

	if mb.button_index != MOUSE_BUTTON_LEFT:
		return

	if not mb.pressed:
		if _drag == "select":
			_finish_band(mb.shift_pressed)
		elif _drag in ["move", "resize", "resize_left"]:
			App.clip_edit_done()
		elif _drag == "autopoint":
			_auto_clip = -1
			_auto_point = -1
		_drag = ""
		_band = Rect2()
		queue_redraw()
		return

	var hit := _clip_at(pos)
	# Twice on an automation clip opens the lane on its own, with room to draw
	# in: a clip an inch tall is somewhere to nudge a point, not somewhere to
	# make a shape.
	if mb.double_click and _is_automation(hit):
		CdAutomationWindow.open(self, int(App.project.clips[hit].index))
		_drag = ""
		accept_event()
		return
	# The body of an automation clip is its curve, and clicking it edits the
	# curve. The title strip along the top still picks the clip up, which is
	# how it gets moved, muted and sliced -- and so do its two edges, or an
	# automation clip would be the one kind you could not take hold of by the
	# end to make it longer or shorter.
	if _is_automation(hit) and pos.y > _clip_rect(App.project.clips[hit]).position.y + 12.0 \
			and not _on_edge(hit, pos) \
			and App.tool in [Cd.Tool.DRAW, Cd.Tool.SELECT]:
		_pick_up(hit)
		var ai := int(App.project.clips[hit].index)
		var pts: Array = App.project.automations[ai].points.duplicate(true)
		var pi := _auto_point_at(hit, pos)
		App.snapshot("Move automation point" if pi >= 0 else "Add automation point")
		if pi < 0:
			var np := _auto_point_from(hit, pos)
			pts.append(np)
			pi = _auto_commit(hit, pts, np)
		_auto_clip = hit
		_auto_point = pi
		_drag = "autopoint"
		accept_event()
		queue_redraw()
		return
	if App.tool == Cd.Tool.SLICE:
		if hit >= 0:
			_slice_clip(hit, _x_to_beat(pos.x))
		accept_event()
		queue_redraw()
		return
	if App.tool == Cd.Tool.MUTE:
		if hit >= 0:
			App.snapshot("Mute clip")
			App.update_clip(hit, {"mute": not bool(App.project.clips[hit].get("mute", false))})
			App.clip_edit_done()
		accept_event()
		queue_redraw()
		return
	if hit >= 0:
		var r := _clip_rect(App.project.clips[hit])
		_pick_up(hit)
		if not App.selected_clips.has(hit):
			if not mb.shift_pressed:
				App.selected_clips.clear()
			App.selected_clips.append(hit)
		App.snapshot("Move clip")
		# Either end. The far end trims the tail; the near end trims the head,
		# taking what is played with it so the rest of the clip stays put.
		var zone := _edge_zone(r)
		if pos.x > r.end.x - zone:
			_hold(hit, pos, "resize")
		elif pos.x < r.position.x + zone:
			_hold(hit, pos, "resize_left")
		else:
			_hold(hit, pos, "move")
	elif mb.shift_pressed or App.tool == Cd.Tool.SELECT:
		_drag = "select"
		_drag_from = pos
		_band = Rect2(pos, Vector2.ZERO)
	else:
		# Painting is how an arrangement gets built, and what it paints is
		# whatever was last clicked -- a pattern, a sample, an automation clip.
		var t := _track_at(pos.y)
		if t >= 0:
			var beat := maxf(0.0, Cd.floor_snap(_x_to_beat(pos.x), maxf(snap, 0.25)))
			var item := App.current_paint_item()
			var idx := App.place_item(String(item.kind), int(item.index), t, beat,
					item.get("props", {}))
			if idx >= 0:
				# Putting a clip down and dragging is one gesture: the clip
				# follows the pointer until the button comes up, the way it
				# does when you drag one that is already there. No snapshot --
				# adding it took one, and undoing should take the clip away
				# rather than leave it at the beat it was born on.
				App.selected_clips = [idx]
				_hold(idx, pos, "move")
	accept_event()
	queue_redraw()


## Takes hold of the selection for a drag. Where every clip was is remembered
## here, so each frame of the drag is worked out from where the gesture started
## rather than from the frame before it, which would drift.
func _hold(clip: int, pos: Vector2, kind: String) -> void:
	_drag_clip = clip
	_drag_from = pos
	_drag_origin = {}
	for i in App.selected_clips:
		var c: Dictionary = App.project.clips[int(i)]
		_drag_origin[i] = {"start": float(c.start), "track": int(c.track),
				"length": float(c.length), "offset": float(c.get("offset", 0.0))}
	_drag = kind


## Clicking a clip picks up what it plays, so the next thing drawn is another
## one of the same -- the way clicking a clip in FL makes it the current thing.
## A pattern clip also makes its pattern the one the piano roll is editing.
func _pick_up(clip: int) -> void:
	if clip < 0 or clip >= App.project.clips.size():
		return
	var c: Dictionary = App.project.clips[clip]
	var index := int(c.index)
	# Everything about it except where it is: length, how far into the file it
	# starts, its level, its pitch and its name. Drawing gives you that clip
	# again rather than a default one.
	var props := {}
	for key in ["length", "offset", "gain", "pitch", "name"]:
		if c.has(key):
			props[key] = c[key]
	match int(c.type):
		Cd.ClipType.PATTERN:
			if App.current_pattern != index:
				App.select_pattern(index)
			App.set_paint_item("pattern", index, props)
		Cd.ClipType.AUDIO:
			App.set_paint_item("sample", index, props)
		Cd.ClipType.AUTOMATION:
			App.set_paint_item("automation", index, props)


func _motion(mm: InputEventMouseMotion) -> void:
	var pos := mm.position
	var snap := maxf(App.snap_beats(), 0.25)
	match _drag:
		"autopoint":
			if _auto_point < 0 or not _is_automation(_auto_clip):
				return
			var ai := int(App.project.clips[_auto_clip].index)
			var pts: Array = App.project.automations[ai].points.duplicate(true)
			if _auto_point >= pts.size():
				return
			var moved := _auto_point_from(_auto_clip, pos)
			moved["curve"] = float(pts[_auto_point].get("curve", 0.0))
			pts[_auto_point] = moved
			_auto_point = _auto_commit(_auto_clip, pts, moved)
			queue_redraw()
			return
		"pan":
			scroll_beat = maxf(0.0, _pan_from.x - (pos.x - _drag_from.x) / px_per_beat)
			scroll_y = maxf(0.0, _pan_from.y - (pos.y - _drag_from.y))
			queue_redraw()
		"map":
			_scroll_from_map(pos.x)
		"scrub":
			_scrub_to = maxf(0.0, Cd.snap_beat(_x_to_beat(pos.x), App.snap_beats()))
			queue_redraw()
		"mark":
			App.set_mark(_mark_from, maxf(0.0, Cd.snap_beat(_x_to_beat(pos.x), App.snap_beats())))
			queue_redraw()
		"select":
			_band = Rect2(_drag_from, pos - _drag_from).abs()
		"erase":
			_erase_along(pos)
		"move":
			var dbeat := Cd.snap_beat(_x_to_beat(pos.x) - _x_to_beat(_drag_from.x), snap)
			# Dragged off the top or the bottom there is no row under the
			# pointer to answer with, so the nearest one holds the drag instead
			# of the clips falling back onto the track they started on.
			var from_track := maxi(0, _track_at(_drag_from.y))
			var to_track := _track_at(pos.y)
			if to_track < 0:
				to_track = 0 if pos.y < _track_y(0) else App.project.tracks.size() - 1
			var dtrack := to_track - from_track
			for i in _drag_origin.keys():
				var o: Dictionary = _drag_origin[i]
				App.update_clip(int(i), {
					"start": maxf(0.0, float(o.start) + dbeat),
					"track": clampi(int(o.track) + dtrack, 0, App.project.tracks.size() - 1),
				})
		"resize":
			for i in _drag_origin.keys():
				var o: Dictionary = _drag_origin[i]
				var want := Cd.snap_beat(_x_to_beat(pos.x) - float(o.start), snap)
				App.update_clip(int(i), {"length": maxf(snap, want)})
		"resize_left":
			# The end stays where it is. The start moves, and what the clip
			# plays moves into it by the same amount, so the audio, the notes
			# or the curve under the part still showing does not slide about.
			for i in _drag_origin.keys():
				var o: Dictionary = _drag_origin[i]
				var tail: float = float(o.start) + float(o.length)
				# Not back past the beginning of what it plays, and not through
				# its own end.
				var floor_beat: float = maxf(0.0, float(o.start) - float(o.offset))
				var want := clampf(Cd.snap_beat(_x_to_beat(pos.x), snap), floor_beat, tail - snap)
				var moved := want - float(o.start)
				App.update_clip(int(i), {"start": want,
						"length": maxf(snap, float(o.length) - moved),
						"offset": maxf(0.0, float(o.offset) + moved)})
		_:
			var hit := _clip_at(pos)
			if hit != _hover_clip:
				_hover_clip = hit
				queue_redraw()
			return
	queue_redraw()


func _scroll_from_map(x: float) -> void:
	var m := _map_rect()
	var t := clampf((x - m.position.x) / maxf(1.0, m.size.x), 0.0, 1.0)
	var visible_beats := (size.x - HEAD_W) / px_per_beat
	scroll_beat = maxf(0.0, _song_span() * t - visible_beats * 0.5)
	queue_redraw()


## Cut a clip in two where you click. The right-hand piece keeps playing from
## the same point in the pattern, which is what makes this useful for
## rearranging rather than just trimming.
func _slice_clip(index: int, at_beat: float) -> void:
	if index < 0 or index >= App.project.clips.size():
		return
	var c: Dictionary = App.project.clips[index]
	var cut := Cd.snap_beat(at_beat, maxf(App.snap_beats(), 0.25))
	var start := float(c.start)
	var end := start + float(c.length)
	if cut <= start + 0.05 or cut >= end - 0.05:
		return
	App.snapshot("Slice clip")
	App.update_clip(index, {"length": cut - start})
	var extra := c.duplicate()
	extra["start"] = cut
	extra["length"] = end - cut
	extra["offset"] = float(c.get("offset", 0.0)) + (cut - start)
	App.add_clip(int(c.type), int(c.index), int(c.track), cut, end - cut, extra)
	App.clip_edit_done()


func _clip_menu(index: int) -> void:
	var pm := PopupMenu.new()
	add_child(pm)
	var c: Dictionary = App.project.clips[index]
	pm.add_item("Mute" if not bool(c.get("mute", false)) else "Unmute", 0)
	pm.add_item("Duplicate", 1)
	pm.add_item("Delete", 2)
	pm.add_item("Slice at Playhead", 4)
	pm.add_separator()
	pm.add_item("Add Audio File...", 3)
	if int(c.type) == Cd.ClipType.AUDIO:
		pm.add_item("Set Project Tempo from This Clip", 5)
	pm.id_pressed.connect(func(id):
		match id:
			0:
				App.update_clip(index, {"mute": not bool(c.get("mute", false))})
				App.clip_edit_done()
			1:
				var copy: Dictionary = c.duplicate()
				App.add_clip(int(copy.type), int(copy.index), int(copy.track),
						float(copy.start) + float(copy.length), float(copy.length), copy)
			2:
				App.remove_clips([index])
			3:
				_pick_audio(int(c.track), float(c.start))
			4:
				_slice_clip(index, Audio.position())
			5:
				_detect_clip_tempo(index)
		pm.queue_free())
	pm.popup(Rect2i(DisplayServer.mouse_get_position(), Vector2i(1, 1)))


func _detect_clip_tempo(index: int) -> void:
	var c: Dictionary = App.project.clips[index]
	var ai := int(c.index)
	if ai < 0 or ai >= App.project.assets.size():
		return
	var wav := String(App.project.assets[ai].get("wav", ""))
	if wav.is_empty():
		return
	App.status.emit("Analysing...")
	await get_tree().process_frame
	var res: Dictionary = Audio.engine.analyze(wav)
	if not bool(res.get("ok", false)):
		App.status.emit("Could not find a tempo in that clip")
		return
	App.set_bpm(float(res.bpm))
	App.status.emit("Tempo set to %.2f (%s, confidence %d%%)" % [float(res.bpm),
			Cd.key_name(int(res.key), bool(res.minor)), int(float(res.key_confidence) * 100.0)])


func _pick_audio(track: int, beat: float) -> void:
	var fd := FileDialog.new()
	fd.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	fd.access = FileDialog.ACCESS_FILESYSTEM
	fd.filters = PackedStringArray([Cd.AUDIO_FILTER])
	# The desktop's own chooser when the platform offers one (the XDG portal on
	# Linux, the shell dialog on Windows); Godot's built-in is the fallback.
	fd.use_native_dialog = DisplayServer.has_feature(DisplayServer.FEATURE_NATIVE_DIALOG_FILE)
	fd.size = Vector2i(880, 600)
	add_child(fd)
	fd.file_selected.connect(func(p):
		add_audio_clip(p, track, beat)
		fd.queue_free())
	fd.canceled.connect(func(): fd.queue_free())
	fd.popup_centered()


func _finish_band(add: bool) -> void:
	if not add:
		App.selected_clips.clear()
	for i in App.project.clips.size():
		if _band.intersects(_clip_rect(App.project.clips[i])) and not App.selected_clips.has(i):
			App.selected_clips.append(i)
	App.selection_changed.emit()


func paste_anchor() -> float:
	var beat := Audio.position()
	var visible := (size.x - HEAD_W) / px_per_beat
	if beat < scroll_beat or beat > scroll_beat + visible:
		beat = scroll_beat
	return Cd.snap_beat(maxf(0.0, beat), maxf(App.snap_beats(), 0.25))


## Copies the selected clips to directly after the block they make up. Holding
## the shortcut repeats it, which is how a four-bar loop becomes thirty-two.
func duplicate_selection() -> void:
	if App.selected_clips.is_empty():
		return
	App.snapshot("Duplicate clips")
	var start := INF
	var end := 0.0
	for i in App.selected_clips:
		var c: Dictionary = App.project.clips[int(i)]
		start = minf(start, float(c.start))
		end = maxf(end, float(c.start) + float(c.length))
	var shift := maxf(end - start, 0.25)
	var added := []
	for i in App.selected_clips:
		var c: Dictionary = App.project.clips[int(i)]
		var extra := {}
		for k in ["name", "offset", "gain", "pitch", "mute"]:
			if c.has(k):
				extra[k] = c[k]
		added.append(App.add_clip(int(c.type), int(c.index), int(c.track),
				float(c.start) + shift, float(c.length), extra))
	App.selected_clips = added
	App.clip_edit_done()
	queue_redraw()


func delete_selection() -> void:
	if App.selected_clips.is_empty():
		return
	App.remove_clips(App.selected_clips)
	queue_redraw()


func _mute_track(t: int) -> void:
	var muted := bool(App.project.tracks[t].get("mute", false))
	for i in App.project.clips.size():
		if int(App.project.clips[i].track) == t:
			App.update_clip(i, {"mute": muted})
	App.clip_edit_done()
	if muted:
		App.silence_track(t)


func _track_menu(t: int) -> void:
	var pm := PopupMenu.new()
	add_child(pm)
	pm.add_item("Rename Track...", 0)
	pm.add_item("Taller", 1)
	pm.add_item("Shorter", 2)
	pm.add_separator()
	pm.add_item("Add Automation Clip...", 3)
	pm.add_separator()
	pm.add_item("Add Track", 4)
	pm.add_item("Add Five Tracks", 5)
	pm.add_item("Remove Last Track", 6)
	pm.id_pressed.connect(func(id):
		match id:
			0: _rename_track(t)
			1: App.project.tracks[t].height = minf(120.0, _track_h(t) + 12.0)
			2: App.project.tracks[t].height = maxf(24.0, _track_h(t) - 12.0)
			3: _automation_menu(t)
			4: App.status.emit("Added %s" % String(App.project.tracks[App.add_track()].name))
			5:
				for i in 5:
					App.add_track()
				App.status.emit("%d tracks" % App.project.tracks.size())
			6:
				if App.remove_track():
					App.status.emit("%d tracks" % App.project.tracks.size())
		queue_redraw()
		pm.queue_free())
	pm.popup(Rect2i(DisplayServer.mouse_get_position(), Vector2i(1, 1)))


func _rename_track(t: int) -> void:
	var dlg := AcceptDialog.new()
	dlg.title = "Rename Track"
	var field := LineEdit.new()
	field.text = String(App.project.tracks[t].name)
	field.custom_minimum_size.x = 240
	dlg.add_child(field)
	dlg.register_text_enter(field)
	add_child(dlg)
	dlg.confirmed.connect(func():
		App.project.tracks[t].name = field.text
		App.project.dirty = true
		queue_redraw()
		dlg.queue_free())
	dlg.popup_centered()
	field.grab_focus()


## An automation clip needs a target: any mixer fader, or any parameter of any
## instrument or effect currently loaded.
## Offered from the picker as well as from the track header, so "make one of
## these" is reachable from wherever you are looking.
func automation_menu(track: int) -> void:
	_automation_menu(track)


func _automation_menu(track: int) -> void:
	CdTargetMenu.open(self, func(entry): _make_automation(entry, track))


func _make_automation(entry: Dictionary, track: int) -> void:
	var idx := App.add_automation(String(entry.name), int(entry.target), entry.ref,
			int(entry.a), int(entry.b), float(entry.lo), float(entry.hi))
	App.add_clip(Cd.ClipType.AUTOMATION, idx, track, 0.0, maxf(4.0, App.project.length_beats()))
	queue_redraw()


func add_audio_clip(path: String, track: int, beat: float) -> void:
	var id := App.add_audio_asset(path)
	if id < 0:
		return
	var length := App.asset_length_beats(path)
	App.add_clip(Cd.ClipType.AUDIO, id, track, beat, length, {"name": path.get_file()})
	queue_redraw()


## The track something dropped at `y` belongs on. Past the last track there is
## no row to land on, so the drop gets one of its own under the arrangement
## rather than piling onto the first track. Above them, on the ruler and the
## overview strip, the top of the arrangement is what was meant.
func _drop_track(y: float) -> int:
	var track := _track_at(y)
	if track >= 0:
		return track
	return 0 if y < _track_y(0) else App.add_track()


## Where a drop at `pos` starts, snapped, with the header column meaning zero.
func _drop_beat(x: float) -> float:
	if x < HEAD_W:
		return 0.0
	return maxf(0.0, Cd.floor_snap(_x_to_beat(x), maxf(App.snap_beats(), 0.25)))


## An audio file dropped on the window, placed where the pointer was.
func drop_audio_at(path: String, pos: Vector2) -> void:
	add_audio_clip(path, _drop_track(pos.y), _drop_beat(pos.x))


func _can_drop_data(_pos: Vector2, data: Variant) -> bool:
	return typeof(data) == TYPE_DICTIONARY and bool(data.get("cadmium", false)) \
			and String(data.get("kind", "")) in ["sample", "pattern", "automation"]


func _drop_data(pos: Vector2, data: Variant) -> void:
	var track := _drop_track(pos.y)
	var beat := _drop_beat(pos.x)
	match String(data.get("kind", "")):
		"sample":
			add_audio_clip(String(data.path), track, beat)
			App.status.emit("Added %s" % String(data.get("label", "audio")))
		"pattern":
			var pi := int(data.index)
			var length: float = float(App.project.patterns[pi].length)
			App.add_clip(Cd.ClipType.PATTERN, pi, track, beat, length)
		"automation":
			var ai := int(data.index)
			if ai >= 0 and ai < App.project.automations.size():
				App.add_clip(Cd.ClipType.AUTOMATION, ai, track, beat,
						maxf(4.0, App.project.length_beats()))
	queue_redraw()


# ---------------------------------------------------------------------------
func _draw() -> void:
	var font := get_theme_default_font()
	draw_rect(Rect2(Vector2.ZERO, size), CdPalette.VIEWPORT)
	var sig := float(App.project.sig_num)

	# Grid. Bar lines are dropped once they are closer together than they are
	# useful, and only the labelled ones are drawn beyond that -- otherwise the
	# whole view fills in solid when you zoom out.
	var step := Cd.ruler_step(px_per_beat, int(sig))
	var per_bar := px_per_beat * sig
	var draw_every_bar := per_bar >= 5.0
	var bar := floorf(scroll_beat / sig) * sig
	while true:
		var x := _beat_to_x(bar)
		if x > size.x:
			break
		if x >= HEAD_W:
			var number := int(bar / sig) + 1
			var marked: bool = Cd.ruler_labels(number, step)
			if draw_every_bar or marked:
				draw_line(Vector2(x, RULER_H + MAP_H), Vector2(x, size.y),
						CdPalette.GRID_BAR if marked else CdPalette.GRID_BEAT, 1.0)
			if px_per_beat > 12.0:
				for b in range(1, int(sig)):
					var bx := _beat_to_x(bar + float(b))
					if bx >= HEAD_W:
						draw_line(Vector2(bx, RULER_H + MAP_H), Vector2(bx, size.y), CdPalette.GRID_BEAT, 1.0)
		bar += sig

	# Tracks.
	for i in App.project.tracks.size():
		var y := _track_y(i)
		var h := _track_h(i)
		if y + h < RULER_H + MAP_H or y > size.y:
			continue
		var muted := bool(App.project.tracks[i].get("mute", false))
		draw_rect(Rect2(HEAD_W, y, size.x - HEAD_W, h),
				Color(0, 0, 0, 0.18) if i % 2 == 1 else Color(0, 0, 0, 0.0))
		draw_line(Vector2(HEAD_W, y + h), Vector2(size.x, y + h), CdPalette.RULE_DARK, 1.0)
		draw_rect(Rect2(0, y, HEAD_W, h), CdPalette.PANEL if not muted else CdPalette.PANEL.darkened(0.2))
		draw_rect(Rect2(0, y, 4, h), CdPalette.track_color(int(App.project.tracks[i].get("color", i))))
		draw_line(Vector2(0, y + h), Vector2(HEAD_W, y + h), CdPalette.RULE_DARK, 1.0)
		draw_string(font, Vector2(10, y + h * 0.5 + 4.0), String(App.project.tracks[i].name),
				HORIZONTAL_ALIGNMENT_LEFT, HEAD_W - 24, 10,
				CdPalette.TEXT_MUTE if muted else CdPalette.TEXT_DIM)
		if muted:
			draw_string(font, Vector2(HEAD_W - 22, y + h * 0.5 + 4.0), "M",
					HORIZONTAL_ALIGNMENT_LEFT, 20, 10, CdPalette.BAD)
	# One more row under the last: twelve tracks is where a song starts, not
	# where it has to stay, and the right-click menu is not somewhere you go
	# looking for a thing you did not know was there.
	var add := _add_track_rect()
	if add.size.y > 0.0 and add.position.y < size.y:
		draw_rect(add, CdPalette.PANEL.darkened(0.12))
		draw_line(add.position, Vector2(add.end.x, add.position.y), CdPalette.RULE_DARK, 1.0)
		draw_string(font, Vector2(10, add.get_center().y + 4.0), "+ track",
				HORIZONTAL_ALIGNMENT_LEFT, HEAD_W - 12, 10, CdPalette.TEXT_MUTE)

	# Clips.
	for i in App.project.clips.size():
		_draw_clip(i, font)

	if _drag == "select" and _band.size.length() > 2.0:
		draw_rect(_band, Color(CdPalette.ACCENT.r, CdPalette.ACCENT.g, CdPalette.ACCENT.b, 0.15))
		draw_rect(_band, CdPalette.ACCENT, false, 1.0)

	# The marked stretch, under the ruler and over the clips, so it reads as
	# part of the timeline rather than as something sitting on the arrangement.
	_draw_mark()

	# Ruler last, so clips scroll under it.
	draw_rect(Rect2(0, MAP_H, size.x, RULER_H), CdPalette.CAPTION)
	draw_line(Vector2(0, RULER_H + MAP_H), Vector2(size.x, RULER_H + MAP_H), CdPalette.RULE_DARK, 1.0)
	bar = floorf(scroll_beat / sig) * sig
	var bpm := float(App.project.bpm)
	while true:
		var x := _beat_to_x(bar)
		if x > size.x:
			break
		if x >= HEAD_W:
			var number := int(bar / sig) + 1
			if Cd.ruler_labels(number, step):
				draw_line(Vector2(x, MAP_H + 4), Vector2(x, MAP_H + RULER_H), CdPalette.TEXT_MUTE, 1.0)
				var text := str(number)
				# Far enough out that bar numbers stop meaning much, the clock
				# is what you are actually navigating by.
				if step >= 10:
					text += "  " + Cd.format_seconds(bar * 60.0 / maxf(20.0, bpm))
				draw_string(font, Vector2(x + 3, MAP_H + 13), text,
						HORIZONTAL_ALIGNMENT_LEFT, -1, 9, CdPalette.TEXT_DIM)
			elif per_bar >= 14.0:
				draw_line(Vector2(x, MAP_H + RULER_H - 5), Vector2(x, MAP_H + RULER_H),
						CdPalette.RULE_LIGHT, 1.0)
		bar += sig
	_draw_mark_bar()
	draw_rect(Rect2(0, MAP_H, HEAD_W, RULER_H), CdPalette.CAPTION)
	draw_string(font, Vector2(8, MAP_H + 15), "PLAYLIST", HORIZONTAL_ALIGNMENT_LEFT, HEAD_W, 9, CdPalette.TEXT_MUTE)

	var px := _beat_to_x(Audio.position())
	if px >= HEAD_W and px < size.x:
		_draw_playhead(px, MAP_H, size.y)
	_draw_minimap(font)


## The whole song in one strip: every clip, the playhead, and a box showing what
## the main view is looking at. Click or drag it to move.
func _draw_minimap(font: Font) -> void:
	var m := _map_rect()
	draw_rect(Rect2(0, 0, size.x, MAP_H), CdPalette.SUNKEN)
	draw_rect(m, CdPalette.WELL)
	draw_string(font, Vector2(8, MAP_H - 9), "SONG", HORIZONTAL_ALIGNMENT_LEFT, HEAD_W, 9, CdPalette.TEXT_MUTE)
	var span := _song_span()
	var tracks: int = maxi(1, App.project.tracks.size())
	var sig := float(App.project.sig_num)
	var bars_per := maxf(1.0, span / sig)
	var bar_step: float = maxf(1.0, ceilf(bars_per / 24.0))
	var b := 0.0
	while b < span:
		var x: float = m.position.x + m.size.x * (b / span)
		draw_line(Vector2(x, 2), Vector2(x, MAP_H - 2), CdPalette.GRID_BEAT, 1.0)
		b += sig * bar_step
	for c in App.project.clips:
		var x0: float = m.position.x + m.size.x * (float(c.start) / span)
		var w: float = maxf(1.5, m.size.x * (float(c.length) / span))
		var t := int(c.track)
		var y: float = m.position.y + 2.0 + (m.size.y - 4.0) * (float(t) / float(tracks))
		var h: float = maxf(1.5, (m.size.y - 4.0) / float(tracks))
		var col := CdPalette.RAISED
		match int(c.type):
			Cd.ClipType.PATTERN:
				var pi := int(c.index)
				if pi < App.project.patterns.size():
					col = CdPalette.track_color(int(App.project.patterns[pi].get("color", pi)))
			Cd.ClipType.AUDIO:
				col = Color("#4f8f92")
			Cd.ClipType.AUTOMATION:
				col = Color("#8a6ba8")
		if bool(c.get("mute", false)):
			col = col.darkened(0.5)
		draw_rect(Rect2(x0, y, w, h), col)
	# What the main view is showing.
	var visible_beats := (size.x - HEAD_W) / px_per_beat
	var vx: float = m.position.x + m.size.x * clampf(scroll_beat / span, 0.0, 1.0)
	var vw: float = m.size.x * clampf(visible_beats / span, 0.02, 1.0)
	draw_rect(Rect2(vx, m.position.y + 1.0, vw, m.size.y - 2.0), Color(1, 1, 1, 0.10))
	draw_rect(Rect2(vx, m.position.y + 1.0, vw, m.size.y - 2.0), CdPalette.TEXT_DIM, false, 1.0)
	var hx: float = m.position.x + m.size.x * clampf(Audio.position() / span, 0.0, 1.0)
	draw_line(Vector2(hx, m.position.y), Vector2(hx, m.end.y), CdPalette.PLAYHEAD, 1.0)


func _draw_playhead(x: float, top: float, bottom: float) -> void:
	var c := CdPalette.PLAYHEAD
	draw_line(Vector2(x + 1.0, top), Vector2(x + 1.0, bottom), Color(0, 0, 0, 0.55), 3.0)
	draw_line(Vector2(x, top), Vector2(x, bottom), c, 1.6)
	var head := PackedVector2Array([
		Vector2(x - 6.0, top), Vector2(x + 6.0, top), Vector2(x, top + 9.0)])
	draw_colored_polygon(head, c)
	draw_polyline(PackedVector2Array([head[0], head[1], head[2], head[0]]),
			Color(0, 0, 0, 0.5), 1.0, true)


func _draw_clip(i: int, font: Font) -> void:
	var c: Dictionary = App.project.clips[i]
	var r := _clip_rect(c)
	if r.end.x < HEAD_W or r.position.x > size.x or r.end.y < RULER_H + MAP_H or r.position.y > size.y:
		return
	var visible := r.intersection(Rect2(HEAD_W, RULER_H + MAP_H, size.x - HEAD_W, size.y - RULER_H - MAP_H))
	if visible.size.x <= 0.0:
		return
	var sel := App.selected_clips.has(i)
	var muted := bool(c.get("mute", false))
	var col := CdPalette.RAISED
	var label := "?"
	match int(c.type):
		Cd.ClipType.PATTERN:
			var pi := int(c.index)
			if pi < App.project.patterns.size():
				col = CdPalette.track_color(int(App.project.patterns[pi].get("color", pi)))
				label = String(App.project.patterns[pi].name)
		Cd.ClipType.AUDIO:
			col = Color("#4f8f92")
			label = String(c.get("name", "audio"))
		Cd.ClipType.AUTOMATION:
			col = Color("#8a6ba8")
			var ai := int(c.index)
			if ai < App.project.automations.size():
				label = String(App.project.automations[ai].name)
	if muted:
		col = col.darkened(0.45)
	draw_rect(visible, Color(col.r, col.g, col.b, 0.85 if not sel else 1.0))
	draw_rect(visible, CdPalette.TEXT if sel else col.darkened(0.4), false, 1.0)
	draw_rect(Rect2(visible.position, Vector2(visible.size.x, 11.0)), col.darkened(0.25))
	draw_string(font, visible.position + Vector2(4, 9), label, HORIZONTAL_ALIGNMENT_LEFT,
			visible.size.x - 6, 9, Color(0.08, 0.08, 0.08))

	match int(c.type):
		Cd.ClipType.PATTERN:
			_draw_pattern_preview(c, visible)
		Cd.ClipType.AUTOMATION:
			_draw_automation_preview(i, c, visible)
		Cd.ClipType.AUDIO:
			_draw_audio_preview(c, visible)


## The notes inside a pattern clip, drawn the way the piano roll draws them:
## every note clipped to the clip it belongs to, coloured by the channel that
## plays it, and vertically spread over whatever range the pattern actually
## uses. Nothing is allowed to spill past the clip's edges.
func _draw_pattern_preview(c: Dictionary, r: Rect2) -> void:
	var pi := int(c.index)
	if pi >= App.project.patterns.size():
		return
	var notes: Array = App.project.patterns[pi].notes
	if notes.is_empty():
		return
	var body := Rect2(r.position + Vector2(1.0, 12.0), r.size - Vector2(2.0, 13.0))
	if body.size.y < 3.0 or body.size.x < 1.0:
		return

	var lo := 127
	var hi := 0
	for n in notes:
		lo = mini(lo, int(n.key))
		hi = maxi(hi, int(n.key))
	# Rows are a readable height whatever the pattern's range is, and the block
	# of them is centred: stretching one octave over a tall clip looks like a
	# different piece of music, and squeezing five octaves into it looks like a
	# smear at the bottom.
	var span := maxi(4, hi - lo + 1)
	var row := clampf(body.size.y / float(span), 1.5, 5.0)
	var block := row * float(span)
	var base := body.position.y + (body.size.y + block) * 0.5

	var plen := maxf(0.25, float(App.project.patterns[pi].length))
	var offset := float(c.get("offset", 0.0))
	var clen := float(c.length)
	var reps := maxi(1, int(ceil((clen + offset) / plen)))
	# Only the repetitions that are actually on screen: a four-bar pattern on a
	# five-minute clip is three hundred of them, and all but a handful are off
	# the side of the window.
	var vis_from: float = _x_to_beat(body.position.x) - float(c.start) + offset
	var vis_to: float = _x_to_beat(body.end.x) - float(c.start) + offset
	var rep_from: int = clampi(int(floor(vis_from / plen)), 0, maxi(0, reps - 1))
	var rep_to: int = clampi(int(ceil(vis_to / plen)) + 1, rep_from + 1, reps)
	var dark := Color(0.06, 0.06, 0.07, 0.75)
	for rep in range(rep_from, rep_to):
		for n in notes:
			# Where this repetition of the note falls inside the clip.
			var b := float(n.beat) + float(rep) * plen - offset
			var b_end := b + maxf(0.03, float(n.len))
			if b_end <= 0.0 or b >= clen:
				continue
			var x0 := _beat_to_x(float(c.start) + maxf(0.0, b))
			var x1 := _beat_to_x(float(c.start) + minf(clen, b_end))
			# Clamped, not skipped: a note that starts before the visible part
			# of the clip still has a tail you should be able to see.
			x0 = maxf(x0, body.position.x)
			x1 = minf(x1, body.end.x)
			if x1 - x0 < 0.75:
				if x1 < body.position.x or x0 > body.end.x:
					continue
				x1 = x0 + 0.75
			var y := base - row * float(int(n.key) - lo + 1)
			y = clampf(y, body.position.y, body.end.y - row)
			var col := dark
			if App.project.channels.size() > 1 and int(n.ch) < App.project.channels.size():
				var cc := CdPalette.track_color(int(App.project.channels[int(n.ch)].get("color", int(n.ch))))
				col = Color(cc.r * 0.35, cc.g * 0.35, cc.b * 0.35, 0.85)
			draw_rect(Rect2(x0, y, x1 - x0, maxf(1.0, row - 0.5)), col)


func _draw_automation_preview(index: int, c: Dictionary, r: Rect2) -> void:
	var ai := int(c.index)
	if ai >= App.project.automations.size():
		return
	var a: Dictionary = App.project.automations[ai]
	var lo := float(a.get("lo", 0.0))
	var hi := float(a.get("hi", 1.0))
	var body := _auto_body(r)
	if body.size.x < 2.0 or body.size.y < 3.0:
		return
	var pts := PackedVector2Array()
	var steps := maxi(8, int(body.size.x / 3.0))
	for s in steps + 1:
		var beat := float(c.start) + float(c.length) * float(s) / float(steps)
		var v := App.automation_value(ai, beat - float(c.start) + float(c.get("offset", 0.0)))
		var t := clampf((v - lo) / maxf(0.0001, hi - lo), 0.0, 1.0)
		var px := clampf(_beat_to_x(beat), body.position.x, body.end.x)
		pts.append(Vector2(px, body.end.y - body.size.y * t))
	if pts.size() > 1:
		draw_polyline(pts, Color(0.08, 0.08, 0.08, 0.9), 1.6, true)
	# The handles. Without something to aim at there is no way to tell that the
	# curve can be edited at all, let alone where its points are.
	var handles: Array = a.points
	if handles.is_empty():
		draw_string(get_theme_default_font(),
				Vector2(body.position.x + 4.0, body.position.y + body.size.y * 0.5 + 4.0),
				"click to add a point", HORIZONTAL_ALIGNMENT_LEFT, body.size.x - 8.0, 9,
				Color(0.08, 0.08, 0.08, 0.55))
	for i in handles.size():
		var hp := _auto_point_pos(c, body, handles[i])
		if hp.x < body.position.x - 6.0 or hp.x > body.end.x + 6.0:
			continue
		var held: bool = _auto_clip == index and _auto_point == i
		draw_circle(hp, 4.5 if held else 3.5, Color(0.08, 0.08, 0.08, 0.9))
		draw_circle(hp, 2.6 if held else 2.0, CdPalette.ACCENT if held else Color(1, 1, 1, 0.92))

	# Where the lane is right now: a light mark riding the curve under the
	# playhead. A clip that draws the same picture whether the song is playing
	# or not tells you nothing about what it is doing at this moment.
	if not Audio.playing():
		return
	var head := Audio.position()
	if head < float(c.start) or head >= float(c.start) + float(c.length):
		return
	var now := App.automation_value(ai, head - float(c.start) + float(c.get("offset", 0.0)))
	var nt := clampf((now - lo) / maxf(0.0001, hi - lo), 0.0, 1.0)
	var at := Vector2(clampf(_beat_to_x(head), body.position.x, body.end.x),
			body.end.y - body.size.y * nt)
	draw_line(Vector2(body.position.x, at.y), Vector2(body.end.x, at.y),
			Color(1, 1, 1, 0.22), 1.0)
	draw_circle(at, 5.0, Color(0.08, 0.08, 0.08, 0.8))
	draw_circle(at, 3.4, Color(1, 1, 1, 0.95))


## The clip's own waveform, drawn from the overview the engine built when the
## file was read. Only the part of the file the clip actually plays is shown,
## and only the part of the clip that is on screen is asked for.
## Off only for measurement, so the cost of drawing waveforms can be told apart
## from the cost of everything else on the timeline.
static var draw_waveforms := true

## The beat range the last waveform drawn covered, from its clip's start. Only
## the tests read it; drawing more than the visible part is how the waveform
## ended up on top of the track headers.
var last_wave_span := Vector2.ZERO


func _draw_audio_preview(c: Dictionary, r: Rect2) -> void:
	if not draw_waveforms:
		return
	var body := Rect2(r.position + Vector2(1.0, 12.0), r.size - Vector2(2.0, 13.0))
	if body.size.x < 2.0 or body.size.y < 3.0:
		return
	var mid := body.position.y + body.size.y * 0.5
	draw_line(Vector2(body.position.x, mid), Vector2(body.end.x, mid), Color(0, 0, 0, 0.35), 1.0)

	var asset := int(c.get("index", -1))
	if asset < 0:
		return
	# The whole file in beats, where the clip starts in it, and how fast it is
	# being read. A clip is a stretch of the arrangement and the sample under
	# it runs at its own rate, so the two are only the same length when that
	# rate is one. Drawing the file stretched to fit the clip -- which is what
	# this used to do -- is a picture of a sound nobody is going to hear.
	var total: float = maxf(0.001, App.asset_length_beats_by_index(asset))
	var off: float = float(c.get("offset", 0.0))
	var rate: float = maxf(0.0001, App.clip_rate(c))
	# As far along the clip as the sample reaches. Past that the clip is empty,
	# which is drawn as empty rather than filled with a stretched waveform.
	var sounded: float = App.clip_sounded_beats(c, total)
	if sounded < 0.0001:
		return

	# The part of the clip on screen, in beats from the clip's own start.
	var clip_x: float = _beat_to_x(float(c.start))
	var b0: float = clampf((body.position.x - clip_x) / maxf(1.0, px_per_beat), 0.0, sounded)
	var b1: float = clampf((body.end.x - clip_x) / maxf(1.0, px_per_beat), b0, sounded)
	if b1 - b0 < 0.0001:
		return

	# Overviews are read in tiles a screenful wide, so scrolling reuses one
	# until the view runs off the end of it, and the shape is kept in beats and
	# amplitude rather than pixels so the same one serves every scroll position.
	# Rebuilding it per pixel per frame was the whole cost of a busy timeline:
	# a hundred clips of a three-minute file ran at sixteen frames a second and
	# at a hundred and twenty with this drawing switched off.
	var tile: float = maxf(0.25, b1 - b0)
	var index: int = int(floor(b0 / tile))
	var t_from: float = clampf(float(index - 1) * tile, 0.0, sounded)
	var t_to: float = clampf(float(index + 2) * tile, t_from, sounded)
	if t_to - t_from < 0.0001:
		return
	var buckets: int = int(clampf((t_to - t_from) * px_per_beat, 8.0, 4096.0))
	# Beats of the clip to a fraction of the file: where the clip starts in the
	# sample, plus however much of the sample those beats get through.
	var shape := _wave_shape(asset,
			clampf((off + t_from * rate) / total, 0.0, 1.0),
			clampf((off + t_to * rate) / total, 0.0, 1.0),
			buckets, t_to - t_from)
	if shape.is_empty():
		return
	# A clip dragged out past the end of its own sample: the line says where
	# the sound stops, and after it there is nothing, because after it there is
	# nothing to hear.
	if sounded < float(c.length) - 0.001:
		var ex: float = clip_x + sounded * px_per_beat
		if ex > body.position.x and ex < body.end.x:
			draw_line(Vector2(ex, body.position.y), Vector2(ex, body.end.y),
					Color(0, 0, 0, 0.45), 1.0)

	# A tile is three screenfuls wide, and drawing all of it put the waveform
	# over the track headers and off the edge of the panel. Only the part that
	# belongs to this clip's visible rectangle is drawn -- sliced out of the
	# cached shape, which is a copy in C++ rather than a loop out here.
	var pairs := shape.size() / 2
	var span: float = maxf(0.0001, t_to - t_from)
	# Rounded inwards on the left and outwards on the right: the track headers
	# are drawn before the clips, so a bucket of overhang there would sit on top
	# of them, while overhang on the right runs into the panel edge, which is
	# clipped, or into the end of the clip itself.
	var k0: int = clampi(int(ceil((b0 - t_from) / span * float(pairs))), 0, pairs)
	var k1: int = clampi(int(ceil((b1 - t_from) / span * float(pairs))) + 1, k0, pairs)
	if k1 - k0 < 1:
		return
	var visible_shape := shape.slice(k0 * 2, k1 * 2)
	if visible_shape.is_empty():
		return
	# What was actually drawn, in beats from the clip's start, so a test can
	# check it stayed inside the clip's visible rectangle.
	last_wave_span = Vector2(t_from + span * float(k0) / float(pairs),
			t_from + span * float(k1) / float(pairs))

	# The transform does the work the loop used to: x is in beats from the
	# tile's start, y is amplitude, and one matrix puts the lot on screen.
	draw_set_transform(Vector2(clip_x + t_from * px_per_beat, mid), 0.0,
			Vector2(px_per_beat, body.size.y * 0.46))
	draw_multiline(visible_shape, Color(0.06, 0.06, 0.07, 0.8))
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


## A sample that has been changed is a sample whose picture is wrong. Only its
## own tiles go: the cache is what keeps a hundred clips drawing at full speed,
## and throwing all of it away on every edit was never the answer.
func _forget_sample(index: int) -> void:
	var prefix := "%d|" % index
	for key in _peak_cache.keys():
		if String(key).begins_with(prefix):
			_peak_cache.erase(key)
	queue_redraw()


## One tile of a file's waveform, as line ends measured in beats across and
## amplitude up. Kept until the view moves off it.
func _wave_shape(asset: int, from: float, to: float, buckets: int, beats: float) -> PackedVector2Array:
	var key := "%d|%.6f|%.6f|%d" % [asset, from, to, buckets]
	if _peak_cache.has(key):
		return _peak_cache[key]
	var peaks: PackedFloat32Array = App.engine().asset_peaks_range(asset, from, to, buckets)
	var pairs := peaks.size() / 2
	var out := PackedVector2Array()
	if pairs >= 2:
		out.resize(pairs * 2)
		for i in pairs:
			var x: float = beats * (float(i) + 0.5) / float(pairs)
			out[i * 2] = Vector2(x, -peaks[i * 2 + 1])
			out[i * 2 + 1] = Vector2(x, -peaks[i * 2])
	# Bounded, or panning across a long arrangement would keep every tile it
	# went past for the rest of the session.
	if _peak_cache.size() > 64:
		_peak_cache.clear()
	_peak_cache[key] = out
	return out


## The waveform in screen coordinates. Kept for the tests, which check that a
## second look costs nothing and that zooming really does draw something finer.
func _wave_lines(asset: int, from: float, to: float, body: Rect2, mid: float) -> PackedVector2Array:
	var px: int = int(clampf(body.size.x, 2.0, 3000.0))
	var shape := _wave_shape(asset, from, to, px, 1.0)
	var out := PackedVector2Array()
	out.resize(shape.size())
	var half: float = body.size.y * 0.46
	for i in shape.size():
		out[i] = Vector2(body.position.x + body.size.x * shape[i].x, mid + shape[i].y * half)
	return out
