import SwiftUI

struct SearchView: View {
    var body: some View {
        NavigationStack {
            // Placeholder for M2 search UI.
            ContentUnavailableView("Search", systemImage: "magnifyingglass")
                .navigationTitle("Search")
        }
    }
}

#Preview {
    SearchView()
}
