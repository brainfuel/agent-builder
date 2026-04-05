//
//  AgenticApp.swift
//  Agentic
//
//  Created by Ben Milford on 15/03/2026.
//

import SwiftUI
import SwiftData

@main
struct AgenticApp: App {
    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            GraphDocument.self,
            UserNodeTemplate.self,
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
                .tint(AppTheme.brandTint)
        }
        .modelContainer(sharedModelContainer)
    }
}
