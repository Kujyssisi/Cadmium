class_name CdExport
extends RefCounted
## What Cadmium can write a mix out as, and the ffmpeg hop that gets it there.
##
## The render itself is always a float WAV: anything else is encoded from that
## afterwards, so the mix is never rounded twice, and the same list is what the
## export window offers and what the tests check can actually be written.

const FORMATS := [
	{"name": "WAV 16-bit", "ext": "wav", "bits": 16},
	{"name": "WAV 24-bit", "ext": "wav", "bits": 24},
	{"name": "WAV 32-bit float", "ext": "wav", "bits": 32},
	{"name": "FLAC (lossless)", "ext": "flac", "bits": 24,
		"args": ["-c:a", "flac", "-compression_level", "8"]},
	{"name": "AIFF 24-bit", "ext": "aiff", "bits": 24, "args": ["-c:a", "pcm_s24be"]},
	{"name": "MP3 320 kbps", "ext": "mp3", "bits": 24, "args": ["-c:a", "libmp3lame", "-b:a", "320k"]},
	{"name": "MP3 V0 (variable)", "ext": "mp3", "bits": 24, "args": ["-c:a", "libmp3lame", "-q:a", "0"]},
	{"name": "OGG Vorbis q7", "ext": "ogg", "bits": 24, "args": ["-c:a", "libvorbis", "-q:a", "7"]},
	{"name": "Opus 192 kbps", "ext": "opus", "bits": 24, "args": ["-c:a", "libopus", "-b:a", "192k"]},
	{"name": "AAC 256 kbps", "ext": "m4a", "bits": 24, "args": ["-c:a", "aac", "-b:a", "256k"]},
]


## ffmpeg, if there is one to be had. Everything but WAV needs it, and it is
## already how anything that is not a WAV gets read back in.
static func ffmpeg() -> String:
	var tool := Audio.tool_path("ffmpeg")
	if tool.contains("/") or tool.contains("\\"):
		return tool if FileAccess.file_exists(tool) else ""
	# A bare name means "look on the path", which is only worth believing once
	# it has been tried.
	return tool if OS.execute(tool, ["-version"], [], true) == 0 else ""


## One file, encoded. `src` is the WAV the engine wrote.
static func encode(tool: String, src: String, dst: String, format: Dictionary) -> bool:
	if tool.is_empty() or not format.has("args"):
		return false
	var args := ["-hide_banner", "-v", "error", "-y", "-i", src]
	args.append_array(format.args)
	args.append(dst)
	return OS.execute(tool, args, [], true) == 0 and FileAccess.file_exists(dst)
