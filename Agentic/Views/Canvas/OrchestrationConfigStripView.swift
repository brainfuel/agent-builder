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
                clearableTopStripField(
                    "Task title",
                    text: activeTaskTitleText,
                    helpText: "Task title"
                )
                .frame(maxWidth: 260)

                Image(systemName: "doc.text")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                clearableTopStripField(
                    "Context (optional)",
                    text: $structure.synthesisContext,
                    helpText: "Add extra context for the team"
                )
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
                                .help("Answer this discovery question")
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
                    .help("Apply suggested structure")

                    Button("Discard", role: .destructive) {
                        onDiscardSynthesizedStructure()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .help("Discard suggested structure")
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

    private func clearableTopStripField(
        _ placeholder: String,
        text: Binding<String>,
        helpText: String
    ) -> some View {
        HStack(spacing: 4) {
            TextField(placeholder, text: text)
                .textFieldStyle(.plain)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(helpText)

            if !text.wrappedValue.isEmpty {
                Button {
                    text.wrappedValue = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear \(placeholder)")
                .help("Clear")
            }
        }
        .padding(.horizontal, 6)
        .frame(height: 24)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color(UIColor.systemBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(Color(UIColor.separator), lineWidth: 1)
        )
    }
}
