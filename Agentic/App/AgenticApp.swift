//
//  AgenticApp.swift
//  Agentic
//
//  Created by Moosia LLC on 15/03/2026.
//

import SwiftUI
import SwiftData

@main
struct AgenticApp: App {
    @StateObject private var mcpManager = MCPServerManager.shared
    private let apiKeyStore: any APIKeyStoring = KeychainAPIKeyStore()
    private let providerModelStore: any ProviderModelPreferencesStoring = UserDefaultsProviderModelStore()
    private let liveProviderExecutor: any LiveProviderExecuting = DefaultLiveProviderExecutor()

    init() {
        RunCompletionNotificationService.requestAuthorizationIfNeeded()
    }

    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            GraphDocument.self,
            UserNodeTemplate.self,
            UserStructureTemplate.self,
            MCPServerConnection.self,
        ])
        // Try CloudKit-backed sync first against our registered private
        // container. This requires the `iCloud.com.moosia.agentic` container
        // to exist in the Apple Developer portal AND the matching entitlement
        // to be in the signed binary. If either is missing — or the user is
        // signed out of iCloud — fall back to a local-only store so the app
        // still launches.
        let cloudConfiguration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: false,
            cloudKitDatabase: .private("iCloud.com.moosia.agentic")
        )

        if let container = try? ModelContainer(for: schema, configurations: [cloudConfiguration]) {
            return container
        }

        // CloudKit unavailable — retry with local-only storage.
        let localConfiguration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: false,
            cloudKitDatabase: .none
        )

        do {
            return try ModelContainer(for: schema, configurations: [localConfiguration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 1600)
                .task {
                    #if DEBUG
                    DemoTaskSeeder.seedIfRequested(into: sharedModelContainer.mainContext)
                    #endif
                }
                .tint(AppTheme.brandTint)
                .environment(\.apiKeyStore, apiKeyStore)
                .environment(\.providerModelStore, providerModelStore)
                .environment(\.liveProviderExecutor, liveProviderExecutor)
                .environmentObject(mcpManager)
        }
        .windowResizability(.contentMinSize)
        .modelContainer(sharedModelContainer)
    }
}
