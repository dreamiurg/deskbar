#!/bin/sh
# Writes the release version into a built app's Info.plist:
#   CFBundleShortVersionString = version.txt (bumped by release-please on each release)
#   CFBundleVersion            = git commit count (always increases, so every build is distinct)
#   DeskBarCommit              = short commit hash, "+dirty" when built from uncommitted changes
# Usage: stamp-version.sh path/to/Info.plist
set -e
plist="$1"
root="$(cd "$(dirname "$0")" && pwd)"
version="$(tr -d '[:space:]' < "$root/version.txt")"
build="$(git -C "$root" rev-list --count HEAD 2>/dev/null || echo 0)"
commit="$(git -C "$root" rev-parse --short HEAD 2>/dev/null || echo unknown)"
[ -n "$(git -C "$root" status --porcelain 2>/dev/null)" ] && commit="$commit+dirty"
pb=/usr/libexec/PlistBuddy
$pb -c "Set :CFBundleShortVersionString $version" "$plist" 2>/dev/null || $pb -c "Add :CFBundleShortVersionString string $version" "$plist"
$pb -c "Set :CFBundleVersion $build" "$plist" 2>/dev/null || $pb -c "Add :CFBundleVersion string $build" "$plist"
$pb -c "Set :DeskBarCommit $commit" "$plist" 2>/dev/null || $pb -c "Add :DeskBarCommit string $commit" "$plist"
echo "stamped $version ($build, $commit) into $plist"
