import ActivityKit
import SwiftUI
import WidgetKit

@main
struct DeskBarWidgets: WidgetBundle {
  var body: some Widget { WatchLiveActivity() }
}

struct WatchLiveActivity: Widget {
  var body: some WidgetConfiguration {
    ActivityConfiguration(for: WatchAttributes.self) { context in
      LockScreenView(state: context.state, until: context.attributes.until)
        .padding(16)
        .activityBackgroundTint(Color.black.opacity(0.75))
    } dynamicIsland: { context in
      let s = context.state
      return DynamicIsland {
        DynamicIslandExpandedRegion(.leading) {
          Label("Watching", systemImage: "dot.radiowaves.left.and.right").font(.subheadline.weight(.semibold))
        }
        DynamicIslandExpandedRegion(.trailing) {
          Text("until \(context.attributes.until.formatted(date: .omitted, time: .shortened))")
            .font(.caption).foregroundStyle(.secondary)
        }
        DynamicIslandExpandedRegion(.bottom) { Stats(state: s) }
      } compactLeading: {
        Image(systemName: "dot.radiowaves.left.and.right").foregroundStyle(.green)
      } compactTrailing: {
        Text(s.bluetoothOff ? "off" : "\(s.nearby)").monospacedDigit()
      } minimal: {
        Text("\(s.nearby)").monospacedDigit().foregroundStyle(.green)
      }
    }
  }
}

struct LockScreenView: View {
  let state: WatchAttributes.ContentState
  let until: Date
  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Label("Watching for desks", systemImage: "dot.radiowaves.left.and.right").font(.headline)
        Spacer()
        Text("until \(until.formatted(date: .omitted, time: .shortened))").font(.caption).foregroundStyle(.secondary)
      }
      if state.bluetoothOff {
        Text("Bluetooth is off. Turn it on to keep watching.").font(.subheadline)
      } else {
        Stats(state: state)
        if let t = state.lastHeard {
          Text("Last heard \(t.formatted(date: .omitted, time: .shortened))\(state.closestLabel.map { " · \($0) is closest" } ?? "")")
            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
      }
    }
    .foregroundStyle(.white)
  }
}

struct Stats: View {
  let state: WatchAttributes.ContentState
  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 24) {
      stat("\(state.nearby)", "nearby", .white)
      stat("\(state.newToday)", "new today", .orange)
      stat(state.closestFeet.map { "~\($0) ft" } ?? "–", "closest", .white)
    }
  }
  func stat(_ value: String, _ label: String, _ color: Color) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(value).font(.title2.weight(.bold)).monospacedDigit().foregroundStyle(color)
      Text(label).font(.caption).foregroundStyle(.secondary)
    }
  }
}
