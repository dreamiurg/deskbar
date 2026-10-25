// Pure desk logic with no Bluetooth or UI dependencies, so it can be checked anywhere `swiftc` runs
// (see tests/run-logic-tests.sh): command frames, the reply parser, distance estimates, IDs and CSV safety.
import Foundation

// MARK: Jiecang protocol

/// Host → desk frame: F1 F1 op len data… sum 7E, where sum = (op + len + data) & 0xFF.
func jiecangFrame(_ op: UInt8, _ data: [UInt8] = []) -> Data {
  let body = [op, UInt8(data.count)] + data
  return Data([0xF1, 0xF1] + body + [UInt8(body.reduce(0) { $0 + Int($1) } & 0xFF), 0x7E])
}

struct JiecangReply: Equatable {
  let op: UInt8
  let payload: [UInt8]

  /// op 0x01: height in tenths of the keypad's display unit.
  var heightTenths: Int? { op == 0x01 && payload.count >= 2 ? Int(payload[0]) << 8 | Int(payload[1]) : nil }
  /// op 0x0E: keypad unit, 0 = cm, 1 = inches.
  var unit: UInt8? { op == 0x0E && !payload.isEmpty ? payload[0] : nil }
}

/// Desk → host frames (F2 F2 op len payload… sum 7E) can arrive split across notifications or several in one.
/// Bytes are buffered until a whole frame is in; corrupt or misaligned frames are skipped by resyncing.
struct JiecangReader {
  private var buffer = Data()

  mutating func feed(_ bytes: Data) -> [JiecangReply] {
    buffer += bytes
    var out: [JiecangReply] = []
    while let start = buffer.firstRange(of: Data([0xF2, 0xF2]))?.lowerBound {
      let b = [UInt8](buffer[start...])
      buffer = Data(b)
      guard b.count >= 4 else { break }  // wait for more bytes
      let len = Int(b[3])
      // Real replies are short; a huge length means this F2 F2 was payload, not a header: resync past it.
      if len > 32 { buffer = Data(b.dropFirst(2)); continue }
      guard b.count >= 6 + len else { break }
      let payload = Array(b[4..<4 + len])
      let sum = UInt8((Int(b[2]) + len + payload.reduce(0) { $0 + Int($1) }) & 0xFF)
      guard b[4 + len] == sum, b[5 + len] == 0x7E else { buffer = Data(b.dropFirst(2)); continue }
      buffer = Data(b[(6 + len)...])
      out.append(JiecangReply(op: b[2], payload: payload))
    }
    return out
  }
}

// MARK: Desk detection

/// Services that alone identify a desk controller: FE60 is registered to Lierda (the BLE module in Jiecang
/// controllers), and the 128-bit one is Linak's own.
let strongDeskServices: Set<String> = ["FE60", "99FA0001-338A-1024-8A49-009C0215F78A"]
/// Generic services also used by unrelated gadgets (00FF is the ESP32 sample-app default; Lime scooters advertise it),
/// so they only count together with the generic "BLE Device …" name these desk modules use.
let weakDeskServices: Set<String> = ["FF12", "FF00", "00FF"]
/// Names that alone say "desk".
let deskNameHints = ["desk", "uplift", "jiecang", "desky", "apex"]

func looksLikeDesk(name: String?, services: [String]) -> Bool {
  let n = name?.lowercased() ?? ""
  if services.contains(where: strongDeskServices.contains) || deskNameHints.contains(where: n.contains) { return true }
  return services.contains(where: weakDeskServices.contains) && n.hasPrefix("ble device")
}

// MARK: Where a desk was found

/// The phone's position when a desk sounded closest is the best estimate of where the desk is. A new fix replaces the
/// saved one only when the desk is clearly louder (3 dB, past normal jitter) or the saved one is over a week old.
func shouldReplaceLocation(savedRSSI: Int?, savedAt: Date?, newRSSI: Int, now: Date = Date()) -> Bool {
  guard let savedRSSI, let savedAt else { return true }
  return newRSSI >= savedRSSI + 3 || now.timeIntervalSince(savedAt) > 7 * 86400
}

// MARK: Distance

/// Log-distance model with an indoor path-loss exponent of about 2.7. `oneMetre` is the expected signal at 1 m for this
/// kind of device. Roughly ±50%: tells near from far, not a tape measure. Rounded to whole feet under 10, else to 5 ft.
func estimatedFeet(rssi: Int, oneMetre: Double) -> Int {
  let ft = pow(10, (oneMetre - Double(rssi)) / 27) * 3.28
  return max(1, ft < 10 ? Int(ft.rounded()) : Int((ft / 5).rounded()) * 5)
}

// Rough device type, guessed from the advertisement. Drives the distance estimate: a TV on mains power is much
// "louder" than a coin-cell tag, so the same dBm means very different distances.
enum Kind: String, Codable {
  case desk = "Desk", phone = "Phone, tablet or computer", watch = "Watch", earbuds = "Earbuds", tag = "Tracker tag"
  case tv = "TV or speaker", light = "Smart light", other = "Bluetooth device"

  /// Expected signal at 1 m (dBm). Fitted to measurements in a house: desk controller −69 dBm at 0.6 m through a wood
  /// top and metal frame; iPhone −52 at 0.6 m; TVs −68…−72 at ~5 m through a floor; AirPods −81 and a tag −86 at ~6.5 m
  /// through a floor and a drawer. Ballpark only.
  var oneMetre: Double {
    switch self {
    case .desk: -75
    case .phone: -58
    case .watch: -50
    case .earbuds: -60
    case .tag: -64
    case .tv: -52
    case .light, .other: -60
    }
  }

  var power: String {
    switch self {
    case .desk, .tv, .light: "plugged in"
    case .phone, .watch, .earbuds, .tag: "battery"
    case .other: "unknown power"
    }
  }

  /// Name hints first (they're specific), then Apple's Continuity message type, then "other".
  static func guess(name: String?, mfg: Data?, desk: Bool) -> Kind {
    if desk { return .desk }
    let n = name?.lowercased() ?? ""
    let hints: [(Kind, [String])] = [
      (.earbuds, ["airpods", "buds", "beats", "headphone", "earbud"]),
      (.watch, ["watch", "band", "fitbit", "garmin"]),
      (.tag, ["tag", "tile", "chipolo"]),
      (.tv, ["[tv]", " tv", "tv ", "homepod", "minipod", "sonos", "echo", "speaker", "soundbar", "roku"]),
      (.light, ["govee", "gvh", "ihoment", "hue", "light", "lamp", "bulb", "led", "strip"]),
      (.phone, ["iphone", "ipad", "macbook", "imac", "pixel", "galaxy", "phone", "laptop"]),
    ]
    if let hit = hints.first(where: { _, words in words.contains { n.contains($0) } }) { return hit.0 }
    // Apple Continuity: company 0x004C, then a message type byte.
    if let m = mfg, m.count >= 3, m[m.startIndex] == 0x4C, m[m.startIndex + 1] == 0x00 {
      switch m[m.startIndex + 2] {
      case 0x07: return .earbuds  // proximity pairing (AirPods, Beats)
      case 0x12: return .tag  // Find My (AirTag, or an offline Apple device)
      case 0x09: return .tv  // AirPlay target (Apple TV, HomePod)
      case 0x10, 0x0C: return .phone  // Nearby Info / Handoff
      default: break
      }
    }
    return .other
  }
}

// MARK: Identity and export

/// iOS hides MAC addresses; Jiecang modules end their name with the MAC tail ("BLE Device 9A1C27"). The last word
/// must be hex with a digit, so "Coffee" or "Desk Cafe" don't pass as MAC tails; otherwise use the iOS identifier.
func shortID(name: String, fallback: String) -> String {
  let tail = name.split(whereSeparator: { " -_".contains($0) }).last.map(String.init) ?? ""
  let mac = tail.count >= 4 && tail.allSatisfy(\.isHexDigit) && tail.contains(where: \.isNumber)
  return mac ? String(tail.suffix(4)).uppercased() : String(fallback.suffix(4))
}

/// Advertised names are set by whoever owns the device: keep spreadsheets from running them as formulas.
/// Checked per scalar: a leading space, tab or line break also gets the prefix, since " =x" evaluates in some apps.
func csvSafe(_ s: String) -> String {
  let skip = CharacterSet.whitespacesAndNewlines.union(.controlCharacters)
  let risky = s.unicodeScalars.first.map { skip.contains($0) || "=+-@".unicodeScalars.contains($0) } ?? false
  return risky ? "'" + s : s
}
