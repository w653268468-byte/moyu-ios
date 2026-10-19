#if os(macOS)
import AppKit
import WebKit
import ReaderCore

/// An ephemeral browser for real-site audits; it never uses a personal browser profile.
@MainActor
enum CorpusWebRenderer {
    private static let store = WKWebsiteDataStore.nonPersistent()
    private static var active = 0
    static func cookies(_ url: URL) async -> [HTTPCookie] {
        _ = NSApplication.shared
        let all: [HTTPCookie] = await withCheckedContinuation { continuation in store.httpCookieStore.getAllCookies { continuation.resume(returning: $0) } }
        return all.filter { SourceCookies.belongs($0, to: url) }
    }
    static func render(_ request: URLRequest, cookies: [HTTPCookie]) async throws -> (Data, URL) {
        while active >= 2 { try Task.checkCancellation(); try await Task.sleep(for: .milliseconds(100)) }
        active += 1; defer { active -= 1 }
        _ = NSApplication.shared
        let session = CorpusRenderSession(request: request, store: store)
        return try await session.run(cookies)
    }
}

@MainActor
private final class CorpusRenderSession: NSObject, WKNavigationDelegate {
    private let request: URLRequest
    private let web: WKWebView
    private var continuation: CheckedContinuation<(Data, URL), Error>?
    private var timeout: Task<Void, Never>?
    private var polling: Task<Void, Never>?
    init(request: URLRequest, store: WKWebsiteDataStore) {
        self.request = request
        let configuration = WKWebViewConfiguration(); configuration.websiteDataStore = store
        web = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844), configuration: configuration)
        super.init(); web.navigationDelegate = self
        web.customUserAgent = request.value(forHTTPHeaderField: "User-Agent") ?? "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 Version/17.0 Mobile/15E148 Safari/604.1"
    }
    func run(_ cookies: [HTTPCookie]) async throws -> (Data, URL) {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                timeout = Task { [weak self] in do { try await Task.sleep(for: .seconds(25)) } catch { return }; self?.finish(.failure(SourceError.message("审计 WebView 渲染超过 25 秒。"))) }
                Task { [weak self] in
                    guard let self else { return }
                    for cookie in cookies where request.url.map({ SourceCookies.belongs(cookie, to: $0) }) == true { await web.configuration.websiteDataStore.httpCookieStore.setCookie(cookie) }
                    guard self.continuation != nil else { return }
                    if let html = SourceRequest.webHTML(request) { web.loadHTMLString(html, baseURL: request.url) }
                    else { web.load(request) }
                }
            }
        } onCancel: { Task { @MainActor [weak self] in self?.finish(.failure(CancellationError())) } }
    }
    private func finish(_ result: Result<(Data, URL), Error>) {
        guard let continuation else { return }; self.continuation = nil
        timeout?.cancel(); polling?.cancel(); web.stopLoading(); web.navigationDelegate = nil
        continuation.resume(with: result)
    }
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) { polling?.cancel() }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        polling?.cancel()
        polling = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: .milliseconds(1200))
                if let script = SourceRequest.webScript(request), !script.isEmpty {
                    let value = try await web.evaluateJavaScript(script)
                    if let text = value as? String { try complete(text); return }
                }
                var previous = "", stable = 0
                for _ in 0..<20 {
                    try Task.checkCancellation()
                    let html = try await web.evaluateJavaScript("document.documentElement ? document.documentElement.outerHTML : ''") as? String ?? ""
                    guard html.utf8.count <= 8 * 1024 * 1024 else { throw SourceError.message("审计网页超过 8 MB。") }
                    stable = !html.isEmpty && html == previous ? stable + 1 : 0; previous = html
                    if stable >= 3 { try complete(html); return }
                    try await Task.sleep(for: .milliseconds(300))
                }
                guard !previous.isEmpty else { throw SourceError.message("审计动态页面没有内容。") }; try complete(previous)
            } catch { if !Task.isCancelled { finish(.failure(error)) } }
        }
    }
    private func complete(_ text: String) throws {
        let url = web.url.flatMap { ["http", "https"].contains($0.scheme?.lowercased() ?? "") ? $0 : nil } ?? request.url
        guard let url, text.utf8.count <= 8 * 1024 * 1024 else { throw SourceError.message("审计动态页面地址或大小无效。") }
        finish(.success((Data(text.utf8), url)))
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(.failure(error)) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finish(.failure(error)) }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { finish(.failure(SourceError.message("审计 WebKit 进程终止。"))) }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) { decisionHandler(["http", "https", "about"].contains(navigationAction.request.url?.scheme?.lowercased() ?? "") ? .allow : .cancel) }
}
#endif
