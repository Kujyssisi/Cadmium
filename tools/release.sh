#!/usr/bin/env bash
# Cuts a GitHub release from whatever tools/package.sh left in dist/.
#
#   tools/release.sh                  release the version dist/ already holds
#   tools/release.sh 1.0.0            release that version (must match the zips)
#   tools/release.sh 1.0.0 --publish  go live instead of leaving a draft
#
# A draft by default: a draft can be deleted and rewritten, a published release
# has already been downloaded by somebody. Publish from the web page, or pass
# --publish when you are sure.
#
# This is the only script here that pushes anything, and it asks first.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$HERE"
DIST="$HERE/dist"

say()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
die()  { printf '\033[31merror: %s\033[0m\n' "$*" >&2; exit 1; }
warn() { printf '\033[33m  ! %s\033[0m\n' "$*"; }

version="${1:-}"
publish="no"
for a in "$@"; do
	[ "$a" = "--publish" ] && publish="yes"
done
[ "$version" = "--publish" ] && version=""

command -v gh >/dev/null || die "gh is not installed"
[ -d "$DIST" ] || die "no dist/ -- run tools/package.sh first"

# --- what is actually in dist/
mapfile -t zips < <(find "$DIST" -maxdepth 1 -name 'Cadmium-*.zip' | sort)
[ "${#zips[@]}" -gt 0 ] || die "dist/ has no Cadmium-*.zip -- run tools/package.sh first"

# The version the zips carry, so a tag cannot disagree with its own artefacts.
found=""
for z in "${zips[@]}"; do
	v="$(basename "$z")"
	v="${v#Cadmium-}"
	v="${v%%-linux*}"; v="${v%%-windows*}"; v="${v%%-macos*}"
	if [ -z "$found" ]; then found="$v"
	elif [ "$found" != "$v" ]; then
		die "dist/ holds more than one version ($found and $v). Clear it and repackage."
	fi
done
if [ -z "$version" ]; then
	version="$found"
elif [ "$version" != "$found" ]; then
	die "asked for $version but dist/ holds $found"
fi
tag="v$version"

# --- preflight
say "checking"
gh auth status >/dev/null 2>&1 || die "not logged in: run 'gh auth login'"
repo="$(gh repo view --json nameWithOwner -q .nameWithOwner)"

[ -z "$(git status --porcelain)" ] || die "the working tree is dirty; commit or stash first"

branch="$(git rev-parse --abbrev-ref HEAD)"
git fetch -q origin "$branch" 2>/dev/null || true
if ! git merge-base --is-ancestor HEAD "origin/$branch" 2>/dev/null; then
	die "HEAD is not on origin/$branch yet -- push your commits first"
fi

if git rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
	die "tag $tag already exists locally"
fi
if gh release view "$tag" >/dev/null 2>&1; then
	die "release $tag already exists on $repo"
fi

# Every archive opened and looked inside, because the one thing worse than no
# release is a release of a corrupt zip.
for z in "${zips[@]}"; do
	unzip -t "$z" >/dev/null 2>&1 || die "$(basename "$z") is corrupt"
	for want in LICENSE.txt THIRD-PARTY-NOTICES.md THIRD-PARTY-GODOT.txt; do
		unzip -l "$z" | grep -q "$want" || warn "$(basename "$z") has no $want"
	done
	unzip -l "$z" | grep -q "FluidR3_GM.sf2" || warn "$(basename "$z") has no soundfont"
	printf '  %s  %s\n' "$(du -h "$z" | cut -f1)" "$(basename "$z")"
done

# --- notes from the commits since the last release
previous="$(git describe --tags --abbrev=0 2>/dev/null || echo "")"
notes_file="$(mktemp)"
trap 'rm -f "$notes_file"' EXIT
{
	if [ -n "$previous" ]; then
		echo "## Changes since $previous"
		echo
		git log --no-merges --pretty='- %s' "$previous..HEAD"
	else
		echo "First release."
	fi
	echo
	echo "## Downloads"
	echo
	for z in "${zips[@]}"; do
		echo "- \`$(basename "$z")\` ($(du -h "$z" | cut -f1))"
	done
	echo
	echo "Unzip and run. Everything travels in the folder: the engine library,"
	echo "the General MIDI soundfont, the FLARE banks and the licences."
} > "$notes_file"

say "about to release"
echo "  repo:     $repo"
echo "  tag:      $tag  (on $branch, $(git rev-parse --short HEAD))"
echo "  assets:   ${#zips[@]}"
echo "  mode:     $([ "$publish" = yes ] && echo 'PUBLISHED, live immediately' || echo 'draft')"
echo
printf 'Type the tag (%s) to go ahead: ' "$tag"
read -r confirm
[ "$confirm" = "$tag" ] || die "not confirmed, nothing done"

say "tagging"
git tag -a "$tag" -m "Cadmium $version"
git push origin "$tag"

say "uploading"
if [ "$publish" = "yes" ]; then
	gh release create "$tag" "${zips[@]}" --title "Cadmium $version" --notes-file "$notes_file"
else
	gh release create "$tag" "${zips[@]}" --title "Cadmium $version" --notes-file "$notes_file" --draft
fi

say "done"
gh release view "$tag" --json url -q .url
if [ "$publish" != "yes" ]; then
	echo
	echo "It is a draft. Publish it from that page, or:"
	echo "    gh release edit $tag --draft=false"
fi
