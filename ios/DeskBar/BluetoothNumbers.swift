// Names for Bluetooth SIG numbers from Nordic's open database (BSD-3-Clause; license file bundled next to the data).
// Refresh with scripts/update-bluetooth-numbers.sh.
import Foundation

enum BluetoothNumbers {
  private struct Company: Decodable {
    let code: Int
    let name: String
  }
  private struct Service: Decodable {
    let uuid: String
    let name: String
  }

  /// Company ID (first two bytes of manufacturer data, little-endian) → registered company name. About 4,000 entries.
  static let companies: [Int: String] =
    (load("company_ids", [Company].self) ?? []).reduce(into: [:]) { $0[$1.code] = $1.name }

  /// Standard GATT services. Nordic's list doesn't cover vendor-registered 16-bit IDs, so the desk one is added here.
  static let services: [String: String] =
    (load("service_uuids", [Service].self) ?? []).reduce(into: ["FE60": "Lierda, Jiecang desk module"]) {
      $0[$1.uuid.uppercased()] = $1.name
    }

  static func company(fromManufacturerData m: Data?) -> String? {
    guard let m, m.count >= 2 else { return nil }
    return companies[Int(m[m.startIndex]) | Int(m[m.startIndex + 1]) << 8]
  }

  /// "180A (Device Information)", or the bare UUID when it isn't a known service.
  static func describe(service uuid: String) -> String {
    services[uuid.uppercased()].map { "\(uuid) (\($0))" } ?? uuid
  }

  private static func load<T: Decodable>(_ name: String, _ type: T.Type) -> T? {
    guard let url = Bundle.main.url(forResource: name, withExtension: "json"), let data = try? Data(contentsOf: url) else {
      return nil
    }
    return try? JSONDecoder().decode(type, from: data)
  }
}
