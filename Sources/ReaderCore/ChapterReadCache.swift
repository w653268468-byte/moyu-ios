import Foundation

/// Serial disk access and shared chapter requests. Cancelling a prefetch must
/// not cancel a foreground reader which has joined the same request.
public actor ChapterReadCache {
    private struct Pending: Sendable {
        let id: UUID
        let task: Task<String, Error>
        var waiters: Set<UUID>
    }
    private var pending: [URL: Pending] = [:]
    private var generation = UUID()
    public init() {}
    #if DEBUG
    func waiterCount(at file: URL) -> Int { pending[file]?.waiters.count ?? 0 }
    #endif

    public func read(at file: URL, load: @escaping @Sendable () async throws -> String) async throws -> String {
        try Task.checkCancellation()
        if let cached = try? String(contentsOf: file, encoding: .utf8), !cached.isEmpty { return cached }
        let waiter = UUID()
        let request: Pending
        if var existing = pending[file] {
            existing.waiters.insert(waiter); pending[file] = existing; request = existing
        } else {
            let version = generation, id = UUID()
            let task = Task.detached(priority: Task.currentPriority) {
                let text = try await load()
                try Task.checkCancellation()
                guard !text.isEmpty else { throw SourceError.message("正文为空，请重试或更换书源。") }
                try await self.save(text, at: file, version: version)
                return text
            }
            request = Pending(id: id, task: task, waiters: [waiter]); pending[file] = request
        }
        return try await withTaskCancellationHandler {
            do {
                let text = try await request.task.value
                try Task.checkCancellation()
                release(file, id: request.id, waiter: waiter)
                return text
            } catch {
                release(file, id: request.id, waiter: waiter)
                throw error
            }
        } onCancel: {
            Task { await self.cancelWaiter(file, id: request.id, waiter: waiter) }
        }
    }

    private func cancelWaiter(_ file: URL, id: UUID, waiter: UUID) {
        guard var request = pending[file], request.id == id else { return }
        request.waiters.remove(waiter); pending[file] = request
        guard request.waiters.isEmpty else { return }
        // SwiftUI cancels the old lookahead before starting the new chapter's
        // foreground task. Allow that reader to claim the existing request.
        Task {
            try? await Task.sleep(for: .milliseconds(200))
            if let orphan = pending[file], orphan.id == id, orphan.waiters.isEmpty {
                pending.removeValue(forKey: file); orphan.task.cancel()
            }
        }
    }

    private func save(_ text: String, at file: URL, version: UUID) throws {
        try Task.checkCancellation()
        guard generation == version else { throw CancellationError() }
        try text.write(to: file, atomically: true, encoding: .utf8)
    }
    private func release(_ file: URL, id: UUID, waiter: UUID) {
        guard var request = pending[file], request.id == id else { return }
        request.waiters.remove(waiter)
        if request.waiters.isEmpty { pending.removeValue(forKey: file); request.task.cancel() }
        else { pending[file] = request }
    }
    public func clear(in directory: URL) throws {
        generation = UUID()
        for request in pending.values { request.task.cancel() }
        pending.removeAll()
        for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        where file.pathExtension == "txt" { try FileManager.default.removeItem(at: file) }
    }
}
