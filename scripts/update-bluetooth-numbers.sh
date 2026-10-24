#!/bin/sh
# Refreshes the bundled Bluetooth SIG numbers (company IDs, registered service UUIDs) from Nordic's open database.
# Pinned to a commit for reproducible builds; bump COMMIT to update. License: BSD-3-Clause, shipped alongside the data.
set -e
COMMIT=d379cc06c9c3681bc1c1cd4d61c246a0b0f80b0e  # 2026-09-02
BASE="https://raw.githubusercontent.com/NordicSemiconductor/bluetooth-numbers-database/$COMMIT"
OUT="$(cd "$(dirname "$0")/.." && pwd)/ios/DeskBar/BluetoothNumbers"
mkdir -p "$OUT"
for f in v1/company_ids.json v1/service_uuids.json LICENSE; do
  curl -fsSL "$BASE/$f" -o "$OUT/$(basename "$f" | sed 's/^LICENSE$/LICENSE-bluetooth-numbers-database.txt/')"
done
ls -l "$OUT"
