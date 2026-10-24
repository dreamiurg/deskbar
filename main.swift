// DeskBar: menu bar Stand/Sit presets for a Jiecang-controller desk (Lierda L-BTMEB95 BLE module).
// Protocol: write F1 F1 <cmd> <len> <data> <sum> 7E to FE61 (with response); desk notifies
// F2 F2 01 03 <hi> <lo> .. on FE62 with height in tenths of the display unit (inches here).
// Move-to-height (0x1B) takes millimetres. Ref: github.com/j0rdsta/ha-desky
import AppKit
import CoreBluetooth
import ServiceManagement

let service = CBUUID(string: "FE60")
let writeUUID = CBUUID(string: "FE61")
let notifyUUID = CBUUID(string: "FE62")

func frame(_ cmd: UInt8, _ data: [UInt8] = []) -> Data {
  let body = [cmd, UInt8(data.count)] + data
  return Data([0xF1, 0xF1] + body + [UInt8(body.reduce(0) { ($0 + Int($1)) } & 0xFF), 0x7E])
}

final class App: NSObject, NSApplicationDelegate, CBCentralManagerDelegate, CBPeripheralDelegate, NSMenuDelegate {
  let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
  var central: CBCentralManager!
  var desk: CBPeripheral?
  var tx: CBCharacteristic?
  var tenths: Int?  // current height, tenths of an inch (converted when the keypad shows cm)

  // Presets in mm. Defaults are the heights seen on first setup (49.0" / 31.8").
  var presets: [String: Int] {
    get { UserDefaults.standard.dictionary(forKey: "presets") as? [String: Int] ?? ["Stand": 1245, "Sit": 808] }
    set { UserDefaults.standard.set(newValue, forKey: "presets") }
  }

  func applicationDidFinishLaunching(_ n: Notification) {
    item.button?.title = "Desk …"
    item.menu = NSMenu()
    item.menu!.delegate = self
    central = CBCentralManager(delegate: self, queue: .main)
  }

  func menuNeedsUpdate(_ menu: NSMenu) {
    menu.removeAllItems()
    let ready = tx != nil
    func add(_ title: String, _ action: Selector, _ preset: String, _ enabled: Bool) {
      let mi = NSMenuItem(title: title, action: action, keyEquivalent: "")
      mi.representedObject = preset
      mi.isEnabled = enabled
      menu.addItem(mi)
    }
    for name in ["Stand", "Sit"] { add("\(name)  \(inches(presets[name]!))", #selector(go(_:)), name, ready) }
    menu.addItem(withTitle: "Stop", action: #selector(stop), keyEquivalent: "").isEnabled = ready
    menu.addItem(.separator())
    for name in ["Stand", "Sit"] { add("Save Current Height as \(name)", #selector(save(_:)), name, tenths != nil) }
    menu.addItem(.separator())
    menu.addItem(withTitle: "Forget Desk", action: #selector(forget), keyEquivalent: "")
    let login = NSMenuItem(title: "Open at Login", action: #selector(toggleLogin), keyEquivalent: "")
    login.state = SMAppService.mainApp.status == .enabled ? .on : .off
    menu.addItem(login)
    let info = Bundle.main.infoDictionary ?? [:]
    let field = { (key: String) in info[key] as? String ?? "?" }
    let version = "DeskBar \(field("CFBundleShortVersionString")) (\(field("CFBundleVersion")) · \(field("DeskBarCommit")))"
    menu.addItem(.separator())
    menu.addItem(withTitle: version, action: nil, keyEquivalent: "").isEnabled = false
    menu.addItem(withTitle: "Quit", action: #selector(NSApp.terminate), keyEquivalent: "q")
    menu.items.forEach { if $0.action != #selector(NSApp.terminate) { $0.target = self } }
  }

  func inches(_ mm: Int) -> String { String(format: "%.1f″", Double(mm) / 25.4) }

  func send(_ d: Data) { if let p = desk, let c = tx { p.writeValue(d, for: c, type: .withResponse) } }

  @objc func go(_ sender: NSMenuItem) {
    guard let name = sender.representedObject as? String, let mm = presets[name] else { return }
    send(frame(0xFE))  // wake: controller ignores commands while its display sleeps
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
      self.send(frame(0x1B, [UInt8(mm >> 8), UInt8(mm & 0xFF)]))
    }
  }

  @objc func stop() { send(frame(0x2B)) }

  @objc func save(_ sender: NSMenuItem) {
    guard let t = tenths, let name = sender.representedObject as? String else { return }
    presets[name] = Int((Double(t) * 2.54).rounded())
  }

  // Unpins the desk and connects to the next FE60 desk found (e.g. after replacing the controller).
  @objc func forget() {
    UserDefaults.standard.removeObject(forKey: "desk")
    if let p = desk { desk = nil; tx = nil; tenths = nil; central.cancelPeripheralConnection(p) }
    item.button?.title = "Desk …"
    central.scanForPeripherals(withServices: [service])
  }

  @objc func toggleLogin() {
    let s = SMAppService.mainApp
    if s.status == .enabled { try? s.unregister() } else { try? s.register() }
  }

  // MARK: Bluetooth

  func centralManagerDidUpdateState(_ c: CBCentralManager) {
    if c.state == .poweredOn { c.scanForPeripherals(withServices: [service]) } else { item.button?.title = "Desk ⚠︎" }
  }

  func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral, advertisementData: [String: Any], rssi: NSNumber) {
    // Pin to the first desk ever connected so a neighbor's FE60 device is never picked up.
    let pinned = UserDefaults.standard.string(forKey: "desk")
    guard pinned == nil || pinned == p.identifier.uuidString else { return }
    UserDefaults.standard.set(p.identifier.uuidString, forKey: "desk")
    c.stopScan()
    desk = p
    p.delegate = self
    c.connect(p)
  }

  func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) { p.discoverServices([service]) }

  func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
    guard p == desk else { return }  // a forgotten desk: don't reconnect
    tx = nil
    tenths = nil  // stale once disconnected; keeps Save from storing it
    item.button?.title = "Desk …"
    c.connect(p)  // pending connect: completes whenever the desk is back in range
  }

  func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) { c.connect(p) }

  func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
    p.services?.forEach { p.discoverCharacteristics([writeUUID, notifyUUID], for: $0) }
  }

  func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
    for ch in s.characteristics ?? [] {
      if ch.uuid == writeUUID { tx = ch }
      if ch.uuid == notifyUUID { p.setNotifyValue(true, for: ch) }
    }
    send(frame(0xFE))  // wake so the desk reports its height right away
  }

  func peripheral(_ p: CBPeripheral, didUpdateValueFor ch: CBCharacteristic, error: Error?) {
    guard let v = ch.value.map(Array.init), v.count >= 9, v[0] == 0xF2, v[1] == 0xF2, v[2] == 0x01, v[3] == 0x03 else { return }
    // Tenths of the keypad's display unit: 24–51″ reads as 240–510, 60–130 cm as 600–1300.
    let raw = Int(v[4]) << 8 | Int(v[5])
    let t = raw < 550 ? raw : Int((Double(raw) / 2.54).rounded())
    guard (200...600).contains(t) else { return }  // 20–60″: drop garbage frames; also keeps saved mm >> 8 within UInt8
    tenths = t
    item.button?.title = raw < 550 ? String(format: "↕ %.1f″", Double(raw) / 10) : String(format: "↕ %.1f cm", Double(raw) / 10)
  }
}

let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
