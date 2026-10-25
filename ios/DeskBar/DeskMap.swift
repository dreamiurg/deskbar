import MapKit
import SwiftUI

// Desks at the spot where each one sounded closest. Indoor GPS is good to tens of metres, so each pin carries a circle
// of the fix's accuracy: it tells which part of a building or which site, not which of two neighbouring desks.
struct DeskMap: View {
  @ObservedObject var scanner: Scanner

  var placed: [Desk] {
    scanner.desks.values.filter { $0.isDesk && $0.seenAt != nil }.sorted { $0.id.uuidString < $1.id.uuidString }
  }

  var body: some View {
    Map(initialPosition: .automatic) {
      ForEach(placed) { d in
        if let s = d.seenAt {
          let spot = CLLocationCoordinate2D(latitude: s.latitude, longitude: s.longitude)
          MapCircle(center: spot, radius: max(s.accuracy, 5))
            .foregroundStyle(.blue.opacity(0.12))
            .stroke(.blue.opacity(0.4), lineWidth: 1)
          Annotation(scanner.label(d), coordinate: spot) {
            Text(d.cm == nil ? d.short : d.height)
              .font(.caption.weight(.semibold).monospacedDigit())
              .padding(.horizontal, 8).padding(.vertical, 4)
              .background(.blue, in: Capsule()).foregroundStyle(.white)
          }
        }
      }
      UserAnnotation()
    }
    .mapControls {
      MapUserLocationButton()
      MapCompass()
    }
    .overlay(alignment: .bottom) {
      if placed.isEmpty {
        Text("No desk positions yet. Pull down on the Desks page to scan; each desk is placed where it sounded closest.")
          .font(.footnote).padding(12)
          .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)).padding()
      }
    }
    .navigationTitle("Map")
    .navigationBarTitleDisplayMode(.inline)
  }
}
