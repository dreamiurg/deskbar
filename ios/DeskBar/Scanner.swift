// Scans BLE for standing desks and reads their height, one connection at a time.
// Protocols (sources in the repo's commit history / mac main.swift header):
//  Jiecang (Uplift, Desky, Deskhouse, …): services FE60 (FE61 write / FE62 notify) or FF12 / FF00
//    (FF01 write / FF02 notify). Host frames F1 F1 op len data sum 7E, desk replies F2 F2 … 7E.
//    op 0x01 = height in tenths of display unit, op 0x0E = unit (0 cm, 1 in). Query 0x07 makes the
//    desk report without moving. Refs: librick/uplift-ble, j0rdsta/ha-desky, vakintosh/ha-desky-ble.
//  Linak / IKEA Idåsen: char 99FA0021, u16 LE in 0.1 mm above the desk's minimum height. Ref: newAM/idasen.
import ActivityKit
import CoreBluetooth
import CoreLocation
import Foundation
import UserNotifications

let linakAdv = CBUUID(string: "99FA0001-338A-1024-8A49-009C0215F78A")
let linakHeight = CBUUID(string: "99FA0021-338A-1024-8A49-009C0215F78A")
let jiecangServices = ["FE60", "FF12", "FF00", "00FF"].map { CBUUID(string: $0) }
let jiecangWrite = ["FE61", "FF01"].map { CBUUID(string: $0) }
let jiecangNotify = ["FE62", "FF02"].map { CBUUID(string: $0) }

final class Scanner: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate, CLLocationManagerDelegate {
  @Published var desks: [UUID: Desk] = [:]
  @Published var labels: [String: String] = UserDefaults.standard.dictionary(forKey: "labels") as? [String: String] ?? [:] {
    didSet { UserDefaults.standard.set(labels, forKey: "labels") }
  }
  @Published var pinned = Set(UserDefaults.standard.stringArray(forKey: "pinned") ?? []) {
    didSet { UserDefaults.standard.set(Array(pinned), forKey: "pinned") }
  }
  // Stored under "archived", the feature's earlier name, so desks hidden before keep their state.
  @Published var hidden = Set(UserDefaults.standard.stringArray(forKey: "archived") ?? []) {
    didSet { UserDefaults.standard.set(Array(hidden), forKey: "archived") }
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
  // Height control (Jiecang): one connection held open while a desk's controls are shown.
  @Published var controlling: UUID?
  @Published var controlReady = false  // connected and the desk's command channel found
  // Watch mode: a desk-only scan that keeps running in the background, alerts about desks this phone has never seen,
  // and feeds a Live Activity. Listening only; it never connects.
  @Published var watching = UserDefaults.standard.bool(forKey: "watching")
  @Published var watchUntil = UserDefaults.standard.object(forKey: "watchUntil") as? Date
  @Published var notificationsAllowed = true
  @Published var newToday = Set(UserDefaults.standard.stringArray(forKey: "newToday") ?? []) {
    didSet { UserDefaults.standard.set(Array(newToday), forKey: "newToday") }
  }
  private var newTodayDay = UserDefaults.standard.string(forKey: "newTodayDay") ?? ""
  private var knownIDs = Set(UserDefaults.standard.stringArray(forKey: "knownDesks") ?? [])  // every desk ever heard
  private var recentNew: [(UUID, Date)] = []  // new desks in the last minute, summarised in one alert
  private var watchTimer: Timer?
  private var activity: Activity<WatchAttributes>?
  private var activityUpdatedAt = Date.distantPast
  private var activityUpdateQueued = false
  static let deskServices = jiecangServices + [linakAdv]
  private var controlTx: CBCharacteristic?
  private var controlType: CBCharacteristicWriteType = .withResponse
  private var controlWritesPending = 0  // acknowledged writes still in flight (CoreBluetooth queues them in order)
  private var holdTimer: Timer?

  private var central: CBCentralManager!
  private var peripherals: [UUID: CBPeripheral] = [:]
  private var queue: [UUID] = []
  private var rssiShownAt: [UUID: Date] = [:]
  private var rssiAvg: [UUID: Double] = [:]  // smoothed: single readings jump ±5–10 dBm
  private var seenIDs: Set<UUID> = []
  private let locator = CLLocationManager()  // only runs during a pull-down scan, with the app open
  private var lastFix: CLLocation?
  private var probing: Set<UUID> = []  // sent Jiecang queries this read; waiting for a reply
  private var token = UUID()  // identifies the current read; delayed work from an older read is ignored
  private var reader = JiecangReader()
  private var rawTenths: Int?
  private var unit: UInt8?

  override init() {
    super.init()
    // Desks found on earlier scans, so the list isn't empty before the first pull-to-refresh.
    if let data = UserDefaults.standard.data(forKey: "desks"), let saved = try? JSONDecoder().decode([Desk].self, from: data) {
      // A failure from an earlier session isn't current; show the last good height instead.
      desks = Dictionary(
        uniqueKeysWithValues: saved.map {
          var d = $0; d.status = ""; d.problem = nil
          d.candidate = looksLikeDesk(name: d.name, services: d.services ?? [])  // re-check under the current rule
          return (d.id, d)
        })
    }
    forgetStale()
    if DemoData.enabled { loadDemo() }
    if knownIDs.isEmpty { knownIDs = Set(desks.keys.map(\.uuidString)) }  // desks found before Watch existed aren't "new"
    if let until = watchUntil, until < Date() { watching = false }
    activity = Activity<WatchAttributes>.activities.first
    UNUserNotificationCenter.current().getNotificationSettings { s in
      DispatchQueue.main.async { self.notificationsAllowed = s.authorizationStatus != .denied }
    }
    // Restore identifier: iOS can relaunch the app in the background for desk advertisements after it was suspended.
    central = CBCentralManager(delegate: self, queue: .main, options: [CBCentralManagerOptionRestoreIdentifierKey: "deskbar"])
  }

  static let scanSeconds = 6

  // Created when the app process starts (see DeskBarApp.init), not when a window appears: a background relaunch for a
  // desk advertisement has no window, and CoreBluetooth restoration needs the restore-identifier central recreated.
  static let shared = Scanner()

  /// Pull-to-refresh: listen for advertisements, then read every desk heard (pinned and nearby, not hidden).
  func refresh() async {
    guard central.state == .poweredOn, !scanning, readTotal == 0, controlling == nil else { return }
    scanning = true
    seenIDs = []; seen = 0; seenDesks = 0
    scanStarted = Date()
    UserDefaults.standard.set(scanStarted, forKey: "scanStarted")
    central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
    startLocating()
    for s in stride(from: Self.scanSeconds, to: 0, by: -1) {
      secondsLeft = s
      do { try await Task.sleep(for: .seconds(1)) } catch { break }  // cancelled: stop early, never spin
    }
    central.stopScan()
    locator.stopUpdatingLocation()
    scanning = false
    resumeWatch()  // the pull-down scan replaced the watch scan; put it back
    let ids = desks.values
      .filter { seenIDs.contains($0.id) && $0.isDesk && !hidden.contains($0.id.uuidString) }
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

  /// Heard in the last pull-down scan or in the last 10 minutes (Watch mode).
  func isInRange(_ d: Desk) -> Bool {
    let heard = d.lastHeard ?? .distantPast
    return heard >= (scanStarted ?? .distantFuture) || heard > Date().addingTimeInterval(-600)
  }

  static let forgetAfterDays = 7

  /// Drops desks not heard for a week, except pinned or renamed ones (those are deliberate inventory).
  /// They stay "known", so one that comes back isn't announced as new.
  private func forgetStale() {
    let cutoff = Date().addingTimeInterval(-Double(Self.forgetAfterDays) * 86400)
    for (id, d) in desks where (d.lastHeard ?? d.readAt ?? .distantPast) < cutoff {
      let key = id.uuidString
      if !pinned.contains(key) && labels[key] == nil { desks[id] = nil }
    }
  }

  private func loadDemo() {
    let demo = DemoData.desks()
    desks = Dictionary(uniqueKeysWithValues: demo.map { ($0.id, $0) })
    labels = Dictionary(uniqueKeysWithValues: demo.compactMap { d in DemoData.labels[d.name].map { (d.id.uuidString, $0) } })
    pinned = Set(demo.prefix(1).map(\.id.uuidString))
    scanStarted = Date().addingTimeInterval(-60)
    lastRefresh = Date()
  }

  private func save() {
    guard !DemoData.enabled else { return }  // demo desks are never written over real ones
    forgetStale()
    let keep = desks.values.filter(\.isDesk)  // not every phone and earbud nearby
    UserDefaults.standard.set(try? JSONEncoder().encode(Array(keep)), forKey: "desks")
    // Desks found by a pull-down count as seen, so Watch won't later announce them as new.
    knownIDs.formUnion(keep.map(\.id.uuidString))
    UserDefaults.standard.set(Array(knownIDs), forKey: "knownDesks")
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
    reader = JiecangReader(); rawTenths = nil; unit = nil
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
    if controlling == p.identifier {
      holdTimer?.invalidate(); holdTimer = nil
      controlling = nil; controlReady = false; controlTx = nil; controlWritesPending = 0
    }
    desks[p.identifier]?.status = status
    if readTotal > 0 { readDone += 1 }
    busy = nil
    central.cancelPeripheralConnection(p)
    next()
  }

  // MARK: Central

  func centralManagerDidUpdateState(_ c: CBCentralManager) {
    switch c.state {
    case .poweredOn:
      bluetoothProblem = nil  // idle until pull-to-refresh, unless Watch is on
      resumeWatch()
      updateActivity(force: true)
    case .unauthorized: bluetoothProblem = "Bluetooth access is off for DeskBar. Turn it on in Settings › DeskBar."
    case .poweredOff:
      bluetoothProblem = "Bluetooth is off."
      updateActivity(force: true)
    case .unsupported: bluetoothProblem = DemoData.enabled ? nil : "This device has no Bluetooth LE."
    default: bluetoothProblem = nil  // unknown/resetting: transient
    }
  }

  func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral, advertisementData a: [String: Any], rssi: NSNumber) {
    let ad = Advert(a, fallbackName: p.name)
    let firstThisScan = seenIDs.insert(p.identifier).inserted
    if firstThisScan {
      seen = seenIDs.count
      if ad.candidate || desks[p.identifier]?.isDesk == true { seenDesks += 1 }
    }
    if desks[p.identifier] == nil {
      addDevice(p, ad, rssi: rssi.intValue)
    } else {
      updateDevice(p, ad, rssi: rssi.doubleValue, firstThisScan: firstThisScan)
    }
  }

  private func addDevice(_ p: CBPeripheral, _ ad: Advert, rssi: Int) {
    // Skip nameless devices: phones and earbuds rotate private addresses, so keeping them grows without bound.
    guard ad.name != nil || ad.candidate else { return }
    peripherals[p.identifier] = p
    var d = Desk(
      id: p.identifier, name: ad.name ?? "Unnamed", rssi: rssi, candidate: ad.candidate,
      lastHeard: Date(), services: ad.services, maker: ad.maker,
      kind: Kind.guess(name: ad.name, mfg: ad.mfg, desk: ad.candidate), txPower: ad.txPower)
    noteLocation(&d)
    desks[p.identifier] = d
    if watching && ad.candidate { heardWhileWatching(p.identifier) }  // first sighting is exactly the case Watch alerts on
  }

  /// Averages readings (single ones jump ±5–10 dBm). Advertisements arrive many times a second, so the shown value
  /// is refreshed at most every 2 s; returns it when due, nil otherwise, to avoid redrawing on every packet.
  private func smoothRSSI(_ id: UUID, _ rssi: Double) -> Int? {
    let smoothed = rssiAvg[id].map { $0 * 0.7 + rssi * 0.3 } ?? rssi
    rssiAvg[id] = smoothed
    guard Date().timeIntervalSince(rssiShownAt[id] ?? .distantPast) > 2 else { return nil }
    rssiShownAt[id] = Date()
    return Int(smoothed.rounded())
  }

  private func updateDevice(_ p: CBPeripheral, _ ad: Advert, rssi: Double, firstThisScan: Bool) {
    guard let old = desks[p.identifier] else { return }
    var d = old
    peripherals[p.identifier] = p
    // Once per scan, or on every report while watching (a pull-down already reports every packet).
    let fresh = firstThisScan || (watching && !scanning)
    if fresh { d.refresh(from: ad) }
    let shownRSSI = smoothRSSI(p.identifier, rssi)
    if let r = shownRSSI {
      d.rssi = r
      noteLocation(&d)
    }
    if let name = ad.name { d.name = name }
    // Re-judged on every update, so a device misclassified by an older rule drops out of Desks.
    d.candidate = looksLikeDesk(name: d.name, services: d.services ?? ad.services)
    if d != old { desks[p.identifier] = d }  // publishing redraws the list: only on a real change
    if fresh, watching, d.isDesk { heardWhileWatching(p.identifier) }
  }

  // MARK: Location

  private func startLocating() {
    locator.delegate = self
    locator.desiredAccuracy = kCLLocationAccuracyBest
    if locator.authorizationStatus == .notDetermined { locator.requestWhenInUseAuthorization() }
    locator.startUpdatingLocation()  // no-op without permission; the scan works the same either way
  }

  func locationManager(_ m: CLLocationManager, didUpdateLocations locations: [CLLocation]) { lastFix = locations.last }

  func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {
    if scanning { m.startUpdatingLocation() }  // permission granted mid-scan
  }

  /// Saves where the phone is if this is the closest the desk has sounded. Skips stale or vague fixes (indoor GPS
  /// above 100 m is not worth keeping).
  private func noteLocation(_ d: inout Desk) {
    guard d.isDesk, let fix = lastFix, fix.horizontalAccuracy > 0, fix.horizontalAccuracy < 100,
      Date().timeIntervalSince(fix.timestamp) < 60,
      shouldReplaceLocation(savedRSSI: d.seenAt?.rssi, savedAt: d.seenAt?.at, newRSSI: d.rssi)
    else { return }
    d.seenAt = .init(
      latitude: fix.coordinate.latitude, longitude: fix.coordinate.longitude, accuracy: fix.horizontalAccuracy,
      rssi: d.rssi, at: Date())
  }

  func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
    desks[p.identifier]?.status = "Reading…"
    p.discoverServices(nil)
  }

  func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
    let d = desks[p.identifier]
    if d?.family == .linak || d?.services?.contains(linakAdv.uuidString) == true {
      return fail(
        p, "Linak desks must be paired with this iPhone first. Hold the desk's Bluetooth button until it blinks, then try again.",
        status: "Needs pairing")
    }
    fail(
      p,
      "Another phone or app may be connected to this desk. A desk accepts one connection at a time, "
        + "so close the other app (for example DeskBar on a Mac) and try again."
    )
  }

  func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
    if busy == p.identifier { fail(p, "The desk dropped the connection before answering. Try again.") }
  }

  // MARK: Peripheral

  func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
    let services = p.services ?? []
    if services.isEmpty {
      return fail(p, "This device exposes no Bluetooth services DeskBar can talk to.", status: "Not supported")
    }
    services.forEach { p.discoverCharacteristics(nil, for: $0) }
  }

  func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
    let chars = s.characteristics ?? []
    if let h = chars.first(where: { $0.uuid == linakHeight }) {
      desks[p.identifier]?.family = .linak
      return p.readValue(for: h)
    }
    if let tx = chars.first(where: { jiecangWrite.contains($0.uuid) }),
      let rx = chars.first(where: { jiecangNotify.contains($0.uuid) })
    {
      return queryJiecang(p, service: s, tx: tx, rx: rx)
    }
    // Unknown device: once every service is explored, report what it exposes so it can be identified later.
    let all = p.services ?? []
    if all.allSatisfy({ $0.characteristics != nil }), desks[p.identifier]?.family == .unknown, !probing.contains(p.identifier) {
      fail(
        p, "DeskBar can't read this device yet. It offers: " + all.map(\.uuid.uuidString).joined(separator: ", ") + ".",
        status: "Not supported")
    }
  }

  func peripheral(_ p: CBPeripheral, didWriteValueFor ch: CBCharacteristic, error: Error?) {
    if controlling == p.identifier { controlWritesPending = max(0, controlWritesPending - 1) }
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
    parseJiecang(p, reader.feed(v))
  }

  // Family is set only once an F2 F2 reply parses: PairLink desks share FF12/FF01/FF02 but speak another protocol.
  private func queryJiecang(_ p: CBPeripheral, service s: CBService, tx: CBCharacteristic, rx: CBCharacteristic) {
    p.setNotifyValue(true, for: rx)
    let type: CBCharacteristicWriteType = tx.properties.contains(.write) ? .withResponse : .withoutResponse
    if controlling == p.identifier {
      controlTx = tx
      controlType = type
      controlReady = true
    }
    // wake (FE60 uses 0xFE, FF* modules 0x00), then status query 0x07 and unit query 0x0E; none move the desk
    let wake: UInt8 = s.uuid == CBUUID(string: "FE60") ? 0xFE : 0x00
    for (i, op) in [wake, 0x07, 0x0E].enumerated() {
      later(0.3 * Double(i + 1)) { p.writeValue(jiecangFrame(op), for: tx, type: type) }
    }
    probing.insert(p.identifier)
  }

  private func parseJiecang(_ p: CBPeripheral, _ replies: [JiecangReply]) {
    let hadHeight = rawTenths != nil
    for r in replies {
      desks[p.identifier]?.family = .jiecang
      if let h = r.heightTenths { rawTenths = h }
      if let u = r.unit { unit = u }
    }
    guard let raw = rawTenths else { return }
    let inches = unit.map { $0 == 1 } ?? (raw < 550)  // no unit reply: 24–51 in vs 60–130 cm
    desks[p.identifier]?.cm = inches ? Double(raw) / 10 * 2.54 : Double(raw) / 10
    desks[p.identifier]?.shownUnit = inches ? "in" : "cm"
    desks[p.identifier]?.readAt = Date()
    if controlling == p.identifier { return }  // controls stay connected; heights keep streaming in while the desk moves
    if unit != nil {
      finish(p, "")
    } else if !hadHeight {
      later(1) { self.finish(p, "") }  // unit reply may not come
    }
  }
}

// MARK: - Watch mode

extension Scanner {

  func startWatching() {
    guard !watching else { return }
    watching = true
    watchUntil = Date().addingTimeInterval(8 * 3600)  // Live Activities can't outlive 8 h
    persistWatch()
    UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { ok, _ in
      DispatchQueue.main.async { self.notificationsAllowed = ok }
    }
    if ActivityAuthorizationInfo().areActivitiesEnabled, let until = watchUntil {
      activity = try? Activity.request(
        attributes: WatchAttributes(until: until),
        content: .init(state: watchState(), staleDate: until))
    }
    resumeWatch()
  }

  func stopWatching() {
    watching = false
    watchUntil = nil
    persistWatch()
    watchTimer?.invalidate(); watchTimer = nil
    if !scanning { central.stopScan() }
    let ending = activity
    activity = nil
    Task { await ending?.end(nil, dismissalPolicy: .immediate) }
  }

  /// (Re)starts the desk-only scan. iOS allows it in the background only with service UUIDs, and paces it itself.
  private func resumeWatch() {
    guard watching, central.state == .poweredOn else { return }
    central.scanForPeripherals(withServices: Self.deskServices, options: nil)
    watchTimer?.invalidate()
    // Every 5 min restart the scan so desks still in range report again; this is what keeps "nearby" current.
    // Timers only fire while iOS gives the app time; in the background that's whenever a desk wakes it.
    watchTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in self?.watchTick() }
  }

  private func watchTick() {
    guard watching else { return }
    if let until = watchUntil, until < Date() { return stopWatching() }
    if !scanning {
      central.stopScan()
      central.scanForPeripherals(withServices: Self.deskServices, options: nil)
    }
    updateActivity(force: true)
    save()  // keep lastHeard across relaunches
  }

  /// Records a desk heard while watching; desks this phone has never heard get an alert.
  private func heardWhileWatching(_ id: UUID) {
    let key = id.uuidString
    rollDay()
    if !knownIDs.contains(key) {
      knownIDs.insert(key)
      UserDefaults.standard.set(Array(knownIDs), forKey: "knownDesks")
      if !hidden.contains(key) {
        newToday.insert(key)
        recentNew = recentNew.filter { Date().timeIntervalSince($0.1) < 60 } + [(id, Date())]
        alertNewDesks()
      }
    }
    updateActivity(force: false)
  }

  // Posted immediately: a background wake can end before any delayed work runs. A fixed identifier makes desks found
  // within the same minute replace one alert ("3 new desks nearby") instead of stacking three.
  private func alertNewDesks() {
    let ids = recentNew.map { $0.0 }
    save()
    guard !ids.isEmpty, notificationsAllowed else { return }
    let content = UNMutableNotificationContent()
    if ids.count == 1, let d = desks[ids[0]] {
      content.title = "New desk nearby"
      content.body = "\(label(d)) · about \(d.feet) ft away"
    } else {
      content.title = "\(ids.count) new desks nearby"
      content.body = ids.compactMap { desks[$0].map(label) }.prefix(3).joined(separator: ", ")
    }
    UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "new-desks", content: content, trigger: nil))
  }

  /// Clears "new today" after midnight; called wherever the count is shown.
  func rollDay() {
    let today = Date().formatted(date: .numeric, time: .omitted)
    guard newTodayDay != today else { return }
    newTodayDay = today
    UserDefaults.standard.set(today, forKey: "newTodayDay")
    if !newToday.isEmpty { newToday = [] }
  }

  var nearbyDesks: [Desk] {
    let since = Date().addingTimeInterval(-600)
    return desks.values.filter { $0.isDesk && !hidden.contains($0.id.uuidString) && ($0.lastHeard ?? .distantPast) > since }
  }

  private func watchState() -> WatchAttributes.ContentState {
    rollDay()
    let near = nearbyDesks
    let closest = near.min { $0.feet < $1.feet }
    var state = WatchAttributes.ContentState(nearby: near.count, newToday: newToday.count)
    state.closestFeet = closest?.feet
    state.closestLabel = closest.map(label)
    state.lastHeard = near.compactMap(\.lastHeard).max()
    state.bluetoothOff = central.state == .poweredOff
    return state
  }

  // At most every 15 s unless forced: iOS rate-limits Live Activity updates and each one costs a little battery.
  private func updateActivity(force: Bool) {
    guard let a = activity else { return }
    let wait = 15 - Date().timeIntervalSince(activityUpdatedAt)
    if !force && wait > 0 {
      // Send the latest state once the window passes, so the lock screen never sits on an older count.
      if !activityUpdateQueued {
        activityUpdateQueued = true
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) {
          self.activityUpdateQueued = false; self.updateActivity(force: true)
        }
      }
      return
    }
    activityUpdatedAt = Date()
    let content = ActivityContent(state: watchState(), staleDate: watchUntil)
    Task { await a.update(content) }
  }

  private func persistWatch() {
    UserDefaults.standard.set(watching, forKey: "watching")
    UserDefaults.standard.set(watchUntil, forKey: "watchUntil")
  }

  func centralManager(_ c: CBCentralManager, willRestoreState dict: [String: Any]) {
    // Nothing to rebuild: the scan restarts from centralManagerDidUpdateState once Bluetooth is on.
  }
}

// MARK: - Height control

extension Scanner {

  func startControl(_ id: UUID) {
    guard busy == nil, let p = peripherals[id] ?? central.retrievePeripherals(withIdentifiers: [id]).first else { return }
    peripherals[id] = p
    controlling = id; controlReady = false; controlTx = nil
    busy = id
    token = UUID()
    reader = JiecangReader(); rawTenths = nil; unit = nil
    desks[id]?.problem = nil
    failed = nil
    p.delegate = self
    central.connect(p)
    later(12) {
      if !self.controlReady {
        self.fail(
          p,
          "Couldn't open the controls: the desk didn't answer. "
            + "Another phone or app may be connected to it (for example DeskBar on a Mac)."
        )
      }
    }
  }

  /// Stops the desk, then disconnects so other apps and phones can reach it again.
  func endControl() {
    guard let id = controlling, let p = peripherals[id] else { return }
    stopMoving()
    later(0.3) { self.finish(p, "") }  // let the stop frame go out before the connection closes
  }

  /// Press-and-hold: wake the controller, then repeat the move frame every 0.1 s like a held keypad button.
  /// Every movement works this way; releasing calls stopMoving().
  func hold(up: Bool) { holdRepeating(up ? 0x01 : 0x02) }

  /// Press-and-hold towards a preset height: the target frame repeats while held, so the desk stops on release
  /// (and also stops by itself on arrival).
  func hold(toward mm: Int) {
    guard (500...1400).contains(mm) else { return }
    holdRepeating(0x1B, [UInt8(mm >> 8), UInt8(mm & 0xFF)])
  }

  private func holdRepeating(_ op: UInt8, _ data: [UInt8] = []) {
    guard controlReady else { return }
    holdTimer?.invalidate()
    send(0xFE)
    let started = Date()
    holdTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
      // Safety net: if a release is ever missed, stop after 15 s instead of driving the desk to its limit.
      if Date().timeIntervalSince(started) > 15 { self?.stopMoving() } else { self?.sendMove(op, data) }
    }
  }

  func stopMoving() {
    holdTimer?.invalidate()
    holdTimer = nil
    send(0x2B)
  }

  private func send(_ op: UInt8, _ data: [UInt8] = []) {
    guard let id = controlling, let p = peripherals[id], let tx = controlTx else { return }
    if controlType == .withResponse { controlWritesPending += 1 }
    p.writeValue(jiecangFrame(op, data), for: tx, type: controlType)
  }

  /// Repeats of a held move skip a tick while the previous write is unacknowledged. Writes queue in order, so a
  /// backlog of moves would delay the stop on release; this keeps at most one move ahead of it.
  private func sendMove(_ op: UInt8, _ data: [UInt8]) {
    guard controlWritesPending == 0 else { return }
    send(op, data)
  }
}
