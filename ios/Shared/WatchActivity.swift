// Live Activity shown while Watch mode is on; shared by the app (which updates it) and the widget (which draws it).
import ActivityKit
import Foundation

struct WatchAttributes: ActivityAttributes {
  struct ContentState: Codable, Hashable {
    var nearby: Int  // desks heard in the last 10 min
    var newToday: Int
    var closestFeet: Int?
    var closestLabel: String?
    var lastHeard: Date?
    var bluetoothOff = false
  }
  var until: Date  // Live Activities last at most 8 h
}
