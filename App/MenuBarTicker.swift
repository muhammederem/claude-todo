import SwiftUI

/// Menu bar item: a checklist icon with the number of waiting tasks.
struct MenuBarTicker: View {
    @ObservedObject var store: TodoStore
    @ObservedObject var clock: TickerClock

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "checklist")
            if store.openCount > 0 { Text("\(store.openCount)") }
        }
    }
}
