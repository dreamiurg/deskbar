import SwiftUI

@main
struct DeskBarApp: App {
  init() { _ = Scanner.shared }
  var body: some Scene { WindowGroup { ContentView() } }
}

struct ContentView: View {
  @ObservedObject var scanner = Scanner.shared
  @State var showAll = false
  @State var search = ""
  @State var expanded: Set<UUID> = []
  @State var showHidden = false
  @State var confirmControl: Desk?  // asks once per launch before the first move
  @State var controlConfirmed = false
  @AppStorage("sitMM") var sitMM = 711  // 28.0″
  @AppStorage("standMM") var standMM = 1067  // 42.0″
  @Environment(\.scenePhase) var scenePhase
  @State var renaming: Desk?
  @State var nameText = ""

  // Stable order: by label, never by signal (which changes every second and made rows jump).
  func list(_ include: (Desk) -> Bool) -> [Desk] {
    scanner.desks.values
      .filter { include($0) && matches($0) }
      .sorted { scanner.label($0).localizedStandardCompare(scanner.label($1)) == .orderedAscending }
  }
  func matches(_ d: Desk) -> Bool {
    search.isEmpty || [title(d), masked(d) ? "" : d.name, d.short].contains { $0.localizedCaseInsensitiveContains(search) }
  }
  func isPinned(_ d: Desk) -> Bool { scanner.pinned.contains(d.id.uuidString) }
  func isHidden(_ d: Desk) -> Bool { scanner.hidden.contains(d.id.uuidString) }

  var pinned: [Desk] { list { $0.isDesk && isPinned($0) } }
  var desks: [Desk] { list { $0.isDesk && !isPinned($0) && !isHidden($0) } }
  var others: [Desk] { showAll ? list { !$0.isDesk && !isHidden($0) } : [] }
  var hiddenDesks: [Desk] { list { isHidden($0) && !isPinned($0) } }

  var body: some View {
    NavigationStack {
      List {
        Section { StatusCard(scanner: scanner, deskCount: pinned.count + desks.count) }
        if !pinned.isEmpty { Section("Pinned") { ForEach(pinned, content: card) } }
        if !desks.isEmpty { Section("Desks · A–Z") { ForEach(desks, content: card) } }
        if !others.isEmpty { Section("Other devices · A–Z") { ForEach(others, content: card) } }
        if !hiddenDesks.isEmpty {
          // Out of the way at the bottom, collapsed until opened.
          Section {
            DisclosureGroup(isExpanded: $showHidden) {
              ForEach(hiddenDesks, content: card)
            } label: {
              LabeledContent("Hidden", value: "\(hiddenDesks.count)").foregroundStyle(.secondary)
            }
          }
        }
        Section { } footer: { Text("Tap a desk for details. Swipe right to pin, left to hide.") }
      }
      .overlay {
        if let problem = scanner.bluetoothProblem {
          ContentUnavailableView("Bluetooth unavailable", systemImage: "exclamationmark.triangle", description: Text(problem))
        } else if scanner.desks.isEmpty && !scanner.scanning && scanner.readTotal == 0 {
          ContentUnavailableView("No desks yet", systemImage: "arrow.down",
                                 description: Text("Pull down to scan for nearby desks."))
        }
      }
      .refreshable { await scanner.refresh() }
      .searchable(text: $search, prompt: "Search label or ID")
      .onChange(of: scanner.failed) { _, id in if let id { withAnimation { _ = expanded.insert(id) } } }
      .onChange(of: scenePhase) { _, phase in
        if phase != .active { scanner.endControl() }  // never leave a desk connected or moving
        if phase == .active { scanner.rollDay() }
      }
      .confirmationDialog("Move this desk?", isPresented: Binding(get: { confirmControl != nil }, set: { if !$0 { confirmControl = nil } }),
                          titleVisibility: .visible, presenting: confirmControl) { d in
        Button("Open Controls") { controlConfirmed = true; scanner.startControl(d.id) }
        Button("Cancel", role: .cancel) {}
      } message: { _ in
        Text("Make sure nothing and no one is in the desk's way. The desk stays connected to this phone until you tap Done.")
      }
      .navigationTitle("Desks")
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          Toggle(isOn: $showAll) { Image(systemName: "line.3.horizontal.decrease.circle") }.toggleStyle(.button)
            .accessibilityLabel("Show all Bluetooth devices")
        }
        ToolbarItem(placement: .topBarTrailing) {
          ShareLink(item: csv(), preview: SharePreview("desks.csv")).accessibilityLabel("Export CSV")
        }
      }
      .alert("Rename Desk", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
        TextField("e.g. Desk 12 · 3rd floor", text: $nameText)
        Button("Cancel", role: .cancel) {}
        Button("Save") { if let d = renaming { scanner.labels[d.id.uuidString] = nameText.isEmpty ? nil : nameText } }
      } message: {
        if let d = renaming { Text("\(d.family.rawValue) · \(d.short)") }
      }
    }
  }

  // Apple devices advertise their owner's name ("Jane's AirPods"); list them by maker instead.
  func masked(_ d: Desk) -> Bool { !d.isDesk && d.maker == "Apple" && scanner.labels[d.id.uuidString] == nil }
  func title(_ d: Desk) -> String {
    guard masked(d) else { return scanner.label(d) }
    switch d.type {
    case .earbuds: return "Apple earbuds"
    case .watch: return "Apple Watch"
    case .tag: return "Find My tag or device"
    case .tv: return "Apple TV or HomePod"
    case .phone: return "iPhone, iPad or Mac"
    default: return "Apple device"
    }
  }

  func card(_ d: Desk) -> some View {
    let key = d.id.uuidString
    let open = expanded.contains(d.id)
    let stale = scanner.scanStarted.map { (d.lastHeard ?? .distantPast) < $0 } ?? false
    let heard = scanner.scanning && !stale
    let pinButton = Button(isPinned(d) ? "Unpin" : "Pin", systemImage: isPinned(d) ? "pin.slash" : "pin") {
      scanner.pinned.formSymmetricDifference([key])
    }
    let hideButton = Button(isHidden(d) ? "Unhide" : "Hide", systemImage: isHidden(d) ? "eye" : "eye.slash") {
      withAnimation { scanner.hidden.formSymmetricDifference([key]) }
    }
    let rename = { nameText = scanner.labels[key] ?? ""; renaming = d }
    return VStack(alignment: .leading, spacing: 12) {
      Button {
        if open && scanner.controlling == d.id { scanner.endControl() }  // collapsing closes the controls
        withAnimation(.snappy) { expanded.formSymmetricDifference([d.id]) }
      } label: {
        HStack(spacing: 10) {
          VStack(alignment: .leading, spacing: 1) {
            Text(title(d)).font(.subheadline.weight(.semibold)).lineLimit(1)
            // Distance up front so you can tell which desk is which while walking around.
            (Text("~\(d.feet) ft · ").bold() + Text((d.isDesk ? d.family.rawValue : d.type.rawValue) + " · ") + Text(d.short).monospaced()
              + Text(stale && d.isDesk ? " · not heard in last scan" : ""))
              .font(.caption).foregroundStyle(.secondary).lineLimit(1)
          }
          Spacer()
          if heard { Chip(text: "heard", tint: .blue) }
          if scanner.newToday.contains(key) { Chip(text: "new", tint: .orange) }
          if scanner.busy == d.id && scanner.controlling != d.id {
            ProgressView()
          } else if d.cm != nil && d.problem == nil {
            Text(d.height).font(.title3.weight(.semibold).monospacedDigit())
              .foregroundStyle(stale ? .secondary : .primary)
          } else if !d.status.isEmpty && d.status != "Connecting…" && d.status != "Reading…" {
            Chip(text: d.status, tint: d.problem == nil ? .gray : .orange)
          }
          Image(systemName: "chevron.down").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            .rotationEffect(.degrees(open ? 180 : 0))
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityHint(open ? "Collapses details" : "Shows details")
      // Only the header: a long press anywhere in the card would steal the hold on Raise/Lower/presets.
      .contextMenu {
        if d.isDesk { Button("Read Now", systemImage: "arrow.clockwise") { scanner.read([d.id]) } }
        Button("Rename…", systemImage: "pencil", action: rename)
        pinButton
        hideButton
      }

      if open {
        if let problem = d.problem {
          VStack(alignment: .leading, spacing: 6) {
            Text(problem).font(.subheadline)
            if d.cm != nil, let at = d.readAt {
              Text("Last good reading: \(d.height), \(at.formatted(.relative(presentation: .named)))")
                .font(.caption).foregroundStyle(.secondary)
            }
          }
          .padding(12).frame(maxWidth: .infinity, alignment: .leading)
          .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
        }
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
          ForEach(details(d), id: \.0) { k, v in
            GridRow {
              Text(k).foregroundStyle(.secondary)
              Text(v).fontWeight(.medium).lineLimit(2)
            }
          }
        }
        .font(.footnote)
        if scanner.controlling == d.id {
          controls(d)
        }
        // iOS pattern: one full-width primary action, then equal-width icon-over-label secondary actions.
        if scanner.controlling != d.id { Group {
          if d.isDesk {
            Button { scanner.read([d.id]) } label: {
              Label(d.problem == nil ? "Read height" : "Try again", systemImage: "arrow.clockwise").frame(maxWidth: .infinity)
            }
            .disabled(scanner.busy == d.id)
          } else {
            Button {
              UIPasteboard.general.string = details(d).map { "\($0): \($1)" }.joined(separator: "\n")
            } label: {
              Label("Copy details", systemImage: "doc.on.doc").frame(maxWidth: .infinity)
            }
          }
        }
        .buttonStyle(.borderedProminent).controlSize(.large) }
        HStack(spacing: 8) {
          if d.family == .jiecang && scanner.controlling != d.id {
            ActionTile(title: "Control", icon: "arrow.up.and.down") {
              if controlConfirmed { scanner.startControl(d.id) } else { confirmControl = d }
            }
            .disabled(scanner.busy != nil)
          }
          ActionTile(title: "Rename", icon: "pencil", action: rename)
          ActionTile(title: isPinned(d) ? "Unpin" : "Pin", icon: isPinned(d) ? "pin.slash" : "pin") {
            scanner.pinned.formSymmetricDifference([key])
          }
          ActionTile(title: isHidden(d) ? "Unhide" : "Hide", icon: isHidden(d) ? "eye" : "eye.slash") {
            withAnimation { scanner.hidden.formSymmetricDifference([key]) }
          }
        }
      }
    }
    .padding(.vertical, 4)
    // No swipes while the desk is under control: a sideways drag on Raise/Lower must not turn into a swipe.
    .swipeActions(edge: .leading) { if scanner.controlling != d.id { pinButton.tint(.orange) } }
    .swipeActions(edge: .trailing) { if scanner.controlling != d.id { hideButton.tint(.gray) } }
  }

  // Live height plus hold-to-move, Stop and presets, shown while the desk is connected for control.
  @ViewBuilder func controls(_ d: Desk) -> some View {
    let ready = scanner.controlReady
    VStack(spacing: 10) {
      HStack(alignment: .firstTextBaseline) {
        Text(d.cm == nil ? "–" : d.height).font(.system(size: 40, weight: .bold)).monospacedDigit()
        if !ready { ProgressView().padding(.leading, 6); Text("Connecting…").font(.caption).foregroundStyle(.secondary) }
        Spacer()
        Button("Done") { scanner.endControl() }.buttonStyle(.bordered)
      }
      HStack(spacing: 8) {
        HoldButton(title: "Raise", icon: "arrow.up") { $0 ? scanner.hold(up: true) : scanner.stopMoving() }
        HoldButton(title: "Lower", icon: "arrow.down") { $0 ? scanner.hold(up: false) : scanner.stopMoving() }
      }
      .disabled(!ready)
      Button { scanner.stopMoving() } label: {
        Label("Stop", systemImage: "stop.fill").frame(maxWidth: .infinity)
      }
      .buttonStyle(.borderedProminent).tint(.red).controlSize(.large)
      HStack(spacing: 8) {
        preset("Sit", mm: $sitMM, d: d)
        preset("Stand", mm: $standMM, d: d)
      }
      .disabled(!ready)
      // Saving lives in its own menu: a long press on a preset is the hold-to-move gesture.
      Menu {
        Button("Save as Sit") { if let cm = d.cm { sitMM = Int((cm * 10).rounded()) } }
        Button("Save as Stand") { if let cm = d.cm { standMM = Int((cm * 10).rounded()) } }
      } label: {
        Label("Save current height as preset", systemImage: "square.and.arrow.down").font(.subheadline)
      }
      .disabled(d.cm == nil)
      Text("Every button moves the desk only while held; lift your finger to stop.")
        .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  // Hold to travel toward the preset; releasing stops the desk, same as Raise and Lower.
  func preset(_ name: String, mm: Binding<Int>, d: Desk) -> some View {
    HoldButton(title: "\(name) · \(Desk.inches(mm.wrappedValue))", icon: name == "Sit" ? "chair" : "figure.stand") {
      $0 ? scanner.hold(toward: mm.wrappedValue) : scanner.stopMoving()
    }
  }

  func details(_ d: Desk) -> [(String, String)] {
    let ago = { (t: Date?) in t?.formatted(.relative(presentation: .named)) ?? "never" }
    var rows: [(String, String)] = []
    if d.isDesk {
      rows.append(("Read", ago(d.readAt)))
      rows.append(("Controller", d.family == .unknown ? "Not identified yet" : d.family.rawValue))
      rows.append(("Keypad unit", d.cm == nil ? "–" : d.shownUnit == "in" ? "inches" : "centimetres"))
    } else {
      rows.append(("Type", "\(d.type.rawValue) · \(d.type.power)"))
      rows.append(("Maker", d.maker ?? "Unknown"))
    }
    rows.append(("Signal", d.signal))
    rows.append(("Bluetooth name", masked(d) ? "hidden (personal device)" : d.name))
    rows.append(("Services", (d.services ?? []).isEmpty ? "none advertised" : d.services!.joined(separator: ", ")))
    rows.append(("Last heard", ago(d.lastHeard)))
    rows.append(("ID", d.short))
    return rows
  }

  // Advertised names are set by whoever owns the device: keep spreadsheets from running them as formulas.
  // Checked per scalar: a leading space, tab or line break also gets the prefix, since " =x" evaluates in some apps.
  func safe(_ s: String) -> String {
    let skip = CharacterSet.whitespacesAndNewlines.union(.controlCharacters)
    let risky = s.unicodeScalars.first.map { skip.contains($0) || "=+-@".unicodeScalars.contains($0) } ?? false
    return risky ? "'" + s : s
  }

  static let iso = ISO8601DateFormatter()

  func csv() -> String {
    let iso = Self.iso
    // The whole inventory, regardless of the search box.
    let all = scanner.desks.values.filter { $0.isDesk && !isHidden($0) && $0.cm != nil }
      .sorted { scanner.label($0).localizedStandardCompare(scanner.label($1)) == .orderedAscending }
    let lines = all.map { d in
      [safe(scanner.label(d)), safe(d.name), d.family.rawValue, d.short, String(format: "%.1f", d.cm! / 2.54), String(format: "%.1f", d.cm!),
       "\(d.rssi)", d.readAt.map(iso.string) ?? "", d.id.uuidString]
        .map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"" }.joined(separator: ",")
    }
    return (["label,name,manufacturer,short_id,height_in,height_cm,rssi,read_at,id"] + lines).joined(separator: "\n")
  }
}

// Moves only while pressed: reports press and release so the desk stops the moment the finger lifts.
struct HoldButton: View {
  let title: String
  let icon: String
  let onPress: (Bool) -> Void
  var body: some View {
    Button {} label: {
      VStack(spacing: 4) {
        Image(systemName: icon).font(.title2.weight(.semibold))
        Text(title).font(.subheadline)
      }
      .frame(maxWidth: .infinity, minHeight: 64)
    }
    .buttonStyle(HoldStyle(onPress: onPress))
    .accessibilityHint("Hold to move the desk")
  }
}

struct HoldStyle: ButtonStyle {
  let onPress: (Bool) -> Void
  @Environment(\.isEnabled) var enabled
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .foregroundStyle(enabled ? Color.accentColor : .secondary)
      .background(configuration.isPressed ? Color.accentColor.opacity(0.25) : Color(.tertiarySystemFill),
                  in: RoundedRectangle(cornerRadius: 12))
      .onChange(of: configuration.isPressed) { _, pressed in onPress(pressed) }
  }
}

// Equal-width secondary action: icon over a short label, like the action rows in Apple's own apps.
struct ActionTile: View {
  let title: String
  let icon: String
  let action: () -> Void
  var body: some View {
    Button(action: action) {
      VStack(spacing: 4) {
        Image(systemName: icon).font(.body)
        Text(title).font(.caption).lineLimit(1).minimumScaleFactor(0.8)
      }
      .frame(maxWidth: .infinity, minHeight: 44)
    }
    .buttonStyle(.bordered)
  }
}

struct Chip: View {
  let text: String
  let tint: Color
  var body: some View {
    Text(text).font(.caption.weight(.semibold)).lineLimit(1)
      .padding(.horizontal, 8).padding(.vertical, 2)
      .background(tint.opacity(0.15), in: Capsule()).foregroundStyle(tint)
  }
}

// Top of the Desks page: what the app is doing right now.
struct StatusCard: View {
  @ObservedObject var scanner: Scanner
  let deskCount: Int

  var body: some View {
    if scanner.scanning {
      VStack(alignment: .leading, spacing: 10) {
        HStack {
          Label("Scanning nearby…", systemImage: "dot.radiowaves.left.and.right").font(.headline)
          Spacer()
          Text("\(scanner.secondsLeft) s").monospacedDigit().foregroundStyle(.secondary)
        }
        ProgressView(value: Double(Scanner.scanSeconds - scanner.secondsLeft), total: Double(Scanner.scanSeconds))
        HStack(alignment: .firstTextBaseline, spacing: 24) {
          stat(scanner.seen, "Bluetooth devices heard")
          stat(scanner.seenDesks, "desks found")
        }
        Text("Next: read each desk found, one at a time.").font(.caption).foregroundStyle(.secondary)
      }
      .padding(.vertical, 4)
    } else if scanner.readTotal > 0 {
      VStack(alignment: .leading, spacing: 10) {
        HStack {
          Text("Reading desk \(min(scanner.readDone + 1, scanner.readTotal)) of \(scanner.readTotal)…").font(.headline)
          Spacer()
          if let id = scanner.busy, let d = scanner.desks[id] {
            Text(scanner.label(d)).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
          }
        }
        ProgressView(value: Double(scanner.readDone), total: Double(scanner.readTotal))
      }
      .padding(.vertical, 4)
    } else {
      VStack(alignment: .leading, spacing: 10) {
        Toggle(isOn: Binding(get: { scanner.watching }, set: { $0 ? scanner.startWatching() : scanner.stopWatching() })) {
          VStack(alignment: .leading, spacing: 2) {
            Label("Watch for desks", systemImage: "dot.radiowaves.left.and.right").font(.headline)
            Text(watchSubtitle).font(.caption).foregroundStyle(.secondary)
          }
        }
        .tint(.green)
        if scanner.watching { TimelineView(.periodic(from: .now, by: 60)) { _ in
          let near = scanner.nearbyDesks
          HStack(alignment: .firstTextBaseline, spacing: 24) {
            stat(near.count, "desks nearby")
            stat(scanner.newToday.count, "new today")
            VStack(alignment: .leading, spacing: 2) {
              Text(near.compactMap(\.lastHeard).max()?.formatted(date: .omitted, time: .shortened) ?? "–")
                .font(.title2.weight(.bold)).monospacedDigit()
              Text("last heard").font(.caption).foregroundStyle(.secondary)
            }
          }
        } }
        let updated = scanner.lastRefresh.map { "Updated \($0.formatted(date: .omitted, time: .shortened)) · " } ?? ""
        Text("\(updated)\(deskCount) desk\(deskCount == 1 ? "" : "s") · pull down to scan and read heights")
          .font(.footnote).foregroundStyle(.secondary)
      }
      .padding(.vertical, 4)
    }
  }

  var watchSubtitle: String {
    guard scanner.watching else { return "Alerts when a desk this phone hasn't seen comes into range. Listens only." }
    let until = scanner.watchUntil.map { " · ends \($0.formatted(date: .omitted, time: .shortened))" } ?? ""
    return (scanner.notificationsAllowed ? "Alerts on for new desks" : "Notifications are off in Settings; watching without alerts") + until
  }

  func stat(_ n: Int, _ label: String) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text("\(n)").font(.title2.weight(.bold)).monospacedDigit()
      Text(label).font(.caption).foregroundStyle(.secondary)
    }
  }
}
