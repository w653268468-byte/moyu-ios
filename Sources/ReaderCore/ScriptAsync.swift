import Foundation

/// Waits only on the script worker; the main actor stays available for WebKit.
enum ScriptAsync {
    private final class Box<T>: @unchecked Sendable {
        let lock = NSLock()
        let signal = DispatchSemaphore(value: 0)
        private var result: Result<T, Error>?
        func finish(_ value: Result<T, Error>) { lock.lock(); result = value; lock.unlock(); signal.signal() }
        func get() throws -> T { lock.lock(); defer { lock.unlock() }; return try result!.get() }
    }
    static func run<T: Sendable>(cancelled: () -> Bool, operation: @escaping @Sendable () async throws -> T) throws -> T {
        guard !Thread.isMainThread else { throw SourceError.message("动态网页脚本需要在后台书源任务执行。") }
        let box = Box<T>()
        let task = Task.detached { do { box.finish(.success(try await operation())) } catch { box.finish(.failure(error)) } }
        defer { task.cancel() }
        let deadline = ProcessInfo.processInfo.systemUptime + 30
        while box.signal.wait(timeout: .now() + .milliseconds(50)) == .timedOut {
            if cancelled() { throw CancellationError() }
            if ProcessInfo.processInfo.systemUptime >= deadline { throw SourceError.message("动态网页脚本等待超过 30 秒。") }
        }
        return try box.get()
    }
}
