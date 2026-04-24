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
        // Opt into CloudKit sync explicitly against the registered container.
        // Requires the `iCloud.com.moosia.agentic` container to exist in the
        // Apple Developer portal AND the matching entitlement in
        // Agentic.entitlements. If the container is unreachable at runtime
        // (e.g. signed-out iCloud account) SwiftData degrades to local-only.
        let modelConfiguration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: false,
            cloudKitDatabase: .private("iCloud.com.moosia.agentic")
        )

        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 1600)
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
