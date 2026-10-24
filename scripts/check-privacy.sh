#!/bin/sh
# Fails if personal identifiers would be published. gitleaks catches secrets (keys, tokens) but not personal data.
#   files  : email addresses and full Bluetooth/Wi-Fi MAC addresses in the given files (default: all tracked files)
#   authors: commit author/committer emails in a range must be GitHub/Anthropic noreply addresses (CI passes base..head)
# Usage: check-privacy.sh [files...]   |   check-privacy.sh --authors <git-range>   |   check-privacy.sh --git-email
set -e
ok_email='([0-9]+\+)?[A-Za-z0-9._-]+@users\.noreply\.github\.com|noreply@github\.com|noreply@anthropic\.com|[A-Za-z0-9._%+-]+@example\.(com|org|net)|[0-9]+\+[A-Za-z0-9_-]+\[bot\]@users\.noreply\.github\.com'
email='[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}'
mac='([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}'

case "$1" in
  --authors)
    bad=$(git log --format='%ae%n%ce' "$2" | sort -u | grep -Ev "^($ok_email)$" || true)
    [ -z "$bad" ] && exit 0
    echo "Commit author/committer emails must be noreply addresses. Found: $bad"
    echo "Fix: git config user.email '<id>+<login>@users.noreply.github.com', then amend/rebase the commits."
    exit 1 ;;
  --git-email)
    e=$(git config user.email || true)
    echo "$e" | grep -Eq "^($ok_email)$" && exit 0
    echo "git user.email is '$e'; commits made with it would publish it. Use your GitHub noreply address:"
    echo "  git config user.email '<id>+<login>@users.noreply.github.com'"
    exit 1 ;;
esac

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
