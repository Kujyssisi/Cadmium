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
	zip_up "$out" "Cadmium-$VERSION-windows-x86_64"
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
	zip_up "$out" "Cadmium-$VERSION-linux-arm64"
}

target="${1:-}"
[ -n "$target" ] || die "say which: linux | windows | linux-arm64 | all"
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

say "done -- $DIST"
ls -la "$DIST"
