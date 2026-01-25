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

            SearchView()
                .tabItem {
                    Label("Search", systemImage: "magnifyingglass")
                }
        }
    }
}

#Preview {
    ContentView(store: ItemStore())
}
