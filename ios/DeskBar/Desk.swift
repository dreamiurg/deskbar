// What the app knows about one Bluetooth device (a desk, or any other device when "show all" is on).
import CoreBluetooth
import Foundation

enum Family: String, Codable { case jiecang = "Jiecang", linak = "Linak", unknown = "Unknown" }

struct Desk: Identifiable, Codable, Equatable {
  let id: UUID
  var name: String
  var rssi: Int
  var candidate: Bool  // advertises something desk-like
  var family: Family = .unknown
  var cm: Double?
  var shownUnit = "cm"
  var status = ""  // short chip text: "Reading…", "Couldn't read", "Not supported"
  var problem: String?  // plain-language reason after a failed read
  var readAt: Date?
  var lastHeard: Date?
  var services: [String]?  // advertised service UUIDs (optional so desks saved by older builds still decode)
  var maker: String?  // from the advertisement's company ID, when known
  var kind: Kind?  // optional so desks saved by older builds still decode
  var txPower: Int?  // advertised transmit power, when the device includes it
  var seenAt: SeenAt?  // where the phone was when this desk sounded closest

  struct SeenAt: Codable, Equatable {
    var latitude: Double
    var longitude: Double
    var accuracy: Double  // metres, from the phone's GPS fix
    var rssi: Int
    var at: Date
  }

  var isDesk: Bool { candidate || family != .unknown }

  var type: Kind { isDesk ? .desk : kind ?? .other }

  // Log-distance model, indoor path-loss exponent ≈ 2.7, with a per-type signal at 1 m (or the device's own advertised
  // transmit power minus the ~41 dB lost over the first metre). Roughly ±50%: tells near from far, not a tape measure.
  var feet: Int { estimatedFeet(rssi: rssi, oneMetre: txPower.map { Double($0) - 41 } ?? type.oneMetre) }

  var place: String { feet <= 5 ? "within a few feet" : feet <= 12 ? "nearby" : feet <= 25 ? "same room" : "far" }

  var signal: String { "\(rssi) dBm · \(place) (~\(feet) ft)" }

  // iOS hides MAC addresses; Jiecang modules end their name with the MAC tail ("BLE Device 9A1C27"),
  // otherwise fall back to the end of the iOS-assigned identifier.
  var short: String { shortID(name: name, fallback: id.uuidString) }

  static func inches(_ mm: Int) -> String { String(format: "%.1f″", Double(mm) / 25.4) }

  var height: String {
    guard let cm else { return "–" }
    return shownUnit == "in" ? String(format: "%.1f″", cm / 2.54) : String(format: "%.1f cm", cm)
  }
}

/// What one advertisement says about a device.
struct Advert {
  let name: String?
  let services: [String]
  let candidate: Bool  // advertises something desk-like
  let mfg: Data?
  let txPower: Int?
  let maker: String?

  init(_ a: [String: Any], fallbackName: String?) {
    name = (a[CBAdvertisementDataLocalNameKey] as? String) ?? fallbackName
    let uuids = (a[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]) ?? []
    services = uuids.map(\.uuidString)
    candidate = looksLikeDesk(name: name, services: services)
    mfg = a[CBAdvertisementDataManufacturerDataKey] as? Data
    txPower = (a[CBAdvertisementDataTxPowerLevelKey] as? NSNumber)?.intValue
    maker = BluetoothNumbers.company(fromManufacturerData: mfg)
  }
}

extension Desk {
  /// Updates what an advertisement can tell us; called once per scan (or per report while watching).
  mutating func refresh(from ad: Advert) {
    lastHeard = Date()
    if !ad.services.isEmpty { services = ad.services }
    if let m = ad.maker { maker = m }
    kind = Kind.guess(name: ad.name ?? name, mfg: ad.mfg, desk: isDesk || ad.candidate)
    if let t = ad.txPower { txPower = t }
  }
}
