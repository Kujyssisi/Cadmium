## Cadmium's shared vocabulary: enums, note naming, beat maths.
class_name Cd
extends RefCounted

enum ClipType { PATTERN = 0, AUDIO = 1, AUTOMATION = 2 }
enum Mode { PATTERN = 0, SONG = 1 }
enum Tool { DRAW = 0, SELECT = 1, ERASE = 2, SLICE = 3, MUTE = 4 }
## What a lane does with the value it produces: hold the control at the curve,
## or add the curve to whatever the control is set to.
enum AutoMode { FORCED = 0, ADDITIVE = 1 }

enum AutoTarget { PLUGIN = 0, MIXER_VOL = 1, MIXER_PAN = 2, CHANNEL_VOL = 3, CHANNEL_PAN = 4,
		TEMPO = 5, SEND = 6, SAMPLE_VOL = 7, SAMPLE_PAN = 8, SAMPLE_PITCH = 9,
		SAMPLE_SPEED = 10 }
## The engine's own kinds are 0..10 and are sent by number; GAIN is ours alone,
## added at the end, for the places that hold a level as a multiplier rather
## than as decibels -- a mixer fader, a channel, a clip.
enum ParamKind { FLOAT = 0, DB = 1, HZ = 2, PCT = 3, CHOICE = 4, BOOL = 5, SEMI = 6, MS = 7,
	SEC = 8, BEATS = 9, Q = 10, GAIN = 11 }
enum PlugUI { GENERIC = 0, EQ = 1, COMP = 2, SAMPLER = 3, SOUNDFONT = 4, SYNTH = 5, DRUM = 6,
	ACID = 7, ORGAN = 8, MODAL = 9, VOX = 10, MULTIBAND = 11, TAPE = 12, IMAGER = 13, GATE = 14,
	PRISM = 15, CLIP = 16, DEESS = 17, DUCK = 18, SPAN = 19, TUNER = 20,
	MOD = 21, DELAY = 22, VERB = 23, FILTER = 24, SHAPE = 25, EXCITE = 26,
	GATEDYN = 27, TRANSIENT = 28, LEVEL = 29, VOCODER = 30, PITCH = 31,
	CONV = 32, OSC = 33, LOUD = 34, AMP = 35, WAVETABLE = 36,
	## The plugin describes its own panel and Cadmium builds it out of its own
	## widgets. See ui/widgets/views/declared_view.gd.
	DECLARED = 37,
	## FLARE, which has a panel of its own. See ui/widgets/views/flare_view.gd.
	FLARE = 38 }

## Everything ffmpeg will decode that anyone actually has music in. Kept in one
## place so a file dialog, a drag onto the window and the browser all agree.
const AUDIO_EXTS := [
	"wav", "wave", "flac", "ogg", "oga", "opus", "mp3", "m4a", "mp4", "aac",
	"aif", "aiff", "aifc", "wma", "alac", "wv", "ape", "mka", "caf", "au",
	"snd", "voc", "w64", "rf64", "mpc", "tta", "webm", "3gp", "amr",
]
const AUDIO_FILTER := "*.wav, *.flac, *.ogg, *.opus, *.mp3, *.m4a, *.aac, *.aiff, *.wma, *.wv, *.ape, *.caf, *.w64 ; Audio"
const IMAGE_EXTS := ["png", "jpg", "jpeg", "bmp", "tga", "webp", "svg", "exr", "hdr"]
const IMAGE_FILTER := "*.png, *.jpg, *.jpeg, *.bmp, *.tga, *.webp, *.svg ; Image"


## Minutes and seconds, for durations that are worth reading rather than
## counting: "3:42" rather than "222.4 s".
## How many bars apart the ruler's numbers should be so they stay readable.
##
## Zoomed right out, a number on every bar is a smear. The ladder is the one
## anybody counts in -- 1, 2, 5, 10, 20, 50, 100 -- so the labels stay round
## however far out you go.
static func ruler_step(px_per_beat: float, sig: int, min_px: float = 56.0) -> int:
	var per_bar: float = maxf(0.0001, px_per_beat * float(maxi(1, sig)))
	for step in [1, 2, 5, 10, 20, 50, 100, 200, 500, 1000, 2000, 5000, 10000]:
		if float(step) * per_bar >= min_px:
			return step
	return 20000


## Whether a bar number is one the ruler labels: every `step` bars, and always
## the first, so the count always starts somewhere you recognise.
static func ruler_labels(bar_number: int, step: int) -> bool:
	return bar_number == 1 or bar_number % step == 0


static func format_seconds(sec: float) -> String:
	if sec <= 0.0:
		return "0:00"
	var m := int(sec) / 60
	var s := int(sec) % 60
	return "%d:%02d" % [m, s]


static func is_audio_file(path: String) -> bool:
	return AUDIO_EXTS.has(path.get_extension().to_lower())


const NOTE_NAMES := ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
## Snap divisions, in beats. "Off" is stored as 0.
const SNAPS := {
	"Off": 0.0, "1/1": 4.0, "1/2": 2.0, "1/4": 1.0, "1/8": 0.5,
	"1/16": 0.25, "1/32": 0.125, "1/3": 4.0 / 3.0, "1/6": 2.0 / 3.0, "1/12": 1.0 / 3.0,
}
## Sixteen steps per bar is the channel rack's grid.
const STEP := 0.25

const MAX_PATTERNS := 512
const MAX_CHANNELS := 128


## The theme pads controls for comfortable clicking, which in a dense strip
## costs more room than the controls themselves. This keeps the look and pulls
## the padding in. Safe to call before the control is in the tree.
## Every control that has been given a tightened copy of a theme style, so the
## copies can be made again when the interface's colours change. A duplicated
## stylebox is a snapshot: it keeps the colours it was copied with, and a
## control wearing one stays the old colour until the program is restarted.
static var _compacted: Array[Dictionary] = []


## Re-tightens every control that has been through compact(), from the theme as
## it is now. Called when a colour changes.
static func recompact() -> void:
	var live: Array[Dictionary] = []
	for e in _compacted:
		var c = e.get("control")
		if c == null or not is_instance_valid(c) or not (c as Control).is_inside_tree():
			continue
		live.append(e)
		_apply_compact(c, String(e.type), float(e.pad))
	_compacted = live


static func compact(c: Control, base_type: String = "", pad: float = 3.0) -> void:
	if not c.is_inside_tree():
		c.tree_entered.connect(Cd.compact.bind(c, base_type, pad), CONNECT_ONE_SHOT)
		return
	_compacted.append({"control": c, "type": base_type, "pad": pad})
	_apply_compact(c, base_type, pad)


static func _apply_compact(c: Control, base_type: String, pad: float) -> void:
	var type := base_type
	if type.is_empty():
		type = c.get_class()
	if c is Button and String((c as Button).text).is_empty():
		icon_only(c as Button)
	for state in ["normal", "hover", "pressed", "disabled", "focus"]:
		# The override is taken off first: asking a control for a style it is
		# already overriding gives back the override, and re-tightening that
		# would copy the colours it was made with all over again.
		c.remove_theme_stylebox_override(state)
		var sb: StyleBox = c.get_theme_stylebox(state, type)
		if sb == null:
			continue
		var copy: StyleBox = sb.duplicate()
		copy.content_margin_left = pad
		copy.content_margin_right = pad
		copy.content_margin_top = maxf(1.0, pad - 1.0)
		copy.content_margin_bottom = maxf(1.0, pad - 1.0)
		c.add_theme_stylebox_override(state, copy)


## Centres the glyph on a button that has an icon and no words.
##
## A Button lays out icon, separator, text as one block and centres the block --
## so with no text the icon ends up half a separator to the left of where it
## looks like it should be. On a toolbar full of 28-pixel buttons that reads as
## every icon being slightly wrong.
static func icon_only(b: Button) -> void:
	b.add_theme_constant_override("h_separation", 0)


## A button that is nothing but a glyph: square, tight, and with the icon in the
## middle of it. The theme pads for buttons with words in them, which leaves a
## lone icon adrift in a box wider than it is tall.
static func icon_button(b: Button, box: float = 26.0) -> void:
	icon_only(b)
	b.expand_icon = false
	b.custom_minimum_size = Vector2(box, box)
	b.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	compact(b, "Button", 2.0)


static func note_name(key: int) -> String:
	return "%s%d" % [NOTE_NAMES[key % 12], (key / 12) - 1]


## "F# minor" from a pitch class and a mode flag, for the analyser's readout.
static func key_name(pitch_class: int, minor: bool) -> String:
	if pitch_class < 0:
		return "unknown key"
	return "%s %s" % [NOTE_NAMES[posmod(pitch_class, 12)], "minor" if minor else "major"]


static func is_black_key(key: int) -> bool:
	return [1, 3, 6, 8, 10].has(key % 12)


## "bar.beat.tick" the way every sequencer shows position.
## The tempo divisions the engine offers, in beats. Kept in step with
## SYNC_NAMES / sync_beats() in plugin.h so a panel can say what a synced
## control is actually going to do.
const SYNC_BEATS := [0.0625, 0.125, 0.1875, 0.25, 0.375, 0.5, 0.75,
	1.0, 1.5, 2.0, 3.0, 4.0, 8.0]


static func sync_beats(i: int) -> float:
	return float(SYNC_BEATS[clampi(i, 0, SYNC_BEATS.size() - 1)])


## True when a polygon has enough area to be drawn. A curve that has gone
## completely flat collapses onto its own baseline, and asking the renderer to
## triangulate that is an error rather than an empty shape.
static func has_area(pts: PackedVector2Array) -> bool:
	if pts.size() < 3:
		return false
	var lo := pts[0]
	var hi := pts[0]
	for p in pts:
		lo = lo.min(p)
		hi = hi.max(p)
	return (hi.x - lo.x) > 0.5 and (hi.y - lo.y) > 0.5


## The user's own folder. HOME is not set on Windows, where the same thing is
## called USERPROFILE, and code that assumes one of them works on one platform.
static func home_dir() -> String:
	var h := OS.get_environment("HOME")
	if h.is_empty():
		h = OS.get_environment("USERPROFILE")
	if h.is_empty():
		h = OS.get_system_dir(OS.SYSTEM_DIR_DOCUMENTS).get_base_dir()
	return h


static func format_beats(beat: float, sig: int = 4) -> String:
	var b := maxf(0.0, beat)
	var bar := int(b / float(sig)) + 1
	var beat_in := int(fmod(b, float(sig))) + 1
	var tick := int(fmod(b, 1.0) * 96.0)
	return "%d.%d.%02d" % [bar, beat_in, tick]


static func format_time(beat: float, bpm: float) -> String:
	var secs := beat * 60.0 / maxf(1.0, bpm)
	return "%d:%05.2f" % [int(secs / 60.0), fmod(secs, 60.0)]


static func snap_beat(beat: float, snap: float) -> float:
	if snap <= 0.0:
		return beat
	return roundf(beat / snap) * snap


static func floor_snap(beat: float, snap: float) -> float:
	if snap <= 0.0:
		return beat
	return floorf(beat / snap) * snap


## Parameter formatting, shared by every knob, list row and tooltip.
static func format_param(value: float, kind: int, choices: String = "") -> String:
	match kind:
		ParamKind.DB:
			return "-inf dB" if value <= -59.9 else "%+.1f dB" % value
		ParamKind.GAIN:
			return "-inf dB" if value <= 0.001 else "%+.1f dB" % gain_to_db(value)
		ParamKind.HZ:
			if value >= 1000.0:
				return "%.2f kHz" % (value / 1000.0)
			return "%.0f Hz" % value if value >= 100.0 else "%.1f Hz" % value
		ParamKind.PCT:
			return "%.0f%%" % (value * 100.0)
		ParamKind.CHOICE:
			var parts := choices.split("|")
			var i := clampi(int(round(value)), 0, maxi(0, parts.size() - 1))
			return parts[i] if parts.size() > 0 else str(i)
		ParamKind.BOOL:
			return "On" if value > 0.5 else "Off"
		ParamKind.SEMI:
			return "%+d" % int(round(value)) if value != 0.0 else "0"
		ParamKind.MS:
			return "%.2f ms" % value if value < 10.0 else "%.0f ms" % value
		ParamKind.SEC:
			if value < 1.0:
				return "%.0f ms" % (value * 1000.0)
			return "%.2f s" % value
		ParamKind.Q:
			return "%.2f" % value
		_:
			if absf(value) >= 100.0:
				return "%.0f" % value
			return "%.2f" % value if absf(value) < 10.0 else "%.1f" % value


## Knobs travel linearly in 0..1; skew < 1 gives frequency-style controls their
## resolution at the low end.
static func to_norm(value: float, lo: float, hi: float, skew: float) -> float:
	if hi <= lo:
		return 0.0
	var t := clampf((value - lo) / (hi - lo), 0.0, 1.0)
	return pow(t, skew) if skew != 1.0 else t


static func from_norm(norm: float, lo: float, hi: float, skew: float) -> float:
	var t := clampf(norm, 0.0, 1.0)
	if skew != 1.0:
		t = pow(t, 1.0 / skew)
	return lo + (hi - lo) * t


static func db_to_gain(db: float) -> float:
	return 0.0 if db <= -60.0 else pow(10.0, db * 0.05)


static func gain_to_db(g: float) -> float:
	return -60.0 if g <= 0.001 else 20.0 * (log(g) / log(10.0))


## Mixer faders are 0..1 travel over -60..+6 dB with the useful range spread out.
static func fader_to_gain(t: float) -> float:
	if t <= 0.0:
		return 0.0
	return db_to_gain(lerpf(-60.0, 6.0, pow(clampf(t, 0.0, 1.0), 0.45)))


static func gain_to_fader(g: float) -> float:
	if g <= 0.0:
		return 0.0
	return pow(clampf((gain_to_db(g) + 60.0) / 66.0, 0.0, 1.0), 1.0 / 0.45)


## Puts a window of ours in the middle of the one it came from, and inside the
## screen. A panel is sized in scaled units, so at a large interface scale it
## can come out bigger than the display it is opening on -- and a panel opening
## mostly past the edge of the screen reads as one that never opened at all.
static func place_window(win: Window, host: Node) -> void:
	if win == null or host == null or not host.is_inside_tree():
		return
	var root := host.get_tree().root
	# A window drawn inside the main one -- embedded subwindows, or a platform
	# with no subwindows at all -- is positioned in that window's coordinates,
	# where the desktop's screens mean nothing. Godot has already centred it.
	if root.gui_embed_subwindows or not DisplayServer.has_feature(DisplayServer.FEATURE_SUBWINDOWS):
		return
	var main := root.get_window()
	var screen := DisplayServer.window_get_current_screen(
			main.get_window_id() if main != null else 0)
	var usable := DisplayServer.screen_get_usable_rect(screen)
	var fits := Vector2i(mini(win.size.x, usable.size.x - 16), mini(win.size.y, usable.size.y - 48))
	if fits != win.size:
		win.size = fits
	var at := usable.position + (usable.size - win.size) / 2
	if main != null:
		at = main.position + (Vector2i(main.size) - win.size) / 2
	at.x = clampi(at.x, usable.position.x, usable.position.x + usable.size.x - win.size.x)
	at.y = clampi(at.y, usable.position.y, usable.position.y + usable.size.y - win.size.y)
	win.position = at
	# In front, said out loud. A window opened from a menu that is closing at
	# the same moment can be left behind the main window by the desktop, and a
	# panel behind a full-screen editor is a menu entry that did nothing.
	win.move_to_foreground()
	win.grab_focus()
