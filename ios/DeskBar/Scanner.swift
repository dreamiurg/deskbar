// Scans BLE for standing desks and reads their height, one connection at a time.
// Protocols (sources in the repo's commit history / mac main.swift header):
//  Jiecang (Uplift, Desky, Deskhouse, …): services FE60 (FE61 write / FE62 notify) or FF12 / FF00
//    (FF01 write / FF02 notify). Host frames F1 F1 op len data sum 7E, desk replies F2 F2 … 7E.
//    op 0x01 = height in tenths of display unit, op 0x0E = unit (0 cm, 1 in). Query 0x07 makes the
//    desk report without moving. Refs: librick/uplift-ble, j0rdsta/ha-desky, vakintosh/ha-desky-ble.
//  Linak / IKEA Idåsen: char 99FA0021, u16 LE in 0.1 mm above the desk's minimum height. Ref: newAM/idasen.
import CoreBluetooth
import Foundation

enum Family: String, Codable { case jiecang = "Jiecang", linak = "Linak", unknown = "Unknown" }

struct Desk: Identifiable, Codable {
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

  var isDesk: Bool { candidate || family != .unknown }

  var signal: String {
    let place = rssi > -60 ? "near" : rssi > -75 ? "same room" : "far"
    return "\(rssi) dBm · \(place)"
  }

  // iOS hides MAC addresses; Jiecang modules end their name with the MAC tail ("BLE Device 9A1C27"),
  // otherwise fall back to the end of the iOS-assigned identifier.
  var short: String {
    // Last word must be hex with a digit, so "Coffee" or "Desk Cafe" don't pass as MAC tails.
    let tail = name.split(whereSeparator: { " -_".contains($0) }).last.map(String.init) ?? ""
    let mac = tail.count >= 4 && tail.allSatisfy(\.isHexDigit) && tail.contains(where: \.isNumber)
    return mac ? String(tail.suffix(4)).uppercased() : String(id.uuidString.suffix(4))
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
// Bluetooth SIG company IDs for makers common around an office. Apple devices advertise their owner's name, so they're shown by maker.
let makers: [UInt16: String] = [0x004C: "Apple", 0x0075: "Samsung", 0x0006: "Microsoft", 0x00E0: "Google", 0x0087: "Garmin", 0x012D: "Sony"]

// Same encoding as frame() in the mac app's main.swift.
func jiecangFrame(_ op: UInt8, _ data: [UInt8] = []) -> Data {
  let body = [op, UInt8(data.count)] + data
  return Data([0xF1, 0xF1] + body + [UInt8(body.reduce(0) { $0 + Int($1) } & 0xFF), 0x7E])
}

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
  @Published var bluetoothProblem: String?  // nil while Bluetooth is on and allowed
  // Pull-to-refresh progress
  @Published var scanning = false
  @Published var secondsLeft = 0
  @Published var seen = 0  // distinct Bluetooth devices heard this scan
  @Published var seenDesks = 0  // of those, desk-like ones
  @Published var readDone = 0
  @Published var readTotal = 0
  @Published var lastRefresh = UserDefaults.standard.object(forKey: "lastRefresh") as? Date
  @Published var scanStarted = UserDefaults.standard.object(forKey: "scanStarted") as? Date
  @Published var failed: UUID?  // last desk whose read failed, so the page can open its card

  private var central: CBCentralManager!
  private var peripherals: [UUID: CBPeripheral] = [:]
  private var queue: [UUID] = []
  private var rssiShownAt: [UUID: Date] = [:]
  private var seenIDs: Set<UUID> = []
  private var probing: Set<UUID> = []  // sent Jiecang queries this read; waiting for a reply
  private var token = UUID()  // identifies the current read; delayed work from an older read is ignored
  private var buffer = Data()
  private var rawTenths: Int?
  private var unit: UInt8?

  override init() {
    super.init()
    // Desks found on earlier scans, so the list isn't empty before the first pull-to-refresh.
    if let data = UserDefaults.standard.data(forKey: "desks"), let saved = try? JSONDecoder().decode([Desk].self, from: data) {
      // A failure from an earlier session isn't current; show the last good height instead.
      desks = Dictionary(uniqueKeysWithValues: saved.map { var d = $0; d.status = ""; d.problem = nil; return (d.id, d) })
    }
    central = CBCentralManager(delegate: self, queue: .main)
  }

  static let scanSeconds = 6

  /// Pull-to-refresh: listen for advertisements, then read every desk heard (pinned and nearby, not archived).
  func refresh() async {
    guard central.state == .poweredOn, !scanning, readTotal == 0 else { return }
    scanning = true
    seenIDs = []; seen = 0; seenDesks = 0
    scanStarted = Date()
    UserDefaults.standard.set(scanStarted, forKey: "scanStarted")
    central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
    for s in stride(from: Self.scanSeconds, to: 0, by: -1) {
      secondsLeft = s
      do { try await Task.sleep(for: .seconds(1)) } catch { break }  // cancelled: stop early, never spin
    }
    central.stopScan()
    scanning = false
    let ids = desks.values
      .filter { seenIDs.contains($0.id) && $0.isDesk && !archived.contains($0.id.uuidString) }
      .map(\.id)
    readDone = 0; readTotal = ids.count
    read(ids)
    // Reads finish on their own; if this task is cancelled, stop waiting instead of spinning on a throwing sleep.
    while busy != nil || !queue.isEmpty {
      do { try await Task.sleep(for: .milliseconds(200)) } catch { break }
    }
    readTotal = 0
    lastRefresh = Date()
    UserDefaults.standard.set(lastRefresh, forKey: "lastRefresh")
    save()
  }

  private func save() {
    let keep = desks.values.filter(\.isDesk)  // not every phone and earbud nearby
    UserDefaults.standard.set(try? JSONEncoder().encode(Array(keep)), forKey: "desks")
  }

  func label(_ d: Desk) -> String { labels[d.id.uuidString] ?? d.name }

  func read(_ ids: [UUID]) {
    queue += ids.filter { !queue.contains($0) && $0 != busy }
    next()
  }

  private func next() {
    guard busy == nil else { return }
    var found: CBPeripheral?
    while found == nil, !queue.isEmpty {
      let id = queue.removeFirst()
      found = peripherals[id] ?? central.retrievePeripherals(withIdentifiers: [id]).first  // desk saved from an earlier launch
    }
    guard let p = found else { return }
    busy = p.identifier
    token = UUID()
    buffer = Data(); rawTenths = nil; unit = nil
    desks[p.identifier]?.status = "Connecting…"
    desks[p.identifier]?.problem = nil
    failed = nil  // so a repeat failure of the same desk still reopens its card
    p.delegate = self
    central.connect(p)
    later(12) {
      self.fail(p, "The desk didn't answer within 12 seconds. It may be out of range, asleep, or a model DeskBar can't read yet.")
    }
  }

  // Runs `work` after `seconds` only if the same read is still in progress.
  private func later(_ seconds: Double, _ work: @escaping () -> Void) {
    let t = token
    DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
      if self?.token == t, self?.busy != nil { work() }
    }
  }

  private func fail(_ p: CBPeripheral, _ problem: String, status: String = "Couldn't read") {
    guard busy == p.identifier else { return }
    desks[p.identifier]?.problem = problem
    failed = p.identifier
    finish(p, status)
  }

  private func finish(_ p: CBPeripheral, _ status: String) {
    guard busy == p.identifier else { return }
    probing.remove(p.identifier)
    desks[p.identifier]?.status = status
    if readTotal > 0 { readDone += 1 }
    busy = nil
    central.cancelPeripheralConnection(p)
    next()
  }

  // MARK: Central

  func centralManagerDidUpdateState(_ c: CBCentralManager) {
    switch c.state {
    case .poweredOn: bluetoothProblem = nil  // idle until pull-to-refresh
    case .unauthorized: bluetoothProblem = "Bluetooth access is off for DeskBar. Turn it on in Settings › DeskBar."
    case .poweredOff: bluetoothProblem = "Bluetooth is off."
    case .unsupported: bluetoothProblem = "This device has no Bluetooth LE."
    default: bluetoothProblem = nil  // unknown/resetting: transient
    }
  }

  func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral, advertisementData a: [String: Any], rssi: NSNumber) {
    let name = (a[CBAdvertisementDataLocalNameKey] as? String) ?? p.name
    let services = (a[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]) ?? []
    let candidate = services.contains(linakAdv) || services.contains(where: jiecangServices.contains)
      || deskNames.contains { name?.lowercased().contains($0) == true }
    let mfg = a[CBAdvertisementDataManufacturerDataKey] as? Data
    let maker = mfg.flatMap { $0.count >= 2 ? makers[UInt16($0[$0.startIndex]) | UInt16($0[$0.startIndex + 1]) << 8] : nil }
    let firstThisScan = seenIDs.insert(p.identifier).inserted
    if firstThisScan {
      seen = seenIDs.count
      if candidate || desks[p.identifier]?.isDesk == true { seenDesks += 1 }
    }
    guard var d = desks[p.identifier] else {
      // Skip nameless devices: phones and earbuds rotate private addresses, so keeping them grows without bound.
      guard name != nil || candidate else { return }
      peripherals[p.identifier] = p
      desks[p.identifier] = Desk(id: p.identifier, name: name ?? "Unnamed", rssi: rssi.intValue, candidate: candidate,
                                 lastHeard: Date(), services: services.map(\.uuidString), maker: maker)
      return
    }
    peripherals[p.identifier] = p
    if firstThisScan {
      d.lastHeard = Date()
      if !services.isEmpty { d.services = services.map(\.uuidString) }
      if maker != nil { d.maker = maker }
    }
    // Advertisements arrive many times a second; publish (and redraw) only real changes, RSSI at most every 2 s.
    let rssiDue = Date().timeIntervalSince(rssiShownAt[p.identifier] ?? .distantPast) > 2
    if rssiDue { d.rssi = rssi.intValue; rssiShownAt[p.identifier] = Date() }
    if let name { d.name = name }
    d.candidate = d.candidate || candidate
    if firstThisScan || rssiDue || d.name != desks[p.identifier]!.name || d.candidate != desks[p.identifier]!.candidate {
      desks[p.identifier] = d
    }
  }

  func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
    desks[p.identifier]?.status = "Reading…"
    p.discoverServices(nil)
  }

  func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
    let d = desks[p.identifier]
    if d?.family == .linak || d?.services?.contains(linakAdv.uuidString) == true {
      return fail(p, "Linak desks must be paired with this iPhone first. Hold the desk's Bluetooth button until it blinks, then try again.", status: "Needs pairing")
    }
    fail(p, "Another phone or app may be connected to this desk. A desk accepts one connection at a time, so close the other app (for example DeskBar on a Mac) and try again.")
  }

  func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
    if busy == p.identifier { fail(p, "The desk dropped the connection before answering. Try again.") }
  }

  // MARK: Peripheral

  func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
    let services = p.services ?? []
    if services.isEmpty { return fail(p, "This device exposes no Bluetooth services DeskBar can talk to.", status: "Not supported") }
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
      // Family is set only once an F2 F2 reply parses: PairLink desks share FF12/FF01/FF02 but speak another protocol.
      p.setNotifyValue(true, for: rx)
      let type: CBCharacteristicWriteType = tx.properties.contains(.write) ? .withResponse : .withoutResponse
      // wake (FE60 uses 0xFE, FF* modules 0x00), then status query 0x07 and unit query 0x0E; none move the desk
      let wake: UInt8 = s.uuid == CBUUID(string: "FE60") ? 0xFE : 0x00
      for (i, op) in [wake, 0x07, 0x0E].enumerated() {
        later(0.3 * Double(i + 1)) { p.writeValue(jiecangFrame(op), for: tx, type: type) }
      }
      probing.insert(p.identifier)
      return
    }
    // Unknown device: once every service is explored, report what it exposes so it can be identified later.
    let all = p.services ?? []
    if all.allSatisfy({ $0.characteristics != nil }), desks[p.identifier]?.family == .unknown, !probing.contains(p.identifier) {
      fail(p, "DeskBar can't read this device yet. It offers: " + all.map(\.uuid.uuidString).joined(separator: ", ") + ".", status: "Not supported")
    }
  }

  func peripheral(_ p: CBPeripheral, didUpdateValueFor ch: CBCharacteristic, error: Error?) {
    guard let v = ch.value else { return }
    if ch.uuid == linakHeight {
      guard v.count >= 2 else { return fail(p, "The desk sent a height DeskBar couldn't decode.") }
      // ponytail: assumes the Idåsen's 62.0 cm minimum; other Linak frames have different bases
      desks[p.identifier]?.cm = 62.0 + Double(Int(v[0]) | Int(v[1]) << 8) / 100
      desks[p.identifier]?.shownUnit = "cm"
      desks[p.identifier]?.readAt = Date()
      return finish(p, "")
    }
    guard jiecangNotify.contains(ch.uuid) else { return }
    buffer += v
    parseJiecang(p)
  }

  // Frames can arrive split or merged: F2 F2 op len payload… sum 7E
  private func parseJiecang(_ p: CBPeripheral) {
    let hadHeight = rawTenths != nil
    while let start = buffer.firstRange(of: Data([0xF2, 0xF2]))?.lowerBound {
      buffer = buffer[start...]
      let b = [UInt8](buffer)
      guard b.count >= 4 else { return }  // wait for more bytes
      let len = Int(b[3])
      // Real replies are short; a huge length means this F2 F2 was payload, not a header: resync past it.
      if len > 32 { buffer = Data(b.dropFirst(2)); continue }
      guard b.count >= 6 + len else { return }
      let payload = Array(b[4..<4 + len])
      let sum = UInt8((Int(b[2]) + len + payload.reduce(0) { $0 + Int($1) }) & 0xFF)
      guard b[4 + len] == sum, b[5 + len] == 0x7E else { buffer = Data(b.dropFirst(2)); continue }
      buffer = Data(b[(6 + len)...])
      desks[p.identifier]?.family = .jiecang
      if b[2] == 0x01, len >= 2 { rawTenths = Int(payload[0]) << 8 | Int(payload[1]) }
      if b[2] == 0x0E, len >= 1 { unit = payload[0] }
    }
    guard let raw = rawTenths else { return }
    let inches = unit.map { $0 == 1 } ?? (raw < 550)  // no unit reply: 24–51 in vs 60–130 cm
    desks[p.identifier]?.cm = inches ? Double(raw) / 10 * 2.54 : Double(raw) / 10
    desks[p.identifier]?.shownUnit = inches ? "in" : "cm"
    desks[p.identifier]?.readAt = Date()
    if unit != nil { finish(p, "") } else if !hadHeight {
      later(1) { self.finish(p, "") }  // unit reply may not come
    }
  }
}
