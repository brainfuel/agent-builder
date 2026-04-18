import SwiftUI

// View-layer color mappings for domain model enums.
// Kept out of Models/ so that the domain layer stays free of SwiftUI.

extension NodeLink {
    var color: Color { tone.color }
}

extension LinkTone {
    var color: Color {
        switch self {
        case .blue:   return AppTheme.linkBlue
        case .orange: return AppTheme.linkOrange
        case .teal:   return AppTheme.linkTeal
        case .green:  return AppTheme.linkGreen
        case .indigo: return AppTheme.linkIndigo
        }
    }
}

extension TaskRunStatus {
    var color: Color {
        switch self {
        case .draft:
            return .gray
        case .inProgress:
            return .blue
        case .needsAttention:
            return .orange
        case .completed:
            return .green
        }
    }
}

extension CoordinatorTraceStatus {
    var color: Color {
        switch self {
        case .queued:
            return .gray
        case .running:
            return .blue
        case .waitingHuman:
            return .indigo
        case .succeeded:
            return .green
        case .approved:
            return .green
        case .rejected:
            return .red
        case .needsInfo:
            return .orange
        case .blocked:
            return .orange
        case .failed:
            return .red
        }
    }
}
