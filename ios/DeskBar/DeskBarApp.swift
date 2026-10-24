import SwiftUI

@main
struct DeskBarApp: App {
  var body: some Scene { WindowGroup { ContentView() } }
}

struct ContentView: View {
  @StateObject var scanner = Scanner()
  @State var showAll = false
  @State var renaming: Desk?
  @State var nameText = ""

  var visible: [Desk] {
    scanner.desks.values
      .filter { showAll || $0.candidate || $0.family != .unknown }
      .sorted { $0.rssi > $1.rssi }
  }
  var pinned: [Desk] { visible.filter { scanner.pinned.contains($0.id.uuidString) } }
  var nearby: [Desk] { visible.filter { !scanner.pinned.contains($0.id.uuidString) && !scanner.archived.contains($0.id.uuidString) } }
  var archived: [Desk] { visible.filter { scanner.archived.contains($0.id.uuidString) } }

  var body: some View {
    NavigationStack {
      List {
        if !pinned.isEmpty { Section("Pinned") { ForEach(pinned, content: row) } }
        Section("Nearby") { ForEach(nearby, content: row) }
        if !archived.isEmpty {
          NavigationLink { List { ForEach(archived, content: row) }.navigationTitle("Archived") } label: {
            LabeledContent("Archived", value: "\(archived.count)")
          }
        }
        Section { } footer: { Text("Swipe right to pin, left to archive. Touch and hold to rename.") }
      }
      .overlay {
        if let problem = scanner.bluetoothProblem {
          ContentUnavailableView("Bluetooth unavailable", systemImage: "exclamationmark.triangle", description: Text(problem))
        } else if visible.isEmpty {
          ContentUnavailableView("Scanning…", systemImage: "antenna.radiowaves.left.and.right")
        }
      }
      .navigationTitle("Desks")
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          Toggle(isOn: $showAll) { Image(systemName: "line.3.horizontal.decrease.circle") }.toggleStyle(.button)
            .accessibilityLabel("Show all Bluetooth devices")
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
          Button("Read All") { scanner.read((pinned + nearby).map(\.id)) }
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

  func row(_ d: Desk) -> some View {
    let key = d.id.uuidString
    let isPinned = scanner.pinned.contains(key), isArchived = scanner.archived.contains(key)
    let pinButton = Button(isPinned ? "Unpin" : "Pin", systemImage: isPinned ? "pin.slash" : "pin") {
      scanner.pinned.formSymmetricDifference([key])
    }
    let archiveButton = Button(isArchived ? "Unarchive" : "Archive", systemImage: "archivebox") {
      scanner.archived.formSymmetricDifference([key])
    }
    return Button { scanner.read([d.id]) } label: {
      HStack {
        VStack(alignment: .leading, spacing: 1) {
          Text(scanner.label(d)).font(.subheadline.weight(.semibold)).lineLimit(1)
          (Text(d.family.rawValue + " · ") + Text(d.short).monospaced())
            .font(.caption).foregroundStyle(.secondary)
        }
        Spacer()
        if scanner.busy == d.id { ProgressView() } else if d.cm != nil {
          Text(d.height).font(.title3.weight(.semibold).monospacedDigit()).lineLimit(1)
        } else {
          Text(d.status.isEmpty ? "–" : d.status).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
      }
    }
    .foregroundStyle(.primary)
    .swipeActions(edge: .leading) { pinButton.tint(.orange) }
    .swipeActions(edge: .trailing) { archiveButton.tint(.indigo) }
    .contextMenu {
      Button("Read Now", systemImage: "arrow.clockwise") { scanner.read([d.id]) }
      Button("Rename…", systemImage: "pencil") { nameText = scanner.labels[key] ?? ""; renaming = d }
      pinButton
      archiveButton
    }
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
    let lines = visible.filter { $0.cm != nil }.map { d in
      [safe(scanner.label(d)), safe(d.name), d.family.rawValue, d.short, String(format: "%.1f", d.cm! / 2.54), String(format: "%.1f", d.cm!),
       "\(d.rssi)", d.readAt.map(iso.string) ?? "", d.id.uuidString]
        .map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"" }.joined(separator: ",")
    }
    return (["label,name,manufacturer,short_id,height_in,height_cm,rssi,read_at,id"] + lines).joined(separator: "\n")
  }
}
