#!/bin/sh
# Writes the release version into a built app's Info.plist:
#   CFBundleShortVersionString = latest release tag vX.Y.Z (every merge to main is tagged by .github/workflows/release.yml)
#   CFBundleVersion            = git commit count (always increases, so every build is distinct)
#   DeskBarCommit              = short commit hash, "+dirty" when built from uncommitted changes
# Usage: stamp-version.sh path/to/Info.plist
set -e
plist="$1"
root="$(cd "$(dirname "$0")" && pwd)"
git -C "$root" fetch --quiet --tags 2>/dev/null || true  # pick up tags the release workflow created
tag="$(git -C "$root" describe --tags --abbrev=0 --match 'v[0-9]*' 2>/dev/null || echo v0.1.0)"
version="${tag#v}"
build="$(git -C "$root" rev-list --count HEAD 2>/dev/null || echo 0)"
commit="$(git -C "$root" rev-parse --short HEAD 2>/dev/null || echo unknown)"
[ -n "$(git -C "$root" status --porcelain 2>/dev/null)" ] && commit="$commit+dirty"
pb=/usr/libexec/PlistBuddy
$pb -c "Set :CFBundleShortVersionString $version" "$plist" 2>/dev/null || $pb -c "Add :CFBundleShortVersionString string $version" "$plist"
$pb -c "Set :CFBundleVersion $build" "$plist" 2>/dev/null || $pb -c "Add :CFBundleVersion string $build" "$plist"
$pb -c "Set :DeskBarCommit $commit" "$plist" 2>/dev/null || $pb -c "Add :DeskBarCommit string $commit" "$plist"
echo "stamped $version ($build, $commit) into $plist"
