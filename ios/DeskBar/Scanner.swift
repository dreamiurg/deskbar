// Scans BLE for standing desks and reads their height, one connection at a time.
// Protocols (sources in the repo's commit history / mac main.swift header):
//  Jiecang (Uplift, Desky, Deskhouse, …): services FE60 (FE61 write / FE62 notify) or FF12 / FF00
//    (FF01 write / FF02 notify). Host frames F1 F1 op len data sum 7E, desk replies F2 F2 … 7E.
//    op 0x01 = height in tenths of display unit, op 0x0E = unit (0 cm, 1 in). Query 0x07 makes the
//    desk report without moving. Refs: librick/uplift-ble, j0rdsta/ha-desky, vakintosh/ha-desky-ble.
//  Linak / IKEA Idåsen: char 99FA0021, u16 LE in 0.1 mm above the desk's minimum height. Ref: newAM/idasen.
import CoreBluetooth
import Foundation

enum Family: String { case jiecang = "Jiecang", linak = "Linak", unknown = "Unknown" }

struct Desk: Identifiable {
  let id: UUID
  var name: String
  var rssi: Int
  var candidate: Bool  // advertises something desk-like
  var family: Family = .unknown
  var cm: Double?
  var shownUnit = "cm"
  var status = ""
  var readAt: Date?

  // iOS hides MAC addresses; Jiecang modules end their name with the MAC tail ("BLE Device 9A1C27"),
  // otherwise fall back to the end of the iOS-assigned identifier.
  var short: String {
    let tail = String(name.reversed().prefix { $0.isHexDigit }.reversed())
    return tail.count >= 4 ? String(tail.suffix(4)).uppercased() : String(id.uuidString.suffix(4))
  }

  var height: String {
    guard let cm else { return "–" }
    return shownUnit == "in" ? String(format: "%.1f″", cm / 2.54) : String(format: "%.1f cm", cm)
  }
}

let linakAdv = CBUUID(string: "99FA0001-338A-1024-8A49-009C0215F78A")
let linakHeight = CBUUID(string: "99FA0021-338A-1024-8A49-009C0215F78A")
let jiecangServices = ["FE60", "FF12", "FF00", "00FF"].map { CBUUID(string: $0) }
let jiecangWrite = ["FE61", "FF01"].map { CBUUID(string: $0) }
let jiecangNotify = ["FE62", "FF02"].map { CBUUID(string: $0) }
let deskNames = ["desk", "uplift", "jiecang", "desky", "apex", "ble device"]

func jiecangFrame(_ op: UInt8) -> Data { Data([0xF1, 0xF1, op, 0x00, op, 0x7E]) }

final class Scanner: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {
  @Published var desks: [UUID: Desk] = [:]
  @Published var labels: [String: String] = UserDefaults.standard.dictionary(forKey: "labels") as? [String: String] ?? [:] {
    didSet { UserDefaults.standard.set(labels, forKey: "labels") }
  }
  @Published var pinned = Set(UserDefaults.standard.stringArray(forKey: "pinned") ?? []) {
    didSet { UserDefaults.standard.set(Array(pinned), forKey: "pinned") }
  }
  @Published var archived = Set(UserDefaults.standard.stringArray(forKey: "archived") ?? []) {
    didSet { UserDefaults.standard.set(Array(archived), forKey: "archived") }
  }
  @Published var busy: UUID?

  private var central: CBCentralManager!
  private var peripherals: [UUID: CBPeripheral] = [:]
  private var queue: [UUID] = []
  private var buffer = Data()
  private var rawTenths: Int?
  private var unit: UInt8?

  override init() {
    super.init()
    central = CBCentralManager(delegate: self, queue: .main)
  }

  func label(_ d: Desk) -> String { labels[d.id.uuidString] ?? d.name }

  func read(_ ids: [UUID]) {
    queue += ids.filter { !queue.contains($0) && $0 != busy }
    next()
  }

  private func next() {
    guard busy == nil, !queue.isEmpty, let p = peripherals[queue.removeFirst()] else { return }
    busy = p.identifier
    buffer = Data(); rawTenths = nil; unit = nil
    desks[p.identifier]?.status = "Connecting…"
    p.delegate = self
    central.connect(p)
    let id = p.identifier
    DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak self] in
      if self?.busy == id { self?.finish(p, "No reply") }
    }
  }

  private func finish(_ p: CBPeripheral, _ status: String) {
    guard busy == p.identifier else { return }
    desks[p.identifier]?.status = status
    if status == "OK" { desks[p.identifier]?.readAt = Date() }
    busy = nil
    central.cancelPeripheralConnection(p)
    next()
  }

  // MARK: Central

  func centralManagerDidUpdateState(_ c: CBCentralManager) {
    if c.state == .poweredOn {
      c.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
    }
  }

  func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral, advertisementData a: [String: Any], rssi: NSNumber) {
    let name = (a[CBAdvertisementDataLocalNameKey] as? String) ?? p.name
    let services = (a[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]) ?? []
    let candidate = services.contains(linakAdv) || services.contains(where: jiecangServices.contains)
      || deskNames.contains { name?.lowercased().contains($0) == true }
    peripherals[p.identifier] = p
    if desks[p.identifier] == nil {
      guard name != nil || candidate else { return }  // skip anonymous beacons
      desks[p.identifier] = Desk(id: p.identifier, name: name ?? "Unnamed", rssi: rssi.intValue, candidate: candidate)
    } else {
      desks[p.identifier]!.rssi = rssi.intValue
      if let name { desks[p.identifier]!.name = name }
      desks[p.identifier]!.candidate = desks[p.identifier]!.candidate || candidate
    }
  }

  func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
    desks[p.identifier]?.status = "Reading…"
    p.discoverServices(nil)
  }

  func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
    finish(p, "Connect failed")  // often: another phone/app already holds the desk
  }

  func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
    if busy == p.identifier { finish(p, "Disconnected") }
  }

  // MARK: Peripheral

  func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
    let services = p.services ?? []
    if services.isEmpty { return finish(p, "No services") }
    services.forEach { p.discoverCharacteristics(nil, for: $0) }
  }

  func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
    let chars = s.characteristics ?? []
    if let h = chars.first(where: { $0.uuid == linakHeight }) {
      desks[p.identifier]?.family = .linak
      return p.readValue(for: h)
    }
    if let tx = chars.first(where: { jiecangWrite.contains($0.uuid) }),
       let rx = chars.first(where: { jiecangNotify.contains($0.uuid) }) {
      desks[p.identifier]?.family = .jiecang
      p.setNotifyValue(true, for: rx)
      let type: CBCharacteristicWriteType = tx.properties.contains(.write) ? .withResponse : .withoutResponse
      // wake (FE60 uses 0xFE, FF* modules 0x00), then status query 0x07 and unit query 0x0E; none move the desk
      let wake: UInt8 = s.uuid == CBUUID(string: "FE60") ? 0xFE : 0x00
      for (i, op) in [wake, 0x07, 0x0E].enumerated() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3 * Double(i + 1)) {
          p.writeValue(jiecangFrame(op), for: tx, type: type)
        }
      }
      return
    }
    // Unknown device: once every service is explored, report what it exposes so it can be identified later.
    let all = p.services ?? []
    if all.allSatisfy({ $0.characteristics != nil }), desks[p.identifier]?.family == .unknown {
      finish(p, "Unsupported: " + all.map(\.uuid.uuidString).joined(separator: ", "))
    }
  }

  func peripheral(_ p: CBPeripheral, didUpdateValueFor ch: CBCharacteristic, error: Error?) {
    guard let v = ch.value else { return }
    if ch.uuid == linakHeight {
      guard v.count >= 2 else { return finish(p, "Bad Linak data") }
      // ponytail: assumes the Idåsen's 62.0 cm minimum; other Linak frames have different bases
      desks[p.identifier]?.cm = 62.0 + Double(Int(v[0]) | Int(v[1]) << 8) / 100
      desks[p.identifier]?.shownUnit = "cm"
      return finish(p, "OK")
    }
    guard jiecangNotify.contains(ch.uuid) else { return }
    buffer += v
    parseJiecang(p)
  }

  // Frames can arrive split or merged: F2 F2 op len payload… sum 7E
  private func parseJiecang(_ p: CBPeripheral) {
    while let start = buffer.firstRange(of: Data([0xF2, 0xF2]))?.lowerBound {
      buffer = buffer[start...]
      let b = [UInt8](buffer)
      guard b.count >= 4, b.count >= 6 + Int(b[3]) else { return }  // wait for more bytes
      let len = Int(b[3]), payload = Array(b[4..<4 + len])
      buffer = Data(b[(6 + len)...])
      guard b[5 + len] == 0x7E else { continue }
      if b[2] == 0x01, len >= 2 { rawTenths = Int(payload[0]) << 8 | Int(payload[1]) }
      if b[2] == 0x0E, len >= 1 { unit = payload[0] }
    }
    guard let raw = rawTenths else { return }
    let inches = unit.map { $0 == 1 } ?? (raw < 550)  // no unit reply: 24–51 in vs 60–130 cm
    desks[p.identifier]?.cm = inches ? Double(raw) / 10 * 2.54 : Double(raw) / 10
    desks[p.identifier]?.shownUnit = inches ? "in" : "cm"
    if unit != nil { finish(p, "OK") } else {
      DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.finish(p, "OK") }  // unit reply may not come
    }
  }
}
