// Logic checks for ios/Shared/DeskProtocol.swift. Plain asserts, no XCTest, so they run anywhere swiftc does
// (pre-push hook and Linux CI). Frames marked "captured" were recorded from a real Jiecang desk.
import Foundation

var failures = 0
func check(_ ok: Bool, _ what: String, line: Int = #line) {
  if !ok { failures += 1; print("FAIL line \(line): \(what)") }
}
func hex(_ s: String) -> Data { Data(stride(from: 0, to: s.count, by: 2).map { UInt8(s.dropFirst($0).prefix(2), radix: 16)! }) }

// Frames the desk accepted during reverse engineering.
check(jiecangFrame(0xFE) == hex("F1F1FE00FE7E"), "wake frame")
check(jiecangFrame(0x1B, [0x03, 0xF8]) == hex("F1F11B0203F8187E"), "move to 1016 mm, checksum wraps past 0xFF")

// Reader: captured height frame, 0x01EA = 49.0 inches in tenths.
var r = JiecangReader()
check(r.feed(hex("F2F2010301EA0FFE7E")).first?.heightTenths == 490, "captured height frame")
// Split across two notifications.
check(r.feed(hex("F2F20103")).isEmpty, "partial frame waits")
check(r.feed(hex("013E0F527E")).first?.heightTenths == 318, "rest of split frame completes it")
// Two frames merged into one notification: captured status frame then a unit reply (inches).
let merged = r.feed(hex("F2F2300100317E" + "F2F20E0101107E"))
check(merged.count == 2 && merged[1].unit == 1, "merged frames both parsed, unit = inches")
// Corrupt checksum is skipped and the next good frame still parses.
check(r.feed(hex("F2F2010301EA0F007E" + "F2F2010301EA0FFE7E")).map(\.heightTenths) == [490], "bad checksum skipped")
// Stray F2 F2 inside payload with a huge length must not stall the parser.
check(r.feed(hex("F2F2FFF0" + "F2F2010301EA0FFE7E")).first?.heightTenths == 490, "resync past bogus header")

// Distance model, calibrated on a desk: −69 dBm at ~2 ft, −76 dBm at ~3 ft; AirPods/tag at ~20 ft.
check(estimatedFeet(rssi: -69, oneMetre: Kind.desk.oneMetre) == 2, "desk at 2 ft")
check(estimatedFeet(rssi: -76, oneMetre: Kind.desk.oneMetre) == 4, "desk at ~3.6 ft")
check(estimatedFeet(rssi: -86, oneMetre: Kind.tag.oneMetre) == 20, "tag at ~21 ft rounds to 20")

// Device type guesses.
check(Kind.guess(name: "Jane's AirPods Pro", mfg: nil, desk: false) == .earbuds, "AirPods by name")
check(Kind.guess(name: nil, mfg: hex("4C0012020000"), desk: false) == .tag, "Find My by Apple Continuity type")
check(Kind.guess(name: "Office TV", mfg: nil, desk: true) == .desk, "desk wins")

// Desk detection: strong services alone, generic ones only with the "BLE Device" name.
check(looksLikeDesk(name: "BLE Device 9A1C27", services: ["FE60"]), "Jiecang/Lierda desk")
check(looksLikeDesk(name: nil, services: ["FE60"]), "FE60 alone is enough (background scans may lack the name)")
check(looksLikeDesk(name: "BLE Device AB12CD", services: ["00FF"]), "Uplift V3: generic service + desk module name")
check(!looksLikeDesk(name: "lime-413306575819", services: ["00FF", "00FF"]), "Lime scooter is not a desk")
check(!looksLikeDesk(name: nil, services: ["FF12"]), "generic service alone is not a desk")
check(looksLikeDesk(name: "Desky 1234", services: []), "desk name alone")

// Short IDs.
check(shortID(name: "BLE Device 9A1C27", fallback: "X") == "1C27", "MAC tail from Jiecang name")
check(shortID(name: "BLE Device-AE267F", fallback: "X") == "267F", "dash separator")
check(
  shortID(name: "Desk Cafe", fallback: "1F2E3D4C-5B6A-4978-8695-A4B3C2D1BF51") == "BF51", "hex word without digit is not a MAC")

// CSV formula safety.
check(csvSafe("=1+1") == "'=1+1", "formula prefixed")
check(csvSafe(" =cmd") == "' =cmd", "leading space prefixed")
check(csvSafe("BLE Device 9A1C27") == "BLE Device 9A1C27", "normal name unchanged")
check(csvSafe("") == "", "empty unchanged")

print(failures == 0 ? "all logic checks passed" : "\(failures) logic check(s) failed")
exit(failures == 0 ? 0 : 1)
