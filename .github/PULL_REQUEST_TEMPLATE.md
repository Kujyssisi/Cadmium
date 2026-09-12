<!--
One change per pull request. CONTRIBUTING.md has the build and test commands
and what happens to this afterwards.
-->

## What this changes

<!-- What it does, in a sentence or two. -->


## Why

<!-- The bug it fixes (link the issue), or the thing that could not be done
     before. If the reason is obvious from the title, delete this. -->


## How it was tested

<!-- Paste the tally from
     xvfb-run -a -s "-screen 0 1600x900x24" godot-beta --path . \
         --rendering-driver opengl3 -- --cd-selftest=/tmp/cadmium-selftest
     and say what you did by hand: which panel, which plugin, which project. -->


## Checklist

- [ ] Built the engine, if anything under `native/` changed
- [ ] `--cd-selftest` passes, or the description says why it does not
- [ ] Reads like the code around it (see CONTRIBUTING.md ▸ House style)
- [ ] Nothing that allocates, locks or blocks on the audio thread
- [ ] No new dependency, or one that was agreed in an issue first
- [ ] No `.godot/`, `build/`, `dist/` or `.os` files in the diff
- [ ] Offered under GPL-3.0-or-later, and it is mine to offer
