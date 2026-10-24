#!/bin/sh
# Builds DeskBar.app and installs it to ~/Applications.
set -e
cd "$(dirname "$0")"
APP="$HOME/Applications/DeskBar.app"
pkill -x DeskBar || true
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"
cp Info.plist "$APP/Contents/"
cp icon/DeskBar.icns "$APP/Contents/Resources/"
swiftc -O main.swift -o "$APP/Contents/MacOS/DeskBar"
# Stable identity: an ad-hoc signature changes every build and macOS then drops the Bluetooth permission.
./stamp-version.sh "$APP/Contents/Info.plist"
codesign -s "Apple Development" --force "$APP"
open "$APP"
