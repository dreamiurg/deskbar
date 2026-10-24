#!/bin/sh
# Compiles the shared desk logic with its checks and runs them (macOS with Xcode, or Linux with a Swift toolchain).
set -e
cd "$(dirname "$0")/.."
out="${TMPDIR:-/tmp}/deskbar-logic-tests"
swiftc ios/Shared/DeskProtocol.swift tests/main.swift -o "$out"
"$out"
