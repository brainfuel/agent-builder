import SwiftUI

struct TaskCardViewModel {
    let document: GraphDocument
    let status: TaskRunStatus

    var titleText: String {
        let raw = document.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return raw.isEmpty ? "Untitled Task" : raw
    }

    var goalText: String {
        let raw = document.goal?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return raw.isEmpty ? "No goal set." : raw
    }

    var updatedText: String {
        document.updatedAt.formatted(date: .abbreviated, time: .shortened)
    }

    var statusLabel: String { status.label }
    var statusColor: Color { status.color }
}
