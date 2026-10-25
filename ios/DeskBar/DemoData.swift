// Made-up desks for screenshots and the simulator (which has no Bluetooth). Launch with `-DeskBarDemo YES`.
// Names, IDs and positions are invented; positions sit around a public park.
import Foundation

enum DemoData {
  static var enabled: Bool { UserDefaults.standard.bool(forKey: "DeskBarDemo") }

  private struct Spec {
    let name: String
    let rssi: Int
    let inches: Double
    var family: Family = .jiecang
    var heardAgo: TimeInterval = 5
    let offset: (lat: Double, lon: Double)
  }

  private static let specs = [
    Spec(name: "BLE Device 7F2A21", rssi: -71, inches: 43.0, offset: (0.0001, 0.0002)),
    Spec(name: "BLE Device 51A0C3", rssi: -79, inches: 29.5, offset: (0.0003, -0.0002)),
    Spec(name: "Desk 4821", rssi: -84, inches: 74.0 / 2.54, family: .linak, offset: (-0.0002, 0.0004)),
    Spec(name: "BLE Device E81224", rssi: -90, inches: 41.0, offset: (-0.0004, -0.0003)),
    Spec(name: "BLE Device 0A77B5", rssi: -95, inches: 30.1, heardAgo: 2 * 3600, offset: (0.0006, 0.0006)),
  ]

  static func desks(now: Date = Date()) -> [Desk] {
    specs.map { spec in
      let heard = now.addingTimeInterval(-spec.heardAgo)
      var d = Desk(id: UUID(), name: spec.name, rssi: spec.rssi, candidate: true)
      d.family = spec.family
      d.cm = spec.inches * 2.54
      d.shownUnit = spec.family == .linak ? "cm" : "in"
      d.readAt = heard
      d.lastHeard = heard
      d.services = [spec.family == .linak ? "99FA0001-338A-1024-8A49-009C0215F78A" : "FE60"]
      d.kind = .desk
      d.seenAt = .init(
        latitude: 47.6205 + spec.offset.lat, longitude: -122.3493 + spec.offset.lon, accuracy: 18, rssi: spec.rssi,
        at: heard)
      return d
    }
  }

  static let labels = ["BLE Device 7F2A21": "Desk 12 · 3rd floor", "BLE Device 51A0C3": "Desk 9", "Desk 4821": "Desk 7 · Idåsen"]
}
