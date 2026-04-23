import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct ToolCatalogSheet: View {
    private struct ServerToolListSelection: Identifiable, Hashable {
        let id: UUID
        let name: String
        let tools: [MCPRemoteTool]
    }

    var embedded: Bool = false

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query private var savedServers: [MCPServerConnection]
    @EnvironmentObject private var mcpManager: MCPServerManager
    @State private var configuringServer: CuratedMCPServer?
    @State private var serverAPIKey = ""
    @State private var addingCustomServer = false
    @State private var customName = ""
    @State private var customURL = ""
    @State private var customAPIKey = ""
    #if os(macOS) || targetEnvironment(macCatalyst)
    @State private var addingLocalServer = false
    @State private var localName = ""
    @State private var localCommand = ""
    @State private var localArguments = ""
    #endif
    @State private var selectedServerTools: ServerToolListSelection?
    @State private var navigationPath = NavigationPath()

    var body: some View {
        if embedded {
            NavigationStack(path: $navigationPath) {
                toolCatalogContent
                    .navigationDestination(for: ServerToolListSelection.self) { selection in
                        ServerToolsDetailView(serverName: selection.name, tools: selection.tools)
                    }
            }
        } else {
            NavigationStack(path: $navigationPath) {
                toolCatalogContent
                    .navigationTitle("Tool Catalog")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button {
                                dismiss()
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .navigationDestination(for: ServerToolListSelection.self) { selection in
                        ServerToolsDetailView(serverName: selection.name, tools: selection.tools)
                    }
            }
        }
    }

    private var toolCatalogContent: some View {
        ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    // MARK: MCP Servers
                    VStack(alignment: .leading, spacing: 4) {
                        Text("MCP SERVERS")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 20)

                        Text(mcpManager.globalToolAccess
                             ? "Connected tools are available to all nodes automatically."
                             : "Connected tools must be assigned per-node in the Node Details inspector.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 20)
                            .padding(.bottom, 4)

                        // Global tool access toggle
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Global Tool Access")
                                    .font(.callout.weight(.medium))
                                Text("All connected tools available to every node")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Toggle("", isOn: $mcpManager.globalToolAccess)
                                .labelsHidden()
                                .help("Share tools with all nodes")
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .background(Color(.secondarySystemGroupedBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .padding(.horizontal, 16)
                        .padding(.bottom, 4)

                        ForEach(CuratedMCPCatalog.categories, id: \.self) { category in
                            VStack(alignment: .leading, spacing: 0) {
                                Text(category)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 20)
                                    .padding(.bottom, 6)
                                    .padding(.top, 8)

                                VStack(spacing: 1) {
                                    ForEach(CuratedMCPCatalog.servers(in: category)) { server in
                                        let savedConnection = preferredSavedConnection(for: server)
                                        let isConnected = savedConnection != nil
                                        let status = savedConnection.flatMap { mcpManager.connectionStatus[$0.id] }
                                        let cachedToolCount = savedConnection.map { toolCountForDisplay(connection: $0, status: status) } ?? 0
                                        let hasToolDetails = cachedToolCount > 0
                                        HStack(alignment: .top, spacing: 14) {
                                            Image(systemName: server.icon)
                                                .font(.title3)
                                                .foregroundStyle(isConnected ? Color.accentColor : .secondary)
                                                .frame(width: 32, height: 32)

                                            VStack(alignment: .leading, spacing: 3) {
                                                HStack(spacing: 8) {
                                                    Text(server.name)
                                                        .font(.body.weight(.medium))
                                                        .lineLimit(1)
                                                    serverStatusBadge(isConnected: isConnected, status: status, cachedToolCount: cachedToolCount)

                                                    Spacer(minLength: 8)

                                                    if case .connecting = status {
                                                        ProgressView()
                                                            .controlSize(.small)
                                                    } else if case .awaitingOAuth = status {
                                                        ProgressView()
                                                            .controlSize(.small)
                                                    } else if isConnected {
                                                        Button {
                                                            if let conn = savedConnection {
                                                                Task { await mcpManager.connect(to: conn) }
                                                            }
                                                        } label: {
                                                            Image(systemName: "arrow.clockwise")
                                                                .font(.callout.weight(.semibold))
                                                                .foregroundStyle(Color.accentColor)
                                                                .frame(width: 20, height: 20)
                                                        }
                                                        .buttonStyle(.plain)
                                                        .accessibilityLabel("Refresh")
                                                        .help("Reconnect and refresh tools")

                                                        Button {
                                                            disconnectServer(named: server.name)
                                                        } label: {
                                                            Image(systemName: "xmark.circle")
                                                                .font(.callout.weight(.semibold))
                                                                .foregroundStyle(.red)
                                                                .frame(width: 20, height: 20)
                                                        }
                                                        .buttonStyle(.plain)
                                                        .accessibilityLabel("Remove")
                                                        .help("Disconnect this server")
                                                    } else {
                                                        Button {
                                                            if server.requiresAPIKey {
                                                                configuringServer = server
                                                                serverAPIKey = ""
                                                            } else {
                                                                connectServer(server, apiKey: "")
                                                            }
                                                        } label: {
                                                            Text("Connect")
                                                                .font(.caption.weight(.semibold))
                                                                .foregroundStyle(.white)
                                                                .lineLimit(1)
                                                                .fixedSize(horizontal: true, vertical: false)
                                                                .padding(.horizontal, 12)
                                                                .padding(.vertical, 3)
                                                                .background(Color.accentColor, in: Capsule())
                                                        }
                                                        .buttonStyle(.plain)
                                                        .help("Connect \(server.name)")
                                                    }

                                                }
                                                HStack(alignment: .center, spacing: 8) {
                                                    Text(server.description)
                                                        .font(.caption)
                                                        .foregroundStyle(.secondary)
                                                        .lineLimit(2)
                                                    if hasToolDetails {
                                                        Spacer(minLength: 0)
                                                        Image(systemName: "chevron.right")
                                                            .font(.caption.weight(.semibold))
                                                            .foregroundStyle(.tertiary)
                                                    }
                                                }
                                                if case .connected(let count) = status {
                                                    Text("\(count) tool\(count == 1 ? "" : "s") available")
                                                        .font(.caption2)
                                                        .foregroundStyle(.green)
                                                } else if case .failed(let msg) = status {
                                                    Text(msg)
                                                        .font(.caption2)
                                                        .foregroundStyle(.red)
                                                        .lineLimit(3)
                                                } else if cachedToolCount > 0 {
                                                    Text("\(cachedToolCount) tool\(cachedToolCount == 1 ? "" : "s") available (tap to view)")
                                                        .font(.caption2)
                                                        .foregroundStyle(.secondary)
                                                }
                                            }
                                            .layoutPriority(1)
                                            .contentShape(Rectangle())
                                            .onTapGesture {
                                                handleServerRowTap(connection: savedConnection, status: status)
                                            }
                                        }
                                        .padding(.horizontal, 20)
                                        .padding(.vertical, 10)
                                        .background(Color(.secondarySystemGroupedBackground))
                                    }
                                }
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                                .padding(.horizontal, 16)
                            }
                        }
                    }

                    // MARK: Custom Server (remote HTTP)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("CUSTOM SERVER")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 20)

                        Button {
                            addingCustomServer = true
                            customName = ""
                            customURL = ""
                            customAPIKey = ""
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "plus.circle.fill")
                                    .font(.title3)
                                Text("Add Custom MCP Server")
                                    .font(.body.weight(.medium))
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.horizontal, 20)
                            .padding(.vertical, 12)
                            .background(Color(.secondarySystemGroupedBackground))
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 16)
                        .help("Add a custom MCP server")

                        // Show remote (HTTP) custom servers only.
                        let customServers = savedServers.filter { conn in
                            !conn.isStdio &&
                            !CuratedMCPCatalog.servers.contains(where: { $0.name == conn.name })
                        }
                        if !customServers.isEmpty {
                            VStack(spacing: 1) {
                                ForEach(customServers) { server in
                                    customServerRow(server)
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.top, 6)
                        }
                    }

                    #if os(macOS) || targetEnvironment(macCatalyst)
                    // MARK: Local (stdio)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("LOCAL")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 20)

                        Button {
                            localName = ""
                            localCommand = ""
                            localArguments = ""
                            addingLocalServer = true
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "terminal.fill")
                                    .font(.title3)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Add Local MCP Server")
                                        .font(.body.weight(.medium))
                                    Text("Spawn a local binary and talk JSON-RPC over stdin/stdout")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.horizontal, 20)
                            .padding(.vertical, 12)
                            .background(Color(.secondarySystemGroupedBackground))
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 16)
                        .help("Add a local MCP server executable (macOS only)")

                        let localServers = savedServers.filter { $0.isStdio }
                        if !localServers.isEmpty {
                            VStack(spacing: 1) {
                                ForEach(localServers) { server in
                                    customServerRow(server)
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.top, 6)
                        }
                    }
                    #endif

                }
                .padding(.vertical, 16)
            }
            .background(Color(.systemGroupedBackground))
            .alert("Connect \(configuringServer?.name ?? "")", isPresented: Binding(
                get: { configuringServer != nil },
                set: { if !$0 { configuringServer = nil } }
            )) {
                SecureField("API Key", text: $serverAPIKey)
                Button("Connect") {
                    if let server = configuringServer {
                        connectServer(server, apiKey: serverAPIKey)
                    }
                    configuringServer = nil
                }
                Button("Cancel", role: .cancel) {
                    configuringServer = nil
                }
            } message: {
                if let hint = configuringServer?.credentialHint, !hint.isEmpty {
                    Text(hint)
                } else {
                    Text("Enter your API key or bearer token for \(configuringServer?.name ?? "this service"). The credential is stored locally on your device.")
                }
            }
            .alert("Add Custom MCP Server", isPresented: $addingCustomServer) {
                TextField("Server Name", text: $customName)
                TextField("Server URL", text: $customURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("API Key (optional)", text: $customAPIKey)
                Button("Add") {
                    addCustomServer()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Enter the MCP server endpoint URL (e.g. https://mcp.example.com/sse).")
            }
            #if os(macOS) || targetEnvironment(macCatalyst)
            .sheet(isPresented: $addingLocalServer) {
                LocalMCPServerSheet(
                    name: $localName,
                    command: $localCommand,
                    arguments: $localArguments,
                    onAdd: {
                        addLocalServer()
                        addingLocalServer = false
                    },
                    onCancel: { addingLocalServer = false }
                )
            }
            #endif
    }

    private func connectServer(_ server: CuratedMCPServer, apiKey: String) {
        let trimmedAPIKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if let existing = savedServers
            .filter({ $0.name == server.name })
            .sorted(by: { $0.addedAt > $1.addedAt })
            .first
        {
            // Keep curated servers aligned to the latest known endpoint/metadata.
            existing.url = server.url
            existing.icon = server.icon
            existing.category = server.category
            existing.serverDescription = server.description
            existing.isEnabled = true
            if !server.requiresAPIKey {
                existing.apiKey = ""
            } else if !trimmedAPIKey.isEmpty {
                existing.apiKey = trimmedAPIKey
            }

            // Remove stale duplicates that may keep old URLs around.
            for duplicate in savedServers where duplicate.name == server.name && duplicate.id != existing.id {
                mcpManager.disconnect(id: duplicate.id)
                modelContext.delete(duplicate)
            }

            Task { await mcpManager.connect(to: existing) }
            return
        }

        let connection = MCPServerConnection(
            name: server.name,
            url: server.url,
            apiKey: server.requiresAPIKey ? trimmedAPIKey : "",
            icon: server.icon,
            category: server.category,
            serverDescription: server.description,
            isEnabled: true
        )
        modelContext.insert(connection)
        Task { await mcpManager.connect(to: connection) }
    }

    private func disconnectServer(named name: String) {
        let matches = savedServers.filter { $0.name == name }
        for existing in matches {
            mcpManager.disconnect(id: existing.id)
            modelContext.delete(existing)
        }
    }

    private func preferredSavedConnection(for server: CuratedMCPServer) -> MCPServerConnection? {
        savedServers
            .filter { $0.name == server.name && $0.isEnabled }
            .sorted { lhs, rhs in
                let lhsMatchesCuratedURL = lhs.url == server.url
                let rhsMatchesCuratedURL = rhs.url == server.url
                if lhsMatchesCuratedURL != rhsMatchesCuratedURL {
                    return lhsMatchesCuratedURL && !rhsMatchesCuratedURL
                }
                return lhs.addedAt > rhs.addedAt
            }
            .first
    }

    private func addCustomServer() {
        let trimmedURL = customURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedName = customName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedURL.isEmpty, !trimmedName.isEmpty else { return }

        let connection = MCPServerConnection(
            name: trimmedName,
            url: trimmedURL,
            apiKey: customAPIKey,
            icon: "server.rack",
            category: "Custom",
            serverDescription: trimmedURL,
            isEnabled: true,
            transport: "http"
        )
        modelContext.insert(connection)
        Task { await mcpManager.connect(to: connection) }
    }

    #if os(macOS) || targetEnvironment(macCatalyst)
    private func addLocalServer() {
        let name = localName.trimmingCharacters(in: .whitespacesAndNewlines)
        let cmd = localCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        let args = localArguments.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !cmd.isEmpty else { return }

        let connection = MCPServerConnection(
            name: name,
            url: "",
            apiKey: "",
            icon: "terminal.fill",
            category: "Local",
            serverDescription: "",
            isEnabled: true,
            transport: "stdio",
            command: cmd,
            arguments: args
        )
        modelContext.insert(connection)
        Task { await mcpManager.connect(to: connection) }
    }

    #endif

    private func handleServerRowTap(connection: MCPServerConnection?, status: MCPServerManager.ConnectionStatus?) {
        guard let connection else { return }

        let liveTools = sortedTools(for: connection.id)
        if !liveTools.isEmpty {
            navigationPath.append(ServerToolListSelection(id: connection.id, name: connection.name, tools: liveTools))
            return
        }

        let cachedTools = sortedCachedTools(for: connection)
        if !cachedTools.isEmpty {
            navigationPath.append(ServerToolListSelection(id: connection.id, name: connection.name, tools: cachedTools))
            return
        }

        if case .connecting = status { return }
        if case .awaitingOAuth = status { return }

        Task {
            await mcpManager.connect(to: connection)
            await MainActor.run {
                let refreshed = sortedTools(for: connection.id)
                if !refreshed.isEmpty {
                    navigationPath.append(ServerToolListSelection(id: connection.id, name: connection.name, tools: refreshed))
                }
            }
        }
    }

    private func sortedTools(for connectionID: UUID) -> [MCPRemoteTool] {
        (mcpManager.discoveredTools[connectionID] ?? []).sorted { lhs, rhs in
            let lhsLabel = lhs.title ?? lhs.name
            let rhsLabel = rhs.title ?? rhs.name
            return lhsLabel.localizedCaseInsensitiveCompare(rhsLabel) == .orderedAscending
        }
    }

    private func sortedCachedTools(for connection: MCPServerConnection) -> [MCPRemoteTool] {
        mcpManager.cachedTools(for: connection.id).sorted { lhs, rhs in
            let lhsLabel = lhs.title ?? lhs.name
            let rhsLabel = rhs.title ?? rhs.name
            return lhsLabel.localizedCaseInsensitiveCompare(rhsLabel) == .orderedAscending
        }
    }

    private func toolCountForDisplay(connection: MCPServerConnection, status: MCPServerManager.ConnectionStatus?) -> Int {
        if case .connected(let liveCount) = status {
            return liveCount
        }
        let liveCount = mcpManager.discoveredTools[connection.id]?.count ?? 0
        if liveCount > 0 { return liveCount }
        return mcpManager.cachedToolCount(for: connection.id)
    }

    @ViewBuilder
    private func serverStatusBadge(isConnected: Bool, status: MCPServerManager.ConnectionStatus?, cachedToolCount: Int) -> some View {
        if case .connected(let count) = status {
            Text("\(count) tools")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.black)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.green, in: Capsule())
        } else if case .connecting = status {
            Text("Connecting…")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color(.tertiarySystemFill), in: Capsule())
        } else if case .awaitingOAuth = status {
            Text("Authorizing…")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.orange, in: Capsule())
        } else if case .failed = status {
            Text("Failed")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.red, in: Capsule())
        } else if isConnected && cachedToolCount > 0 {
            Text("\(cachedToolCount) tools")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.black)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.green, in: Capsule())
        } else if isConnected {
            Text("Saved")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color(.tertiarySystemFill), in: Capsule())
        }
    }

    /// Renders a single custom-server row. Shared by the CUSTOM SERVER (HTTP)
    /// and LOCAL (stdio) sections — the section header supplies the context
    /// so no "LOCAL" badge is rendered inline.
    @ViewBuilder
    private func customServerRow(_ server: MCPServerConnection) -> some View {
        let status = mcpManager.connectionStatus[server.id]
        let toolCount = toolCountForDisplay(connection: server, status: status)
        let hasToolDetails = toolCount > 0
        let isConnected = server.isEnabled
        // Prefer a stored description; fall back to the URL/path so the row
        // still conveys identity (what Exa/Cloudinary show is their description).
        let descriptionText: String = {
            let trimmed = server.serverDescription.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
            return server.isStdio ? server.command : server.url
        }()

        HStack(alignment: .top, spacing: 14) {
            Image(systemName: server.isStdio ? "terminal.fill" : "server.rack")
                .font(.title3)
                .foregroundStyle(isConnected ? Color.accentColor : .secondary)
                .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(server.name)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                    serverStatusBadge(
                        isConnected: isConnected,
                        status: status,
                        cachedToolCount: toolCount
                    )

                    Spacer(minLength: 8)

                    if case .connecting = status {
                        ProgressView().controlSize(.small)
                    } else if case .awaitingOAuth = status {
                        ProgressView().controlSize(.small)
                    } else if isConnected {
                        Button {
                            Task { await mcpManager.connect(to: server) }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                                .font(.callout.weight(.semibold))
                                .foregroundStyle(Color.accentColor)
                                .frame(width: 20, height: 20)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Refresh")
                        .help("Reconnect and refresh tools")

                        Button {
                            mcpManager.disconnect(id: server.id)
                            modelContext.delete(server)
                        } label: {
                            Image(systemName: "xmark.circle")
                                .font(.callout.weight(.semibold))
                                .foregroundStyle(.red)
                                .frame(width: 20, height: 20)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remove")
                        .help("Remove this server")
                    } else {
                        Button {
                            server.isEnabled = true
                            Task { await mcpManager.connect(to: server) }
                        } label: {
                            Text("Connect")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 3)
                                .background(Color.accentColor, in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .help("Connect \(server.name)")
                    }
                }

                HStack(alignment: .center, spacing: 8) {
                    Text(descriptionText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    if hasToolDetails {
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                }

                if case .connected(let count) = status {
                    Text("\(count) tool\(count == 1 ? "" : "s") available")
                        .font(.caption2)
                        .foregroundStyle(.green)
                } else if case .failed(let msg) = status {
                    Text(msg)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .lineLimit(3)
                } else if toolCount > 0 {
                    Text("\(toolCount) tool\(toolCount == 1 ? "" : "s") available (tap to view)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .layoutPriority(1)
            .contentShape(Rectangle())
            .onTapGesture {
                handleServerRowTap(connection: server, status: status)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

}

struct ServerToolsDetailView: View {
    let serverName: String
    let tools: [MCPRemoteTool]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("\(tools.count) tool\(tools.count == 1 ? "" : "s") available")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 20)
                    .padding(.top, 4)

                if tools.isEmpty {
                    Text("No tools discovered yet. Use Refresh in Tool Catalog to load tools.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 20)
                } else {
                    VStack(spacing: 12) {
                        ForEach(tools) { tool in
                            ServerToolCard(tool: tool)
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }
            .padding(.bottom, 20)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("\(serverName) Tools")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct ServerToolCard: View {
    let tool: MCPRemoteTool
    @State private var isExpanded = false

    private static let wordLimit = 40

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Title
            Text(tool.title ?? tool.name)
                .font(.body.weight(.semibold))

            // Tool ID badge
            Text(tool.name)
                .font(.caption2.monospaced())
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color(.tertiaryLabel), in: Capsule())

            // Description with show more/less
            if let description = tool.description, !description.isEmpty {
                let cleaned = Self.cleanForDisplay(description)
                let words = cleaned.split(separator: " ", omittingEmptySubsequences: true)
                let needsTruncation = words.count > Self.wordLimit

                if isExpanded || !needsTruncation {
                    // Render full markdown
                    markdownText(description)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if needsTruncation {
                        Button("Show Less") {
                            withAnimation(.easeInOut(duration: 0.2)) { isExpanded = false }
                        }
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Color.accentColor)
                        .help("Collapse description")
                    }
                } else {
                    // Truncated preview
                    let truncated = words.prefix(Self.wordLimit).joined(separator: " ") + "…"
                    markdownText(truncated)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Button("Show More") {
                        withAnimation(.easeInOut(duration: 0.2)) { isExpanded = true }
                    }
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Color.accentColor)
                    .help("Expand description")
                }
            }

            // Parameters
            if let schema = tool.inputSchema,
               let props = schema.properties, !props.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Parameters")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)

                    ForEach(props.keys.sorted(), id: \.self) { key in
                        let prop = props[key]!
                        let isRequired = schema.required?.contains(key) ?? false
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(key)
                                    .font(.caption.monospaced().weight(.medium))
                                if let type = prop.type {
                                    Text(type)
                                        .font(.caption2)
                                        .foregroundStyle(.white.opacity(0.9))
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 1)
                                        .background(Color(.systemGray3), in: Capsule())
                                }
                                if isRequired {
                                    Text("required")
                                        .font(.caption2.weight(.medium))
                                        .foregroundStyle(.red.opacity(0.8))
                                }
                            }
                            if let desc = prop.description, !desc.isEmpty {
                                Text(desc)
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    /// Cleans raw MCP description text before rendering.
    /// Strips custom XML-like tags (e.g. `<example>...</example>`, `<data-source>`)
    /// that are meant for the LLM, not the user.
    private static func cleanForDisplay(_ source: String) -> String {
        var text = source
        // Remove full <tag ...>...</tag> blocks (including multiline)
        text = text.replacingOccurrences(
            of: "(?s)<[a-zA-Z][a-zA-Z0-9_-]*[^>]*>.*?</[a-zA-Z][a-zA-Z0-9_-]*>",
            with: "",
            options: .regularExpression
        )
        // Remove any remaining self-closing or orphan tags
        text = text.replacingOccurrences(
            of: "</?[a-zA-Z][a-zA-Z0-9_-]*[^>]*>",
            with: "",
            options: .regularExpression
        )
        // Collapse excessive whitespace left behind
        text = text.replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Renders markdown text using SwiftUI's AttributedString, falling back to plain text.
    @ViewBuilder
    private func markdownText(_ source: String) -> some View {
        let cleaned = Self.cleanForDisplay(source)
        if let attributed = try? AttributedString(markdown: cleaned, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            Text(attributed)
        } else {
            Text(cleaned)
        }
    }
}

#if os(macOS) || targetEnvironment(macCatalyst)

// MARK: - Local (stdio) MCP Server sheet

private struct LocalMCPServerSheet: View {
    @Binding var name: String
    @Binding var command: String
    @Binding var arguments: String
    let onAdd: () -> Void
    let onCancel: () -> Void

    @State private var pickingExecutable = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Server") {
                    TextField("Name", text: $name)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Section("Executable") {
                    HStack {
                        TextField("/path/to/mcp-binary", text: $command)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(.system(.body, design: .monospaced))
                        Button("Choose…") { pickingExecutable = true }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                    TextField("Arguments (optional)", text: $arguments)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.system(.body, design: .monospaced))
                }
                Section {
                    Text("Agentic will launch this binary and exchange JSON-RPC over stdin/stdout. Example: /Applications/Publisher.app/Contents/MacOS/publisher-mcp")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Add Local MCP Server")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onCancel() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { onAdd() }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty ||
                                  command.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .fileImporter(
                isPresented: $pickingExecutable,
                allowedContentTypes: [.application, .executable, .unixExecutable, .item],
                allowsMultipleSelection: false
            ) { result in
                guard case .success(let urls) = result, let url = urls.first else { return }
                _ = url.startAccessingSecurityScopedResource()

                let fm = FileManager.default
                var chosen = url
                var isDir: ObjCBool = false

                // If the user picked an .app bundle, hunt for the MCP binary inside.
                if url.pathExtension.lowercased() == "app",
                   fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                    let macos = url.appendingPathComponent("Contents/MacOS")
                    if let entries = try? fm.contentsOfDirectory(atPath: macos.path) {
                        // Prefer a binary whose name contains "mcp", otherwise
                        // fall back to anything not named like the app itself.
                        let appBase = url.deletingPathExtension().lastPathComponent.lowercased()
                        let mcpHit = entries.first { $0.lowercased().contains("mcp") }
                        let nonMain = entries.first { $0.lowercased() != appBase }
                        if let pick = mcpHit ?? nonMain ?? entries.first {
                            chosen = macos.appendingPathComponent(pick)
                        }
                    }
                }

                command = chosen.path
                if name.isEmpty {
                    // Prefer the app bundle's name if we drilled in, else the file name.
                    name = (url.pathExtension.lowercased() == "app")
                        ? url.deletingPathExtension().lastPathComponent
                        : chosen.deletingPathExtension().lastPathComponent
                }
            }
        }
        .frame(minWidth: 520, minHeight: 320)
    }
}

#endif
