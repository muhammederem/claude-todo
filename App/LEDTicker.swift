import SwiftUI

/// Animated wrapper for the panel header; the menu bar drives LEDMatrix from a clock instead.
struct LEDTicker: View {
    let text: String
    var pitch: CGFloat = 4
    var speed: Double = 10   // columns per second

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20)) { timeline in
            LEDMatrix(text: text, shift: Int(timeline.date.timeIntervalSinceReferenceDate * speed), pitch: pitch)
        }
    }
}
