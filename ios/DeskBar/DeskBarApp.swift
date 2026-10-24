import SwiftUI

@main
struct DeskBarApp: App {
  var body: some Scene { WindowGroup { ContentView() } }
}

struct ContentView: View {
  @StateObject var scanner = Scanner()
  @State var showAll = false
  @State var search = ""
  @State var expanded: Set<UUID> = []
  @State var showHidden = false
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
  func title(_ d: Desk) -> String { masked(d) ? "Apple device" : scanner.label(d) }

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
        withAnimation(.snappy) { expanded.formSymmetricDifference([d.id]) }
      } label: {
        HStack(spacing: 10) {
          VStack(alignment: .leading, spacing: 1) {
            Text(title(d)).font(.subheadline.weight(.semibold)).lineLimit(1)
            (Text((d.isDesk ? d.family.rawValue : d.maker ?? "Unknown maker") + " · ") + Text(d.short).monospaced()
              + Text(stale && d.isDesk ? " · not heard in last scan" : ""))
              .font(.caption).foregroundStyle(.secondary).lineLimit(1)
          }
          Spacer()
          if heard { Chip(text: "heard", tint: .blue) }
          if scanner.busy == d.id {
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
        // iOS pattern: one full-width primary action, then equal-width icon-over-label secondary actions.
        Group {
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
        .buttonStyle(.borderedProminent).controlSize(.large)
        HStack(spacing: 8) {
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
    .swipeActions(edge: .leading) { pinButton.tint(.orange) }
    .swipeActions(edge: .trailing) { hideButton.tint(.gray) }
    .contextMenu {
      if d.isDesk { Button("Read Now", systemImage: "arrow.clockwise") { scanner.read([d.id]) } }
      Button("Rename…", systemImage: "pencil", action: rename)
      pinButton
      hideButton
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
      let updated = scanner.lastRefresh.map { "Updated \($0.formatted(date: .omitted, time: .shortened)) · " } ?? ""
      Text("\(updated)\(deskCount) desk\(deskCount == 1 ? "" : "s") · pull down to scan")
        .font(.footnote).foregroundStyle(.secondary)
    }
  }

  func stat(_ n: Int, _ label: String) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text("\(n)").font(.title2.weight(.bold)).monospacedDigit()
      Text(label).font(.caption).foregroundStyle(.secondary)
    }
  }
}
