## Runs the whole stack against itself: every stock instrument and effect, the
## VST3 host, the SoundFont player, the sampler, save/load, MIDI round-trip and
## undo. Invoked with --cd-selftest=<dir>; prints one line per check and the
## tally at the end.
class_name CdSelfTest
extends RefCounted

var dir := ""
var pass_count := 0
var fail_count := 0
var app
var tree


static func run(a, t, out_dir: String) -> int:
	var s := CdSelfTest.new()
	s.app = a
	s.tree = t
	s.dir = out_dir
	DirAccess.make_dir_recursive_absolute(out_dir)
	# A path the platform will not take (a drive root on Windows, say) would make
	# every render silently produce nothing; fall back to somewhere writable.
	if not DirAccess.dir_exists_absolute(out_dir):
		s.dir = OS.get_user_data_dir().path_join("selftest")
		DirAccess.make_dir_recursive_absolute(s.dir)
	print("writing test output to ", s.dir)
	return await s._run()


func _check(name: String, ok: bool, detail: String = "") -> void:
	if ok:
		pass_count += 1
		print("  ok    %s%s" % [name, ("  " + detail) if not detail.is_empty() else ""])
	else:
		fail_count += 1
		print("  FAIL  %s%s" % [name, ("  " + detail) if not detail.is_empty() else ""])


func _wav_stats(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var f := FileAccess.open(path, FileAccess.READ)
	var data := f.get_buffer(f.get_length())
	f.close()
	if data.size() < 64:
		return {}
	# 24-bit little-endian PCM, which is what the harness asks the engine for.
	var peak := 0.0
	var sum := 0.0
	var n := 0
	var i := 44
	while i + 3 <= data.size():
		var v: int = data[i] | (data[i + 1] << 8) | (data[i + 2] << 16)
		if v & 0x800000:
			v -= 0x1000000
		var x := float(v) / 8388608.0
		peak = maxf(peak, absf(x))
		sum += x * x
		n += 1
		i += 3
	return {"peak": peak, "rms": sqrt(sum / maxf(1.0, float(n))), "frames": n}


## The loudest the mixer track gets over the next fifth of a second, taken
## from the meters the audio callback fills. For things that only happen live.
func _live_peak(track: int, settle: int = 30, frames: int = 12) -> float:
	# The meter holds its peak and lets it down slowly, so it is given time to
	# settle before being read: what is wanted is the level now, not the
	# loudest thing that happened while the key was going down.
	for i in settle:
		await tree.process_frame
	var peak := 0.0
	for i in frames:
		await tree.process_frame
		var m: PackedFloat32Array = Audio.engine.meters()
		if m.size() > track * 4 + 1:
			peak = maxf(peak, maxf(m[track * 4], m[track * 4 + 1]))
	return peak


## A short audio file to test the sampler with: whatever the sampler test
## already found, or nothing.
func _find_sample() -> String:
	for d in ["/usr/share/sounds/alsa", "/usr/share/sounds"]:
		var dir := DirAccess.open(d)
		if dir == null:
			continue
		for f in dir.get_files():
			if f.ends_with(".wav"):
				return d.path_join(f)
	return ""


## How long a 24-bit stereo render is, in seconds.
func _wav_seconds(path: String) -> float:
	if not FileAccess.file_exists(path):
		return 0.0
	var f := FileAccess.open(path, FileAccess.READ)
	var bytes := f.get_length()
	f.close()
	return float(maxi(0, bytes - 44)) / (3.0 * 2.0 * float(Audio.engine.sample_rate()))


## Whether a rendered click really is the recording it should have come from.
##
## Compared by shape rather than by level: the click goes through the master
## fader like everything else, so what comes out is the file times whatever that
## fader is set to. The best-fitting single scale is worked out and what is
## returned is the worst sample left over after it, as a fraction of the click's
## own peak -- near zero only if the same waveform came out. A couple of samples
## of slack either side, because a beat almost never lands exactly on a frame.
func _click_error(render_path: String, click: AudioStreamWAV, at_sec: float) -> float:
	if click == null or not FileAccess.file_exists(render_path):
		return -1.0
	var src := Audio._wav_floats(click)
	var channels := 2 if click.stereo else 1
	var src_frames: int = src.size() / channels
	if src_frames < 8:
		return -1.0
	var f := FileAccess.open(render_path, FileAccess.READ)
	var data := f.get_buffer(f.get_length())
	f.close()
	var rate := float(Audio.engine.sample_rate())
	var step := float(click.mix_rate) / rate

	# The file read the way the engine reads it: at the engine's rate, with the
	# same linear interpolation between frames.
	var want := PackedFloat32Array()
	var peak := 0.0
	var pos := 0.0
	while true:
		var i0 := int(pos)
		if i0 + 1 >= src_frames:
			break
		var v := lerpf(src[i0 * channels], src[(i0 + 1) * channels], float(pos - float(i0)))
		want.append(v)
		peak = maxf(peak, absf(v))
		pos += step
	if want.size() < 8 or peak < 0.001:
		return -1.0

	var best := -1.0
	for slip in range(-3, 4):
		var first: int = int(at_sec * rate) + slip
		if first < 0:
			continue
		var got := PackedFloat32Array()
		var ok := true
		for i in want.size():
			var at: int = 44 + (first + i) * 6          # 24-bit, two channels
			if at + 3 > data.size():
				ok = false
				break
			var raw: int = data[at] | (data[at + 1] << 8) | (data[at + 2] << 16)
			if raw & 0x800000:
				raw -= 0x1000000
			got.append(float(raw) / 8388608.0)
		if not ok:
			continue
		# The one scale that fits the whole click best, so the master fader's
		# setting is not what this is measuring.
		var num := 0.0
		var den := 0.0
		for i in want.size():
			num += got[i] * want[i]
			den += want[i] * want[i]
		if den <= 0.0:
			continue
		var scale := num / den
		var worst := 0.0
		for i in want.size():
			worst = maxf(worst, absf(got[i] - want[i] * scale))
		var err := worst / peak
		if best < 0.0 or err < best:
			best = err
	return best


## The level over one stretch of a 24-bit stereo render, for asking whether a
## particular part of the file has anything in it.
func _wav_region_rms(path: String, from_sec: float, to_sec: float) -> float:
	if not FileAccess.file_exists(path) or to_sec <= from_sec:
		return 0.0
	var f := FileAccess.open(path, FileAccess.READ)
	var data := f.get_buffer(f.get_length())
	f.close()
	var rate := float(Audio.engine.sample_rate())
	var frame := 6                                  # 24-bit, two channels
	var i: int = 44 + int(from_sec * rate) * frame
	var last: int = mini(data.size(), 44 + int(to_sec * rate) * frame)
	var sum := 0.0
	var n := 0
	while i + 3 <= last:
		var v: int = data[i] | (data[i + 1] << 8) | (data[i + 2] << 16)
		if v & 0x800000:
			v -= 0x1000000
		var x := float(v) / 8388608.0
		sum += x * x
		n += 1
		i += 3
	return sqrt(sum / maxf(1.0, float(n)))


## How much a stretch of a 24-bit file looks like noise rather than like music.
##
## The average step between one sample and the next, against the average
## sample. White noise moves as far between samples as its own amplitude, so
## the ratio comes out around 1.4; anything with a note in it moves a small
## fraction of that. It tells "the export went wrong" from "the export is
## quiet" without anybody having to listen to it.
func _wav_noisiness(path: String, from_sec: float, to_sec: float) -> float:
	if not FileAccess.file_exists(path) or to_sec <= from_sec:
		return 0.0
	var f := FileAccess.open(path, FileAccess.READ)
	var data := f.get_buffer(f.get_length())
	f.close()
	var rate := float(Audio.engine.sample_rate())
	var frame := 6                                  # 24-bit, two channels
	var i: int = 44 + int(from_sec * rate) * frame
	var last: int = mini(data.size(), 44 + int(to_sec * rate) * frame)
	var sum := 0.0
	var step := 0.0
	var n := 0
	var prev := 0.0
	while i + 3 <= last:
		var v: int = data[i] | (data[i + 1] << 8) | (data[i + 2] << 16)
		if v & 0x800000:
			v -= 0x1000000
		var x := float(v) / 8388608.0
		sum += absf(x)
		if n > 0:
			step += absf(x - prev)
		prev = x
		n += 1
		i += frame                                  # one channel, every frame
	if n < 2 or sum <= 0.000001:
		return 0.0
	return (step / float(n - 1)) / (sum / float(n))


## The same render, but handing back the file so it can be measured rather than
## just weighed.
func _render_path(name: String, beats: float = 2.0) -> String:
	var path := dir.path_join(name + ".wav")
	return path if Audio.engine.render(path, 0.0, beats, 0.4, 24, false) else ""


## The index a parameter answers to, asked of the loaded instance. The
## catalogue only carries a count, not the list, so looking it up there quietly
## found nothing and every set landed on parameter zero.
func _param_index(ref: Dictionary, param_id: String) -> int:
	var h: int = app.handle_for(ref)
	if h < 0:
		return -1
	for q in Audio.engine.plugin_params(h):
		if String(q.id) == param_id:
			return int(q.index)
	return -1


## The fundamental, by autocorrelation over the middle of the file -- past the
## attack, and past the window of latency a spectral effect adds.
func _dominant_hz(path: String) -> float:
	if path.is_empty() or not FileAccess.file_exists(path):
		return 0.0
	var f := FileAccess.open(path, FileAccess.READ)
	var data := f.get_buffer(f.get_length())
	f.close()
	if data.size() < 64:
		return 0.0
	# The render is stereo, and reading the two channels as one signal is how
	# you measure an octave below the note that is actually playing.
	var channels: int = maxi(1, data[22] | (data[23] << 8))
	var x := PackedFloat32Array()
	var i := 44
	var c := 0
	while i + 3 <= data.size():
		if c == 0:
			var v: int = data[i] | (data[i + 1] << 8) | (data[i + 2] << 16)
			if v & 0x800000:
				v -= 0x1000000
			x.append(float(v) / 8388608.0)
		i += 3
		c = (c + 1) % channels
	var rate := float(Audio.engine.sample_rate())
	var start := int(rate * 0.6)
	var n := int(rate * 0.3)
	var lo := int(rate / 1500.0)
	var hi := mini(int(rate / 40.0), n - 1)
	if x.size() < start + n + hi:
		return 0.0
	# Normalised, so the peak at twice the period is not mistaken for the
	# period: an unnormalised correlation slopes and the comparison is unfair.
	var corr := PackedFloat32Array()
	corr.resize(hi + 1)
	var e0 := 0.0
	for k in range(0, n, 2):
		e0 += x[start + k] * x[start + k]
	if e0 < 1e-9:
		return 0.0
	var best_r := 0.0
	for lag in range(lo, hi + 1):
		var r := 0.0
		var e := 0.0
		for k in range(0, n, 2):
			var b := x[start + k + lag]
			r += x[start + k] * b
			e += b * b
		var v: float = r / sqrt(maxf(1e-12, e0 * e))
		corr[lag] = v
		best_r = maxf(best_r, v)
	if best_r < 0.2:
		return 0.0
	# The shortest lag that gets most of the way to the best one: the true
	# period, rather than a multiple of it that scores a hair higher.
	for lag in range(lo, hi + 1):
		if corr[lag] >= best_r * 0.9:
			return rate / float(lag)
	return 0.0


## How loud each side of a render is on its own, for checking that something
## really is where it was put across the stereo field.
func _wav_sides(path: String) -> Dictionary:
	if path.is_empty() or not FileAccess.file_exists(path):
		return {}
	var f := FileAccess.open(path, FileAccess.READ)
	var data := f.get_buffer(f.get_length())
	f.close()
	if data.size() < 64:
		return {}
	var channels: int = maxi(1, data[22] | (data[23] << 8))
	var sums := [0.0, 0.0]
	var counts := [0, 0]
	var i := 44
	var c := 0
	while i + 3 <= data.size():
		var v: int = data[i] | (data[i + 1] << 8) | (data[i + 2] << 16)
		if v & 0x800000:
			v -= 0x1000000
		var x := float(v) / 8388608.0
		var side: int = mini(c, 1)
		sums[side] += x * x
		counts[side] += 1
		i += 3
		c = (c + 1) % channels
	return {
		"l": sqrt(sums[0] / maxf(1.0, float(counts[0]))),
		"r": sqrt(sums[1] / maxf(1.0, float(counts[1]))),
	}


func _render(name: String, beats: float = 2.0, from_beat: float = 0.0) -> Dictionary:
	var path := dir.path_join(name + ".wav")
	var ok: bool = Audio.engine.render(path, from_beat, from_beat + beats, 0.4, 24, false)
	if not ok:
		return {}
	return _wav_stats(path)


func _run() -> int:
	print("Cadmium self-test")
	print("--- engine")
	_check("extension loaded", Audio.engine != null)
	_check("sample rate", Audio.engine.sample_rate() >= 44100.0, "%d Hz" % int(Audio.engine.sample_rate()))
	_check("stock plugin count", Plugins.stock.size() >= 20, "%d processors" % Plugins.stock.size())

	# --- every stock instrument makes a sound
	print("--- instruments")
	app.new_project()
	await tree.process_frame
	for p in Plugins.stock:
		if not bool(p.instrument):
			continue
		var id := String(p.id)
		if id == "cd.sampler":
			continue    # needs a file; covered below
		app.project.channels.clear()
		app.project.patterns[0].notes.clear()
		app.channel_handles.clear()
		var plug := CdProject.plugin_dict("stock", id, "", String(p.name))
		app.project.add_channel(String(p.name), plug, 1)
		app.sync_all()
		if id == "cd.soundfont":
			var sf := _find_soundfont()
			if sf.is_empty():
				print("  skip  soundfont (none installed)")
				continue
			app.set_plugin_string({"kind": "channel", "index": 0}, "file", sf)
		elif id == "cd.prism":
			# Prism plays a picture, and correctly makes silence without one.
			app.load_plugin_image({"kind": "channel", "index": 0}, _test_image(), 48, 64)
		for k in [48, 55, 60]:
			app.add_note(0, 0, 0.0, 1.5, k, 0.9)
		Audio.engine.set_mode(Cd.Mode.PATTERN)
		Audio.engine.set_current_pattern(0)
		var st := _render("inst_" + id.replace(".", "_"))
		_check(id, not st.is_empty() and float(st.peak) > 0.005,
				"peak %.3f rms %.4f" % [st.get("peak", 0.0), st.get("rms", 0.0)])

	# --- notes that touch each other both play
	# Quick legato leaves a pattern full of notes that end exactly where the
	# next one starts, and on the same pitch that is the awkward case: the end
	# of one and the start of the next fall on the same sample.
	print("--- notes that touch")
	app.new_project()
	await tree.process_frame
	app.project.channels.clear()
	app.project.patterns[0].notes.clear()
	app.channel_handles.clear()
	app.project.add_channel("Ember", CdProject.plugin_dict("stock", "cd.ember", "", "Ember"), 1)
	app.sync_all()
	app.add_note(0, 0, 0.0, 1.0, 60, 0.9)
	app.add_note(0, 0, 1.0, 1.0, 60, 0.9)
	app.note_edit_done(0)
	Audio.engine.set_mode(Cd.Mode.PATTERN)
	Audio.engine.set_current_pattern(0)
	var spb := 60.0 / float(app.project.bpm)
	var touch := _render_path("touching_notes", 2.0)
	var first_note := _wav_region_rms(touch, spb * 0.3, spb * 0.9)
	var second_note := _wav_region_rms(touch, spb * 1.3, spb * 1.9)
	_check("a note starting where the last one ended plays rather than stopping",
			second_note > first_note * 0.4,
			"%.4f after, %.4f before" % [second_note, first_note])
	# And the same thing where the second note is a step up, which is the case
	# that always worked and is here to show the first one is a fair test.
	app.project.patterns[0].notes.clear()
	app.add_note(0, 0, 0.0, 1.0, 60, 0.9)
	app.add_note(0, 0, 1.0, 1.0, 62, 0.9)
	app.note_edit_done(0)
	var stepped := _render_path("touching_steps", 2.0)
	_check("and so does one that touches at a different pitch",
			_wav_region_rms(stepped, spb * 1.3, spb * 1.9) > first_note * 0.4,
			"%.4f" % _wav_region_rms(stepped, spb * 1.3, spb * 1.9))

	# --- the metronome actually clicks
	print("--- metronome")
	app.new_project()
	await tree.process_frame
	Audio.engine.set_metronome(true)
	Audio.engine.set_mode(Cd.Mode.PATTERN)
	var metro_path := _render_path("metronome", 2.0)
	var metro := _wav_stats(metro_path)
	Audio.engine.set_metronome(false)
	_check("metronome sounds", float(metro.get("peak", 0.0)) > 0.05,
			"peak %.3f" % metro.get("peak", 0.0))

	# It is a recording, not the synthesised blip, and it is the recording in
	# the project rather than whatever was last left in the engine. The two
	# clicks are compared against the files they came from, read the same way
	# the engine reads them: at its own rate, with the same interpolation.
	var bar_click := Audio._wav_floats(load(Audio.METRONOME_BAR) as AudioStreamWAV)
	var beat_click := Audio._wav_floats(load(Audio.METRONOME_BEAT) as AudioStreamWAV)
	_check("both clicks load from the project", bar_click.size() > 64 and beat_click.size() > 64,
			"%d and %d samples" % [bar_click.size(), beat_click.size()])
	_check("and they are different sounds", bar_click != beat_click)
	var worst := _click_error(metro_path, load(Audio.METRONOME_BAR) as AudioStreamWAV, 0.0)
	_check("the first beat of the bar is the accented recording", worst >= 0.0 and worst < 0.02,
			"worst sample %.2f%% of the click" % (worst * 100.0))
	var one_beat := 60.0 / float(app.project.bpm)
	var off := _click_error(metro_path, load(Audio.METRONOME_BEAT) as AudioStreamWAV, one_beat)
	_check("and the beat after it is the other one", off >= 0.0 and off < 0.02,
			"worst sample %.2f%% of the click" % (off * 100.0))
	# The wrong file must not pass the same test, or it is measuring nothing.
	var crossed := _click_error(metro_path, load(Audio.METRONOME_BEAT) as AudioStreamWAV, 0.0)
	_check("and the two are told apart", crossed > 0.1,
			"the other click fits the bar to %.2f%%" % (crossed * 100.0))

	# --- a new project starts empty
	_check("new project has no channels", app.project.channels.is_empty(),
			"%d channels" % app.project.channels.size())

	# --- every effect passes audio without blowing up
	print("--- effects")
	app.new_project()
	await tree.process_frame
	app.project.channels.clear()
	app.channel_handles.clear()
	var ember := CdProject.plugin_dict("stock", "cd.ember", "", "Ember")
	app.project.add_channel("Ember", ember, 1)
	app.sync_all()
	for k in [40, 47, 52]:
		app.add_note(0, 0, 0.0, 1.6, k, 0.9)
	for p in Plugins.stock:
		if bool(p.instrument):
			continue
		var id := String(p.id)
		var fx := CdProject.plugin_dict("stock", id, "", String(p.name))
		app.project.mixer[1].inserts[0] = fx
		app.sync_all()
		var st := _render("fx_" + id.replace(".", "_"))
		var peak := float(st.get("peak", 0.0))
		var sane := not st.is_empty() and peak > 0.0001 and peak < 8.0
		_check(id, sane, "peak %.3f" % peak)
	app.project.mixer[1].inserts[0] = null
	app.sync_all()

	# --- the pitch shifter moves the pitch, and moves it by the right amount.
	# "It made a noise" is not a test for this one: the delay-line version it
	# replaced made plenty of noise and none of it was the right note.
	print("--- pitch")
	app.project.channels.clear()
	app.channel_handles.clear()
	app.project.patterns[0].notes.clear()
	var sine := CdProject.plugin_dict("stock", "cd.ember", "", "Ember")
	app.project.add_channel("Ember", sine, 1)
	app.sync_all()
	app.add_note(0, 0, 0.0, 3.0, 57, 0.9)
	var dry_hz := _dominant_hz(_render_path("pitch_dry", 3.0))
	_check("the note going in has a pitch to measure", dry_hz > 40.0 and dry_hz < 2000.0,
			"%.1f Hz" % dry_hz)
	var shifter := CdProject.plugin_dict("stock", "cd.pitch", "", "Pitch Shift")
	app.project.mixer[1].inserts[0] = shifter
	app.sync_all()
	# Set through the same path the panel uses, so what is being tested is what
	# a knob does rather than what a saved project happens to restore.
	var fxref := {"kind": "insert", "track": 1, "slot": 0}
	app.set_plugin_param(fxref, _param_index(fxref, "mix"), 1.0)
	app.set_plugin_param(fxref, _param_index(fxref, "dry"), 0.0)
	app.set_plugin_param(fxref, _param_index(fxref, "semi"), 12.0)
	var up_hz := _dominant_hz(_render_path("pitch_up", 3.0))
	_check("an octave up is an octave up", absf(up_hz - dry_hz * 2.0) < dry_hz * 0.12,
			"%.1f Hz, wanted %.1f" % [up_hz, dry_hz * 2.0])
	app.set_plugin_param(fxref, _param_index(fxref, "semi"), -12.0)
	var down_hz := _dominant_hz(_render_path("pitch_down", 3.0))
	_check("an octave down is an octave down", absf(down_hz - dry_hz * 0.5) < dry_hz * 0.06,
			"%.1f Hz, wanted %.1f" % [down_hz, dry_hz * 0.5])
	app.set_plugin_param(fxref, _param_index(fxref, "semi"), 7.0)
	var fifth_hz := _dominant_hz(_render_path("pitch_fifth", 3.0))
	_check("a fifth up is a fifth up", absf(fifth_hz - dry_hz * 1.4983) < dry_hz * 0.09,
			"%.1f Hz, wanted %.1f" % [fifth_hz, dry_hz * 1.4983])
	app.project.mixer[1].inserts[0] = null
	app.sync_all()

	# --- per-note expression: the piano roll's control lane writes pan and
	# fine pitch onto the note, and both have to reach the sound.
	print("--- note expression")
	app.project.patterns[0].notes.clear()
	var left: int = app.add_note(0, 0, 0.0, 2.0, 57, 0.9)
	app.update_note(0, left, {"pan": -1.0})
	app.note_edit_done(0)
	var lstat := _wav_sides(_render_path("note_pan_left", 2.0))
	_check("a note panned left comes out of the left",
			float(lstat.get("l", 0.0)) > float(lstat.get("r", 1.0)) * 3.0,
			"L %.4f  R %.4f" % [lstat.get("l", 0.0), lstat.get("r", 0.0)])
	app.update_note(0, left, {"pan": 1.0})
	app.note_edit_done(0)
	var rstat := _wav_sides(_render_path("note_pan_right", 2.0))
	_check("a note panned right comes out of the right",
			float(rstat.get("r", 0.0)) > float(rstat.get("l", 1.0)) * 3.0,
			"L %.4f  R %.4f" % [rstat.get("l", 0.0), rstat.get("r", 0.0)])
	app.update_note(0, left, {"pan": 0.0, "fine": 0.0})
	app.note_edit_done(0)
	var plain_hz := _dominant_hz(_render_path("note_fine_off", 2.0))
	app.update_note(0, left, {"fine": 1.0})
	app.note_edit_done(0)
	var sharp_hz := _dominant_hz(_render_path("note_fine_on", 2.0))
	var want_hz := plain_hz * 1.059463
	_check("a note detuned a semitone plays a semitone higher",
			plain_hz > 0.0 and absf(sharp_hz - want_hz) < plain_hz * 0.02,
			"%.1f Hz, wanted %.1f" % [sharp_hz, want_hz])
	app.project.patterns[0].notes.clear()
	app.note_edit_done(0)

	# --- sampler round trip: render something, then play it back
	print("--- sampler")
	var sample := dir.path_join("inst_cd_ember.wav")
	if FileAccess.file_exists(sample):
		app.project.channels.clear()
		app.channel_handles.clear()
		var smp := CdProject.plugin_dict("stock", "cd.sampler", "", "Sampler")
		smp["strings"]["sample"] = sample
		app.project.add_channel("Sampler", smp, 1)
		app.sync_all()
		app.project.patterns[0].notes.clear()
		app.add_note(0, 0, 0.0, 1.5, 60, 1.0)
		var info: String = Audio.engine.plugin_get_string(app.handle_for({"kind": "channel", "index": 0}), "info")
		_check("sampler loaded a file", not info.is_empty(), info)
		var st := _render("sampler_playback")
		_check("sampler plays", float(st.get("peak", 0.0)) > 0.005, "peak %.3f" % st.get("peak", 0.0))

	# --- VST3
	print("--- vst3")
	# The test plugins that ship with Cadmium, if they are installed. The
	# "Twin" one is shaped the way FabFilter's are: one object that also names
	# itself as its own controller class. A host that believes that answer
	# builds a second copy of the plugin and draws the interface with it, and
	# then nothing the user touches in the plugin's own window is connected to
	# what they hear. It is the reason this check exists.
	for probe_name in ["Cadmium Probe", "Cadmium Probe Twin"]:
		var entry := {}
		for e in Plugins.vst3:
			if String(e.get("name", "")) == probe_name:
				entry = e
		if entry.is_empty():
			continue
		app.new_project()
		await tree.process_frame
		app.project.mixer[1].inserts[0] = CdProject.plugin_dict("vst3", String(entry.cid),
				String(entry.path), probe_name)
		app.sync_all()
		await tree.process_frame
		var pref := {"kind": "insert", "track": 1, "slot": 0}
		var pinfo: Dictionary = app.plugin_info(pref)
		if not bool(pinfo.get("single_component", false)):
			_check("%s is one object" % probe_name, false, "it reports two")
			continue
		_check("%s draws itself rather than a second copy" % probe_name,
				bool(pinfo.get("controller_is_component", false)))
		# And the control has to reach the audio from both directions.
		var ph: int = app.handle_for(pref)
		app.set_plugin_param(pref, 0, 0.9)
		await tree.process_frame
		_check("%s takes a value from Cadmium" % probe_name,
				absf(float(Audio.engine.plugin_param_live(ph, 0)) - 0.9) < 0.01,
				"%.2f" % Audio.engine.plugin_param_live(ph, 0))
		Audio.engine.plugin_simulate_gui_edit(ph, 0, 0.2)
		await tree.process_frame
		_check("%s takes one from its own interface" % probe_name,
				absf(float(Audio.engine.plugin_param_live(ph, 0)) - 0.2) < 0.01,
				"%.2f" % Audio.engine.plugin_param_live(ph, 0))
	app.new_project()
	await tree.process_frame
	var found: int = await Plugins.rescan_vst3()
	_check("scan found plugins", found > 0, "%d classes" % found)

	# A note played by hand has to stop when the key comes up. The instrument
	# probe only believes a note-off that names the same note id the note-on
	# did -- which is what the specification allows, and what Serum 2 and
	# others actually do -- so a host that invents an id for a live note and
	# then forgets it leaves this one droning.
	var notes_entry := {}
	for e in Plugins.vst3:
		if String(e.get("name", "")) == "Cadmium Probe Notes":
			notes_entry = e
	if not notes_entry.is_empty():
		app.new_project()
		await tree.process_frame
		app.add_vst3_channel(notes_entry)
		await tree.process_frame
		# Watched live through the mixer's meter, not rendered: an offline
		# render silences everything before it starts, which is exactly the
		# note being asked about.
		app.live_note_on(60, 0.9)
		var on_peak := await _live_peak(1)
		_check("a note played by hand sounds", on_peak > 0.01, "peak %.3f" % on_peak)
		app.live_note_off(60)
		var off_peak := await _live_peak(1)
		_check("and stops when the key comes up", off_peak < 0.005, "peak %.4f" % off_peak)
		app.live_all_off()
		await tree.process_frame

	var tested := 0
	for entry in Plugins.vst3:
		if not bool(entry.get("instrument", false)):
			continue
		app.project.channels.clear()
		app.channel_handles.clear()
		var plug := CdProject.plugin_dict("vst3", String(entry.cid), String(entry.path), String(entry.name))
		app.project.add_channel(String(entry.name), plug, 1)
		app.sync_all()
		var h: int = app.handle_for({"kind": "channel", "index": 0})
		_check("load %s" % String(entry.name), h >= 0)
		if h < 0:
			continue
		var params: Array = Audio.engine.plugin_params(h)
		_check("%s parameters" % String(entry.name), params.size() > 0, "%d" % params.size())
		app.project.patterns[0].notes.clear()
		for k in [48, 55, 60]:
			app.add_note(0, 0, 0.0, 1.8, k, 0.9)
		var st := _render("vst3_" + String(entry.name).replace(" ", "_"), 2.5)
		_check("%s renders audio" % String(entry.name), float(st.get("peak", 0.0)) > 0.001,
				"peak %.4f" % st.get("peak", 0.0))
		var state: String = Audio.engine.plugin_get_string(h, "state")
		_check("%s state saves" % String(entry.name), state.length() > 16, "%d bytes base64" % state.length())
		tested += 1
		if tested >= 2:
			break
	# An effect plugin too, if one is installed.
	for entry in Plugins.vst3:
		if bool(entry.get("instrument", false)):
			continue
		var fx := CdProject.plugin_dict("vst3", String(entry.cid), String(entry.path), String(entry.name))
		app.project.mixer[1].inserts[0] = fx
		app.sync_all()
		var fh: int = app.handle_for({"kind": "insert", "track": 1, "slot": 0})
		_check("load effect %s" % String(entry.name), fh >= 0)
		if fh >= 0:
			var st := _render("vst3fx_" + String(entry.name).replace(" ", "_"), 2.0)
			_check("%s passes audio" % String(entry.name), not st.is_empty(), "peak %.4f" % st.get("peak", 0.0))
		app.project.mixer[1].inserts[0] = null
		app.sync_all()
		break

	# --- project round trip
	print("--- project")
	CdFixture.build(app)
	await tree.process_frame
	# A knob moved before saving has to come back where it was left. Turning a
	# plugin's parameters into a saved file and back is most of what a project
	# file is for, and nothing was checking that the value survived.
	var knob_ref := {"kind": "channel", "index": 0}
	var knob_index := -1
	var knob_before := 0.0
	if not app.project.channels.is_empty() and app.handle_for(knob_ref) >= 0:
		var plist: Array = Audio.engine.plugin_params(app.handle_for(knob_ref))
		for q in plist:
			if float(q.max) > float(q.min) + 0.001:
				knob_index = int(q.index)
				knob_before = float(q.min) + (float(q.max) - float(q.min)) * 0.37
				break
		if knob_index >= 0:
			app.set_plugin_param(knob_ref, knob_index, knob_before)

	var proj := dir.path_join("roundtrip.cadmium")
	_check("save", app.save_project(proj) == OK)
	var before: Dictionary = app.project.to_dict()
	app.new_project()
	await tree.process_frame
	_check("load", app.load_project(proj) == OK)
	var after: Dictionary = app.project.to_dict()
	_check("channels survive", int(before.channels.size()) == int(after.channels.size()),
			"%d" % after.channels.size())
	_check("patterns survive", int(before.patterns.size()) == int(after.patterns.size()))
	_check("clips survive", int(before.clips.size()) == int(after.clips.size()))
	_check("notes survive", _note_count(before) == _note_count(after), "%d notes" % _note_count(after))
	if knob_index >= 0:
		var knob_after: float = app.get_plugin_param(knob_ref, knob_index)
		_check("plugin parameters survive", absf(knob_after - knob_before) < 0.001,
				"%.4f, was %.4f" % [knob_after, knob_before])
	var demo_render := _render_song("demo_song")
	_check("the test arrangement renders", float(demo_render.get("peak", 0.0)) > 0.02,
			"peak %.3f rms %.4f" % [demo_render.get("peak", 0.0), demo_render.get("rms", 0.0)])

	# --- MIDI round trip
	print("--- midi")
	var mid := dir.path_join("roundtrip.mid")
	_check("export midi", CdMidi.export_file(mid, app.project) == OK)
	var fresh := CdProject.new()
	var res := CdMidi.import_file(mid, fresh)
	_check("import midi", not res.is_empty(), str(res))
	if not res.is_empty():
		_check("midi notes survive", _pattern_notes(fresh) > 0, "%d notes" % _pattern_notes(fresh))
		_check("midi tempo survives", absf(fresh.bpm - app.project.bpm) < 0.6,
				"%.2f vs %.2f" % [fresh.bpm, app.project.bpm])

	# --- a project from somebody else's machine
	#
	# Exported on Linux, opened on Windows: every path in the file is a fact
	# about a computer that is not this one. The plugins were found only by the
	# path they were saved at, so none of them loaded and every hosted channel
	# went silent -- "his project sounded nothing like mine".
	print("--- a project from another machine")
	var foreign := ""
	for entry in Plugins.vst3:
		if String(entry.get("error", "")).is_empty() and bool(entry.get("instrument", false)):
			foreign = String(entry.name)
			app.new_project()
			await tree.process_frame
			# The same plugin, recorded where a Windows machine would keep it.
			var elsewhere := "C:/Program Files/Common Files/VST3/%s.vst3" % String(entry.name)
			var plug := CdProject.plugin_dict("vst3", String(entry.cid), elsewhere, String(entry.name))
			app.project.add_channel(String(entry.name), plug, 1)
			app.sync_all()
			await tree.process_frame
			var h: int = app.handle_for({"kind": "channel", "index": 0})
			_check("a plugin saved at a path this machine has never had still loads",
					h >= 0, "%s from %s" % [String(entry.name), elsewhere])
			if h >= 0:
				app.project.patterns[0].notes.clear()
				for k in [48, 55, 60]:
					app.add_note(0, 0, 0.0, 1.5, k, 0.9)
				Audio.engine.set_mode(Cd.Mode.PATTERN)
				var st := _render("foreign_plugin", 2.0)
				_check("and plays", float(st.get("peak", 0.0)) > 0.001,
						"peak %.4f" % st.get("peak", 0.0))
			break
	if foreign.is_empty():
		print("  skip  no VST3 instrument installed to test relocation with")

	# A plugin that genuinely is not here is said so, rather than passed over.
	app.new_project()
	await tree.process_frame
	var nowhere := CdProject.plugin_dict("vst3", "0123456789abcdef0123456789abcdef",
			"C:/Program Files/Common Files/VST3/NotInstalled.vst3", "NotInstalled")
	app.project.add_channel("Ghost", nowhere, 1)
	app.sync_all()
	await tree.process_frame
	_check("one that really is not installed is reported, not passed over",
			app.handle_for({"kind": "channel", "index": 0}) < 0
			and not app._missing.is_empty(), str(app._missing))

	# --- a missing sample must not shift the ones after it
	print("--- samples from another machine")
	var real := _find_sample()
	if real.is_empty():
		print("  skip  no test audio on this machine")
	else:
		app.new_project()
		await tree.process_frame
		var first: int = app.add_audio_asset(real)
		# One that is not here, between two that are.
		app.project.assets.append({"path": "/home/someone-else/Music/gone.wav",
				"wav": "", "name": "gone.wav", "sampler": app.default_sample_settings()})
		var third: int = (app.project.assets as Array).size()
		var copy: Dictionary = (app.project.assets[first] as Dictionary).duplicate(true)
		copy["wav"] = ""
		app.project.assets.append(copy)
		app.sync_all()
		await tree.process_frame
		_check("the sample that is there loads", float(Audio.engine.asset_seconds(0)) > 0.0,
				"%.3f s" % Audio.engine.asset_seconds(0))
		_check("the missing one holds its place and makes no sound",
				absf(float(Audio.engine.asset_seconds(1))) < 0.0001,
				"%.3f s" % Audio.engine.asset_seconds(1))
		_check("so the one after it is still itself, not shifted down a slot",
				float(Audio.engine.asset_seconds(2)) > 0.0,
				"%.3f s" % Audio.engine.asset_seconds(2))
		_check("and the missing one is reported", not app._missing.is_empty(), str(app._missing))

		# Beside the project is where a sample sent with a project actually is.
		var moved_dir := dir.path_join("sent")
		DirAccess.make_dir_recursive_absolute(moved_dir)
		var copied := moved_dir.path_join(real.get_file())
		DirAccess.copy_absolute(real, copied)
		app.new_project()
		await tree.process_frame
		app.project.path = moved_dir.path_join("sent.cadmium")
		app.project.assets.append({"path": "/home/someone-else/Music/%s" % real.get_file(),
				"wav": "", "name": real.get_file(), "sampler": app.default_sample_settings()})
		app.sync_all()
		await tree.process_frame
		_check("a sample sent beside the project is found there",
				float(Audio.engine.asset_seconds(0)) > 0.0,
				"%.3f s" % Audio.engine.asset_seconds(0))

	# --- what a MIDI file is actually shaped like
	print("--- midi parts")
	# Three instruments, each on a track of its own and all of them on MIDI
	# channel 1. That is what nearly every Type 1 file looks like, and splitting
	# it by channel -- which is what the reader used to do -- turned a three
	# instrument arrangement into one pile of notes on one channel.
	var same_chan := [
		{"name": "Bass", "channel": 0, "notes": [
			{"beat": 0.0, "len": 1.0, "key": 36, "vel": 0.9},
			{"beat": 2.0, "len": 1.0, "key": 38, "vel": 0.8}]},
		{"name": "Keys", "channel": 0, "notes": [
			{"beat": 0.0, "len": 2.0, "key": 60, "vel": 0.7}]},
		{"name": "Lead", "channel": 0, "notes": [
			{"beat": 1.0, "len": 0.5, "key": 72, "vel": 0.6}]},
	]
	var multi := dir.path_join("three_tracks.mid")
	var mf := FileAccess.open(multi, FileAccess.WRITE)
	mf.store_buffer(CdMidi.write(same_chan, 128.0, 3, 4, 480, "Three"))
	mf.close()
	var back := CdMidi.read_file(multi)
	_check("three tracks on one MIDI channel read back as three parts",
			not back.is_empty() and (back.parts as Array).size() == 3,
			"%d part(s)" % ((back.parts as Array).size() if not back.is_empty() else 0))
	if not back.is_empty():
		var got_names := []
		for part in back.parts:
			got_names.append(String(part.name))
		_check("and each one keeps its track's name", got_names == ["Bass", "Keys", "Lead"],
				str(got_names))
		_check("the tempo comes back", absf(float(back.bpm) - 128.0) < 0.05, "%.2f" % back.bpm)
		_check("and the signature with it",
				int(back.sig_num) == 3 and int(back.sig_den) == 4,
				"%d/%d" % [int(back.sig_num), int(back.sig_den)])
		_check("every note survives the round trip", int(back.notes) == 4, "%d notes" % back.notes)
		var first: Array = (back.parts[0] as Dictionary).notes
		_check("and lands where it was written",
				absf(float(first[1].beat) - 2.0) < 0.002 and int(first[1].key) == 38,
				"beat %.3f key %d" % [float(first[1].beat), int(first[1].key)])

	# The same key struck again before the first is released is two notes, not
	# one long one and one stub.
	var overlap := PackedByteArray()
	overlap.append_array("MThd".to_ascii_buffer())
	overlap.append_array([0, 0, 0, 6, 0, 0, 0, 1, 0x01, 0xE0])      # type 0, 1 track, 480 ppq
	var trk := PackedByteArray([
		0x00, 0x90, 60, 100,        # on  C4
		0x60, 0x90, 60, 100,        # on  C4 again, 96 ticks later
		0x60, 0x80, 60, 0,          # off
		0x60, 0x80, 60, 0,          # off
		0x00, 0xFF, 0x2F, 0x00])
	overlap.append_array("MTrk".to_ascii_buffer())
	overlap.append_array([0, 0, 0, trk.size()])
	overlap.append_array(trk)
	var ov := CdMidi.read(overlap)
	_check("two overlapping notes on the same key stay two notes",
			not ov.is_empty() and int(ov.notes) == 2, "%d note(s)" % (int(ov.notes) if not ov.is_empty() else 0))

	# --- scores
	print("--- scores")
	app.new_project()
	await tree.process_frame
	app.add_stock_channel("cd.ember")
	app.add_stock_channel("cd.pluck")
	app.project.channels[0]["name"] = "Pads"
	app.project.channels[1]["name"] = "Pluck"
	app.add_note(0, 0, 0.0, 2.0, 60, 0.8)
	app.add_note(0, 0, 2.0, 1.0, 64, 0.6)
	app.add_note(0, 1, 1.0, 0.5, 72, 0.9)
	app.project.patterns[0].notes[2]["pan"] = -0.5
	app.project.patterns[0].notes[2]["fine"] = 0.25
	app.note_edit_done(0)
	var score_path := dir.path_join("riff." + CdScore.EXT)
	_check("a score saves", CdScore.save(score_path, app.project, 0) == OK)
	var score := CdScore.load_file(score_path)
	_check("and reads back", not score.is_empty() and (score.parts as Array).size() == 2,
			"%d part(s)" % ((score.parts as Array).size() if not score.is_empty() else 0))
	_check("with the channels named rather than numbered",
			not score.is_empty() and String(score.parts[0].channel) == "Pads"
			and String(score.parts[1].channel) == "Pluck",
			str(score.get("parts", []).map(func(x): return String(x.channel))))

	# Into a project that has never seen it: the channels it names are made,
	# carrying the instruments they had.
	var empty := CdProject.new()
	var applied := CdScore.apply(empty, 0, score, true)
	_check("a score opened into an empty project brings its channels with it",
			empty.channels.size() == 2 and String(empty.channels[0].name) == "Pads",
			"%d channel(s)" % empty.channels.size())
	_check("and the instruments they were written for",
			empty.channels.size() > 1
			and String(empty.channels[1].plugin.id) == "cd.pluck",
			String(empty.channels[1].plugin.id) if empty.channels.size() > 1 else "-")
	_check("every note arrives", int(applied.notes) == 3, "%d notes" % int(applied.notes))
	var pan_kept := false
	for n in empty.patterns[0].notes:
		if int(n.key) == 72:
			pan_kept = absf(float(n.get("pan", 0.0)) + 0.5) < 0.001 \
					and absf(float(n.get("fine", 0.0)) - 0.25) < 0.001
	_check("with the pan and fine pitch that MIDI cannot carry", pan_kept)

	# Opened into a project that already has those channels, it lands on them
	# rather than making a second copy.
	var again := CdScore.apply(app.project, 0, score, true)
	_check("and onto the channels already there when it knows them",
			int(again.channels_made) == 0 and app.project.channels.size() == 2,
			"%d made, %d channels" % [int(again.channels_made), app.project.channels.size()])

	# --- MIDI into the pattern being edited
	print("--- midi into a pattern")
	var one_part := [{"name": "Whatever", "channel": 0, "notes": [
		{"beat": 0.0, "len": 1.0, "key": 48, "vel": 0.9},
		{"beat": 1.0, "len": 1.0, "key": 50, "vel": 0.9}]}]
	# Ninety, so that "the tempo is left alone" is a real question: a new project
	# is 140, and a file that agreed with it would prove nothing.
	var single := CdMidi.read(CdMidi.write(one_part, 90.0, 4, 4, 480, "One"))
	var target := CdProject.new()
	target.add_channel("Bass", CdProject.plugin_dict("stock", "cd.ember", "", "Ember"))
	target.add_channel("Lead", CdProject.plugin_dict("stock", "cd.ember", "", "Ember"))
	var into := CdScore.midi_into_pattern(single, target, 0, 1, false)
	_check("a one-part MIDI file lands on the channel you are pointing at",
			target.channels.size() == 2 and int(into.notes) == 2,
			"%d channels, %d notes" % [target.channels.size(), int(into.notes)])
	var on_target := 0
	for n in target.patterns[0].notes:
		if int(n.ch) == 1:
			on_target += 1
	_check("all of it", on_target == 2, "%d of %d on the target" % [on_target, int(into.notes)])
	_check("and the project's tempo is left where it was",
			absf(target.bpm - 140.0) < 0.01 and absf(float(into.bpm) - 90.0) < 0.05,
			"project %.2f, file %.2f" % [target.bpm, float(into.bpm)])

	# Bass and Lead are already in this project; only Keys is new. Matching by
	# name is what stops an import doubling every channel it touches.
	var many := CdScore.midi_into_pattern(back, target, 0, 1, true)
	var names := []
	for c in target.channels:
		names.append(String(c.name))
	_check("a several-part file lands on the channels it names",
			names == ["Bass", "Lead", "Keys"] and int(many.channels_made) == 1,
			"%s, %d made" % [str(names), int(many.channels_made)])
	var per_channel := {}
	for n in target.patterns[0].notes:
		per_channel[int(n.ch)] = int(per_channel.get(int(n.ch), 0)) + 1
	_check("and its notes go to the right ones",
			int(per_channel.get(0, 0)) == 2 and int(per_channel.get(1, 0)) == 1
			and int(per_channel.get(2, 0)) == 1,
			"Bass %d, Lead %d, Keys %d" % [int(per_channel.get(0, 0)),
				int(per_channel.get(1, 0)), int(per_channel.get(2, 0))])

	# --- score sheet
	var sheet := CdScore.score_sheet(score)
	_check("the score sheet names the parts and the notes",
			sheet.contains("Pads") and sheet.contains("Pluck") and sheet.contains("C4"),
			"%d characters" % sheet.length())

	# --- undo
	print("--- undo")
	app.new_project()
	await tree.process_frame
	var n0: int = app.project.channels.size()
	app.add_stock_channel("cd.ember")
	_check("add channel", app.project.channels.size() == n0 + 1)
	app.undo()
	_check("undo restores", app.project.channels.size() == n0)
	app.redo()
	_check("redo reapplies", app.project.channels.size() == n0 + 1)

	# --- layering: one pattern driving two instruments at once
	print("--- layers")
	app.new_project()
	await tree.process_frame
	app.project.channels.clear()
	app.channel_handles.clear()
	app.project.add_channel("Lead", CdProject.plugin_dict("stock", "cd.ember", "", "Ember"), 1)
	app.project.add_channel("Sub", CdProject.plugin_dict("stock", "cd.ember", "", "Ember"), 2)
	app.sync_all()
	app.add_note(0, 0, 0.0, 1.5, 60, 0.9)
	Audio.engine.set_mode(Cd.Mode.PATTERN)
	var solo := _render("layer_off", 2.0)
	app.set_channel_layers(0, [{"channel": 1, "transpose": -12, "gain": 1.0}], false)
	await tree.process_frame
	var layered := _render("layer_on", 2.0)
	_check("layer adds the second channel",
			float(layered.get("rms", 0.0)) > float(solo.get("rms", 0.0)) * 1.15,
			"rms %.4f -> %.4f" % [solo.get("rms", 0.0), layered.get("rms", 0.0)])
	app.set_channel_layers(0, [{"channel": 1, "transpose": -12, "gain": 1.0}], true)
	await tree.process_frame
	var only := _render("layer_only", 2.0)
	_check("layer-only channel is silent itself", float(only.get("peak", 0.0)) > 0.005
			and absf(float(only.get("rms", 0.0)) - float(solo.get("rms", 0.0))) < float(solo.get("rms", 0.001)) * 0.9,
			"rms %.4f" % only.get("rms", 0.0))

	# --- samples: what the sampler does to them before they are played
	print("--- sample settings")
	app.new_project()
	await tree.process_frame
	var wav_file := _find_sample()
	if wav_file.is_empty():
		print("  skip  sample settings (no test audio)")
	else:
		var ai: int = app.add_audio_asset(wav_file)
		await tree.process_frame
		var plain := float(Audio.engine.asset_seconds(ai))
		_check("a sample arrives at its own length", plain > 0.05, "%.3f s" % plain)
		# Resampling an octave up plays it twice as fast, so it is half as long.
		app.set_sample_setting(ai, "mode", 0)
		app.set_sample_setting(ai, "pitch", 12.0)
		await tree.process_frame
		var up := float(Audio.engine.asset_seconds(ai))
		_check("resampling an octave up halves it", absf(up - plain * 0.5) < plain * 0.08,
				"%.3f s against %.3f" % [up, plain])
		# Stretching leaves the pitch alone and changes the length.
		app.set_sample_setting(ai, "pitch", 0.0)
		app.set_sample_setting(ai, "mode", 1)
		app.set_sample_setting(ai, "stretch", 2.0)
		await tree.process_frame
		var longer := float(Audio.engine.asset_seconds(ai))
		_check("stretching twice over doubles it", absf(longer - plain * 2.0) < plain * 0.15,
				"%.3f s against %.3f" % [longer, plain])
		# And pitching leaves the length alone.
		app.set_sample_setting(ai, "mode", 2)
		app.set_sample_setting(ai, "stretch", 1.0)
		app.set_sample_setting(ai, "pitch", 12.0)
		await tree.process_frame
		var pitched := float(Audio.engine.asset_seconds(ai))
		_check("pitching leaves the length where it was",
				absf(pitched - plain) < plain * 0.15, "%.3f s against %.3f" % [pitched, plain])

		# The precomputed effects, on the audio rather than on the playing.
		app.set_sample_setting(ai, "mode", 3)
		app.set_sample_setting(ai, "pitch", 0.0)
		app.set_sample_setting(ai, "normalize", true)
		await tree.process_frame
		var peaks: PackedFloat32Array = Audio.engine.asset_peaks_range(ai, 0.0, 1.0, 64)
		var top := 0.0
		for v in peaks:
			top = maxf(top, absf(v))
		_check("normalising takes it to the top", top > 0.9 and top <= 1.001, "peak %.3f" % top)
		app.set_sample_setting(ai, "normalize", false)
		var head_before: PackedFloat32Array = Audio.engine.asset_peaks_range(ai, 0.0, 0.2, 16)
		app.set_sample_setting(ai, "reverse", true)
		await tree.process_frame
		var head_after: PackedFloat32Array = Audio.engine.asset_peaks_range(ai, 0.0, 0.2, 16)
		var moved := false
		for i in mini(head_before.size(), head_after.size()):
			if absf(head_before[i] - head_after[i]) > 0.01:
				moved = true
		_check("reversing turns the picture round too", moved)
		app.set_sample_setting(ai, "reverse", false)
		await tree.process_frame

		# And a clip of it still plays.
		while app.project.tracks.size() < 2:
			app.add_track()
		app.add_clip(Cd.ClipType.AUDIO, ai, 0, 0.0, app.asset_length_beats_by_index(ai),
				{"name": "sample"})
		app.clip_edit_done()
		Audio.engine.set_mode(Cd.Mode.SONG)
		await tree.process_frame
		var st := _render("sample_clip", 2.0)
		_check("a clip of it plays", float(st.get("peak", 0.0)) > 0.005,
				"peak %.3f" % st.get("peak", 0.0))

		# And a sampler can be automated: its own level over the clip, heard by
		# whatever is playing it rather than only by the next one to start.
		var lane: int = app.add_automation("sample volume", Cd.AutoTarget.SAMPLE_VOL, {}, ai, 0,
				0.0, 2.0)
		app.project.automations[lane].points = [
			{"beat": 0.0, "value": 0.02, "curve": 0.0},
			{"beat": 2.0, "value": 1.0, "curve": 0.0},
		]
		app.push_automation()
		app.add_clip(Cd.ClipType.AUTOMATION, lane, 1, 0.0, 2.0)
		app.clip_edit_done()
		await tree.process_frame
		var swept := _render_path("sample_auto", 2.0)
		var quiet := _wav_region_rms(swept, 0.05, 0.35)
		var loud := _wav_region_rms(swept, 0.65, 0.95)
		_check("automating a sample's level is heard while it plays", loud > quiet * 2.0,
				"%.4f then %.4f" % [quiet, loud])
		app.set_sample_setting(ai, "gain", 1.0)
		app.project.automations[lane].points = [{"beat": 0.0, "value": 1.0, "curve": 0.0}]
		app.push_automation()

		# And the two that can move while it plays: pitch and speed, read like
		# a record rather than stretched again. Twice the speed reaches the end
		# of the sample in half the time, so the second half falls quiet.
		var fast: int = app.add_automation("sample speed", Cd.AutoTarget.SAMPLE_SPEED, {}, ai, 0,
				0.25, 4.0)
		app.project.automations[fast].points = [{"beat": 0.0, "value": 2.0, "curve": 0.0}]
		app.push_automation()
		app.add_clip(Cd.ClipType.AUTOMATION, fast, 1, 0.0, 4.0)
		app.clip_edit_done()
		await tree.process_frame
		var quick := _render_path("sample_speed", 4.0)
		var early := _wav_region_rms(quick, 0.05, 0.30)
		var late := _wav_region_rms(quick, 1.30, 1.80)
		_check("automating a sample's speed plays it faster", early > 0.0005 and late < early * 0.5,
				"%.4f then %.4f" % [early, late])
		app.set_sample_live(ai, "speed", 1.0)
		Audio.engine.set_mode(Cd.Mode.PATTERN)

	# --- what a lane does with the value it produces
	print("--- automation modes")
	app.new_project()
	await tree.process_frame
	app.add_stock_channel("cd.pluck")
	app.add_note(0, 0, 0.0, 1.5, 60, 0.9)
	app.note_edit_done(0)
	app.set_channel_prop(0, "mixer", 1)
	app.set_mixer_prop(1, "vol", 0.5)
	var mlane: int = app.add_automation("mixer volume", Cd.AutoTarget.MIXER_VOL, {}, 1, 0, 0.0, 1.25)
	app.project.automations[mlane].points = [
		{"beat": 0.0, "value": 0.3, "curve": 0.0},
		{"beat": 4.0, "value": 0.3, "curve": 0.0},
	]
	app.add_clip(Cd.ClipType.PATTERN, 0, 0, 0.0, 4.0)
	app.add_clip(Cd.ClipType.AUTOMATION, mlane, 1, 0.0, 4.0)
	app.clip_edit_done()
	app.set_automation_prop(mlane, "on", false)
	Audio.engine.set_mode(Cd.Mode.SONG)
	await tree.process_frame
	_render("auto_off", 2.0)
	var off_st := _render("auto_off", 2.0)
	app.set_automation_prop(mlane, "on", true)
	app.set_mixer_prop(1, "vol", 0.5)
	await tree.process_frame
	_render("auto_forced", 2.0)
	var forced_st := _render("auto_forced", 2.0)
	app.set_mixer_prop(1, "vol", 0.5)
	app.set_automation_prop(mlane, "mode", Cd.AutoMode.ADDITIVE)
	await tree.process_frame
	_render("auto_additive", 2.0)
	var add_st := _render("auto_additive", 2.0)
	# What additive should add up to, done by forcing: 0.5 set by hand plus a
	# curve at 0.3 is the same sound as the control held at 0.8. Compared
	# against that rather than against a ratio, because the mixer's gain is
	# smoothed and a plucked attack does not scale exactly with it.
	app.set_automation_prop(mlane, "mode", Cd.AutoMode.FORCED)
	app.project.automations[mlane].points = [
		{"beat": 0.0, "value": 0.8, "curve": 0.0},
		{"beat": 4.0, "value": 0.8, "curve": 0.0},
	]
	app.push_automation()
	await tree.process_frame
	_render("auto_08", 2.0)
	var eight_st := _render("auto_08", 2.0)
	_check("a lane switched off leaves its control where it was set",
			float(off_st.get("rms", 0.0)) > 0.0001, "rms %.4f" % off_st.get("rms", 0.0))
	_check("forced holds the control at the curve",
			float(forced_st.get("rms", 0.0)) < float(off_st.get("rms", 0.0)) * 0.85,
			"%.4f against %.4f set by hand" % [forced_st.get("rms", 0.0), off_st.get("rms", 0.0)])
	_check("additive adds the curve to what it was set to",
			float(add_st.get("rms", 0.0)) > float(off_st.get("rms", 0.0))
			and absf(float(add_st.get("rms", 0.0)) - float(eight_st.get("rms", 0.0)))
					< float(eight_st.get("rms", 0.0)) * 0.08,
			"%.5f, and %.5f held at the total" % [add_st.get("rms", 0.0), eight_st.get("rms", 0.0)])
	Audio.engine.set_mode(Cd.Mode.PATTERN)

	# --- the ceiling on the master
	print("--- master ceiling")
	app.new_project()
	await tree.process_frame
	app.add_stock_channel("cd.pluck")
	app.add_note(0, 0, 0.0, 1.0, 60, 1.0)
	app.note_edit_done(0)
	# Wound up far past full scale, the way a runaway gain or a feedback loop
	# does it.
	# The master wound up thirty times past unity, which is what a runaway gain
	# or a feedback loop looks like from here.
	app.set_mixer_prop(0, "vol", 30.0)
	Audio.engine.set_mode(Cd.Mode.PATTERN)
	Audio.engine.set_current_pattern(0)
	Audio.engine.set_limiter(false, -1.0)
	await tree.process_frame
	var unheld := _render("limiter_off", 2.0)
	Audio.engine.set_limiter(true, -1.0)
	await tree.process_frame
	var held := _render("limiter_on", 2.0)
	Audio.engine.set_limiter(bool(Settings.get_value("limiter", true)),
			float(Settings.get_value("limiter_ceiling", -1.0)))
	# -1 dBFS is 0.891; the file is 24-bit, so allow a bit for the rounding.
	_check("the ceiling holds the master down", float(held.get("peak", 0.0)) <= 0.9,
			"peak %.4f" % held.get("peak", 0.0))
	_check("and something is still coming out", float(held.get("rms", 0.0)) > 0.001,
			"rms %.4f" % held.get("rms", 0.0))
	_check("and without it the same mix runs into the top of the file",
			float(unheld.get("peak", 0.0)) > 0.98,
			"peak %.4f against %.4f held" % [unheld.get("peak", 0.0), held.get("peak", 0.0)])

	# --- routing: a track's audio really does follow the lines drawn under it
	print("--- routing")
	app.new_project()
	await tree.process_frame
	app.add_stock_channel("cd.pluck")
	app.add_note(0, 0, 0.0, 1.0, 60, 0.9)
	app.note_edit_done(0)
	Audio.engine.set_mode(Cd.Mode.PATTERN)
	Audio.engine.set_current_pattern(0)
	await tree.process_frame
	# Twice, and the second one measured, throughout this section: an
	# instrument carries its own state from one render into the next and a
	# fader takes a moment to move, and neither is what is being asked about.
	_render("route_direct", 2.0)
	var direct := _render("route_direct", 2.0)
	_check("a track is heard through the master", float(direct.get("rms", 0.0)) > 0.001,
			"rms %.4f" % direct.get("rms", 0.0))
	# Through another track instead, with that one turned down: if the audio
	# really goes that way, the master hears nothing.
	var through: int = app.add_mixer_track("Bus")
	app.set_route(1, 0, false)
	app.set_route(1, through, true)
	app.set_mixer_prop(through, "vol", 0.0)
	await tree.process_frame
	# Rendered twice, the second one measured: a fader moves over a few
	# milliseconds rather than instantly, and the first render would be mostly
	# a measurement of it on its way down.
	_render("route_muted", 2.0)
	var muted := _render("route_muted", 2.0)
	_check("routed through a silent track, nothing comes out",
			float(muted.get("rms", 0.0)) < float(direct.get("rms", 0.0)) * 0.02,
			"rms %.5f against %.4f" % [muted.get("rms", 0.0), direct.get("rms", 0.0)])
	app.set_mixer_prop(through, "vol", 1.0)
	await tree.process_frame
	# Twice again: the fader is on its way back up during the first one.
	_render("route_open", 2.0)
	var open_bus := _render("route_open", 2.0)
	_check("and with it open the sound comes back",
			float(open_bus.get("rms", 0.0)) > float(direct.get("rms", 0.0)) * 0.5,
			"rms %.4f" % open_bus.get("rms", 0.0))
	# A track may feed several at once, which is what the extra lines are.
	var second: int = app.add_mixer_track("Bus 2")
	app.set_route(1, second, true)
	await tree.process_frame
	_check("a track can feed more than one", app.routes_of(1).size() == 2,
			str(app.routes_of(1)))
	_render("route_both", 2.0)
	var both := _render("route_both", 2.0)
	_check("and both of them are heard", float(both.get("rms", 0.0))
			> float(open_bus.get("rms", 0.0)) * 1.1,
			"rms %.4f against %.4f" % [both.get("rms", 0.0), open_bus.get("rms", 0.0)])

	# --- effect chain editing keeps the stack packed
	print("--- effect stack")
	app.new_project()
	await tree.process_frame
	app.set_insert(1, 0, CdProject.plugin_dict("stock", "cd.reverb", "", "Reverb"))
	app.set_insert(1, 1, CdProject.plugin_dict("stock", "cd.delay", "", "Delay"))
	app.remove_insert(1, 0)
	var top = app.project.mixer[1].inserts[0]
	_check("removing an effect closes the gap", top != null and String(top.get("name", "")) == "Delay",
			String(top.get("name", "(empty)")) if top != null else "(empty)")
	app.copy_insert(1, 0, 2)
	var copied = app.project.mixer[2].inserts[0]
	_check("effects copy to another strip", copied != null and String(copied.get("name", "")) == "Delay")

	# --- icons are rasterised for the screen, not for the layout
	print("--- icons")
	var over: float = Icons.oversample()
	var tex: Texture2D = Icons.get_icon("play", 16)
	var raster := Vector2i.ZERO
	if tex is ImageTexture:
		raster = Vector2i(tex.get_image().get_width(), tex.get_image().get_height())
	_check("icon measures as its nominal size", tex != null and tex.get_size() == Vector2(16, 16),
			"%s" % str(tex.get_size() if tex != null else Vector2.ZERO))
	_check("icon is rasterised above its nominal size", raster.x >= int(16.0 * over) - 1,
			"%dx%d pixels for a 16 px icon at %.2fx" % [raster.x, raster.y, over])

	# --- muting cuts what is already sounding, and playing from the middle of a
	#     note plays that note
	print("--- transport and mute")
	app.new_project()
	await tree.process_frame
	app.project.channels.clear()
	app.channel_handles.clear()
	app.project.add_channel("Pad", CdProject.plugin_dict("stock", "cd.ember", "", "Ember"), 1)
	app.sync_all()
	app.add_note(0, 0, 0.0, 4.0, 60, 0.9)
	Audio.engine.set_mode(Cd.Mode.PATTERN)
	var from_mid := _render("mid_note", 1.0, 2.0)
	_check("playing from the middle of a note sounds it", float(from_mid.get("peak", 0.0)) > 0.02,
			"peak %.3f starting two beats in" % from_mid.get("peak", 0.0))

	Audio.engine.set_position(0.0)
	Audio.engine.note_on(0, 60, 0.9)
	await tree.process_frame
	var before_mute: int = Audio.engine.active_notes(0).size()
	Audio.engine.stop_channel(0)
	await tree.process_frame
	_check("muting a channel cuts what it is playing",
			before_mute > 0 and Audio.engine.active_notes(0).is_empty(),
			"%d sounding before, %d after" % [before_mute, Audio.engine.active_notes(0).size()])

	# --- a picture played as sound
	print("--- prism")
	app.new_project()
	await tree.process_frame
	app.project.channels.clear()
	app.channel_handles.clear()
	app.project.add_channel("Prism", CdProject.plugin_dict("stock", "cd.prism", "", "Prism"), 1)
	app.sync_all()
	var ref := {"kind": "channel", "index": 0}
	# Three bright rows: three partials that should be there in the output.
	var loaded: bool = app.load_plugin_image(ref, _test_image(), 48, 64)
	_check("prism reads a picture", loaded)
	app.add_note(0, 0, 0.0, 1.8, 60, 0.9)
	Audio.engine.set_mode(Cd.Mode.PATTERN)
	var pr := _render("prism", 2.0)
	_check("prism turns the picture into sound", float(pr.get("peak", 0.0)) > 0.02,
			"peak %.3f rms %.4f" % [pr.get("peak", 0.0), pr.get("rms", 0.0)])
	# An empty picture has to be silence, not noise.
	var blank := Image.create(32, 32, false, Image.FORMAT_RGB8)
	blank.fill(Color.BLACK)
	var blank_path := dir.path_join("prism_blank.png")
	blank.save_png(blank_path)
	app.load_plugin_image(ref, blank_path, 32, 32)
	var silent := _render("prism_blank", 1.0)
	_check("a black picture is silence", float(silent.get("peak", 0.0)) < 0.01,
			"peak %.4f" % silent.get("peak", 0.0))

	print("--- automation")
	var ai: int = app.add_automation("test", Cd.AutoTarget.MIXER_VOL, {}, 1, 0, 0.0, 1.0)
	app.set_automation_points(ai, [{"beat": 0.0, "value": 0.0, "curve": 0.0},
			{"beat": 4.0, "value": 1.0, "curve": 0.0}])
	_check("automation interpolates", absf(app.automation_value(ai, 2.0) - 0.5) < 0.01,
			"%.3f at the midpoint" % app.automation_value(ai, 2.0))

	# --- a run of short notes on one key
	print("--- fast repeats")
	for inst_id in ["cd.pluck", "cd.ember"]:
		app.new_project()
		await tree.process_frame
		app.add_stock_channel(inst_id)
		# Sixteen notes on the same key, back to back. Every one of them has to
		# be heard: a repeated key is the case where a note-off for the one
		# before can land on top of the one after and silence it.
		for i in 16:
			app.add_note(0, 0, float(i) * 0.25, 0.2, 60, 0.9)
		app.note_edit_done(0)
		app.project.patterns[0]["length"] = 4.0
		app.push_pattern(0)
		Audio.engine.set_mode(Cd.Mode.PATTERN)
		Audio.engine.set_current_pattern(0)
		await tree.process_frame
		var run := dir.path_join("fast_%s.wav" % inst_id.replace(".", "_"))
		var ok_run: bool = Audio.engine.render_loop(run, 0.0, 4.0, 0.05, 24, false, false)
		var secs: float = 4.0 * 60.0 / float(app.project.bpm)
		var loud := 0.0
		var slices := []
		for i in 16:
			var a := secs * float(i) / 16.0
			var b := secs * float(i + 1) / 16.0
			var r := _wav_region_rms(run, a, b)
			slices.append(r)
			loud = maxf(loud, r)
		var heard := 0
		for r in slices:
			if float(r) > loud * 0.1:
				heard += 1
		_check("%s plays every note of a fast run" % inst_id, ok_run and heard >= 15,
				"%d of 16 sounded" % heard)

	# --- exporting: the tail, and folding it back for a seamless loop
	print("--- export")
	app.new_project()
	await tree.process_frame
	app.add_stock_channel("cd.ember")
	# One note at the very end of the range, so everything that is still
	# sounding when the range ends is the tail and nothing else.
	app.add_note(0, 0, 3.5, 0.5, 60, 0.9)
	app.set_insert(1, 0, CdProject.plugin_dict("stock", "cd.reverb", "", "Reverb"))
	app.note_edit_done(0)
	Audio.engine.set_mode(Cd.Mode.PATTERN)
	Audio.engine.set_current_pattern(0)
	await tree.process_frame

	var beats := 4.0
	var body_secs: float = beats * 60.0 / float(app.project.bpm)
	var plain := dir.path_join("export_plain.wav")
	var made: bool = Audio.engine.render_loop(plain, 0.0, beats, 1.5, 24, false, false)
	var plain_secs := _wav_seconds(plain)
	_check("a plain export is the range plus the tail it was asked for", made
			and absf(plain_secs - (body_secs + 1.5)) < 0.15,
			"%.2f s, expected about %.2f" % [plain_secs, body_secs + 1.5])
	_check("nothing sounds before the note does",
			_wav_region_rms(plain, 0.0, 0.2) < 0.0005,
			"rms %.5f in the first 200 ms" % _wav_region_rms(plain, 0.0, 0.2))

	var looped := dir.path_join("export_loop.wav")
	var made2: bool = Audio.engine.render_loop(looped, 0.0, beats, 1.5, 24, false, true)
	var loop_secs := _wav_seconds(looped)
	_check("a seamless export is exactly the range", made2
			and absf(loop_secs - body_secs) < 0.05,
			"%.2f s, expected %.2f" % [loop_secs, body_secs])
	var folded := _wav_region_rms(looped, 0.0, 0.2)
	_check("the tail is folded onto the start, so the join has something in it",
			folded > 0.001, "rms %.5f in the first 200 ms" % folded)

	var auto := dir.path_join("export_auto.wav")
	var made3: bool = Audio.engine.render_loop(auto, 0.0, beats, -1.0, 24, false, false)
	var auto_secs := _wav_seconds(auto)
	_check("an automatic tail runs past the end and stops on its own", made3
			and auto_secs > body_secs + 0.2 and auto_secs < 60.0,
			"%.2f s for a %.2f s range" % [auto_secs, body_secs])
	_check("an automatic tail ends quiet",
			_wav_region_rms(auto, auto_secs - 0.2, auto_secs) < 0.0005,
			"rms %.5f in the last 200 ms" % _wav_region_rms(auto, maxf(0.0, auto_secs - 0.2), auto_secs))

	# Exporting the current pattern, asked for exactly the way the export
	# window asks for it: the whole pattern, from its first beat to its last,
	# with the tail left to run itself out. The checks above all stop short of
	# the pattern's own end, which is the one case that matters here.
	var pat_beats := float(app.project.patterns[app.current_pattern].length)
	var whole := dir.path_join("export_pattern.wav")
	var made4: bool = Audio.engine.render_loop(whole, 0.0, pat_beats, -1.0, 24, false, false)
	var whole_secs := _wav_seconds(whole)
	var pat_secs: float = pat_beats * 60.0 / float(app.project.bpm)
	_check("the whole of a pattern renders", made4 and whole_secs > pat_secs * 0.9,
			"%.2f s for a %.2f beat pattern (%.2f s)" % [whole_secs, pat_beats, pat_secs])
	var noisy := _wav_noisiness(whole, 0.0, whole_secs)
	_check("and what comes out is music rather than noise", noisy < 0.5,
			"noisiness %.3f over %.2f s" % [noisy, whole_secs])
	var late := _wav_noisiness(whole, maxf(0.0, whole_secs - 1.0), whole_secs)
	_check("including the end of it", late < 0.5, "noisiness %.3f in the last second" % late)
	var st := _wav_stats(whole)
	_check("and nothing in it is louder than full scale",
			not st.is_empty() and float(st.peak) <= 1.001, "peak %.3f" % float(st.get("peak", 0.0)))

	# Seamless and an automatic tail together. The tail can easily run longer
	# than the range it is being folded back onto -- a whole pattern of reverb
	# over four bars of music -- and folding it round and round would pile
	# copy on copy until the file clips.
	var seam := dir.path_join("export_pattern_seamless.wav")
	var made_s: bool = Audio.engine.render_loop(seam, 0.0, pat_beats, -1.0, 24, false, true)
	var seam_secs := _wav_seconds(seam)
	var seam_stats := _wav_stats(seam)
	_check("a seamless export with an automatic tail is the range", made_s
			and absf(seam_secs - pat_secs) < 0.1,
			"%.2f s, expected %.2f" % [seam_secs, pat_secs])
	_check("and folding the tail back on does not pile up into clipping",
			not seam_stats.is_empty() and float(seam_stats.peak) <= 1.001,
			"peak %.3f" % float(seam_stats.get("peak", 0.0)))
	var seam_noise := _wav_noisiness(seam, 0.0, seam_secs)
	_check("and still sounds like music", seam_noise < 0.5,
			"noisiness %.3f" % seam_noise)

	# The same again with a hosted plugin making the sound, which is what a real
	# project has on it. A stock instrument and a VST3 are rendered by different
	# code and only one of them was ever checked here.
	var vst := {}
	for e in Plugins.vst3:
		if bool(e.get("instrument", false)):
			vst = e
			break
	if vst.is_empty():
		print("  --    no VST3 instrument installed to export through")
	else:
		app.replace_channel_plugin(0, CdProject.plugin_dict("vst3", String(vst.cid),
				String(vst.path), String(vst.name)))
		# A big instrument takes a moment to come up before it makes any sound.
		for i in 40:
			await tree.process_frame
		var hosted := dir.path_join("export_pattern_vst.wav")
		var made5: bool = Audio.engine.render_loop(hosted, 0.0, pat_beats, -1.0, 24, false, false)
		var hosted_secs := _wav_seconds(hosted)
		var hosted_noise := _wav_noisiness(hosted, 0.0, hosted_secs)
		_check("a pattern with a hosted instrument on it renders", made5 and hosted_secs > 0.5,
				"%.2f s through %s" % [hosted_secs, String(vst.name)])
		_check("and that comes out as music rather than noise", hosted_noise < 0.5,
				"noisiness %.3f over %.2f s" % [hosted_noise, hosted_secs])
		var hst := _wav_stats(hosted)
		_check("and stays inside full scale",
				not hst.is_empty() and float(hst.peak) <= 1.001,
				"peak %.3f" % float(hst.get("peak", 0.0)))

	# --- and the formats it can be written as
	var tool := CdExport.ffmpeg()
	if tool.is_empty():
		print("  skip  export formats (no ffmpeg here)")
	else:
		for f in CdExport.FORMATS:
			if not f.has("args"):
				continue
			var dst: String = dir.path_join("export_fmt.%s" % String(f.ext))
			DirAccess.remove_absolute(dst)
			var made_fmt: bool = CdExport.encode(tool, plain, dst, f)
			var size := 0
			if FileAccess.file_exists(dst):
				var fh := FileAccess.open(dst, FileAccess.READ)
				size = int(fh.get_length())
				fh.close()
			_check(String(f.name), made_fmt and size > 2048, "%d bytes" % size)

	print("")
	print("%d passed, %d failed" % [pass_count, fail_count])
	return fail_count


func _render_song(name: String) -> Dictionary:
	var path := dir.path_join(name + ".wav")
	Audio.engine.set_mode(Cd.Mode.SONG)
	var ok: bool = Audio.engine.render(path, 0.0, minf(16.0, app.project.length_beats()), 1.0, 24, false)
	return _wav_stats(path) if ok else {}


## A picture with a few bright rows, for the instrument sweep and for Prism's
## own checks. Written once and reused.
func _test_image() -> String:
	var path := dir.path_join("prism_test.png")
	if FileAccess.file_exists(path):
		return path
	var img := Image.create(64, 48, false, Image.FORMAT_RGB8)
	img.fill(Color.BLACK)
	for x in 64:
		for row in [8, 20, 33]:
			img.set_pixel(x, row, Color(1, 1, 1))
	img.save_png(path)
	return path


func _find_soundfont() -> String:
	var list := Plugins.soundfonts()
	return String(list[0].path) if not list.is_empty() else ""


func _note_count(d: Dictionary) -> int:
	var n := 0
	for p in d.get("patterns", []):
		n += (p.get("notes", []) as Array).size()
	return n


func _pattern_notes(p: CdProject) -> int:
	var n := 0
	for pat in p.patterns:
		n += (pat.notes as Array).size()
	return n
