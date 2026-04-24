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

        // Only opt into CloudKit sync when the iCloud container is actually
        // reachable — i.e. the `iCloud.com.moosia.agentic` entitlement is
        // present in the signed binary AND the user is signed in to iCloud.
        //
        // `url(forUbiquityContainerIdentifier:)` returns nil if either is
        // missing; asking SwiftData to open a CloudKit-backed store when the
        // entitlement isn't there traps asynchronously on
        // `com.apple.coredata.cloudkit.queue` and kills the app.
        let iCloudContainerID = "iCloud.com.moosia.agentic"
        let iCloudReachable = FileManager.default
            .url(forUbiquityContainerIdentifier: iCloudContainerID) != nil

        let configuration: ModelConfiguration
        if iCloudReachable {
            configuration = ModelConfiguration(
                schema: schema,
                isStoredInMemoryOnly: false,
                cloudKitDatabase: .private(iCloudContainerID)
            )
        } else {
            configuration = ModelConfiguration(
                schema: schema,
                isStoredInMemoryOnly: false,
                cloudKitDatabase: .none
            )
        }

        do {
            return try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            // As a last-ditch fallback, if CloudKit config fails for any
            // reason, retry with a pure local store so the app still launches.
            if iCloudReachable {
                let localConfiguration = ModelConfiguration(
                    schema: schema,
                    isStoredInMemoryOnly: false,
                    cloudKitDatabase: .none
                )
                if let container = try? ModelContainer(for: schema, configurations: [localConfiguration]) {
                    return container
                }
            }
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
