class_name CdPerfLog
extends RefCounted
## A recording of how Cadmium is running, meant to be sent to someone else.
##
## Somebody reporting that it is "laggy" cannot say how laggy, on what, or when.
## This samples the numbers four times a second while it is on, and writes a
## file at the end with the machine it ran on at the top -- so a report arrives
## with the frame times, the audio load and the project that produced them
## rather than an adjective.

const INTERVAL := 0.25
const MAX_SAMPLES := 60 * 60 * 4          ## an hour at four a second

var running := false
var _t := 0.0
var _elapsed := 0.0
var _started := ""
var _samples: Array = []
## The worst frame seen, kept separately: an average hides exactly the stall
## everyone is complaining about.
var _worst_frame := 0.0
var _worst_at := 0.0
var _frames := 0
var _stalls := 0


func start() -> void:
	_samples.clear()
	_t = 0.0
	_elapsed = 0.0
	_frames = 0
	_stalls = 0
	_worst_frame = 0.0
	_worst_at = 0.0
	_started = Time.get_datetime_string_from_system()
	running = true


## Called every frame while running.
func tick(dt: float) -> void:
	if not running:
		return
	_elapsed += dt
	_frames += 1
	if dt > _worst_frame:
		_worst_frame = dt
		_worst_at = _elapsed
	# A frame over 50 ms is a visible hitch, whatever the average says.
	if dt > 0.05:
		_stalls += 1
	_t += dt
	if _t < INTERVAL:
		return
	if dt <= 0.0 and _frames > 0:
		# Called from stop(): the frame it reports is the worst one seen, since
		# there is no current one to speak of.
		dt = _worst_frame
	_t = 0.0
	if _samples.size() >= MAX_SAMPLES:
		return
	var voices := 0
	var e = Audio.engine
	if e != null:
		for i in App.project.channels.size():
			voices += int(e.active_notes(i).size())
	_samples.append({
		"t": snappedf(_elapsed, 0.01),
		"fps": Engine.get_frames_per_second(),
		"frame_ms": snappedf(dt * 1000.0, 0.01),
		"audio_cpu": snappedf((e.cpu() if e != null else 0.0) * 100.0, 0.1),
		"voices": voices,
		"playing": Audio.playing(),
		"mem_mb": snappedf(float(OS.get_static_memory_usage()) / 1048576.0, 0.1),
		"objects": Performance.get_monitor(Performance.OBJECT_COUNT),
		"draw_calls": Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME),
	})


## Stops and writes the file. Returns where it went, or "" if it could not.
func stop() -> String:
	# One last reading, so a recording shorter than the sampling interval still
	# says something rather than handing back an empty list.
	if running and _samples.is_empty():
		_t = INTERVAL
		tick(0.0)
	running = false
	var path := _path()
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return ""
	f.store_string(JSON.stringify(_report(), "\t"))
	f.close()
	return path


func _path() -> String:
	var stamp := Time.get_datetime_string_from_system().replace(":", "-").replace("T", "_")
	var dir := OS.get_user_data_dir().path_join("performance")
	DirAccess.make_dir_recursive_absolute(dir)
	return dir.path_join("cadmium-performance-%s.json" % stamp)


func _report() -> Dictionary:
	var fps_min := 1000.0
	var fps_sum := 0.0
	var cpu_max := 0.0
	var cpu_sum := 0.0
	for s in _samples:
		fps_min = minf(fps_min, float(s.fps))
		fps_sum += float(s.fps)
		cpu_max = maxf(cpu_max, float(s.audio_cpu))
		cpu_sum += float(s.audio_cpu)
	var n := maxf(1.0, float(_samples.size()))
	var plugins: Array = []
	for c in App.project.channels:
		var p: Dictionary = c.plugin
		plugins.append("%s: %s (%s)" % [String(c.name), String(p.get("name", "?")), String(p.get("kind", "?"))])
	for t in App.project.mixer.size():
		for slot in App.project.mixer[t].inserts.size():
			var ins = App.project.mixer[t].inserts[slot]
			if ins != null:
				plugins.append("mixer %d slot %d: %s (%s)" % [t, slot,
						String(ins.get("name", "?")), String(ins.get("kind", "?"))])
	return {
		"cadmium": {
			"started": _started,
			"seconds": snappedf(_elapsed, 0.01),
			"frames": _frames,
		},
		"machine": {
			"os": OS.get_name(),
			"distribution": OS.get_distribution_name(),
			"version": OS.get_version(),
			"cpu": OS.get_processor_name(),
			"cores": OS.get_processor_count(),
			"gpu": RenderingServer.get_video_adapter_name(),
			"driver": RenderingServer.get_video_adapter_api_version(),
			"display_scale": Settings.ui_scale(),
			"screen_refresh": DisplayServer.screen_get_refresh_rate(),
			"audio_rate": Audio.engine.sample_rate() if Audio.engine != null else 0,
			"audio_device": AudioServer.get_output_device(),
			"max_fps": Engine.max_fps,
		},
		"summary": {
			"average_fps": snappedf(fps_sum / n, 0.1),
			"lowest_fps": snappedf(fps_min, 0.1),
			"worst_frame_ms": snappedf(_worst_frame * 1000.0, 0.01),
			"worst_frame_at_seconds": snappedf(_worst_at, 0.01),
			"frames_over_50ms": _stalls,
			"average_audio_cpu": snappedf(cpu_sum / n, 0.1),
			"peak_audio_cpu": snappedf(cpu_max, 0.1),
		},
		"project": {
			"channels": App.project.channels.size(),
			"patterns": App.project.patterns.size(),
			"clips": App.project.clips.size(),
			"notes": _note_total(),
			"plugins": plugins,
		},
		"samples": _samples,
	}


func _note_total() -> int:
	var n := 0
	for p in App.project.patterns:
		n += int(p.notes.size())
	return n
