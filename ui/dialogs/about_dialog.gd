extends Window
## About, and the keyboard shortcut sheet. The layout is about_dialog.tscn;
## which of the two documents is shown is decided here.

var _help := false


func configure(args: Dictionary) -> void:
	_help = bool(args.get("help", false))


func _ready() -> void:
	title = "Keyboard Shortcuts" if _help else "About Cadmium"
	# A window is sized in pixels but laid out in scaled units.
	var sc := Settings.ui_scale()
	content_scale_factor = sc
	size = Vector2i(int(560.0 * sc), int(500.0 * sc))
	close_requested.connect(queue_free)
	($Root/Col/Buttons/Close as Button).pressed.connect(queue_free)
	($Root/Col/Text as RichTextLabel).text = SHORTCUTS if _help else ABOUT


const SHORTCUTS := """[b]Transport[/b]
Space  play / pause      Ctrl+Space  play from start
Enter  stop (again returns to the start)
L  switch between pattern and song
Esc  all notes off

[b]Views[/b]
F5 playlist    F6 channel rack    F7 piano roll    F9 mixer
F11  full screen

[b]Editing[/b]
Ctrl+Z / Ctrl+Shift+Z  undo / redo
Ctrl+N / Ctrl+O / Ctrl+S  new / open / save
Ctrl+E  export audio
Delete  remove the selection
Ctrl+A  select every note on this channel
Ctrl+D  duplicate the selected notes
Arrow keys  nudge and transpose (Ctrl for octaves)

[b]Piano roll and playlist[/b]
Left drag  draw, move, resize     Right drag  erase
Shift+drag  rubber-band select
Ctrl+wheel  zoom in time    Alt+wheel  zoom the keys
Shift+wheel  scroll sideways

[b]Playing[/b]
Z S X D C V G B H N J M  lower octave      Q 2 W 3 E R 5 T 6 Y 7 U  upper
[  ]  octave down / up
"""


const ABOUT := """[b]Cadmium[/b] is a pattern-based digital audio workstation.

Channel rack, piano roll, playlist, mixer with sends and sidechains, and a set of instruments and effects written for it: [b]Ember[/b] (subtractive), [b]Kilo FM[/b], [b]Vector[/b] (wavetable), [b]Pulse[/b] (drums), [b]Pluck[/b], a sampler and a SoundFont player, plus EQ, dynamics, saturation, modulation, delay, reverb, convolution, pitch and vocoding.

VST3 plugins are hosted for both instruments and effects.

The audio engine is C++ running on the audio thread; the interface is Godot. Nothing is sample-rate-locked and every render is done offline, so an export sounds exactly like the mix.

By [b]cfinite[/b].  Copyright (c) 2026 cfinite. See LICENSE.txt and THIRD-PARTY-NOTICES.md beside the application.

[i]Linux and Windows. Interface styled after Source 2 Hammer, primary colour cadmium red.[/i]"""
