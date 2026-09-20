#!/usr/bin/env bash
# Installs Cadmium on any freedesktop system -- KDE, GNOME, Xfce, whatever --
# from the folder this script sits in.
#
#   ./install.sh                 just for you, no root, into ~/.local
#   ./install.sh --system        for everyone, into /opt and /usr/local
#   ./install.sh --prefix DIR    somewhere else entirely
#   ./install.sh --uninstall     take it off again
#
# Everything it writes is recorded in a manifest beside the program, and the
# uninstaller removes exactly what the manifest lists and nothing else. That is
# the whole point: an installer that cannot say what it touched is one you
# cannot undo.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

say()  { printf '\033[1m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[33m  ! %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[31merror: %s\033[0m\n' "$*" >&2; exit 1; }

mode="user"
prefix=""
action="install"
while [ $# -gt 0 ]; do
	case "$1" in
		--system)    mode="system" ;;
		--user)      mode="user" ;;
		--prefix)    shift; prefix="${1:-}"; [ -n "$prefix" ] || die "--prefix needs a folder" ;;
		--uninstall) action="uninstall" ;;
		-h|--help)   sed -n '2,13p' "${BASH_SOURCE[0]}" | sed 's/^# \?//'; exit 0 ;;
		*)           die "unknown option: $1" ;;
	esac
	shift
done

# An installed copy keeps a note of where it put everything, so the uninstaller
# does not have to be told again and cannot guess wrong.
if [ -f "$HERE/.install-prefix" ]; then
	# shellcheck disable=SC1091
	. "$HERE/.install-prefix"
	DEST="${DEST:-$HERE}"
elif [ -n "$prefix" ]; then
	mode="prefix"
	DEST="$prefix"; BIN="$prefix/bin"; SHARE="$prefix/share"
elif [ "$mode" = "system" ]; then
	DEST="/opt/cadmium"; BIN="/usr/local/bin"; SHARE="/usr/share"
else
	DEST="${XDG_DATA_HOME:-$HOME/.local/share}/cadmium"
	BIN="$HOME/.local/bin"
	SHARE="${XDG_DATA_HOME:-$HOME/.local/share}"
fi
DESKTOP="$SHARE/applications"
ICONS="$SHARE/icons/hicolor"
MIME="$SHARE/mime/packages"
MANIFEST="$DEST/.install-manifest"

refresh_caches() {
	command -v update-desktop-database >/dev/null && update-desktop-database "$DESKTOP" 2>/dev/null || true
	command -v update-mime-database    >/dev/null && update-mime-database "$SHARE/mime" 2>/dev/null || true
	command -v gtk-update-icon-cache   >/dev/null && gtk-update-icon-cache -qtf "$ICONS" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Uninstall: the manifest, backwards
# ---------------------------------------------------------------------------
if [ "$action" = "uninstall" ]; then
	[ -f "$MANIFEST" ] || die "no install manifest at $MANIFEST -- nothing to uninstall"
	if [ ! -w "$DEST" ] && [ "$(id -u)" != "0" ]; then
		say "this copy needs root to remove; asking for it"
		command -v pkexec >/dev/null && exec pkexec "$DEST/uninstall.sh" --uninstall
		command -v sudo   >/dev/null && exec sudo   "$DEST/uninstall.sh" --uninstall
		die "no pkexec or sudo; run this as root"
	fi
	say "removing what $MANIFEST lists"
	gone=0
	while IFS= read -r f; do
		[ -n "$f" ] || continue
		if [ -e "$f" ] || [ -L "$f" ]; then rm -f "$f" && gone=$((gone + 1)); fi
	done < "$MANIFEST"
	# Then the folders those files were in, deepest first, and only when empty:
	# never rm -rf a path read out of a file.
	while IFS= read -r f; do
		[ -n "$f" ] || continue
		d="$(dirname "$f")"
		while [ "$d" != "/" ] && [ "$d" != "." ] && [ "$d" != "$HOME" ]; do
			rmdir "$d" 2>/dev/null || break
			d="$(dirname "$d")"
		done
	done < <(sort -r "$MANIFEST")
	rm -f "$MANIFEST" "$DEST/.install-prefix"
	rmdir "$DEST" 2>/dev/null || true
	refresh_caches
	say "removed $gone files"
	say "Your projects and settings are untouched; those live in"
	say "  ${XDG_DATA_HOME:-$HOME/.local/share}/godot/app_userdata/Cadmium"
	exit 0
fi

# ---------------------------------------------------------------------------
# Install
# ---------------------------------------------------------------------------
APP="Cadmium.x86_64"
[ -f "$HERE/$APP" ] || APP="Cadmium.arm64"
[ -f "$HERE/$APP" ] || die "no Cadmium executable beside this script -- run it from the unzipped folder"

if [ "$mode" = "system" ] && [ "$(id -u)" != "0" ]; then
	say "a system install needs root; asking for it"
	command -v pkexec >/dev/null && exec pkexec "$HERE/install.sh" --system
	command -v sudo   >/dev/null && exec sudo   "$HERE/install.sh" --system
	die "no pkexec or sudo; run this as root, or leave off --system for a copy of your own"
fi

say "installing into $DEST"
mkdir -p "$DEST" "$BIN" "$DESKTOP" "$MIME" "$ICONS/scalable/apps"

: > "$MANIFEST"
record() { printf '%s\n' "$1" >> "$MANIFEST"; }

copy_one() {
	local src="$1"
	[ -e "$src" ] || return 0
	cp -f "$src" "$DEST/"
	record "$DEST/$(basename "$src")"
}

for name in "$APP" Cadmium.pck LICENSE.txt COPYRIGHT.txt \
		THIRD-PARTY-NOTICES.md THIRD-PARTY-GODOT.txt README.txt; do
	copy_one "$HERE/$name"
done
# The engine library, whatever it is called on this architecture.
while IFS= read -r so; do copy_one "$so"; done < <(find "$HERE" -maxdepth 1 -name 'libcadmium.*.so')
chmod +x "$DEST/$APP"

# The soundfont and the FLARE banks are read from beside the executable, so
# they have to land beside the installed one rather than stay in the zip.
for d in Content Banks; do
	[ -d "$HERE/$d" ] || continue
	say "copying $d ($(du -sh "$HERE/$d" | cut -f1))"
	while IFS= read -r -d '' rel; do
		rel="${rel#./}"
		mkdir -p "$DEST/$d/$(dirname "$rel")"
		cp -f "$HERE/$d/$rel" "$DEST/$d/$rel"
		record "$DEST/$d/$rel"
	done < <(cd "$HERE/$d" && find . -type f -print0)
done

# A launcher rather than a symlink: two readable lines beat a path you have to
# resolve to understand.
cat > "$BIN/cadmium" <<LAUNCHER
#!/usr/bin/env sh
# Installed by Cadmium's install.sh. Remove with: $DEST/uninstall.sh --uninstall
exec "$DEST/$APP" "\$@"
LAUNCHER
chmod +x "$BIN/cadmium"
record "$BIN/cadmium"

# The desktop entry, pointed at where the program actually landed, plus the
# icon and what a .cadmium file is. All three ship in packaging/ inside the zip.
P="$HERE/packaging"
if [ -f "$P/cadmium.desktop" ]; then
	sed "s|@EXEC@|$DEST/$APP|g" "$P/cadmium.desktop" > "$DESKTOP/cadmium.desktop"
	record "$DESKTOP/cadmium.desktop"
fi
if [ -f "$P/icon.svg" ]; then
	cp -f "$P/icon.svg" "$ICONS/scalable/apps/cadmium.svg"
	record "$ICONS/scalable/apps/cadmium.svg"
fi
if [ -f "$P/cadmium-project.xml" ]; then
	cp -f "$P/cadmium-project.xml" "$MIME/cadmium-project.xml"
	record "$MIME/cadmium-project.xml"
fi

# The uninstaller is this script, with a note of where everything went beside
# it so it never has to guess.
cp -f "${BASH_SOURCE[0]}" "$DEST/uninstall.sh"
chmod +x "$DEST/uninstall.sh"
record "$DEST/uninstall.sh"
cat > "$DEST/.install-prefix" <<PREFIX
DEST="$DEST"
BIN="$BIN"
SHARE="$SHARE"
MODE="$mode"
PREFIX

refresh_caches

say "done"
echo "  program     $DEST"
echo "  launcher    $BIN/cadmium"
echo "  menu entry  $DESKTOP/cadmium.desktop"
echo "  uninstall   $DEST/uninstall.sh --uninstall"
if [ "$mode" = "user" ] && ! printf '%s' ":$PATH:" | grep -q ":$BIN:"; then
	warn "$BIN is not on your PATH, so typing 'cadmium' will not find it."
	warn "The application menu entry works either way."
fi
