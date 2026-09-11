Cadmium — digital audio workstation
===================================

Run Cadmium.exe. Keep all three files in the same folder:

  Cadmium.exe                                     the application
  Cadmium.pck                                     its data
  libcadmium.windows.template_release.x86_64.dll  the audio engine

VST3
----
Plugins are picked up from the usual places, including vendor folders inside
them (…\VST3\Some Company\Their Plugin.vst3):

  C:\Program Files\Common Files\VST3
  C:\Program Files (x86)\Common Files\VST3
  C:\Program Files\VST3          C:\Program Files (x86)\VST3
  C:\Program Files\VSTPlugins    C:\Program Files (x86)\VSTPlugins
  C:\Program Files\Steinberg\VST3 and \VSTPlugins  (and the x86 pair)
  %LOCALAPPDATA%\Programs\Common\VST3      %LOCALAPPDATA%\VST3
  %APPDATA%\VST3                 C:\VST3          C:\VSTPlugins

...plus whatever folder another host's installer recorded in the registry
(HKLM and HKCU, SOFTWARE\VST3 and SOFTWARE\VST), which is where plugins put
somewhere of your own choosing usually turn up.

Company folders are looked inside, eight levels deep, and a bundle that is a
single .vst3 file rather than a folder is loaded too -- as is one written
.VST3 or .Vst3, which some installers do. Between them that covers how
Kilohearts, FabFilter, Spectrasonics and the rest lay things out.

Add more folders in Preferences > Folders, then press Rescan. VST3_PATH is
read as well; separate folders in it with semicolons.

The first run scans on its own. After that, only bundles whose files have
changed are opened again, so a rescan is quick. A plugin that will not load is
listed in the browser under "Would not load" with the reason; click it to see
the full path. One that crashes while being opened is remembered and skipped
next time, so a single bad plugin cannot stop the rest being found.

A note played by hand is given an id of its own and the release names that
same id, which is what a plugin needs to stop it: several instruments -- Serum
2 among them -- stop only the note whose id they recognise, and a host that
forgets it leaves the note playing for ever. A key held down when a plugin's
own window takes the keyboard is let go of rather than left sounding, since
its release goes to the plugin and never comes back to Cadmium.

A plugin is allowed to put its processing and its interface in one object --
FabFilter and many others do -- or to keep them in two. Cadmium asks the
plugin which it is rather than assuming; getting that wrong builds a second,
disconnected copy of the plugin, and then nothing you touch in its own window
affects what you hear. Controls moved inside a plugin's own interface are
passed to its audio side on the next block, and two changes to the same
control inside one block no longer leave the plugin a choice about which one
to believe.

A plugin's own interface takes a moment to build itself. Until it has, the
window shows a spinner rather than the half-drawn grey rectangle that reads as
a broken plugin, and a plugin that produces nothing at all is attached again
from scratch, up to three times -- which is what opening the window twice used
to do by hand.

Clicking a plugin's name in the channel rack or the mixer opens its window;
clicking it again puts it away.

A control the plugin says has steps -- a two-way switch, a five-way filter
type -- snaps to them in Cadmium's own panel. Drawn as a smooth knob it looked
like a control that did nothing: you would turn it a quarter of the way and
the plugin would still be on the same setting.

A plugin's own interface is shown inside its Cadmium window. The computer
keyboard plays notes while a plugin's window is in front, including Space for
play and stop, and a plugin that grabs the keyboard when you click it has it
handed back -- but only once the pointer has left the plugin's own canvas, so
its right-click menus stay open and its text boxes can be typed into for as
long as you are working in there. "Typing" in the title strip gives the
keyboard to the plugin outright, for when you would rather it stayed there.

Audio files
-----------
.wav loads on its own. Anything else — mp3, flac, m4a, ogg — needs ffmpeg.
Either put ffmpeg on PATH, or drop ffmpeg.exe and ffprobe.exe next to
Cadmium.exe (an ffmpeg\bin folder beside it works too).

SoundFonts
----------
The .sf2 player lists what it finds in Documents\SoundFonts, in a soundfonts
folder beside Cadmium.exe, and in C:\soundfonts. Any .sf2 can also be loaded
by hand, or dragged onto the player.

MIDI keyboards are opened automatically (Windows multimedia MIDI).

Samplers
--------
Every sample in the song has a sampler of its own, the way FL gives an audio
clip a channel. Click one in the picker's Audio tab, or right-click it and
choose Sampler, and you get: what to do to the file once -- remove DC offset,
normalise, reverse, invert, swap or fade the stereo, trim the silence off the
ends, fade it in and out, take part of it -- and how to stretch it. It draws
what you will actually hear, so reversing a sample turns its picture round.

Stretching has four modes. Resample moves speed and pitch together, the way a
record plays faster. Stretch changes the length and leaves the pitch. Pitch
changes the pitch and leaves the length. Off plays it as it is.

The sampler you load as an instrument and play from the piano roll has all of
that as well, plus what only makes sense for something being played: the
region and loop points, the envelope, the filter and the polyphony. A sample
sitting on the timeline has no envelope, exactly as in FL.

Replace... plays a different file through the same clips, keeping everything
the sample is set to.

Changing a sample changes everything that shows it. The pictures on the
timeline and in the picker are redrawn -- turning a sample down draws it
smaller, since that is what you will hear -- and stretching a sample stretches
its clips on the timeline by the same amount, so a clip is always as long as
what it plays.

It is heard straight away as well: turning these knobs while the song is
playing does not stop the sample and does not need the transport stopped and
started again. Whatever is sounding carries on from the same point of the
sample, with the change in it. Space plays and pauses with the sampler in
front, the same as everywhere else.

The chooser at the top of the piano roll points it at anything in the song --
any instrument in the rack, or any sample. Picking a sample gives it a sampler
channel to be played from.

Arrangement
-----------
A song starts with twelve tracks and takes as many as you want: the "+ track"
strip under the last header adds one, and the header's right-click menu adds
five at a time or takes the last one away along with whatever is on it.

Down the left of the arrangement is everything the song is made of: its
patterns, the audio files it uses, and its automation clips, on three tabs.
Each row draws what it holds -- the notes of a pattern, the shape of an audio
file, the curve of an automation lane -- so six patterns called "Pattern 4"
are still telling apart.
Click a pattern to make it the one the piano roll is editing; drag any of them
onto a track to put it down; right-click for rename, duplicate and delete. The
divider between the list and the arrangement can be dragged.

Clicking picks up. Whatever you last clicked -- a row in the list, or a clip
already on the timeline -- is what drawing on an empty track puts down, so a
second copy of a sample or an automation clip never means going to find it
again. A clip is picked up as it is set: its length, how far into the file it
starts, its level and its pitch all come with it, so drawing gives you that
clip rather than a default one. Clicking a pattern clip also makes its pattern
the one the piano roll is editing.

Piano roll
----------
Click and drag on empty grid draws a note and carries it -- any direction,
pitch and time both. The right-hand edge of a note resizes it. Ctrl+B copies
the selection to directly after it, and holding the shortcut keeps copying.

The playhead is drawn where the pattern is being played. A pattern is edited
on its own timeline, and in song mode it is played by its clips -- so a clip
at bar thirty-three plays the pattern's first bar there, and that is where the
playhead is shown. Nothing of the pattern playing means no playhead, rather
than one a hundred beats off to the side.

The corner above the keyboard picks the key the piece is in: a root note and a
scale. The rows that belong to it are lit, the root more than the rest, and
everything else is dimmed, so a run drawn by ear lands where it should.

Ctrl+L closes a run up: every selected note is stretched, or trimmed, to end
exactly where the next one starts. Nothing selected does the whole pattern,
and the last note keeps the length it has. Notes that end exactly where the
next one begins both play, on the same pitch as well as on different ones:
the end of a note is always sent before the start of the next one landing on
the same instant, which is what stops a plugin cutting the note it has just
been given.

The lane along the bottom edits one property of each note; the button at its
left says which -- velocity, pan or fine pitch. Left button sets it, right
button puts it back to the default.

Automation clips are edited on the clip itself: click the curve to add a point,
drag to move it, right-click to remove it. The clip's title strip still picks
the clip up, and so do its two ends. While the song plays, a light mark rides
the curve where the lane stands at that moment.

Double-click one -- or click its row in the picker's Auto tab -- and the lane
opens in an editor of its own, with room to draw in. Bars across the top, the
lane's range up the side, and the same gestures as on the clip: click to add a
point, drag to move it, right-click to remove it, shift-drag a segment to bend
it, double-click a point to straighten what follows it. The wheel gets closer,
shift and the wheel moves sideways, because a lane is as long as the clips
that play it and the shape in it is usually four bars.

Along the top: On, which leaves the control alone when it is off; MIN and MAX,
the ends of the range the curve works over; and the mode.

  Forced     holds the control at the curve, which is what a lane has
             always done.
  Additive   adds the curve to whatever the control was set to by hand, so
             the same shape can be dropped onto a fader without throwing
             away the level under it.

The targets are listed at the bottom, in the controls' own terms rather than
in whatever the lane was called, each with a button that opens it. "Drive
something else..." adds another: one lane can hold a filter, a delay's mix and
a fader together, which is one shape to draw and one clip to move rather than
three of each. Additive gives each of them its own starting point, so the same
shape rides on top of three different settings. The lane's own target is the
first in the list and stays; the rest can be taken off with the x beside them.

Clips resize from either end. The far end trims the tail; the near end trims
the head and takes what is played with it, so the audio, the notes or the
curve under the part still showing stays where it was.

Scores
------
A pattern is worth keeping on its own, separately from the song it was written
for: a riff, a drum part, a chord progression. The piano roll's own menu, at
the top left of it, is where that lives.

File > Save score as writes one as a .cdscore, in Documents\Cadmium\Scores.
It is Cadmium's own format rather than MIDI because MIDI cannot carry what the
piano roll actually edits: a note's pan and its fine pitch, which channel of
the rack it belongs to, and what instrument that channel was. Open a score into
an empty project and it brings its channels with it, playing the instruments
they were written for; open one into a project that already has channels of
those names and it lands on those instead of making a second set.

MIDI is the other half of the same menu, and it goes into the pattern you are
editing rather than building a project around itself. A file with one part
lands on the channel the piano roll is pointing at; a file with several gets a
channel each, matched by name. The tempo is reported and not applied -- note
positions are in beats, so it makes no difference to where anything lands.
Dropping a .mid on the window follows the same rule: into the pattern when the
piano roll is open, into the project otherwise. File > Import MIDI file on the
main menu is the other one, and builds a pattern, a channel per part and a clip
on the timeline.

There is no MIDI clipboard on a desktop, so Copy to MIDI clipboard puts a whole
MIDI file on the ordinary text clipboard as base64 behind a marker line.
Another Cadmium pastes it straight back; anything else at least gets text it
can keep.

Export as score sheet writes the part out to read rather than to play: every
note by bar, beat, name, length and velocity. A listing, not engraved notation.

The rest of the menu is what the piano roll can do to what is in it -- Edit,
Tools (legato, reverse, flip pitch, strum, arpeggiate, randomise velocity,
humanise), Select, Snap, Zoom, View, and the target channel and lane control.

Metronome
---------
Ctrl+M. The click is a pair of recordings: an accented one on the first beat of
a bar and another on the rest. It plays through the master, so the master fader
sets how loud it is against the music.

Colours
-------
Preferences > Appearance has two: the primary, which is everything Cadmium
picks out -- faders, selections, the playhead marker, the icons' accent -- and
the secondary, which is everything else: the panels, the wells, the bevels,
the text and the neutral inks in the icons. The secondary keeps each shade's
relative brightness and gives them all the hue and saturation you pick, so a
grey stays grey and a blue turns the whole interface blue.

Output
------
The master has a ceiling on it, on by default at -1 dB, under
Preferences > General. It does nothing at all until something asks for more
than the ceiling and then holds it there, so a runaway feedback loop or a
synth with its gain wound up cannot arrive at full scale. It applies to what
you hear and to what you export, and it can be turned off or moved between
-0.1 dB and -12 dB.

Mixer
-----
As many tracks as you want: the + at the end of the strips adds one, the -
takes the last one away when nothing is using it.

A control that is automated but cannot follow its lane -- the sampler's
stretching pair, which are automated as playback speed rather than as the
number written on them -- shows where the lane stands with a light mark riding
its rim instead, so it can be watched moving while the knob goes on saying
what it is set to.

An automated control says so. A knob or a fader with a lane driving it is
drawn in a lighter shade of the accent, with a faint halo round the knob's
rim, so a rack of them tells you at a glance which ones are being held by
something else. While the song plays they move with what is driving them --
mixer faders, pan knobs, channel levels, a plugin's own parameters and a
sample's level and position. Only what is on screen is updated, thirty times a
second, and nothing at all happens when the song is stopped or when the
project has no automation in it.

A sampler can be automated too. Right-click a sample's VOL, PAN, PITCH or MUL
knob for "Create automation clip", or take any of them from the arrangement's
automation menu, where every sample in the song has its own submenu. Level and
position move the sample as it is. Pitch and the stretch multiplier are
automated as playback speed -- faster as it goes up, the way a record does --
because the stretching modes are worked into the audio itself and cannot be
redone a hundred times a second. The stretching you set by hand is unchanged
by any of this.

Everything on a strip can be automated. Right-click its fader or its pan knob
for "Create automation clip", or take the strip menu's Automate for the whole
list: volume, pan, every send that goes anywhere, and every parameter of every
effect on it. An effect's own slot menu has the same list. The clip lands on
the first arrangement track with room for it, and a new one is added if every
track is busy. The playlist's own automation menu carries the same, strip by
strip.

Under the strips is the routing, drawn the way FL draws it. Every strip has a
socket; the selected strip's audio is followed by a line along the band and up
into each strip it feeds, with an arrow pointing the way it goes. Click a
socket to send the selected strip into that one, click it again to stop. The
first strip you route into is the main output and the rest are sends, which
means a strip can feed as many others as you like.

Exporting
---------
File > Export Audio writes WAV (16, 24 or 32-bit float), and -- when ffmpeg is
around -- FLAC, AIFF, MP3 at 320 or V0, OGG Vorbis, Opus and AAC. The mix is
always rendered as a float WAV first and encoded from that, so nothing is
rounded twice.

Range is the whole song, the current pattern, or whatever clips are selected.

Tail set to Automatic keeps rendering past the end until the sound has
actually decayed, instead of guessing a number of seconds.

Seamless folds that tail back onto the beginning and cuts the file to exactly
the range you asked for, so the file loops into itself with nothing to hear at
the join -- the reverb from the end is already ringing when it starts again.

Last tweaked
------------
The knob at the right of the toolbar holds whichever control you moved last,
wherever it was: one of Cadmium's own, a mixer fader, or a knob inside a hosted
plugin's own interface. Drag it to nudge that control from anywhere.
Right-click it for "Create automation clip", for clips for everything you have
touched recently at once, and for the list of those controls.

Add-ons
-------
Tools > Add-ons lists what is installed and switches each one on or off; what
an add-on offers appears at the end of the Tools menu. An add-on is a folder
with an addon.gd inside, dropped into the add-ons folder yourself (the button
on that page opens it). Cadmium ships none of its own.

Preferences
-----------
Every page scrolls and every row is lined up on one column, so a tall page at
a large interface scale can be reached rather than running off the bottom of
the window, and the drop-downs share an edge instead of starting wherever
their longest entry happened to put them. Dialogs open inside the screen: one
sized in scaled units can be bigger than the display it opens on.

Crash reports
-------------
Help > Crash Reports lists what Cadmium left behind the last time it stopped
unexpectedly: when it was, what it was doing, whose code it was in, which
thread it was on, how it stopped, and where in the program it was. Every call
into a plugin says what it is -- opening it, ticking its interface, asking it
for its state, processing audio through it -- and names the plugin, so a report
says which plugin and which call rather than "something went wrong". They are
written by the engine as it goes down, so they survive the kind of stop that
never reaches any code that could write a file the usual way. The window has
Copy, for sending one to somebody, and Open Folder.

If the last run ended that way, Cadmium says so on the next start and names
what it was doing at the time, rather than coming back as though nothing had
happened.

Plugins that will not open
--------------------------
A plugin is opened for the first time in a process of its own: created,
started and taken down again, which is the same thing that happens when it
goes on a channel. A plugin that falls over on the way up takes that process
with it and nothing else -- Cadmium notes which one it was, remembers it, and
picks up the scan where it left off. The drop-down says how many would not
load, and Preferences > Folders is where the scan looks.

What was learned there is remembered afterwards: a plugin that has taken a
process down once is refused rather than tried again, so a project full of it
opens without it and says so, instead of not opening at all.

That is why a big library instrument that used to take the program down on
startup no longer can. What it cannot do is make a plugin that crashes work:
one that will not open is reported rather than offered.

An instrument with more than one output -- Omnisphere's parts, a drum machine's
separate outs -- is given real memory for every one of them, whether Cadmium is
listening to it or not. Only the first is asked for and only the first is
heard, but a plugin is free to ignore being told that and write to the rest,
and one that does would otherwise be writing into whatever happened to be
there. The arrangement it settled on is read back rather than assumed, too.

Windows plugins are loaded with COM going, as a single-threaded apartment.
Licensing, embedded browsers and the system's own dialogs are all COM, and a
big commercial instrument that assumes it and finds it missing falls over
inside its own code on the way up, where nothing here can help it.

A plugin installed somewhere other than the VST3 folder -- on a second drive,
reached through a link left behind by its installer, which is how Roland Cloud
and most big libraries do it -- is loaded by where the file really is rather
than by the name it was reached through. The folder a plugin was loaded from
is the first place Windows looks for the rest of what it needs, so a plugin
found through a link used to send it looking beside the link, where none of
its own libraries are.

Every plugin already in the library is opened once, in a process of its own,
the first time this version starts: the earlier scan only read what a plugin
said about itself and never opened it, so anything that falls over on the way
up was written down as perfectly fine. It takes a while once and never again.

A plugin's own interface is a window of Cadmium's own, kept exactly over the
space it would have filled inside Cadmium's. Godot draws with Vulkan, which
paints over the whole of a window sixty times a second and takes no notice of
anything else living inside it, so a plugin interface put in there is painted
over as fast as it can draw -- which is what a plugin whose interface is
"there, but mostly not drawn" is. Setting CADMIUM_PLUGIN_WINDOW=child puts it
back the old way, for a machine that disagrees.

Two plugins that share a runtime
--------------------------------
Plugins from one maker usually share a single library -- Kilohearts' HeartCore,
and most of the big houses have one -- and one of them already started up in a
process can bring the next one down with it, which is not the second plugin's
fault and must not be held against it. A plugin that stops the scan therefore
gets one more go with nothing else in the process, and is only written off if
it falls over on its own as well.

A scan that stops now says so and moves on rather than starting the same list
again: the report says which plugin, the process ends there and then instead of
being handed to Windows Error Reporting to sit about in Task Manager, and the
plugin after it is the next one tried.

When a plugin interface comes up wrong
--------------------------------------
Every number that decides where a plugin's interface ends up -- what the
display is scaled by, what the plugin was told, how big it says it is, how big
the window it got actually is, and the size of the canvas it made inside it --
is written to plugin-windows.txt, in the same folder as the crash reports
(Help > Crash Reports > Open Folder). An interface at the wrong scale is nearly
always two of those disagreeing, and none of them can be seen in a screenshot.

The keyboard, and the plugin that took it
-----------------------------------------
A plugin's own interface takes the keyboard the moment it is clicked -- that is
how you type into its preset search -- and from then on every key goes there.
On Linux, Cadmium takes it back as soon as you are somewhere else in the
program, so Space, the transport and the typing keys carry on working. On
Windows it does not, and that is deliberate: keys there go to whatever window
is in front, so a plugin you are not using is not getting them anyway, and the
plugin's canvas is a window of its own -- taking the focus off it would be
taking it away while you are using it, which ends a drag the moment it starts.

A note played on the typing keyboard is let go of too. It has to be, because
the key-up went to the plugin: Godot was never told the key came up and goes on
believing it is held, so asking Godot is no use -- it is the thing that is
wrong. The keyboard itself is asked instead, and the note stops once nothing at
all is down. That question is only asked while a key is being held, so it costs
nothing the rest of the time, and because it can only fire when the whole
keyboard is idle it can never cut off a key you are still holding.


Marking a stretch of the timeline
---------------------------------
Hold Shift and drag along the playlist's ruler to mark a stretch out. What is
marked is what the transport loops over, and it is tinted across the
arrangement so there is no guessing where it starts and ends. Double-click the
ruler to take it away again, which puts the loop back over the whole song.

The export window gains "Marked region" to go with it, and offers it by default
when there is one -- the stretch you marked is nearly always the stretch you
came to export. The range row now says how long what you are about to write
will be, in bars and in minutes and seconds, before you start it rather than
after. A mark is saved with the project.



Sending a sample to a mixer track
---------------------------------
The sampler window names the mixer track a sample plays through, next to the
file it is playing. Until now a sample went wherever its clip's own playlist
track pointed, so the only way to put a filter on one was to move the clip --
and two clips of the same sample on different tracks came out of two different
places. Naming the track here gives a sample an effect chain of its own,
wherever its clips happen to sit.

"As the track says" is the default and is what everything did before. Changing
it costs nothing and takes effect on what is already sounding: it decides where
the sound goes, not what the sound is, so the sample is not rebuilt for it.

When Cadmium refuses to open a plugin
-------------------------------------
A plugin that takes Cadmium down while it is being opened is remembered and not
tried again -- but only on the strength of a crash report written at about that
moment. Cadmium being killed from a task manager, force-quit, or taken down
with the machine leaves the same trace behind and is nobody's fault; blaming
the plugin that happened to be loading was refusing working synths for ever.

And it now says so. A plugin Cadmium is refusing opens its window with the
reason written in it and a button to give it another go, rather than an empty
panel with no name and no controls on it.

One copy of Cadmium
-------------------
Checking a plugin means starting a second copy of Cadmium to open it in. A copy
started for that job never starts one of its own accord, and the one whose job
is checking never starts another at all. Without that rule each copy started
more copies: a machine full of Cadmium until it ran out of memory.

The display's scale is handed to a plugin before anything asks it how big it
is, because asking is what makes it build its view: one built without knowing
works its size out for a hundred percent and then draws for a hundred and
fifty, which is an interface at the wrong scale with most of it off the edge.
Whatever it says it is once it has actually been given its window is taken as
the answer, too, since several only work it out at that point.

Transposing
-----------
Edit > Transpose Patterns... moves whole patterns up or down by however many
semitones you type -- -1, +7, anything up to four octaves either way. It works
on the patterns of whatever is selected in the arrangement, or on the one being
edited when nothing is; the picker's own right-click menu has it too. Notes
that would fall off either end of the keyboard stay where they are rather than
piling up on the last key.

Reporting a problem
-------------------
Help > Start Performance Log records frame times, audio load, voice counts and
what the project is running, four times a second. Choosing it again stops the
recording, writes a .json file and opens the folder it went to. Send that file
along with the report -- it says what the machine is and what it was doing.

The typing keyboard plays by where the keys are rather than by the letters on
them, so the bottom row plays the white notes on QWERTZ, AZERTY and the rest.
Preferences > General has a switch for anyone who would rather have the
letters, and names the layout the system reports.

The marker plays from where you put it and comes back there when you stop;
stopping a second time takes it to the beginning. Drawing a note while the
song is playing puts the note in without playing it at you as well.

Keyboard: Space play/pause, Enter stop, L pattern/song, Ctrl+L legato,
Ctrl+Shift+L loop, F5 playlist,
F6 channel rack, F7 piano roll, F9 mixer, Ctrl+Z undo, Ctrl+S save,
Ctrl+E export, Ctrl+C/X/V clipboard, Ctrl+Q quantize, 1-4 tools.


Sending a project to somebody else
----------------------------------
A .cadmium file records where every plugin and every sample was on the machine
that saved it, and an absolute path is a fact about one computer. Opening the
project somewhere else -- especially on another operating system -- has to find
all of it again, and Cadmium does that rather than quietly loading nothing.

Hosted plugins are found by their VST3 class id, which is the same on every
platform for the same plugin. A project written on Linux with Vital on it opens
on Windows with the Windows copy of Vital, wherever that machine keeps it. The
recorded path is only a hint and is tried first because it is usually right.

Samples are looked for where the project says, then beside the project file,
then in Samples, Audio or Content folders next to it, then under this machine's
home instead of the one that saved it. The same goes for a soundfont, an
impulse response and Prism's picture. So the easy way to send a project is to
put the .cadmium file and its samples in one folder and send the folder.

Anything that still cannot be found is said so when the project opens, with a
list, rather than being passed over in silence. A sample that is missing keeps
its place in the numbering and makes no sound: dropping it would renumber every
sample after it and the clips would then play the wrong audio, which is worse
than silence and much harder to notice.

What does not travel is a plugin nobody has installed. Cadmium will tell you
which ones; install them and reopen.


Licensing
---------
Cadmium is free software under the GNU General Public License, version 3 or
later. LICENSE.txt is the full text and COPYRIGHT the notice. THIRD-PARTY-NOTICES.md lists everything
else that is in this folder and what it is licensed under, and
THIRD-PARTY-GODOT.txt carries the notices for the Godot Engine and the
libraries it bundles. All three ship with every copy.
