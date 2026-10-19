import Foundation

/// Synchronous only on the interpreter queue. Native URLSession callbacks remain asynchronous.
final class ScriptHTTP {
    struct Response {
        let text: String
        let url: URL
        let status: Int
        let headers: [String: String]
        var json: [String: Any] { ["__gavinResponse": ["body": text, "url": url.absoluteString, "status": status, "headers": headers]] }
    }
    private final class Collector: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        let signal = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var bytes = Data()
        var response: HTTPURLResponse?
        var outcome: Result<Response, Error>?
        let allowHTTPError: Bool
        let followRedirects: Bool
        init(allowHTTPError: Bool, followRedirects: Bool) { self.allowHTTPError = allowHTTPError; self.followRedirects = followRedirects; super.init() }
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(followRedirects ? request : nil)
        }
        func finish(_ value: Result<Response, Error>) {
            lock.lock(); defer { lock.unlock() }
            guard outcome == nil else { return }
            outcome = value; signal.signal()
        }
        func result() throws -> Response {
            lock.lock(); defer { lock.unlock() }
            guard let outcome else { throw SourceError.message("脚本网络请求未完成。") }
            return try outcome.get()
        }
        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            guard let response = response as? HTTPURLResponse else { finish(.failure(SourceError.message("脚本网络请求没有 HTTP 响应。"))); completionHandler(.cancel); return }
            self.response = response
            guard allowHTTPError || (200...299).contains(response.statusCode) else { finish(.failure(SourceError.message("脚本请求 HTTP \(response.statusCode) · \(response.url?.host ?? "")"))); completionHandler(.cancel); return }
            guard response.expectedContentLength <= 4 * 1024 * 1024 else { finish(.failure(SourceError.message("脚本网络响应超过 4 MB。"))); completionHandler(.cancel); return }
            completionHandler(.allow)
        }
        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            guard bytes.count + data.count <= 4 * 1024 * 1024 else { finish(.failure(SourceError.message("脚本网络响应超过 4 MB。"))); dataTask.cancel(); return }
            bytes.append(data)
        }
        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            if let error { finish(.failure(error)); return }
            guard let response, let url = response.url else { finish(.failure(SourceError.message("脚本响应缺少网址。"))); return }
            do {
                let headers = Dictionary(response.allHeaderFields.map { (String(describing: $0.key), String(describing: $0.value)) }, uniquingKeysWith: { _, last in last })
                finish(.success(Response(text: try TextParser.decode(bytes), url: url, status: response.statusCode, headers: headers)))
            } catch { finish(.failure(error)) }
        }
    }
    private let configuration: URLSessionConfiguration
    init(configuration: URLSessionConfiguration) { self.configuration = configuration }
    func request(_ request: URLRequest, allowHTTPError: Bool = false, followRedirects: Bool = true, cancelled: () -> Bool) throws -> Response {
        guard !SourceRequest.requiresWebView(request) else { throw SourceError.message("同步 ajax 不能执行 WebView 请求，请在书源请求地址中设置 webView 选项。") }
        let collector = Collector(allowHTTPError: allowHTTPError, followRedirects: followRedirects)
        let config = configuration.copy() as! URLSessionConfiguration
        config.timeoutIntervalForRequest = 10; config.timeoutIntervalForResource = 15
        let session = URLSession(configuration: config, delegate: collector, delegateQueue: nil)
        let task = session.dataTask(with: request)
        defer { session.invalidateAndCancel() }
        task.resume()
        let end = ProcessInfo.processInfo.systemUptime + 15
        while collector.signal.wait(timeout: .now() + 0.1) == .timedOut {
            if cancelled() || ProcessInfo.processInfo.systemUptime >= end {
                task.cancel()
                throw SourceError.message("脚本网络请求取消或超时 · \(request.url?.host ?? "")")
            }
        }
        return try collector.result()
    }
}
