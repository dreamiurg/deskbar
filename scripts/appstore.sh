#!/bin/sh
# Archives DeskBar for the App Store (iPhone app + widget, and the sandboxed Mac app) and exports or uploads it.
#   scripts/appstore.sh [ios|mac|all]            archive and export to ios/build-appstore (nothing uploaded)
#   scripts/appstore.sh [ios|mac|all] --upload   archive and upload to App Store Connect
# Version = latest vX.Y.Z tag, build = commit count (stamp-version.sh), so build from a clean, pushed main.
# Nothing secret lives in this repo. The script reads, in order:
#   team ID:  $DEVELOPMENT_TEAM, else DRAGONTAIL_TEAM_ID from Doppler (project studio, config prd)
#   API key:  ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_P8 from Doppler; without them,
#             the Apple ID signed in to Xcode is used. The .p8 is written to a temp dir and deleted on exit.
# Signing is automatic: Xcode creates the certificates and profiles itself (-allowProvisioningUpdates).
set -eu
cd "$(dirname "$0")/.."
platform="${1:-all}"
destination="export"
[ "${2:-}" = "--upload" ] && destination=upload
case "$platform" in ios | mac | all) ;; *) echo "usage: $0 [ios|mac|all] [--upload]" >&2; exit 2 ;; esac
[ -z "$(git status --porcelain --untracked-files=no)" ] || { echo "Commit first: the build number is the commit count." >&2; exit 1; }

secret() { doppler secrets get "$1" --project studio --config prd --plain 2>/dev/null || true; }
DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM:-$(secret DRAGONTAIL_TEAM_ID)}"
[ -n "$DEVELOPMENT_TEAM" ] || { echo "Set DEVELOPMENT_TEAM (Apple team ID) or DRAGONTAIL_TEAM_ID in Doppler." >&2; exit 1; }
export DEVELOPMENT_TEAM

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
out="$PWD/ios/build-appstore"
mkdir -p "$out"

set --   # auth flags for every xcodebuild call
secret ASC_KEY_P8 > "$tmp/AuthKey.p8"
if [ -s "$tmp/AuthKey.p8" ]; then
  chmod 600 "$tmp/AuthKey.p8"
  set -- -authenticationKeyPath "$tmp/AuthKey.p8" \
    -authenticationKeyID "$(secret ASC_KEY_ID)" -authenticationKeyIssuerID "$(secret ASC_ISSUER_ID)"
  echo "Using the App Store Connect API key from Doppler"
else
  echo "No API key in Doppler: using the Apple ID signed in to Xcode"
fi

cat > "$tmp/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>$destination</string>
  <key>teamID</key><string>$DEVELOPMENT_TEAM</string>
  <key>signingStyle</key><string>automatic</string>
  <key>uploadSymbols</key><true/>
  <key>manageAppVersionAndBuildNumber</key><false/>
</dict>
</plist>
PLIST

(cd ios && xcodegen generate --quiet)
build=$(git rev-list --count HEAD)
config="${CONFIG:-Release}"   # Alpha = personal-team test build (io.dreamiurg.deskbar.alpha)
schemes="DeskBar DeskBarMac"
[ "$platform" = ios ] && schemes=DeskBar
[ "$platform" = mac ] && schemes=DeskBarMac
for scheme in $schemes; do   # a loop, not a function: "$@" must stay the auth flags
  dest=generic/platform=iOS
  [ "$scheme" = DeskBarMac ] && dest=generic/platform=macOS
  archive="$out/$scheme-$build.xcarchive"
  xcodebuild -project ios/DeskBar.xcodeproj -scheme "$scheme" -configuration "$config" -destination "$dest" \
    -archivePath "$archive" -allowProvisioningUpdates "$@" archive -quiet
  xcodebuild -exportArchive -archivePath "$archive" -exportOptionsPlist "$tmp/ExportOptions.plist" \
    -exportPath "$out/$scheme-$build" -allowProvisioningUpdates "$@"
done
if [ "$destination" = upload ]; then echo "Uploaded build $build. Processing takes 5-30 min, then it shows in TestFlight."
else echo "Exported build $build to $out"; fi
