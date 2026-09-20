#!/usr/bin/env bash
# Builds and packages Cadmium for one target, or all of them.
#
#   tools/package.sh linux          Linux x86_64
#   tools/package.sh windows        Windows x86_64 (cross-compiled with MinGW)
#   tools/package.sh linux-arm64    Linux arm64 (needs an aarch64 toolchain)
#   tools/package.sh all            every target that can be built here
#
# Each target gets its engine library cross-built, the game exported, the
# licences and the shipped content copied in, and the lot zipped into dist/.
#
# Nothing here is published. See docs/RELEASE.md for that.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$HERE"

GODOT="${GODOT_BIN:-godot-beta}"
VERSION="${CADMIUM_VERSION:-$(date +%Y.%m.%d)}"
JOBS="$(nproc)"
DIST="$HERE/dist"

say() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
die() { printf '\033[31merror: %s\033[0m\n' "$*" >&2; exit 1; }

# The version the build reports is the version it was built as -- Help > About,
# the crash reports and the update check all read the same project setting, so
# it is stamped in for the export and put back afterwards, whatever happens.
stamp_version() {
	VERSION_WAS="$(sed -n 's/^config\/version="\(.*\)"$/\1/p' project.godot)"
	[ -n "$VERSION_WAS" ] || die "project.godot has no config/version to stamp"
	trap 'unstamp_version' EXIT INT TERM
	sed -i "s|^config/version=\".*\"$|config/version=\"$VERSION\"|" project.godot
	say "building as $VERSION (project.godot said $VERSION_WAS)"
}

unstamp_version() {
	[ -n "${VERSION_WAS:-}" ] || return 0
	sed -i "s|^config/version=\".*\"$|config/version=\"$VERSION_WAS\"|" project.godot
	VERSION_WAS=""
}

command -v "$GODOT" >/dev/null || die "no Godot binary ($GODOT). Set GODOT_BIN."
command -v scons  >/dev/null || die "scons is not installed"
command -v zip    >/dev/null || die "zip is not installed"

# --- the licence bundle, regenerated every time so it matches this engine
licences() {
	say "licences"
	mkdir -p build
	"$GODOT" --headless --path . --script res://tools/licences.gd >/dev/null
	[ -s build/THIRD-PARTY-GODOT.txt ] || die "the Godot licence dump came out empty"
}

# Everything that has to sit beside the executable, whatever the platform.
stage_common() {
	local out="$1"
	cp -f LICENSE "$out/LICENSE.txt"
	cp -f COPYRIGHT "$out/COPYRIGHT.txt"
	cp -f THIRD-PARTY-NOTICES.md "$out/THIRD-PARTY-NOTICES.md"
	cp -f build/THIRD-PARTY-GODOT.txt "$out/THIRD-PARTY-GODOT.txt"
	# The soundfont and the FLARE presets. Deliberately not in the pck -- the
	# engine reads them from beside the executable at run time. See content/.
	[ -d content/Content ] || die "content/Content is missing; see content/README.md"
	[ -d content/Banks ]   || die "content/Banks is missing; see content/README.md"
	cp -rf content/Content "$out/"
	cp -rf content/Banks   "$out/"
	# README.txt is the user-facing one that ships, not the developer README.
	[ -f docs/SHIPPED-README.txt ] && cp -f docs/SHIPPED-README.txt "$out/README.txt" || true
}

# What the installers need, in one folder inside the zip so install.sh has a
# single place to look and a user poking around can see what it is about to do.
stage_linux_installer() {
	local out="$1"
	mkdir -p "$out/packaging"
	cp -f packaging/linux/cadmium.desktop      "$out/packaging/"
	cp -f packaging/linux/cadmium-project.xml  "$out/packaging/"
	cp -f icon.svg                             "$out/packaging/icon.svg"
	cp -f packaging/linux/install.sh           "$out/install.sh"
	chmod +x "$out/install.sh"
}

zip_up() {
	local dir="$1" name="$2"
	mkdir -p "$DIST"
	rm -f "$DIST/$name.zip"
	# Zipped from a parent so everything lands in one folder rather than spraying
	# into whatever the user unzipped into.
	( cd "$(dirname "$dir")" && zip -r -q "$DIST/$name.zip" "$(basename "$dir")" )
	say "$(du -h "$DIST/$name.zip" | cut -f1)  $DIST/$name.zip"
}

# One staging folder per release, built into directly rather than copied: the
# soundfont alone is 142 MB and there is no reason to write it twice.
stage_dir() {
	local name="build/Cadmium-$VERSION-$1"
	rm -rf "$name"
	mkdir -p "$name"
	printf '%s' "$name"
}

build_linux() {
	say "engine: linux x86_64"
	( cd native && scons platform=linux target=template_release arch=x86_64 \
		custom_api_file="$PWD/extension_api.json" -j"$JOBS" )
	local out
	out="$(stage_dir linux-x86_64)"
	say "export: Linux -> $out"
	"$GODOT" --headless --path . --export-release "Linux" "$out/Cadmium.x86_64"
	stage_common "$out"
	stage_linux_installer "$out"
	zip_up "$out" "Cadmium-$VERSION-linux-x86_64"
}

build_windows() {
	command -v x86_64-w64-mingw32-g++ >/dev/null \
		|| die "MinGW is not installed (pacman -S mingw-w64-gcc)"
	say "engine: windows x86_64"
	( cd native && scons platform=windows target=template_release use_mingw=yes \
		custom_api_file="$PWD/extension_api.json" -j"$JOBS" )
	local out
	out="$(stage_dir windows-x86_64)"
	say "export: Windows Desktop -> $out"
	"$GODOT" --headless --path . --export-release "Windows Desktop" "$out/Cadmium.exe"
	stage_common "$out"
	mkdir -p "$out/packaging"
	cp -f packaging/windows/cadmium.ico "$out/packaging/"
	zip_up "$out" "Cadmium-$VERSION-windows-x86_64"
	build_windows_installer "$out"
}

# makensis, native if it is installed and through Wine if it is not. NSIS is a
# Windows program; its own binaries run perfectly well under Wine, which is
# already here for testing the Windows build, and that beats a chain of AUR
# packages for a tool that only the release machine needs.
NSIS_CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/cadmium"
NSIS_VERSION="3.12"

find_makensis() {
	if [ -n "${MAKENSIS:-}" ]; then printf 'native'; return 0; fi
	if command -v makensis >/dev/null; then MAKENSIS="makensis"; printf 'native'; return 0; fi
	command -v wine >/dev/null || return 1
	local dir="$NSIS_CACHE/nsis-$NSIS_VERSION"
	if [ ! -f "$dir/makensis.exe" ]; then
		command -v curl >/dev/null || return 1
		mkdir -p "$NSIS_CACHE"
		say "fetching NSIS $NSIS_VERSION (once, into $NSIS_CACHE)"
		curl -sSL -o "$NSIS_CACHE/nsis.zip" \
			"https://downloads.sourceforge.net/project/nsis/NSIS%203/$NSIS_VERSION/nsis-$NSIS_VERSION.zip" \
			|| return 1
		( cd "$NSIS_CACHE" && unzip -q -o nsis.zip ) || return 1
	fi
	[ -f "$dir/makensis.exe" ] || return 1
	MAKENSIS="$dir/makensis.exe"
	printf 'wine'
}

build_windows_installer() {
	local src="$1"
	local how
	if ! how="$(find_makensis)"; then
		say "skipping the Windows installer: no makensis and no wine to run it under"
		return 0
	fi
	local setup="$DIST/Cadmium-$VERSION-windows-x86_64-setup.exe"
	mkdir -p "$DIST"
	rm -f "$setup"
	say "installer: $(basename "$setup")  (makensis, $how)"
	if [ "$how" = "wine" ]; then
		# NSIS is reading and writing through Wine, so every path it is handed
		# has to be one Wine understands. Z: is the host filesystem.
		local wsrc wout wnsi
		wsrc="Z:$(printf '%s' "$(cd "$src" && pwd)" | tr '/' '\\')"
		wout="Z:$(printf '%s' "$DIST" | tr '/' '\\')\\$(basename "$setup")"
		wnsi="Z:$(printf '%s' "$HERE/packaging/windows" | tr '/' '\\')\\cadmium.nsi"
		WINEDEBUG=-all wine "$MAKENSIS" -V2 \
			"-DVERSION=$VERSION" "-DSRC=$wsrc" "-DOUT=$wout" "$wnsi" \
			|| die "makensis failed"
	else
		"$MAKENSIS" -V2 "-DVERSION=$VERSION" "-DSRC=$src" "-DOUT=$setup" \
			"$HERE/packaging/windows/cadmium.nsi" || die "makensis failed"
	fi
	[ -f "$setup" ] || die "makensis reported success but wrote no $setup"
	say "$(du -h "$setup" | cut -f1)  $setup"
}

build_linux_arm64() {
	# UNTESTED here -- there is no aarch64 toolchain on this machine. The engine
	# needs ALSA and X11 headers for aarch64 as well as the compiler, which in
	# practice means a sysroot or a container. See docs/RELEASE.md.
	command -v aarch64-linux-gnu-g++ >/dev/null \
		|| die "no aarch64 toolchain (aarch64-linux-gnu-g++). See docs/RELEASE.md."
	say "engine: linux arm64"
	( cd native && scons platform=linux target=template_release arch=arm64 \
		CXX=aarch64-linux-gnu-g++ CC=aarch64-linux-gnu-gcc \
		custom_api_file="$PWD/extension_api.json" -j"$JOBS" )
	local out
	out="$(stage_dir linux-arm64)"
	say "export: Linux ARM64 -> $out"
	"$GODOT" --headless --path . --export-release "Linux ARM64" "$out/Cadmium.arm64"
	stage_common "$out"
	stage_linux_installer "$out"
	zip_up "$out" "Cadmium-$VERSION-linux-arm64"
}

target="${1:-}"
[ -n "$target" ] || die "say which: linux | windows | linux-arm64 | all"
stamp_version
licences
case "$target" in
	linux)       build_linux ;;
	windows)     build_windows ;;
	linux-arm64) build_linux_arm64 ;;
	all)
		build_linux
		build_windows
		# Only if the toolchain is there; not being able to build arm64 is not a
		# reason for the other two to have been wasted.
		if command -v aarch64-linux-gnu-g++ >/dev/null; then
			build_linux_arm64
		else
			say "skipping linux-arm64: no aarch64 toolchain"
		fi
		;;
	*) die "unknown target: $target" ;;
esac

unstamp_version
say "done -- $DIST"
ls -la "$DIST"
