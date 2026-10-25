#!/bin/sh
# Fails if personal identifiers are written into files: email addresses (other than noreply/example ones) and full
# Bluetooth/Wi-Fi MAC addresses. gitleaks catches secrets (keys, tokens), not personal data.
# Usage: check-privacy.sh [files...]   (default: all tracked files)
set -e
ok_email='([0-9]+\+)?[A-Za-z0-9._-]+@users\.noreply\.github\.com|noreply@github\.com|noreply@anthropic\.com|[A-Za-z0-9._%+-]+@example\.(com|org|net)|[0-9]+\+[A-Za-z0-9_-]+\[bot\]@users\.noreply\.github\.com'
email='[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}'
mac='([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}'

[ $# -eq 0 ] && set -- $(git ls-files)
status=0
for f in "$@"; do
  [ -f "$f" ] || continue
  case "$f" in ios/DeskBar/BluetoothNumbers/*) continue ;; esac  # vendored upstream data
  hits=$( (grep -EnoI "$email" "$f" | grep -Ev ":($ok_email)$"; grep -EnoI "$mac" "$f") || true)
  if [ -n "$hits" ]; then
    echo "$hits" | sed "s|^|$f:|"
    status=1
  fi
done
[ $status -eq 0 ] || echo "Personal data above: use placeholders (user@example.com, a made-up device name) instead of real addresses."
exit $status
