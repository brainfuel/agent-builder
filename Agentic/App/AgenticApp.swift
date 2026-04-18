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

    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            GraphDocument.self,
            UserNodeTemplate.self,
            MCPServerConnection.self,
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
                .frame(minWidth: 1688)
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
