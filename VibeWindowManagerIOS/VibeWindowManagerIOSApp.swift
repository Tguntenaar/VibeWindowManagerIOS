//
//  VibeWindowManagerIOSApp.swift
//  VibeWindowManagerIOS
//
//  Created by Thomas Guntenaar on 23/04/2026.
//

import SwiftUI
import SwiftData

@main
struct VibeWindowManagerIOSApp: App {
    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            Item.self,
        ])
        let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)

        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(sharedModelContainer)
    }
}
