# Shipped content

What has to sit **beside the executable** rather than inside the `.pck`, because
the engine reads it from the filesystem at run time (see `preset_dirs()` and
`content_dirs()` in `native/src/flare/preset.cpp`).

    Content/    FluidR3_GM.sf2 and its MIT licence -- the General MIDI bank
    Banks/      FLARE presets: Factory, and GM derived from the soundfont above

`tools/package.sh` copies both into every build. They live here rather than in
`build/` because `build/` is disposable and this is not: they used to exist only
inside the two output folders, where `rm -rf build` would have taken 142 MB of
soundfont with it and there was no other copy.

They are deliberately kept out of the `.pck`: 142 MB of soundfont has no
business inside one, and the FLARE library wants real files on disk anyway.

## The soundfont is not in the repository

`Content/FluidR3_GM.sf2` is 142 MB, which is over GitHub's 100 MB limit for a
single file, so it is in `.gitignore`. A fresh clone has the FLARE banks and the
licence text but not the soundfont, and the SoundFont instrument is silent until
it is there.

To put it back:

    # Arch / Manjaro
    sudo pacman -S soundfont-fluid
    cp /usr/share/soundfonts/FluidR3_GM.sf2 content/Content/

    # or straight from the source
    curl -L -o content/Content/FluidR3_GM.sf2 \
        https://ftp.osuosl.org/pub/musescore/soundfont/FluidR3_GM.sf2

It is MIT-licensed (Frank Wen) and `Content/FluidR3_GM.LICENSE.txt`, which *is*
in the repository, has to travel with it.
