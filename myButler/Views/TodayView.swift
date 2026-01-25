import SwiftUI

struct TodayView: View {
    var body: some View {
        NavigationStack {
            // Placeholder for M1; will show due items in M5.
            ContentUnavailableView("Today", systemImage: "sun.max")
                .navigationTitle("Today")
        }
    }
}

#Preview {
    TodayView()
}
