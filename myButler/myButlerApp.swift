//
//  myButlerApp.swift
//  myButler
//
//  Created by Hairong Yu on 1/25/26.
//

import SwiftUI

@main
struct myButlerApp: App {
    // Single source of truth for items.
    @StateObject private var store = ItemStore()

    init() {
        AppPerformanceLogger.shared.log("App init")
    }

    var body: some Scene {
        WindowGroup {
            // Inject the store into the root view.
            ContentView(store: store)
        }
    }
}
