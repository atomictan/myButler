//
//  ContentView.swift
//  myButler
//
//  Created by Hairong Yu on 1/25/26.
//

import SwiftUI

struct ContentView: View {
    // Shared store injected from the App entry point.
    @ObservedObject var store: ItemStore

    var body: some View {
        TabView {
            // Inbox is the primary capture list.
            InboxView(store: store)
                .tabItem {
                    Label("Inbox", systemImage: "tray")
                }

            // Placeholder tabs for upcoming milestones.
            TodayView()
                .tabItem {
                    Label("Today", systemImage: "sun.max")
                }

            // Search needs access to the shared item store.
            SearchView(store: store)
                .tabItem {
                    Label("Search", systemImage: "magnifyingglass")
                }

            SettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gearshape")
                }
        }
    }
}

#Preview {
    ContentView(store: ItemStore())
}
