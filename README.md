# DeskBar
[![CI](https://github.com/dreamiurg/deskbar/actions/workflows/ci.yml/badge.svg)](https://github.com/dreamiurg/deskbar/actions/workflows/ci.yml)

> Control a Bluetooth standing desk from the Mac menu bar, and inventory and control desks nearby from an iPhone.

Works with desks using a **Jiecang** controller over Bluetooth (sold under Deskhouse, Uplift, Desky and other brands).
The iPhone app also reads **Linak** desks (IKEA Idåsen and others) and lists any Bluetooth device it can't read yet.

## Mac menu bar app

```bash
./build.sh
```

Builds `~/Applications/DeskBar.app` and starts it. The menu bar shows the desk's height; the menu has Stand / Sit presets,
Stop, "Save Current Height as…", Forget Desk and Open at Login. macOS asks for Bluetooth access on first launch.

## iPhone app

```bash
cd ios && xcodegen && open DeskBar.xcodeproj
```

Set your signing team, then run on a device. What it does:

- **Desks page:** pull down to scan; each desk shows an approximate distance, its height and a short ID. Tap to expand.
- **Height controls:** hold Raise, Lower, Sit or Stand; the desk stops when you lift your finger.
- **Watch mode:** a background scan for desks only, an alert for desks the phone hasn't seen before, and a Live Activity.
- **Export:** CSV of every desk with its height.

A desk accepts one Bluetooth connection at a time: quit the Mac app before using the phone on the same desk.

## Development

```bash
pre-commit install && pre-commit install --hook-type pre-push
make check
```

`make check` runs swift-format, SwiftLint, the complexity limits, the logic tests and a typecheck of both apps.
CI runs the parts that work on Linux; builds stay local because macOS runners are expensive.
Every merge to `main` is released automatically: breaking change → major, `feat:` → minor, anything else → patch
(`.github/workflows/release.yml`). Builds stamp in the latest tag, the commit count and the commit hash.

## Acknowledgements

Bluetooth company and service names come from Nordic Semiconductor's
[bluetooth-numbers-database](https://github.com/NordicSemiconductor/bluetooth-numbers-database) (BSD-3-Clause, license in
`ios/DeskBar/BluetoothNumbers/`). Refresh with `scripts/update-bluetooth-numbers.sh`.

## License

Private project.
