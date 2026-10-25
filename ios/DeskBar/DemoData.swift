// Made-up desks for screenshots and the simulator (which has no Bluetooth). Launch with `-DeskBarDemo YES`.
// Names, IDs and positions are invented; positions sit around a public park.
import Foundation

enum DemoData {
  static var enabled: Bool { UserDefaults.standard.bool(forKey: "DeskBarDemo") }

  static func desks(now: Date = Date()) -> [Desk] {
    func desk(
      _ name: String, rssi: Int, inches: Double?, family: Family = .jiecang, heardAgo: TimeInterval = 5,
      at offset: (Double, Double)
    ) -> Desk {
      var d = Desk(id: UUID(), name: name, rssi: rssi, candidate: true)
      d.family = family
      d.cm = inches.map { $0 * 2.54 }
      d.shownUnit = family == .linak ? "cm" : "in"
      d.readAt = inches == nil ? nil : now.addingTimeInterval(-heardAgo)
      d.lastHeard = now.addingTimeInterval(-heardAgo)
      d.services = [family == .linak ? "99FA0001-338A-1024-8A49-009C0215F78A" : "FE60"]
      d.kind = .desk
      d.seenAt = .init(
        latitude: 47.6205 + offset.0, longitude: -122.3493 + offset.1, accuracy: 18, rssi: rssi, at: d.lastHeard!)
      return d
    }
    return [
      desk("BLE Device 7F2A21", rssi: -71, inches: 43.0, at: (0.0001, 0.0002)),
      desk("BLE Device 51A0C3", rssi: -79, inches: 29.5, at: (0.0003, -0.0002)),
      desk("Desk 4821", rssi: -84, inches: 74.0 / 2.54, family: .linak, at: (-0.0002, 0.0004)),
      desk("BLE Device E81224", rssi: -90, inches: 41.0, at: (-0.0004, -0.0003)),
      desk("BLE Device 0A77B5", rssi: -95, inches: 30.1, heardAgo: 2 * 3600, at: (0.0006, 0.0006)),
    ]
  }

  static let labels = ["BLE Device 7F2A21": "Desk 12 · 3rd floor", "BLE Device 51A0C3": "Desk 9", "Desk 4821": "Desk 7 · Idåsen"]
}
