import SwiftUI
import Observation

enum SidebarTab: String, CaseIterable, Identifiable {
    case tasks = "Tasks"
    case tools = "Tools"
    case settings = "Keys"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .tasks: return "list.bullet.rectangle"
        case .tools: return "wrench.and.screwdriver"
        case .settings: return "key.horizontal"
        }
    }
}

struct TaskResultsTarget: Identifiable, Equatable {
    let id: String
}

@MainActor
@Observable
final class NavigationCoordinator {
    var currentGraphKey: String?
    var isShowingTaskList: Bool = true
    var splitViewVisibility: NavigationSplitViewVisibility = .all
    var sidebarTab: SidebarTab = .tasks
    var taskResultsTarget: TaskResultsTarget?
    var isShowingNodeTemplateLibrary: Bool = false
    var isShowingSettingsPlaceholderSheet: Bool = false

    func selectFirstTaskIfNeeded(taskKeys: [String]) {
        if currentGraphKey == nil {
            currentGraphKey = taskKeys.first
        }
    }

    func reconcileCurrentTaskSelection(taskKeys: [String]) {
        guard !taskKeys.isEmpty else {
            currentGraphKey = nil
            return
        }
        guard let currentGraphKey else {
            self.currentGraphKey = taskKeys.first
            return
        }
        if !taskKeys.contains(currentGraphKey) {
            self.currentGraphKey = taskKeys.first
        }
    }

    func showTaskList() {
        isShowingTaskList = true
    }

    func showEditor() {
        isShowingTaskList = false
    }

    func showAllColumns() {
        splitViewVisibility = .all
    }

    func openTaskResults(for taskKey: String) {
        taskResultsTarget = TaskResultsTarget(id: taskKey)
    }

    func closeTaskResults() {
        taskResultsTarget = nil
    }
}
