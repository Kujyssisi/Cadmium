extends Node
## Owns the C++ engine node and everything that talks to the audio device:
## transport, meters, MIDI input, and the ffmpeg hop that turns any audio file
## into the float WAV the engine reads.

signal transport_changed()
signal midi_note(key: int, velocity: float, on: bool)
signal midi_cc(controller: int, value: float)
signal midi_bend(value: float)

var engine                                  ## CdEngine (GDExtension)
var meters := PackedFloat32Array()
var _last_playing := false
var _midi_open := false

const CACHE_DIR := "user://cache"

## The metronome's two clicks: the accented one on the first beat of a bar, and
## the one every other beat gets. Recordings rather than a synthesised blip,
## which is what the engine falls back to if either will not load.
const METRONOME_BAR := "res://resources/metronome_loud.wav"
const METRONOME_BEAT := "res://resources/metronome_silent.wav"


## The ceiling on the master, from the preferences. Kept here so the setting
## and the engine cannot drift apart: everything that changes it calls this.
func apply_limiter() -> void:
	if engine == null:
		return
	engine.set_limiter(bool(Settings.get_value("limiter", true)),
			float(Settings.get_value("limiter_ceiling", -1.0)))


func _ready() -> void:
	process_priority = -100
	engine = ClassDB.instantiate("CdEngine")
	if engine == null:
		push_error("Cadmium: the audio engine extension is not loaded -- build native/ first.")
		return
	add_child(engine)
	# Before anything else can go wrong: a report of what was being done is
	# only useful if the handler was armed before it was done.
	CdCrash.arm()
	engine.start_audio()
	apply_limiter()
	_load_metronome()
	DirAccess.make_dir_recursive_absolute(CACHE_DIR)
	# Godot's own OS.open_midi_inputs() crashes here, so the engine talks to the
	# ALSA sequencer itself and we poll it.
	if bool(Settings.get_value("midi_input", true)):
		_midi_open = engine.midi_open()
		if _midi_open:
			var n: int = engine.midi_connect_all()
			if n > 0:
				print("Cadmium: connected %d MIDI input%s" % [n, "" if n == 1 else "s"])


## Hands the two clicks to the engine as plain samples. They travel as an
## imported AudioStreamWAV rather than as a file on disk, so they are still
## there inside an exported build, where nothing under res:// is a real file any
## more and ffmpeg could not be pointed at them.
func _load_metronome() -> void:
	for entry in [[0, METRONOME_BAR], [1, METRONOME_BEAT]]:
		var which := int(entry[0])
		var path := String(entry[1])
		if not ResourceLoader.exists(path):
			push_warning("Cadmium: %s is missing, the metronome falls back to its own click" % path)
			continue
		var st := load(path) as AudioStreamWAV
		if st == null:
			continue
		var pcm := _wav_floats(st)
		if pcm.is_empty():
			push_warning("Cadmium: %s is in a format the metronome cannot read" % path)
			continue
		engine.set_metronome_sound(which, pcm, float(st.mix_rate), 2 if st.stereo else 1)


## An imported WAV's bytes as interleaved floats. Only the uncompressed formats:
## the two clicks are ours and are imported without compression, and a click
## that arrived as ADPCM would be the wrong thing to quietly half-decode.
func _wav_floats(st: AudioStreamWAV) -> PackedFloat32Array:
	var raw: PackedByteArray = st.data
	var out := PackedFloat32Array()
	match st.format:
		AudioStreamWAV.FORMAT_16_BITS:
			var n := raw.size() / 2
			out.resize(n)
			for i in n:
				out[i] = float(raw.decode_s16(i * 2)) / 32768.0
		AudioStreamWAV.FORMAT_8_BITS:
			out.resize(raw.size())
			for i in raw.size():
				out[i] = float(raw.decode_s8(i)) / 128.0
	return out


func _process(_dt: float) -> void:
	if engine == null:
		return
	meters = engine.meters()
	var p: bool = engine.is_playing()
	if p != _last_playing:
		_last_playing = p
		transport_changed.emit()
	if _midi_open:
		_pump_midi()


func _pump_midi() -> void:
	var ev: PackedInt32Array = engine.midi_poll()
	var i := 0
	while i + 2 < ev.size():
		var status := ev[i]
		var d1 := ev[i + 1]
		var d2 := ev[i + 2]
		i += 3
		match status & 0xF0:
			0x90:
				if d2 > 0:
					midi_note.emit(d1, float(d2) / 127.0, true)
				else:
					midi_note.emit(d1, 0.0, false)
			0x80:
				midi_note.emit(d1, 0.0, false)
			0xB0:
				midi_cc.emit(d1, float(d2) / 127.0)
			0xE0:
				midi_bend.emit((float((d2 << 7) | d1) - 8192.0) / 8192.0)


func midi_devices() -> Array:
	return engine.midi_ports() if engine != null else []


# ---------------------------------------------------------------------------
# Transport
# ---------------------------------------------------------------------------
## Where playback last began, which is where stopping puts the marker back to.
## Moving the marker by hand sets it: put the marker somewhere, play, stop, and
## you are back where you put it rather than wherever the music got to, which
## is how every other sequencer behaves and how you listen to the same eight
## bars twice.
var start_beat := 0.0


func play(from_start: bool = false) -> void:
	if engine == null:
		return
	if from_start:
		start_beat = 0.0
	engine.play(from_start)
	transport_changed.emit()


func stop() -> void:
	if engine == null:
		return
	engine.stop()
	# Stopped twice over goes to the beginning: the first press returns to the
	# marker, the second takes the marker itself home.
	if not engine.is_playing() and absf(engine.get_position() - start_beat) < 0.001:
		start_beat = 0.0
	engine.set_position(start_beat)
	transport_changed.emit()


func toggle() -> void:
	if engine == null:
		return
	if engine.is_playing():
		engine.stop()
		engine.set_position(start_beat)
	else:
		engine.play(false)
	transport_changed.emit()


## Puts the marker somewhere by hand. That spot is where playing starts from
## and where stopping comes back to.
func seek(beat: float) -> void:
	if engine == null:
		return
	start_beat = maxf(0.0, beat)
	engine.set_position(start_beat)
	transport_changed.emit()


func position() -> float:
	return engine.get_position() if engine else 0.0


func playing() -> bool:
	return engine.is_playing() if engine else false


func peak(track: int) -> Vector2:
	var i := track * 4
	if i + 1 >= meters.size():
		return Vector2.ZERO
	return Vector2(meters[i], meters[i + 1])


func rms(track: int) -> Vector2:
	var i := track * 4
	if i + 3 >= meters.size():
		return Vector2.ZERO
	return Vector2(meters[i + 2], meters[i + 3])


# ---------------------------------------------------------------------------
# Media
# ---------------------------------------------------------------------------
## Where to find one of the ffmpeg tools. On Linux it is on the path; on Windows
## it usually is not, so a copy dropped beside Cadmium -- either in the folder
## itself or in an ffmpeg\bin under it -- is used before the path is tried.
var _tool_cache := {}


func tool_path(name: String) -> String:
	if _tool_cache.has(name):
		return String(_tool_cache[name])
	var found := name
	if OS.get_name() == "Windows":
		var here := OS.get_executable_path().get_base_dir()
		for candidate in [here.path_join("%s.exe" % name),
				here.path_join("ffmpeg/bin/%s.exe" % name),
				here.path_join("ffmpeg/%s.exe" % name)]:
			if FileAccess.file_exists(candidate):
				found = candidate
				break
	_tool_cache[name] = found
	return found


## Anything ffmpeg can open becomes a 32-bit float WAV at the engine's rate.
## Plain WAVs are handed straight through -- the engine reads those itself.
func to_engine_wav(src: String) -> String:
	if src.is_empty() or not FileAccess.file_exists(src):
		return ""
	var rate := int(engine.sample_rate()) if engine else 48000
	if src.get_extension().to_lower() == "wav":
		return src
	var hash := str(src.hash()) + "_" + str(FileAccess.get_modified_time(src)) + "_" + str(rate)
	var out := ProjectSettings.globalize_path(CACHE_DIR).path_join("a_%s.wav" % hash)
	if FileAccess.file_exists(out):
		return out
	var args := ["-hide_banner", "-v", "error", "-y", "-i", src, "-ar", str(rate),
			"-acodec", "pcm_f32le", out]
	var res := OS.execute(tool_path("ffmpeg"), args, [], true)
	if res != 0 or not FileAccess.file_exists(out):
		push_warning("Cadmium: ffmpeg could not decode %s" % src)
		return ""
	return out


## What ffprobe says about a file. Cached by path: it is a subprocess, it costs
## about ten milliseconds, and the answer for a file on disk does not change
## while Cadmium is looking at it.
var _info_cache := {}


func audio_info(path: String) -> Dictionary:
	if _info_cache.has(path):
		return _info_cache[path]
	var d := _probe(path)
	if _info_cache.size() > 256:
		_info_cache.clear()
	_info_cache[path] = d
	return d


func _probe(path: String) -> Dictionary:
	var out := []
	var args := ["-v", "error", "-show_entries", "format=duration:stream=sample_rate,channels",
			"-of", "default=noprint_wrappers=1:nokey=0", path]
	if OS.execute(tool_path("ffprobe"), args, out, true) != 0 or out.is_empty():
		return {}
	var d := {}
	for line in String(out[0]).split("\n"):
		var kv := line.split("=")
		if kv.size() == 2:
			d[kv[0]] = kv[1]
	return d
