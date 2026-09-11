# Third-party notices

Everything Cadmium ships that somebody else wrote, what it is licensed under,
and what that obliges you to do. **This file must ship with every build** — most
of these licences require the notice to travel with the binary.

None of these forced a licence on Cadmium itself -- they are all permissive
(MIT, Apache-2.0, OFL) and all compatible with the GPL. Cadmium is GPL-3.0-or-
later; see `LICENSE` and `COPYRIGHT`.

---

## Two things to settle before you publish

These are not blockers I can resolve for you.

### 1. The metronome clicks — provenance unknown

`resources/metronome_loud.wav` and `resources/metronome_silent.wav` are converted
from `MetronomeLoud.ogg` and `MetronomeSilent.ogg`, which arrived as files on
this machine with no licence attached. **I do not know where they came from.**

If they were ripped from another DAW, a sample pack with a no-redistribution
clause, or a video, they cannot ship. Before publishing, either:

- confirm you made them or they are public domain / CC0, and record that below;
  or
- replace them. CC0 metronome clicks are easy to find (freesound.org, filtered
  to CC0), or record a rimshot and a woodblock; or
- delete both files. The engine falls back to its own synthesised click when
  either is missing — that path is kept alive deliberately, and `--cd-selftest`
  covers it.

### 2. "VST" is a Steinberg trade mark

The VST3 interface headers vendored in `native/vendor/vst3` are **MIT** (see
below), so the *code* is free to use. The **name** is not: Steinberg requires a
signed VST3 licensing agreement to use the "VST" word or logo in a product, in
its marketing, or in its documentation.

Cadmium's interface says "VST3" in several places. Before publishing either sign
the agreement (it is free, at steinberg.net/developers) or stop using the mark
and call it "plugin support". This is a trade mark question, not a copyright
one — the MIT licence on the headers does not cover it.

---

## Components

### Godot Engine

- **Used for:** the whole application runtime; the exported binary *is* Godot.
- **Licence:** MIT, Copyright (c) 2014-present Godot Engine contributors,
  Copyright (c) 2007-2014 Juan Linietsky, Ariel Manzur.
- **Obligation:** ship the MIT notice, and the notices of the libraries Godot
  itself bundles (FreeType, Harfbuzz, zlib, miniupnpc, Thorvg and around forty
  more).
- **How:** `godot-beta --headless --path . --script res://tools/licences.gd`
  writes `THIRD-PARTY-GODOT.txt` straight out of the engine, so the list is
  whatever the engine you actually built with contains rather than whatever was
  true when this file was written. `tools/package.sh` runs it for you.

### godot-cpp

- **Used for:** the C++ bindings the audio engine is built against
  (`native/godot-cpp`).
- **Licence:** MIT, Copyright (c) 2017-present Godot Engine contributors.
- **Text:** `native/godot-cpp/LICENSE.md`.
- **Obligation:** ship the notice. Statically linked into
  `libcadmium.*`, so it travels with the binary.

### VST3 interfaces (`pluginterfaces`, `base`)

- **Used for:** hosting VST3 plugins (`native/vendor/vst3`).
- **Licence:** MIT, Copyright (c) 2025 Steinberg Media Technologies GmbH.
- **Text:** `native/vendor/vst3/LICENSE.txt`,
  `native/vendor/vst3/pluginterfaces/LICENSE.txt`,
  `native/vendor/vst3/base/LICENSE.txt`.
- **Obligation:** ship the notice. **See the trade mark note above** — the
  licence and the mark are separate questions.

### FluidR3_GM (SoundFont)

- **Used for:** the General MIDI bank shipped in `Content/`, and the source of
  the `Banks/GM/*.flare` presets.
- **Licence:** MIT, Copyright (c) 2000-2002, 2008 Frank Wen.
- **Text:** `Content/FluidR3_GM.LICENSE.txt`, already beside the file.
- **Obligation:** ship the notice with it. Already done.
- **Note:** this is 148 MB of the 174 MB download. If you want a smaller
  installer, this is the thing to make an optional download.

### Roboto

- **Used for:** the interface font (`fonts/Roboto-*.ttf`).
- **Licence:** Apache-2.0, Copyright Google Inc.
- **Obligation:** ship the Apache-2.0 text and the notice.
- **Missing:** there is no licence file beside the fonts. Add
  `fonts/Roboto-LICENSE.txt` from
  <https://github.com/googlefonts/roboto/blob/main/LICENSE> before publishing.

### Noto Sans Mono

- **Used for:** the monospaced font (`fonts/NotoSansMono-Regular.ttf`).
- **Licence:** SIL Open Font License 1.1, Copyright The Noto Project Authors.
- **Obligation:** ship the OFL text. The OFL also forbids selling the font on
  its own (fine — it is bundled), and forbids using the reserved font name on a
  modified version (fine — it is unmodified).
- **Missing:** add `fonts/NotoSansMono-LICENSE.txt` from
  <https://github.com/notofonts/latin-greek-cyrillic/blob/main/OFL.txt> before
  publishing.

### FLARE factory and GM presets

- **Used for:** `Banks/Factory/*.flare` and `Banks/GM/*.flare`.
- **Origin:** Cadmium's own, except that the GM bank's samples are derived from
  FluidR3_GM and each preset already credits `"FluidR3 (Frank Wen, MIT)"` in its
  `author` field.
- **Obligation:** covered by the FluidR3 notice above.

---

## Not shipped, but worth knowing

### ffmpeg / ffprobe

Cadmium **executes** ffmpeg to decode audio formats the engine cannot read
itself; it does not bundle or link it. `Audio.tool_path()` looks on `PATH`, and
on Windows also beside the executable so a user can drop it in themselves.

Because it is a separate program invoked over a process boundary, ffmpeg's
LGPL/GPL terms do not reach Cadmium. **If you ever ship ffmpeg binaries inside
the download, that changes** — you would then have to satisfy LGPL-2.1 (or
GPL-3.0, depending on the build) for those binaries, which at minimum means
shipping their licence and offering their source.

### VST3 plugins the user has installed

Loaded at runtime from the user's own machine. Nothing of theirs is
redistributed.

---

## Keeping this file honest

`tools/package.sh` copies `LICENSE`, this file and the generated
`THIRD-PARTY-GODOT.txt` into every build it makes. If you add a dependency, add
it here in the same shape: what it is used for, its licence, where the text
lives, and what shipping it obliges you to do.
