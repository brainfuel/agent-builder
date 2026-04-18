import Foundation
import SwiftData

@MainActor
protocol GraphPersistenceServicing {
    func configure(undoManager: UndoManager?)
    func insertTemplate(_ template: UserNodeTemplate)
    func insertGraphDocument(_ document: GraphDocument)
    func deleteGraphDocument(_ document: GraphDocument)
    func deleteGraphDocuments(_ documents: [GraphDocument])
    func save(operation: String) -> Result<Void, WorkflowError>
}

@MainActor
final class SwiftDataGraphPersistenceService: GraphPersistenceServicing {
    private let modelContext: ModelContext

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    func configure(undoManager: UndoManager?) {
        modelContext.undoManager = undoManager
    }

    func insertTemplate(_ template: UserNodeTemplate) {
        modelContext.insert(template)
    }

    func insertGraphDocument(_ document: GraphDocument) {
        modelContext.insert(document)
    }

    func deleteGraphDocument(_ document: GraphDocument) {
        modelContext.delete(document)
    }

    func deleteGraphDocuments(_ documents: [GraphDocument]) {
        for document in documents {
            modelContext.delete(document)
        }
    }

    func save(operation: String) -> Result<Void, WorkflowError> {
        do {
            try modelContext.save()
            return .success(())
        } catch {
            return .failure(.persistenceFailed(operation: operation, underlying: error))
        }
    }
}
