import SwiftUI

/// Owns structure synthesis, LLM generation, and structure chat state.
/// Contains all structure-related business logic extracted from ContentView.
@Observable
final class StructureViewModel {

    // MARK: - Synthesis State

    var synthesisContext = ""
    var synthesisQuestions: [SynthesisQuestionState] = []
    var synthesizedStructure: HierarchySnapshot?
    var synthesisStatusMessage: String?

    // MARK: - LLM Generation

    var isShowingGenerateProviderPicker = false
    var isGeneratingStructure = false
    var generateStructureError: String?

    // MARK: - Structure Chat

    var structureChatMessages: [StructureChatMessageEntry] = []
    var structureChatInput = ""
    var structureChatProvider: APIKeyProvider = .chatGPT
    var isStructureChatRunning = false
    var structureChatStatusMessage: String?
    var structureChatDebugRunningMessageIDs: Set<UUID> = []
    var structureChatDebugCompletedMessageIDs: Set<UUID> = []

    // MARK: - Injected Dependencies

    /// Injected once by ContentView on appear — holds API key, model prefs, LLM executor, and MCP manager.
    var dependencies: AppDependencies?
    /// Kept in sync by ContentView via onChange — the live @Query result from SwiftData.
    var mcpServerConnections: [MCPServerConnection] = []

    // MARK: - Callbacks

    /// Called after structure chat state changes that should be persisted.
    var onPersistChatState: (() -> Void)?
    /// Called when a structure snapshot should be applied to the canvas.
    var onApplySnapshot: ((HierarchySnapshot, Bool) -> Void)?

    // MARK: - Synthesis Helpers

    func discardSynthesizedStructure() {
        synthesizedStructure = nil
        synthesisStatusMessage = nil
    }

    func startFreshChat() {
        structureChatMessages = []
        structureChatInput = ""
        structureChatStatusMessage = nil
        structureChatDebugRunningMessageIDs = []
        structureChatDebugCompletedMessageIDs = []
    }

    // MARK: - Local Synthesis (no LLM)

    func generateSuggestedStructure(
        taskQuestion: String,
        structureStrategy: String
    ) {
        guard !structureStrategy.isEmpty else {
            synthesisStatusMessage = "Enter a task question or structure strategy first."
            return
        }

        let synthesizerInputGoal: String
        if taskQuestion.isEmpty {
            synthesizerInputGoal = structureStrategy
        } else {
            synthesizerInputGoal = "Task question: \(taskQuestion)\nStructure strategy: \(structureStrategy)"
        }

        let synthesizer = TeamStructureSynthesizer()
        let requiredQuestions = synthesizer.discoveryQuestions(goal: synthesizerInputGoal, context: synthesisContext)
        let previousAnswers = Dictionary(uniqueKeysWithValues: synthesisQuestions.map { ($0.key, $0.answer) })
        synthesisQuestions = requiredQuestions.map {
            SynthesisQuestionState(key: $0, answer: previousAnswers[$0] ?? "")
        }

        let answers = Dictionary(uniqueKeysWithValues: synthesisQuestions.map {
            ($0.key, $0.answer.trimmingCharacters(in: .whitespacesAndNewlines))
        })

        synthesizedStructure = synthesizer.synthesize(
            goal: synthesizerInputGoal,
            context: synthesisContext,
            answers: answers
        )

        let unansweredCount = synthesisQuestions.filter {
            $0.answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }.count

        if unansweredCount > 0 {
            synthesisStatusMessage =
                "Draft generated. \(unansweredCount) discovery question(s) are unanswered; fill them and re-generate for a tighter team plan."
        } else {
            synthesisStatusMessage = "Suggested structure generated from question, strategy, context, and discovery answers."
        }
    }

    // MARK: - LLM Structure Generation

    @MainActor
    func generateStructureWithLLM(
        provider: APIKeyProvider,
        taskQuestion: String,
        structureStrategy: String
    ) async {
        guard let deps = dependencies else { return }
        guard !structureStrategy.isEmpty else {
            synthesisStatusMessage = "Enter a task question or structure strategy first."
            return
        }
        let apiKey: String
        switch deps.loadAPIKey(for: provider) {
        case .success(let key): apiKey = key
        case .failure(let err):
            generateStructureError = err.userMessage
            return
        }
        let preferredModelID = deps.providerModelStore.defaultModel(for: provider)
        let availableProviders = deps.availableProviders().map(\.rawValue)
        let serverToolExpansion = deps.makeServerToolExpansionMap(connections: mcpServerConnections)

        isGeneratingStructure = true
        generateStructureError = nil
        synthesisStatusMessage = "Generating structure with \(provider.label)…"

        let contextText = synthesisContext.trimmingCharacters(in: .whitespacesAndNewlines)
        let systemPrompt = buildGenerateStructureSystemPrompt(availableProviders: availableProviders)
        let userPrompt = buildGenerateStructureUserPrompt(
            taskQuestion: taskQuestion,
            structureStrategy: structureStrategy,
            context: contextText
        )

        print("[GenerateStructure] Provider: \(provider.label)")
        print("[GenerateStructure] Model: \(preferredModelID ?? "auto")")
        print("[GenerateStructure] System prompt length: \(systemPrompt.count) chars")
        print("[GenerateStructure] User prompt length: \(userPrompt.count) chars")

        do {
            let llmService = LLMResponseService(liveProviderExecutor: deps.liveProviderExecutor)
            let llmResponse = try await llmService.requestRawText(
                provider: provider,
                apiKey: apiKey,
                preferredModelID: preferredModelID,
                systemPrompt: systemPrompt,
                messages: [ChatMessage(role: .user, text: userPrompt, attachments: [])]
            )
            print("[GenerateStructure] Resolved model: \(llmResponse.modelID)")

            let raw = llmResponse.rawText
            print("[GenerateStructure] Raw response length: \(raw.count) chars")

            var snapshot = try StructureResponseParserService.parseGeneratedStructure(
                from: raw,
                serverToolExpansion: serverToolExpansion
            )
            print("[GenerateStructure] Parsed \(snapshot.nodes.count) nodes, \(snapshot.links.count) links")

            let validProviders = Set(availableProviders.compactMap { LLMProvider(rawValue: $0) })
            let fallbackProvider = LLMProvider(rawValue: provider.rawValue) ?? .chatGPT
            snapshot.nodes = snapshot.nodes.map { node in
                var fixed = node
                if !validProviders.contains(node.provider) {
                    print("[GenerateStructure] Fixing provider for \(node.name): \(node.provider.rawValue) → \(fallbackProvider.rawValue)")
                    fixed.provider = fallbackProvider
                }
                return fixed
            }

            onApplySnapshot?(snapshot, false)
            let nodeNames = snapshot.nodes.map { $0.name }.joined(separator: ", ")
            synthesisStatusMessage = "Applied \(snapshot.nodes.count) nodes from \(provider.label): \(nodeNames). Use Undo to revert."
            print("[GenerateStructure] Applied to canvas: \(nodeNames)")
        } catch {
            print("[GenerateStructure] ERROR: \(error)")
            generateStructureError = "Generation failed: \(Self.userFacingErrorMessage(error))"
            synthesisStatusMessage = nil
        }

        isGeneratingStructure = false
    }

    // MARK: - Structure Chat Execution

    func submitStructureChatTurn(currentSnapshotJSON: String) {
        guard dependencies != nil else { return }
        let prompt = structureChatInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !isStructureChatRunning else { return }

        structureChatInput = ""
        structureChatMessages.append(StructureChatMessageEntry(role: .user, text: prompt))
        onPersistChatState?()

        Task { [weak self] in
            await self?.executeStructureChatTurn(userPrompt: prompt, currentSnapshotJSON: currentSnapshotJSON)
        }
    }

    @MainActor
    private func executeStructureChatTurn(userPrompt: String, currentSnapshotJSON: String) async {
        guard let deps = dependencies else { return }

        let apiKey: String
        switch deps.loadAPIKey(for: structureChatProvider) {
        case .success(let key):
            apiKey = key
        case .failure:
            let message = "No API key configured for \(structureChatProvider.label)."
            structureChatMessages.append(StructureChatMessageEntry(role: .assistant, text: message))
            structureChatStatusMessage = message
            onPersistChatState?()
            return
        }

        isStructureChatRunning = true
        structureChatStatusMessage = "Thinking…"
        defer { isStructureChatRunning = false }

        do {
            let preferredModelID = deps.providerModelStore.defaultModel(for: structureChatProvider)
            let providerStrings = deps.availableProviders().map(\.rawValue)
            let serverToolExpansion = deps.makeServerToolExpansionMap(connections: mcpServerConnections)
            let systemPrompt = buildStructureChatSystemPrompt(
                availableProviders: providerStrings,
                mcpServerConnections: mcpServerConnections,
                mcpManager: deps.mcpManager
            )
            let turnPrompt = buildStructureChatTurnPrompt(userPrompt: userPrompt, snapshotJSON: currentSnapshotJSON)

            let history = Array(structureChatMessages.dropLast().suffix(12))
            var messages = history.map { entry in
                ChatMessage(role: entry.role == .user ? .user : .assistant, text: entry.text, attachments: [])
            }
            messages.append(ChatMessage(role: .user, text: turnPrompt, attachments: []))

            let llmService = LLMResponseService(liveProviderExecutor: deps.liveProviderExecutor)
            let llmResponse = try await llmService.requestRawText(
                provider: structureChatProvider,
                apiKey: apiKey,
                preferredModelID: preferredModelID,
                systemPrompt: systemPrompt,
                messages: messages
            )
            let result = try StructureResponseParserService.parseStructureChatModelResponse(
                from: llmResponse.rawText,
                serverToolExpansion: serverToolExpansion
            )
            switch result {
            case .chat(let message):
                structureChatMessages.append(
                    StructureChatMessageEntry(role: .assistant, text: message, rawResponse: llmResponse.rawText)
                )
                structureChatStatusMessage = "Response received."
            case .update(let message, let snapshot):
                onApplySnapshot?(snapshot, true)
                structureChatMessages.append(
                    StructureChatMessageEntry(
                        role: .assistant, text: message,
                        appliedStructureUpdate: true, rawResponse: llmResponse.rawText
                    )
                )
                structureChatStatusMessage = "Applied structure update. Use Undo to revert."
            }
            onPersistChatState?()
        } catch {
            let message = "Structure chat failed: \(Self.userFacingErrorMessage(error))"
            structureChatMessages.append(StructureChatMessageEntry(role: .assistant, text: message))
            structureChatStatusMessage = message
            onPersistChatState?()
        }
    }

    // MARK: - Debug Broadcast

    func runStructureChatDebugBroadcast(for entry: StructureChatMessageEntry, currentSnapshotJSON: String) {
        guard !structureChatDebugRunningMessageIDs.contains(entry.id) else { return }
        Task { [weak self] in
            await self?.executeStructureChatDebugBroadcast(for: entry, currentSnapshotJSON: currentSnapshotJSON)
        }
    }

    @MainActor
    private func executeStructureChatDebugBroadcast(
        for entry: StructureChatMessageEntry,
        currentSnapshotJSON: String
    ) async {
        guard let deps = dependencies else { return }

        structureChatDebugRunningMessageIDs.insert(entry.id)
        structureChatDebugCompletedMessageIDs.remove(entry.id)
        defer { structureChatDebugRunningMessageIDs.remove(entry.id) }

        let availableProviders = deps.availableProviders()
        guard !availableProviders.isEmpty else {
            structureChatStatusMessage = "Debug failed: add at least one provider key in Keys."
            return
        }

        let providerStrings = availableProviders.map(\.rawValue)
        let systemPrompt = buildStructureChatSystemPrompt(
            availableProviders: providerStrings,
            mcpServerConnections: mcpServerConnections,
            mcpManager: deps.mcpManager
        )
        let turnPrompt = buildStructureChatTurnPrompt(userPrompt: entry.text, snapshotJSON: currentSnapshotJSON)

        let historyEntries: [StructureChatMessageEntry]
        if let entryIndex = structureChatMessages.firstIndex(where: { $0.id == entry.id }) {
            historyEntries = Array(structureChatMessages.prefix(entryIndex).suffix(12))
        } else {
            historyEntries = Array(structureChatMessages.suffix(12))
        }

        var messages = historyEntries.map { item in
            ChatMessage(role: item.role == .user ? .user : .assistant, text: item.text, attachments: [])
        }
        messages.append(ChatMessage(role: .user, text: turnPrompt, attachments: []))

        structureChatStatusMessage = "Debugging \(availableProviders.count) provider(s)…"

        let llmService = LLMResponseService(liveProviderExecutor: deps.liveProviderExecutor)
        var results: [StructureChatProviderDebugResult] = []
        for provider in availableProviders {
            let preferredModelID = deps.providerModelStore.defaultModel(for: provider)
            let apiKey = try? deps.apiKeyStore.key(for: provider)
            let result = await llmService.executeDebugRequest(
                provider: provider,
                apiKey: apiKey,
                preferredModelID: preferredModelID,
                systemPrompt: systemPrompt,
                messages: messages
            )
            results.append(result)
        }

        let orderedResults = results.sorted {
            $0.provider.rawValue.localizedCaseInsensitiveCompare($1.provider.rawValue) == .orderedAscending
        }
        let report = structureChatDebugClipboardReport(
            userMessage: entry.text,
            historyEntries: historyEntries,
            systemPrompt: systemPrompt,
            turnPrompt: turnPrompt,
            sentMessages: messages,
            results: orderedResults
        )
        copyTextToClipboard(report)

        structureChatDebugCompletedMessageIDs.insert(entry.id)
        let successCount = orderedResults.filter { $0.errorMessage == nil }.count
        structureChatStatusMessage = "Debug complete: \(successCount)/\(orderedResults.count) responded. Copied to clipboard."
    }

    private func structureChatDebugClipboardReport(
        userMessage: String,
        historyEntries: [StructureChatMessageEntry],
        systemPrompt: String,
        turnPrompt: String,
        sentMessages: [ChatMessage],
        results: [StructureChatProviderDebugResult]
    ) -> String {
        var lines: [String] = []
        lines.append("Structure Chat Debug Broadcast")
        lines.append("Generated: \(ISO8601DateFormatter().string(from: Date()))")
        lines.append("")
        lines.append("Original user text:")
        lines.append(userMessage)
        lines.append("")
        lines.append("SYSTEM PROMPT")
        lines.append(systemPrompt)
        lines.append("")
        lines.append("TURN PROMPT (includes current graph snapshot)")
        lines.append(turnPrompt)
        lines.append("")
        lines.append("CHAT HISTORY SENT (\(historyEntries.count) messages)")
        for (index, entry) in historyEntries.enumerated() {
            lines.append("\(index + 1). [\(entry.role.rawValue)] \(entry.text)")
        }
        lines.append("")
        lines.append("FINAL MESSAGE PAYLOAD SENT (\(sentMessages.count) messages)")
        for (index, message) in sentMessages.enumerated() {
            lines.append("\(index + 1). [\(message.role.rawValue)] \(message.text)")
        }
        lines.append("")
        lines.append("PROVIDER RESPONSES")
        for result in results {
            lines.append("")
            lines.append("=== \(result.provider.label) ===")
            lines.append("Preferred model: \(result.preferredModelID ?? "auto")")
            lines.append("Resolved model: \(result.resolvedModelID ?? "unresolved")")
            if let errorMessage = result.errorMessage {
                lines.append("Error: \(errorMessage)")
            } else {
                lines.append("Response:")
                lines.append(result.responseText ?? "")
            }
        }
        return lines.joined(separator: "\n")
    }

    func applyTemplateFromStructureChat(_ template: PresetHierarchyTemplate?, label: String, simpleTaskSnapshot: HierarchySnapshot) {
        let snapshot = template?.snapshot() ?? simpleTaskSnapshot
        onApplySnapshot?(snapshot, true)
        structureChatMessages.append(
            StructureChatMessageEntry(
                role: .assistant,
                text: "Applied template: \(label).",
                appliedStructureUpdate: true
            )
        )
        structureChatStatusMessage = "Applied \(label)."
        onPersistChatState?()
    }

    // MARK: - Synthesis Preview

    func summarizeSynthesisPreview(for snapshot: HierarchySnapshot, currentNodes: [OrgNode]) -> SynthesisPreviewSummary {
        let currentNames = Set(currentNodes.map { $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
        let suggestedNames = Set(snapshot.nodes.map { $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })

        let addedNames = snapshot.nodes
            .map(\.name)
            .filter { !currentNames.contains($0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) }
            .sorted()
        let removedNames = currentNodes
            .map(\.name)
            .filter { !suggestedNames.contains($0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) }
            .sorted()

        return SynthesisPreviewSummary(
            suggestedNodeCount: snapshot.nodes.count,
            suggestedLinkCount: snapshot.links.count,
            nodeDelta: snapshot.nodes.count - currentNodes.count,
            linkDelta: snapshot.links.count - currentNodes.count, // approximate
            addedNodeNames: Array(addedNames.prefix(8)),
            removedNodeNames: Array(removedNames.prefix(8))
        )
    }

    // MARK: - Prompt Building

    func buildGenerateStructureSystemPrompt(availableProviders: [String]) -> String {
        let nodeTemplateDescriptions = NodeTemplate.allCases.map { t in
            "  - \(t.label): \(t.roleDescription) [type: \(t.nodeType.rawValue), department: \(t.department)]"
        }.joined(separator: "\n")

        let schemaDescriptions = DefaultSchema.allSchemas.map { schema in
            "  - \"\(schema)\": \(DefaultSchema.defaultDescription(for: schema))"
        }.joined(separator: "\n")

        let securityOptions = SecurityAccess.allCases.map { "  - \($0.rawValue): \($0.label)" }.joined(separator: "\n")

        let providerList = availableProviders.joined(separator: ", ")
        let providerRule: String
        if availableProviders.count == 1 {
            providerRule = "- The ONLY available provider is \"\(availableProviders[0])\". You MUST set provider to \"\(availableProviders[0])\" for EVERY node. Do NOT use any other provider."
        } else {
            providerRule = "- Available providers are: \(providerList). You MUST only use these providers — no others are configured. Distribute nodes across them for diversity."
        }

        let jsonContract = String(
            format: PromptTemplateConfig.generateStructureJSONContractTemplate,
            availableProviders.first ?? "chatGPT"
        )

        return """
        \(PromptTemplateConfig.generateStructureLeadIn)

        Available node templates for inspiration:
        \(nodeTemplateDescriptions)

        Available output schema types:
        \(schemaDescriptions)
        You can also use custom schema names with a description.

        Available security permissions:
        \(securityOptions)

        Available link tones: blue, orange, teal, green, indigo

        IMPORTANT RULES:
        \(providerRule)
        \(PromptTemplateConfig.generateStructureRules)

        \(jsonContract)
        """
    }

    func buildGenerateStructureUserPrompt(
        taskQuestion: String,
        structureStrategy: String,
        context: String
    ) -> String {
        var prompt = PromptTemplateConfig.generateStructureUserLeadIn
        if !taskQuestion.isEmpty {
            prompt += "\n\n\(PromptTemplateConfig.generateStructureUserTaskQuestionHeading)\n\n\(taskQuestion)"
        }
        prompt += "\n\n\(PromptTemplateConfig.generateStructureUserStrategyHeading)\n\n\(structureStrategy)"
        if !context.isEmpty {
            prompt += "\n\n\(PromptTemplateConfig.generateStructureUserContextHeading) \(context)"
        }
        prompt += "\n\n\(PromptTemplateConfig.generateStructureUserStrictResponseInstruction)"
        return prompt
    }

    func buildStructureChatSystemPrompt(
        availableProviders: [String],
        mcpServerConnections: [MCPServerConnection],
        mcpManager: MCPServerManager
    ) -> String {
        let providerList = availableProviders.joined(separator: ", ")
        let providerRule: String
        if availableProviders.isEmpty {
            providerRule = "- If you propose providers, use only: chatGPT, gemini, claude, grok."
        } else if availableProviders.count == 1 {
            providerRule = "- The ONLY configured provider is \"\(availableProviders[0])\". Use that provider for all nodes."
        } else {
            providerRule = "- Configured providers are: \(providerList). Use only these."
        }

        var toolDescriptions: [String] = []
        for tool in MCPToolRegistry.allTools {
            toolDescriptions.append("  - \"\(tool.id)\": \(tool.description)")
        }
        for connection in mcpServerConnections where connection.isEnabled {
            let tools = mcpManager.discoveredTools[connection.id] ?? mcpManager.cachedTools(for: connection.id)
            if !tools.isEmpty {
                let toolNames = tools.prefix(10).map(\.name).joined(separator: ", ")
                toolDescriptions.append("  - \"\(connection.name.lowercased())\": Connected app with tools: \(toolNames)")
            }
        }
        let toolsSection: String
        if toolDescriptions.isEmpty {
            toolsSection = ""
        } else {
            toolsSection = """

            Available tools that can be assigned to nodes:
            \(toolDescriptions.joined(separator: "\n"))
            When the user mentions using a connected app or tool, include the relevant tool IDs in the node's assignedTools array.
            """
        }

        return """
        \(PromptTemplateConfig.structureChatLeadIn)
        \(PromptTemplateConfig.structureChatResponseContract)
        \(PromptTemplateConfig.structureChatNodeSchema)
        \(PromptTemplateConfig.structureChatLinkSchema)
        \(toolsSection)

        Rules for update mode:
        \(providerRule)
        \(PromptTemplateConfig.structureChatUpdateRules)
        """
    }

    func buildStructureChatTurnPrompt(userPrompt: String, snapshotJSON: String) -> String {
        String(format: PromptTemplateConfig.structureChatTurnTemplate, userPrompt, snapshotJSON)
    }

    // MARK: - State Sync

    func syncFromBundle(_ decoded: StructureChatStateBundle) {
        structureChatMessages = decoded.messages
        if let provider = APIKeyProvider(rawValue: decoded.providerRaw) {
            structureChatProvider = provider
        }
    }

    func resetChatState() {
        structureChatMessages = []
        structureChatInput = ""
        structureChatStatusMessage = nil
        structureChatDebugRunningMessageIDs = []
        structureChatDebugCompletedMessageIDs = []
    }

    func buildChatStateBundle() -> StructureChatStateBundle {
        StructureChatStateBundle(
            messages: structureChatMessages,
            providerRaw: structureChatProvider.rawValue
        )
    }

    // MARK: - Document Sync

    /// Restores structure chat state from a persisted document.
    func load(from document: GraphDocument?, defaultProvider: APIKeyProvider) {
        let storedContext = document?.context ?? ""
        if synthesisContext != storedContext { synthesisContext = storedContext }

        guard
            let data = document?.structureChatData,
            let decoded = try? JSONDecoder().decode(StructureChatStateBundle.self, from: data)
        else {
            structureChatMessages = []
            structureChatInput = ""
            structureChatStatusMessage = nil
            isStructureChatRunning = false
            structureChatProvider = defaultProvider
            structureChatDebugRunningMessageIDs = []
            structureChatDebugCompletedMessageIDs = []
            return
        }

        structureChatMessages = decoded.messages
        structureChatProvider = APIKeyProvider(rawValue: decoded.providerRaw) ?? defaultProvider
        structureChatInput = ""
        structureChatStatusMessage = nil
        isStructureChatRunning = false
        structureChatDebugRunningMessageIDs = []
        structureChatDebugCompletedMessageIDs = []
    }

    /// Writes structure chat state to the document and calls `onSave`.
    func persist(to document: GraphDocument, onSave: () -> Void) {
        let payload = StructureChatStateBundle(
            messages: structureChatMessages,
            providerRaw: structureChatProvider.rawValue
        )
        guard let data = try? JSONEncoder().encode(payload) else { return }
        document.structureChatData = data
        document.updatedAt = Date()
        onSave()
    }

    // MARK: - Helpers

    static func userFacingErrorMessage(_ error: Error) -> String {
        if let workflowError = error as? WorkflowError {
            return workflowError.userMessage
        }
        if let structureError = error as? GenerateStructureError {
            return structureError.localizedDescription
        }
        return error.localizedDescription
    }
}
