#!/bin/sh
# Builds DeskBar.app and installs it to ~/Applications.
set -e
cd "$(dirname "$0")"
APP="$HOME/Applications/DeskBar.app"
pkill -x DeskBar || true
mkdir -p "$APP/Contents/MacOS"
cp Info.plist "$APP/Contents/"
swiftc -O main.swift -o "$APP/Contents/MacOS/DeskBar"
codesign -s - --force "$APP"
open "$APP"
