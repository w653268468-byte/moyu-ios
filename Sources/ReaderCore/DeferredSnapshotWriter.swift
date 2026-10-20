import Foundation

/// Coalesces frequent progress updates without encoding or writing on the UI thread.
/// Explicit edits and backup/restore use the same serial queue as progress writes.
public final class DeferredSnapshotWriter: @unchecked Sendable {
    private struct Pending {
        let id: UUID
        let encode: @Sendable () throws -> Data
        let failure: @Sendable (Error) -> Void
    }
    private let queue = DispatchQueue(label: "Gavin.progress.persistence", qos: .utility)
    private let lock = NSLock()
    private var pending: Pending?
    private var generation = UUID()
    private let destination: URL
    private let backup: URL
    private let delay: TimeInterval

    public init(destination: URL, backup: URL, delay: TimeInterval = 0.4) {
        self.destination = destination; self.backup = backup; self.delay = delay
    }
    public func schedule(encode: @escaping @Sendable () throws -> Data, failure: @escaping @Sendable (Error) -> Void) {
        let item = Pending(id: UUID(), encode: encode, failure: failure)
        lock.lock(); generation = item.id; pending = item; lock.unlock()
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            do { try self.writePending(id: item.id) } catch { item.failure(error) }
        }
    }
    public func writeNow(encode: @Sendable () throws -> Data) throws {
        lock.lock(); generation = UUID(); pending = nil; lock.unlock()
        try queue.sync { try persist(encode()) }
    }
    public func flush() throws { try queue.sync { try writePending(id: nil) } }
    /// Use before reloading a restored index so an old timer cannot overwrite it.
    public func discardPendingAndWait() {
        lock.lock(); generation = UUID(); pending = nil; lock.unlock()
        queue.sync {}
    }
    private func writePending(id: UUID?) throws {
        lock.lock()
        guard let item = pending, id == nil || item.id == id else { lock.unlock(); return }
        pending = nil; lock.unlock()
        do { try persist(item.encode()) }
        catch {
            lock.lock(); if generation == item.id && pending == nil { pending = item }; lock.unlock()
            throw error
        }
    }
    private func persist(_ data: Data) throws {
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: destination.path) {
            try Data(contentsOf: destination).write(to: backup, options: .atomic)
        }
        try data.write(to: destination, options: .atomic)
    }
}
