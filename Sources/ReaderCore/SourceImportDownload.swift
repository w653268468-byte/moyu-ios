import Foundation

/// Import collections are much larger than chapter pages. Receive bounded chunks,
/// with a separate timeout budget, without buffering an unbounded response.
final class SourceImportDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let configuration: URLSessionConfiguration
    private let limit: Int
    private var continuation: CheckedContinuation<(Data, URL), Error>?
    private var completed: Result<(Data, URL), Error>?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var data = Data()
    private var finalURL: URL?

    init(configuration: URLSessionConfiguration, limit: Int) {
        self.configuration = configuration.copy() as! URLSessionConfiguration
        self.limit = limit
        super.init()
        self.configuration.timeoutIntervalForRequest = 60
        self.configuration.timeoutIntervalForResource = 180
    }

    func run(_ url: URL) async throws -> (Data, URL) {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if let completed { lock.unlock(); continuation.resume(with: completed); return }
                self.continuation = continuation
                let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
                self.session = session
                var request = URLRequest(url: url)
                request.timeoutInterval = 60
                request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 Version/17.0 Mobile/15E148 Safari/604.1", forHTTPHeaderField: "User-Agent")
                request.setValue("application/json,text/plain;q=0.9,*/*;q=0.5", forHTTPHeaderField: "Accept")
                let task = session.dataTask(with: request); self.task = task
                lock.unlock()
                task.resume()
            }
        } onCancel: { self.finish(.failure(CancellationError())) }
    }

    private func finish(_ result: Result<(Data, URL), Error>) {
        lock.lock()
        guard completed == nil else { lock.unlock(); return }
        completed = result
        let continuation = self.continuation; self.continuation = nil
        let session = self.session; self.session = nil
        let task = self.task; self.task = nil
        lock.unlock()
        continuation?.resume(with: result)
        task?.cancel(); session?.invalidateAndCancel()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse, let url = http.url else {
            completionHandler(.cancel); finish(.failure(SourceError.message("书源下载未收到 HTTP 响应。"))); return
        }
        guard (200...299).contains(http.statusCode) else {
            completionHandler(.cancel); finish(.failure(SourceError.message("\(url.host ?? "网站")：书源下载返回 HTTP \(http.statusCode)。"))); return
        }
        guard http.expectedContentLength <= Int64(limit) else {
            completionHandler(.cancel); finish(.failure(SourceError.message("书源响应超过 20 MB，请拆分合集。"))); return
        }
        lock.lock(); finalURL = url
        if http.expectedContentLength > 0 { data.reserveCapacity(Int(http.expectedContentLength)) }
        lock.unlock()
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
        lock.lock()
        guard completed == nil else { lock.unlock(); return }
        guard chunk.count <= limit - data.count else {
            lock.unlock(); finish(.failure(SourceError.message("书源响应超过 20 MB，请拆分合集。"))); return
        }
        data.append(chunk); lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(.failure(error)); return }
        lock.lock(); let value = data; let url = finalURL; lock.unlock()
        guard let url else { finish(.failure(SourceError.message("书源下载没有有效地址。"))); return }
        finish(.success((value, url)))
    }
}
