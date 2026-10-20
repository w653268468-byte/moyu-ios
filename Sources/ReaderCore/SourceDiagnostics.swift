import Foundation

public struct SourceDiagnostics: Sendable, Equatable {
    public var search: String?
    public var full: String?
    public static func analyze(_ sources: [BookSource]) async throws -> [String: SourceDiagnostics] {
        let worker = Task.detached(priority: .utility) {
            var result: [String: SourceDiagnostics] = [:]
            result.reserveCapacity(sources.count)
            for source in sources {
                try Task.checkCancellation()
                result[source.id] = SourceDiagnostics(search: source.searchIncompatibility, full: source.incompatibility)
            }
            return result
        }
        return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }
}
