import Foundation

struct LLMStreamResponse {
    let modelID: String
    let rawText: String
}

struct LLMResponseService {
    let liveProviderExecutor: any LiveProviderExecuting

    func requestRawText(
        provider: APIKeyProvider,
        apiKey: String,
        preferredModelID: String?,
        systemPrompt: String,
        messages: [ChatMessage]
    ) async throws -> LLMStreamResponse {
        let modelID: String
        do {
            modelID = try await liveProviderExecutor.resolveModel(
                for: provider,
                apiKey: apiKey,
                preferredModelID: preferredModelID
            )
        } catch {
            throw WorkflowError.modelResolutionFailed(provider: provider, underlying: error)
        }

        var combinedText = ""
        do {
            let client = liveProviderExecutor.makeClient(for: provider, apiKey: apiKey)
            let stream = client.generateReplyStream(
                modelID: modelID,
                systemInstruction: systemPrompt,
                messages: messages,
                latestUserAttachments: []
            )

            for try await chunk in stream {
                if !chunk.text.isEmpty {
                    combinedText += chunk.text
                }
            }
        } catch {
            throw WorkflowError.streamFailed(provider: provider, underlying: error)
        }

        let raw = combinedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else {
            throw WorkflowError.emptyModelResponse(provider: provider)
        }

        return LLMStreamResponse(modelID: modelID, rawText: raw)
    }

    func executeDebugRequest(
        provider: APIKeyProvider,
        apiKey: String?,
        preferredModelID: String?,
        systemPrompt: String,
        messages: [ChatMessage]
    ) async -> StructureChatProviderDebugResult {
        guard let apiKey, !apiKey.isEmpty else {
            let error = WorkflowError.missingAPIKey(provider: provider)
            return StructureChatProviderDebugResult(
                provider: provider,
                preferredModelID: preferredModelID,
                resolvedModelID: nil,
                responseText: nil,
                errorMessage: error.userMessage
            )
        }

        do {
            let response = try await requestRawText(
                provider: provider,
                apiKey: apiKey,
                preferredModelID: preferredModelID,
                systemPrompt: systemPrompt,
                messages: messages
            )
            return StructureChatProviderDebugResult(
                provider: provider,
                preferredModelID: preferredModelID,
                resolvedModelID: response.modelID,
                responseText: response.rawText,
                errorMessage: nil
            )
        } catch {
            return StructureChatProviderDebugResult(
                provider: provider,
                preferredModelID: preferredModelID,
                resolvedModelID: nil,
                responseText: nil,
                errorMessage: (error as? WorkflowError)?.userMessage ?? error.localizedDescription
            )
        }
    }
}

struct CoordinatorPacketExecutionService {
    let nodes: [OrgNode]
    let apiKeyStore: any APIKeyStoring
    let providerModelStore: any ProviderModelPreferencesStoring
    let liveProviderExecutor: any LiveProviderExecuting
    let mcpManager: MCPServerManager
    let mcpServerConnections: [MCPServerConnection]

    func executeLiveProviderPacket(
        _ packet: CoordinatorTaskPacket,
        handoffSummaries: [String],
        goal: String
    ) async -> MCPTaskResponse {
        guard let node = nodes.first(where: { $0.id == packet.assignedNodeID }) else {
            return MCPTaskResponse(
                summary: "Live run failed: node for packet \(packet.id) was not found.",
                confidence: 0,
                completed: false
            )
        }

        let provider = node.provider.apiKeyProvider
        let trimmedKey: String
        do {
            trimmedKey = (try apiKeyStore.key(for: provider) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            let workflowError = WorkflowError.apiKeyReadFailed(provider: provider, underlying: error)
            return MCPTaskResponse(
                summary: "Live run failed for \(node.name): \(workflowError.userMessage)",
                confidence: 0,
                completed: false
            )
        }

        guard !trimmedKey.isEmpty else {
            let workflowError = WorkflowError.missingAPIKey(provider: provider)
            return MCPTaskResponse(
                summary: "Live run failed for \(node.name): \(workflowError.userMessage)",
                confidence: 0,
                completed: false
            )
        }

        mcpManager.registerKnownConnections(mcpServerConnections)

        var effectiveTools = packet.assignedTools
        var effectivePermissions = packet.allowedPermissions
        if mcpManager.globalToolAccess {
            let allRemote = mcpManager.allRemoteTools
            for tool in allRemote where !effectiveTools.contains(tool.name) {
                effectiveTools.append(tool.name)
            }
        }
        // Auto-grant workspace permissions whenever any remote MCP tool is
        // assigned (global OR per-tool mode). Without this, per-tool nodes
        // show "Allowed permissions: (none)" in their user prompt, which
        // pressures the model into inventing auth/team parameters or
        // declaring BLOCKED because "authorization is missing".
        let remoteToolNames = Set(mcpManager.allRemoteTools.map(\.name))
        let hasAssignedRemoteTool = effectiveTools.contains(where: { remoteToolNames.contains($0) })
        if hasAssignedRemoteTool {
            if !effectivePermissions.contains("workspaceRead") {
                effectivePermissions.append("workspaceRead")
            }
            if !effectivePermissions.contains("workspaceWrite") {
                effectivePermissions.append("workspaceWrite")
            }
        }

        var remoteToolSchemas: [String: String] = [:]
        for toolID in effectiveTools {
            if let schema = mcpManager.toolSchemaDescription(forToolName: toolID) {
                remoteToolSchemas[toolID] = schema
            }
        }

        let request = LiveProviderTaskRequest(
            goal: goal,
            objective: packet.objective,
            roleContext: packet.assignedNodeName,
            requiredInputSchema: packet.requiredInputSchema,
            requiredOutputSchema: packet.requiredOutputSchema,
            outputSchemaDescription: packet.outputSchemaDescription,
            handoffSummaries: handoffSummaries,
            allowedPermissions: effectivePermissions,
            assignedTools: effectiveTools,
            assignedToolNames: effectiveTools.map { MCPToolRegistry.toolsByID[$0]?.name ?? $0 },
            remoteToolSchemas: remoteToolSchemas
        )

        do {
            let preferredModel = providerModelStore.defaultModel(for: provider)
            let output = try await liveProviderExecutor.execute(
                provider: provider,
                apiKey: trimmedKey,
                request: request,
                preferredModelID: preferredModel
            )
            let normalized = output.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let needsHumanReview = normalized.contains("HUMAN_REVIEW_REQUESTED")
            let completed = !normalized.lowercased().hasPrefix("blocked") && !needsHumanReview
            return MCPTaskResponse(
                summary: normalized,
                confidence: completed ? 0.9 : (needsHumanReview ? 0.7 : 0.4),
                completed: completed,
                inputTokens: output.inputTokens,
                outputTokens: output.outputTokens,
                modelID: output.modelID,
                systemPrompt: output.systemPrompt,
                userPrompt: output.userPrompt,
                rawResponse: output.rawResponse
            )
        } catch {
            let workflowError = WorkflowError.providerExecutionFailed(provider: provider, underlying: error)
            return MCPTaskResponse(
                summary: "Live run failed for \(node.name): \(workflowError.userMessage)",
                confidence: 0,
                completed: false
            )
        }
    }
}

enum StructureResponseParserService {
    static func stripCodeFences(_ text: String) -> String {
        var cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix("```json") {
            cleaned = String(cleaned.dropFirst(7))
        } else if cleaned.hasPrefix("```") {
            cleaned = String(cleaned.dropFirst(3))
        }
        if cleaned.hasSuffix("```") {
            cleaned = String(cleaned.dropLast(3))
        }
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func looksLikeTruncatedJSON(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{") || trimmed.hasPrefix("[") else { return false }
        let opens = trimmed.filter { $0 == "{" || $0 == "[" }.count
        let closes = trimmed.filter { $0 == "}" || $0 == "]" }.count
        return opens > closes
    }

    static func parseStructureChatModelResponse(
        from raw: String,
        serverToolExpansion: [String: [String]]
    ) throws -> StructureChatTurnResult {
        let cleaned = stripCodeFences(raw)
        guard let data = cleaned.data(using: .utf8) else {
            return .chat(raw.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        guard let envelope = try? JSONDecoder().decode(StructureChatResponseEnvelope.self, from: data) else {
            if looksLikeTruncatedJSON(cleaned) {
                return .chat("⚠️ The response was cut off (output token limit). Try a more capable model for structure chat, or simplify your request.")
            }
            return .chat(raw.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        let mode = (envelope.mode ?? "chat").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if mode == "update" || envelope.structure != nil || (envelope.nodes != nil && envelope.links != nil) {
            let response: GeneratedStructureResponse?
            if let structure = envelope.structure {
                response = structure
            } else if let nodes = envelope.nodes, let links = envelope.links {
                response = GeneratedStructureResponse(nodes: nodes, links: links)
            } else {
                response = nil
            }

            if let response {
                let snapshot = try snapshotFromGeneratedStructure(response, serverToolExpansion: serverToolExpansion)
                let message = envelope.message?.trimmingCharacters(in: .whitespacesAndNewlines)
                let resolvedMessage = (message?.isEmpty == false) ? (message ?? "") : "Applied structure update."
                return .update(message: resolvedMessage, snapshot: snapshot)
            }
        }

        let message = envelope.message?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let message, !message.isEmpty {
            return .chat(message)
        }
        return .chat(raw.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func parseGeneratedStructure(
        from raw: String,
        serverToolExpansion: [String: [String]]
    ) throws -> HierarchySnapshot {
        let cleaned = stripCodeFences(raw)

        guard let data = cleaned.data(using: .utf8) else {
            throw GenerateStructureError.invalidJSON("Response was not valid UTF-8 text.")
        }

        let decoded: GeneratedStructureResponse
        do {
            decoded = try JSONDecoder().decode(GeneratedStructureResponse.self, from: data)
        } catch {
            throw GenerateStructureError.invalidJSON("Could not parse JSON: \(error.localizedDescription)")
        }

        guard !decoded.nodes.isEmpty else {
            throw GenerateStructureError.emptyStructure
        }

        return try snapshotFromGeneratedStructure(decoded, serverToolExpansion: serverToolExpansion)
    }

    private static func snapshotFromGeneratedStructure(
        _ decoded: GeneratedStructureResponse,
        serverToolExpansion: [String: [String]]
    ) throws -> HierarchySnapshot {
        guard !decoded.nodes.isEmpty else {
            throw GenerateStructureError.emptyStructure
        }

        let nodeIDMap = Dictionary(uniqueKeysWithValues: decoded.nodes.map { ($0.id, $0.parsedID) })

        let snapshotNodes = decoded.nodes.map { node in
            let resolvedTools: [String]? = node.assignedTools.map { tools in
                tools.flatMap { toolID -> [String] in
                    if let expanded = serverToolExpansion[toolID.lowercased()] {
                        return expanded
                    }
                    return [toolID]
                }
            }

            return HierarchySnapshotNode(
                id: nodeIDMap[node.id] ?? UUID(),
                name: node.name,
                title: node.title ?? node.name,
                department: node.department ?? "General",
                type: NodeType(rawValue: node.type) ?? .agent,
                provider: LLMProvider(rawValue: node.provider) ?? .chatGPT,
                roleDescription: node.roleDescription ?? node.name,
                inputSchema: nil,
                outputSchema: node.outputSchema,
                outputSchemaDescription: node.outputSchemaDescription,
                selectedRoles: [],
                securityAccess: (node.securityAccess ?? []).compactMap { SecurityAccess(rawValue: $0) },
                assignedTools: resolvedTools,
                positionX: node.positionX ?? 400,
                positionY: node.positionY ?? 0
            )
        }

        let snapshotLinks = decoded.links.compactMap { link -> HierarchySnapshotLink? in
            guard let fromID = nodeIDMap[link.fromID], let toID = nodeIDMap[link.toID] else {
                return nil
            }
            let tone = LinkTone(rawValue: link.tone ?? "blue") ?? .blue
            return HierarchySnapshotLink(fromID: fromID, toID: toID, tone: tone)
        }

        return HierarchySnapshot(nodes: snapshotNodes, links: snapshotLinks)
    }
}
