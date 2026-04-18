import SwiftUI

/// Strip below the header: task title/goal/context text fields, discovery questions, and synthesis preview controls.
struct OrchestrationConfigStripView: View {
    @Bindable var execution: ExecutionViewModel
    @Bindable var structure: StructureViewModel

    let activeTaskTitleText: Binding<String>
    let orphanCount: Int
    let synthesisPreview: SynthesisPreviewSummary?
    let onApplySynthesizedStructure: () -> Void
    let onDiscardSynthesizedStructure: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "textformat")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                TextField("Task title", text: activeTaskTitleText)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
                    .lineLimit(1)

                Image(systemName: "text.bubble")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                TextField("What should the team answer?", text: $execution.orchestrationGoal)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
                    .lineLimit(1)

                Image(systemName: "doc.text")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                TextField("Context (optional)", text: $structure.synthesisContext)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
                    .lineLimit(1)
            }

            if orphanCount > 0 {
                Text(
                    "\(orphanCount) orphan \(orphanCount == 1 ? "node" : "canvas.nodes") disconnected — excluded from runs."
                )
                .font(.caption2)
                .foregroundStyle(.orange)
            }

            if !structure.synthesisQuestions.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Discovery Questions")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach($structure.synthesisQuestions) { $question in
                        HStack(spacing: 6) {
                            Text(question.key.prompt)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            TextField("Answer", text: $question.answer)
                                .textFieldStyle(.roundedBorder)
                                .font(.caption2)
                        }
                    }
                }
            }

            if let synthesisPreview {
                HStack(spacing: 8) {
                    Text(
                        "Suggested: \(synthesisPreview.suggestedNodeCount) canvas.nodes (\(synthesisPreview.nodeDeltaString)), \(synthesisPreview.suggestedLinkCount) canvas.links (\(synthesisPreview.linkDeltaString))"
                    )
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                    Button {
                        onApplySynthesizedStructure()
                    } label: {
                        Label("Apply", systemImage: "checkmark.circle")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.mini)

                    Button("Discard", role: .destructive) {
                        onDiscardSynthesizedStructure()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                }
            }

            if let synthesisStatusMessage = structure.synthesisStatusMessage {
                Text(synthesisStatusMessage)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if let generateStructureError = structure.generateStructureError {
                Text(generateStructureError)
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(AppTheme.surfaceSecondary)
    }
}
