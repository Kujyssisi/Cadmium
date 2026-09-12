# Contributing to Cadmium

Cadmium is written by one person, in the open, under the GPL. Bug reports are
welcome, changes are welcome, and both get read. This file says what to put in
one and what happens to it afterwards.


## Reporting a bug

**[Open an issue](https://github.com/Kujyssisi/Cadmium/issues/new/choose).**
There are three forms — a bug, a plugin that will not work, and a feature — and
the fields on them are the things that would otherwise have to be asked for in
a second message.

Two of them are worth more than the rest:

- **What Cadmium left behind when it stopped.** A host that loads other
  people's code cannot be crash-proof — a plugin that writes over memory takes
  the process with it — so Cadmium writes down what it was doing at the time.
  **Help ▸ Crash Reports…** lists those reports and copies one to the clipboard.
  The ones named `cadmium-scan-…` come from the separate process that opens
  plugins to see whether they can be opened; a crash there is contained on
  purpose and still says which plugin did it.
- **The steps, from a fresh start.** "It glitches sometimes" cannot be fixed.
  "New project, drop a WAV on track 1, drag its right edge past bar 64" can be,
  usually the same day.

The log is at `~/.local/share/godot/app_userdata/Cadmium/logs/godot.log`, and at
`%APPDATA%\Godot\app_userdata\Cadmium\logs\` on Windows.

If a project file shows it, attach the `.cadmium`. It is small — it records
paths to samples and plugins rather than carrying them — so scrub it first if
those paths say more about your machine than you want them to.

**Security bugs** — something that lets a project file or a plugin do damage on
the machine that opens it — go to the repository owner privately rather than
into a public issue.


## Sending a change

You do not need permission and you do not need to ask first. Small fixes can
just arrive.

    # fork it on GitHub, then
    git clone https://github.com/<you>/Cadmium.git
    cd Cadmium
    git submodule update --init --recursive     # native/godot-cpp
    git checkout -b what-it-does

    cd native && scons platform=linux target=template_release \
        custom_api_file=$PWD/extension_api.json -j$(nproc)

    xvfb-run -a -s "-screen 0 1600x900x24" godot-beta --path . \
        --rendering-driver opengl3 -- --cd-selftest=/tmp/cadmium-selftest

`--cd-selftest` renders and measures every instrument and effect, loads and
round-trips VST3 state, and exercises the sampler, projects, MIDI, undo and
automation. It prints a pass/fail tally. **Run it before you open a pull
request, and put the tally in the description** — a change that breaks it is
not necessarily wrong, but it needs saying why.

Then push the branch to your fork and open a pull request against `main`. One
change per pull request; a fix and a refactor in the same branch take four
times as long to review as they do apart.

If you are about to spend a weekend on something large, open an issue first and
say what you are planning. Not for approval — so you do not find out afterwards
that it was already half-built on a branch here, or that it cannot work the way
you intend for a reason that is not visible from outside.


## What happens to it

Every pull request gets read. There are three ways one ends:

- **It goes in.** If it is right, it is merged and you are in the history.
- **It comes back with questions.** Usually about a case the change does not
  cover, or about the audio thread. That is a conversation, not a rejection.
- **The idea goes in but the code does not.** Sometimes a change is pointing at
  a real problem and the fix belongs somewhere else entirely, or has to be
  written against parts of the engine that are not in the diff. When that
  happens it gets written here instead, and the commit credits you and links
  the pull request. That is not a snub — it is often faster than three rounds
  of review, and the bug still gets fixed.

Review is one person's, so it is not instant. A pull request that has gone
quiet for a week has not been forgotten; ping it.


## House style

The rule is: **new code should read like the code around it.** Beyond that:

- **Match the file you are in.** Tabs, typed GDScript, `_leading_underscore`
  for what is private, `##` doc comments at the top of a class saying what it is
  *for*.
- **Comments say why, not what.** The repository is full of comments explaining
  a decision that looks wrong until you know what it is avoiding. Those are the
  valuable ones. `# increment i` is not.
- **The interface is scene files.** Panels, dialogs and repeated items are
  `.tscn`, and the script beside one wires it up rather than building it. Build
  controls in code only for the three reasons the README lists: what the plugin
  decides, what the project decides, and what is drawn rather than assembled.
- **The audio thread allocates nothing, locks nothing and blocks on nothing.**
  It takes a `try_lock` and outputs one silent block if it fails. Loading a
  plugin or reading a 30 MB soundfont happens outside the lock, and only the
  pointer swap happens inside it. A change that reads a file, allocates, or
  waits inside `process()` will be sent back however well it works on your
  machine.
- **Rendering is the playback path.** An export must sound exactly like the
  mix, so anything that changes one changes both by construction, not by being
  written twice.
- **No new dependencies without asking.** Everything Cadmium links is either
  vendored or a system library that is everywhere, and each one is in
  `THIRD-PARTY-NOTICES.md` with its licence. A new one has to be
  GPL-compatible, and someone has to keep it building on Windows too.
- **Do not commit `.godot/`, `build/`, `dist/` or `.os` files.** `.gitignore`
  covers them; the `.import` files beside resources *are* committed on purpose,
  because they carry the UIDs that every reference in the project depends on.
- Keep the commit message in the imperative — "Fix the clip drawn over the
  ruler", not "Fixed" or "Fixes" — and say why in the body if the why is not
  obvious.


## Licence

Cadmium is free software under the **GNU General Public License, version 3 or
later**. Sending a pull request means you are offering your change under the
same licence and that it is yours to offer. There is no contributor agreement
and nobody signs anything over; the code stays under the GPL, including mine.

Do not paste code out of a proprietary DAW, a leaked SDK, or anything whose
licence is not GPL-compatible. If a change is based on something you read
somewhere, say where in the pull request — attribution is cheap and a licence
problem found later is not.
