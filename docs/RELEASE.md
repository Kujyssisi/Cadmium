# Releasing Cadmium

Everything you need to type. Nothing here has been run for you.

---

## 0. Before the first release — three things to settle

These are decisions, not commands, and two of them can stop a release dead.

1. ~~Pick a licence.~~ **Done:** Cadmium is GPL-3.0-or-later. `LICENSE` holds the
   full text and `COPYRIGHT` the notice. Every dependency is MIT / Apache-2.0 /
   OFL, all GPL-compatible, so nothing forced it and nothing conflicts.

2. **Settle the metronome clicks.** `resources/metronome_*.wav` came from two
   `.ogg` files with no licence attached and unknown provenance. Confirm you own
   them, replace them with something CC0, or delete them — the engine falls back
   to its synthesised click and the self-test covers that path. See
   `THIRD-PARTY-NOTICES.md`.

3. **Settle the VST trade mark.** The VST3 headers are MIT, but "VST" is a
   Steinberg mark and using it in a product needs their (free) licensing
   agreement. Either sign it at <https://steinberg.net/developers> or stop
   saying "VST3" in the interface and the marketing.

Two font licence files are also missing — see `THIRD-PARTY-NOTICES.md` for the
two URLs to drop into `fonts/`.

---

## 1. Prerequisites

    # Arch / Manjaro
    sudo pacman -S --needed scons mingw-w64-gcc zip alsa-lib libx11 ffmpeg

Godot 4.7 with **export templates installed for that exact version**. The
templates are what the export step turns into an executable; without them the
export fails with "the given export path doesn't exist" or similar.

    godot-beta --version                       # must match the templates
    ls ~/.local/share/godot/export_templates/  # one folder per version

Set `GODOT_BIN` if your Godot is not called `godot-beta`.

---

## 2. Check it before you build it

Three suites. They need a real display, so they run under Xvfb; `--` before the
hook is required, or the flags are swallowed as Godot's own.

    cd ~/Cadmium
    X="xvfb-run -a -s '-screen 0 1600x900x24'"

    # the engine: every instrument and effect rendered and measured, scores,
    # MIDI, sampler, project round trip, undo, automation
    xvfb-run -a -s "-screen 0 1600x900x24" godot-beta --path . \
        --rendering-driver opengl3 -- --cd-selftest=selftest

    # the interface: real InputEvents through the piano roll, playlist and knobs
    xvfb-run -a -s "-screen 0 1600x900x24" godot-beta --path . \
        --rendering-driver opengl3 -- --cd-uitest

    # hosted plugins: does a VST3 keep its settings across everything
    xvfb-run -a -s "-screen 0 1600x900x24" godot-beta --path . \
        --rendering-driver opengl3 -- --cd-statetest

Each ends with `N passed, M failed`. **Do not release on a non-zero M.**

Optional, slower, and worth it before a release that touches plugin hosting:

    # opens every installed VST3's own editor and reads the pixels back
    xvfb-run -a -s "-screen 0 1600x900x24" godot-beta --path . \
        --rendering-driver opengl3 -- --cd-vsttest=/tmp/vsttest

---

## 3. Build

One command per target, or all of them:

    tools/package.sh linux
    tools/package.sh windows
    tools/package.sh all

Each target: cross-builds the engine, exports the game, regenerates the licence
bundle from the engine, copies `content/` (soundfont and FLARE banks) in, and
zips the result into `dist/`.

Version the filenames with:

    CADMIUM_VERSION=1.0.0 tools/package.sh all      # default is today's date

### What each target actually is

| Target | Status | Notes |
|---|---|---|
| `linux` (x86_64) | **ships** | built and tested here |
| `windows` (x86_64) | **ships** | cross-built with MinGW, smoke-tested under Wine |
| `linux-arm64` | **untested** | needs an aarch64 toolchain; see below |
| macOS | **not a target yet** | needs porting, not just a build; see below |

### Linux arm64

The preset and the `.gdextension` entries are in place, but this has never been
built. You need `aarch64-linux-gnu-gcc`, plus ALSA and X11 headers **for
aarch64** — the compiler alone is not enough, because the engine links
`libasound` and `libX11`. In practice that means a sysroot or a container:

    # rough shape — a Debian arm64 container with the dev packages
    podman run --rm -v "$PWD":/src -w /src docker.io/arm64v8/debian:bookworm \
        bash -c 'apt update && apt install -y scons g++ libasound2-dev libx11-dev &&
                 cd native && scons platform=linux target=template_release arch=arm64 \
                     custom_api_file=$PWD/extension_api.json -j$(nproc)'

Then `tools/package.sh linux-arm64` on the host does the export and the zip.
**Test it on real hardware before publishing it** — cross-built audio code that
has never run is not a release.

### macOS

Not close, and worth being honest about rather than shipping something broken.
Two pieces of the engine are written against Linux and Windows only:

- `native/src/midi_in.cpp` talks to the **ALSA sequencer**. macOS needs a
  CoreMIDI implementation of the same small interface.
- `native/src/vst3_editor.cpp` embeds a plugin's own editor through **Xlib** on
  Linux and **HWND** on Windows. macOS plugins want an `NSView`
  (`kPlatformTypeNSView`), which is a third implementation.

`SConstruct` also links `asound` and `X11` unconditionally on non-Windows. On
top of that, cross-compiling from Linux needs the macOS SDK (osxcross), and a
distributable `.app` needs signing and notarising with an Apple Developer
account. Budget it as a port, not a build target.

---

## 4. Check the build, not just the source

The thing you ship is not the thing you tested — a different binary, a different
`.pck`. At minimum, run the packaged build:

    # Linux
    ( cd build/Cadmium-*-linux-x86_64 && ./Cadmium.x86_64 )

    # Windows, under Wine, in a scratch prefix
    export WINEPREFIX=/tmp/cadmium-wine
    wineboot -i
    cd build/Cadmium-*-windows-x86_64
    wine Cadmium.exe

Under Xvfb, Wine needs `--rendering-driver opengl3` (no DRI3 there). To take a
screenshot of the packaged build instead of driving it by hand:

    wine Cadmium.exe --rendering-driver opengl3 -- --cd-shot='Z:\tmp\shot.png,piano'

Confirm before publishing:

- it starts and the audio engine loads (no "the extension is not loaded" error)
- `Help > About` shows the version you think you built
- `LICENSE.txt`, `THIRD-PARTY-NOTICES.md` and `THIRD-PARTY-GODOT.txt` are all in
  the folder
- `Content/FluidR3_GM.sf2` and `Banks/` are there — the SoundFont instrument is
  silent without them

---

## 5. Publish

Nothing below is automated on purpose: publishing is the step you cannot undo.

### itch.io (easiest for a DAW, handles updates and payment)

    # one-time
    yay -S butler       # or from https://itch.io/docs/butler/
    butler login

    # per release — one channel per target
    butler push dist/Cadmium-1.0.0-linux-x86_64.zip   cfinite/cadmium:linux   --userversion 1.0.0
    butler push dist/Cadmium-1.0.0-windows-x86_64.zip cfinite/cadmium:windows --userversion 1.0.0
    butler status cfinite/cadmium

### Polar (what you already sell through)

Polar takes a file upload per product. Upload the zips from `dist/` to the
product's Downloadables, and put the changelog in the release notes. There is a
CLI (`npx @polar-sh/cli`) but the upload is simple enough by hand, and it is one
file per platform.

### GitHub Releases

    tools/release.sh                  release whatever version dist/ holds
    tools/release.sh 1.0.0            that version (must match the zip names)
    tools/release.sh 1.0.0 --publish  go live instead of leaving a draft

It refuses to do anything until: gh is logged in, the working tree is clean,
HEAD is already on origin, the tag does not exist, and every zip opens and
contains its licence files. Then it shows you what it is about to do and makes
you type the tag back before it tags, pushes the tag and uploads.

A **draft** unless you pass `--publish`: a draft can be deleted and rewritten,
a published release has already been downloaded by somebody. Release notes are
generated from the commits since the previous tag.

This is the only script in the repository that pushes, and it asks first.

#### By hand instead



    gh release create v1.0.0 \
        dist/Cadmium-1.0.0-linux-x86_64.zip \
        dist/Cadmium-1.0.0-windows-x86_64.zip \
        --title "Cadmium 1.0.0" --notes-file docs/CHANGELOG.md

Do not do this before step 0 — publishing the source under no licence at all is
worse than either choice.

### A Linux package, later

A Flatpak is the sane one for a DAW (it can be given ALSA/PulseAudio and JACK
permissions, and users get updates). It wants its own manifest and a
`flathub`-style repo; leave it until the zip release is settled.

---

## 6. After publishing

    git tag -a v1.0.0 -m "Cadmium 1.0.0" && git push --tags

Keep the exact `dist/` zips you published. When someone reports a bug against
1.0.0, you want the actual bytes they ran, not a rebuild that might differ.
