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
    @AppStorage("uiTheme") private var uiTheme = UITheme.classicBlue.rawValue
    @State private var isShowingUndoHistory = false
    @State private var isShowingUndoBanner = false
    @AppStorage("weeklyDigestRemindersEnabled") private var weeklyDigestRemindersEnabled = true
    @AppStorage("weeklyDigestReminderWeekday") private var weeklyDigestReminderWeekday = 1
    @AppStorage("weeklyDigestReminderHour") private var weeklyDigestReminderHour = 18
    @AppStorage("weeklyDigestReminderMinute") private var weeklyDigestReminderMinute = 0
    @State private var hasLoggedFirstAppear = false

    var body: some View {
        TabView {
            VoiceSessionView(store: store)
                .tabItem {
                    Label("Voice", systemImage: "waveform")
                }

            // Inbox is the primary capture list.
            InboxView(store: store)
                .tabItem {
                    Label("Inbox", systemImage: "tray")
                }

            // Search needs access to the shared item store.
            SearchView(store: store)
                .tabItem {
                    Label("Search", systemImage: "magnifyingglass")
                }

            ProjectsView(store: store)
                .tabItem {
                    Label("Projects", systemImage: "folder")
                }

            TodayView(store: store)
                .tabItem {
                    Label("Today", systemImage: "sun.max")
                }

            SettingsView(store: store)
                .tabItem {
                    Label("Settings", systemImage: "gearshape")
                }
        }
        .tint(selectedTheme.tintColor)
        .overlay(alignment: .bottom) {
            if store.latestDeleted != nil && isShowingUndoBanner {
                undoBanner
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .padding(.bottom, 12)
            }
        }
        .sheet(isPresented: $isShowingUndoHistory) {
            UndoHistoryView(store: store)
        }
        .onChange(of: store.deletedHistory.count) { _, newValue in
            isShowingUndoBanner = newValue > 0
        }
        .task {
            cleanupLegacyReminderSettings()
            await WeeklyDigestReminder.updateSchedule(isEnabled: weeklyDigestRemindersEnabled, schedule: reminderSchedule)
        }
        .onAppear {
            guard !hasLoggedFirstAppear else { return }
            hasLoggedFirstAppear = true
            AppPerformanceLogger.shared.log("ContentView first appear")
        }
    }

    private func cleanupLegacyReminderSettings() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "weeklyDigestReminderFrequency")
        defaults.removeObject(forKey: "weeklyDigestReminderMonthDay")
    }

    private var selectedTheme: UITheme {
        UITheme(rawValue: uiTheme) ?? .classicBlue
    }

    private var reminderSchedule: WeeklyDigestSchedule {
        WeeklyDigestSchedule(
            frequency: .weekly,
            weekday: weeklyDigestReminderWeekday,
            monthDay: 1,
            hour: weeklyDigestReminderHour,
            minute: weeklyDigestReminderMinute
        )
    }

    private var undoBanner: some View {
        HStack(spacing: 12) {
            Text("Deleted \(deletedTitle)")
                .font(.subheadline)
            Spacer()
            Button("Undo") {
                store.undoLastDelete()
            }
            Button("History") {
                isShowingUndoHistory = true
            }
            Button {
                isShowingUndoBanner = false
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial)
        .clipShape(Capsule())
        .shadow(radius: 6)
        .padding(.horizontal, 16)
    }

    private var deletedTitle: String {
        let title = store.latestDeleted?.item.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return title.isEmpty ? "item" : title
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView(store: ItemStore())
    }
}
