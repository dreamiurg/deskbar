# Publishing DeskBar on the App Store

DeskBar ships as one App Store app for iPhone and Mac (Universal Purchase), published by Dragontail Holdings, LLC.
The code stays open source; signing material and keys never enter this repo.

## What is in the repo

| Piece | Where |
| --- | --- |
| Bundle ID `io.dragontail.deskbar` (iPhone and Mac), widget `io.dragontail.deskbar.widget` | `ios/project.yml` |
| Mac App Store target `DeskBarMac`: App Sandbox + Bluetooth, hardened runtime, asset-catalog icon | `ios/project.yml`, `mac/` |
| Privacy manifests: no tracking, no collected data, UserDefaults reason CA92.1 | `ios/DeskBar/PrivacyInfo.xcprivacy`, `mac/PrivacyInfo.xcprivacy` |
| Bluetooth and location usage strings | `ios/project.yml` |
| Export compliance: `ITSAppUsesNonExemptEncryption = NO` (the apps have no network code) | `ios/project.yml` |
| Version from the latest `vX.Y.Z` tag, build number = commit count | `stamp-version.sh` |
| Archive and upload both apps | `scripts/appstore.sh` |

`./build.sh` still builds the quick, unsandboxed local Mac copy (`net.dreamiurg.deskbar`), separate from the store build.

## What stays out of the repo

- Apple team ID: `DEVELOPMENT_TEAM` in the environment, or `DRAGONTAIL_TEAM_ID` in Doppler (project `studio`, config `prd`).
- App Store Connect API key: `DRAGONTAIL_ASC_KEY_ID`, `DRAGONTAIL_ASC_ISSUER_ID`, `DRAGONTAIL_ASC_KEY_P8` (the .p8 contents) in
  the same Doppler config. `scripts/appstore.sh` writes the .p8 to a temp dir and deletes it on exit. Without the key it
  uses the Apple ID signed in to Xcode.
- Certificates and provisioning profiles: automatic signing creates and keeps them in the Mac's keychain and Xcode.
- `.gitignore` blocks `*.p8`, `*.p12`, `*.cer`, `*.mobileprovision`, `*.provisionprofile`; gitleaks and
  `scripts/check-privacy.sh` run on every commit and PR.

## Build and upload (on a Mac with Xcode, XcodeGen and the Doppler CLI)

```bash
git checkout main && git pull --tags
scripts/appstore.sh all            # archive + export both apps to ios/build-appstore
scripts/appstore.sh all --upload   # archive + upload to App Store Connect
```

## App Store Connect listing (paste-ready)

- **Name:** DeskBar: Standing Desk Remote (fall back to "DeskBar Desk Remote" if taken)
- **Subtitle:** Control your standing desk
- **Category:** Utilities; secondary Productivity
- **Price:** Free
- **Age rating:** 4+ (every answer None or No)
- **Copyright:** 2026 Dragontail Holdings, LLC
- **Keywords:** `sit stand,height,presets,bluetooth,menu bar,ergonomic,office,workstation,adjustable,raise,lower`
- **Support URL:** https://dragontail.io/support/
- **Marketing URL:** https://github.com/dreamiurg/deskbar
- **Privacy Policy URL:** https://dragontail.io/deskbar/privacy/
- **App Privacy:** Data Not Collected. Location is used only on the phone to place desks on the map and never leaves it.

**Description:**

```
I built DeskBar for the standing desk in my home office. It talks to the desk over Bluetooth, so the desk moves from my Mac's menu bar or my phone instead of the keypad.

On the Mac
DeskBar lives in the menu bar and shows the desk's height. The menu has Stand and Sit presets, Stop, and a way to save the current height as a preset. It can open at login.

On the iPhone
Pull down to scan for desks nearby. Each desk shows its height and a rough distance. Hold Raise, Lower, Sit or Stand to move a desk; it stops as soon as you let go. Watch mode keeps listening in the background and tells you when a new desk shows up. The map shows where each desk sounded closest, and you can export the list as CSV.

Which desks work
Desks with a Jiecang Bluetooth controller, sold under several brands, including DeskHaus, Uplift and Desky. The iPhone app also reads the height of Linak desks, such as IKEA Idåsen, and lists other Bluetooth devices it can't read yet.

A desk takes one Bluetooth connection at a time, so quit the Mac app before you use the phone on the same desk.

Privacy
No account, no ads, no analytics. Nothing leaves your device.

DeskBar is open source: github.com/dreamiurg/deskbar
```

**App Review notes:**

```
DeskBar controls Bluetooth standing desks that use a Jiecang controller, so moving a desk needs real hardware. A video of both apps finding and moving a desk: <video link>.
Background Bluetooth (bluetooth-central) is used only by Watch mode, which the user turns on: it scans for desk services, shows a Live Activity and stops after 8 hours.
Moving a desk asks for confirmation first, and the desk stops when the finger lifts.
No account and no sign-in. The apps make no network requests.
```

## Screenshots

- **iPhone 6.9"** (1320 × 2868, iPhone 17 Pro Max Simulator, launch argument `-DeskBarDemo YES` for made-up desks):
  1. Desks page, in range and seen earlier
  2. Expanded desk card
  3. Height controls
  4. Map
  5. Watch mode Live Activity on the Lock Screen
- **Mac** (2880 × 1800): the open DeskBar menu over a plain desktop, with a real desk connected (the Mac app has no demo mode).
- No iPad set: the app is iPhone-only.
