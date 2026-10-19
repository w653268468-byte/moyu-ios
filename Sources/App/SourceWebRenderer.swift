import Foundation
import UIKit
import WebKit

@MainActor
enum SourceWebRenderer {
    private static var active = 0
    static func render(_ request: URLRequest, cookies: [HTTPCookie]) async throws -> (Data, URL) {
        let until = Date().addingTimeInterval(15)
        while active >= 2 {
            try Task.checkCancellation()
            guard Date() < until else { throw SourceError.message("动态网页正在忙，请稍后重试。") }
            try await Task.sleep(for: .milliseconds(100))
        }
        active += 1; defer { active -= 1 }
        let renderer = RenderSession(request: request)
        return try await renderer.run(cookies: cookies)
    }
}

@MainActor
private final class RenderSession: NSObject, WKNavigationDelegate, WKUIDelegate {
    private let request: URLRequest
    private let web: WKWebView
    private var continuation: CheckedContinuation<(Data, URL), Error>?
    private var timeout: Task<Void, Never>?
    private var poll: Task<Void, Never>?
    init(request: URLRequest) {
        self.request = request
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        web = WKWebView(frame: CGRect(x: -10000, y: 0, width: 390, height: 844), configuration: configuration)
        super.init()
        web.navigationDelegate = self; web.uiDelegate = self
        web.customUserAgent = request.value(forHTTPHeaderField: "User-Agent")
    }
    func run(cookies: [HTTPCookie]) async throws -> (Data, URL) {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                timeout = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(30)) } catch { return }
                    self?.finish(.failure(SourceError.message("动态网页渲染超过 30 秒，请通过网页登录/验证后重试。")))
                }
                Task { [weak self] in
                    guard let self else { return }
                    for cookie in cookies where request.url.map({ SourceCookies.belongs(cookie, to: $0) }) == true {
                        await web.configuration.websiteDataStore.httpCookieStore.setCookie(cookie)
                    }
                    guard self.continuation != nil else { return }
                    let window = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first(where: \.isKeyWindow)
                    window?.addSubview(web)
                    web.load(request)
                }
            }
        } onCancel: { Task { @MainActor [weak self] in self?.finish(.failure(CancellationError())) } }
    }
    private func finish(_ result: Result<(Data, URL), Error>) {
        guard let continuation else { return }
        self.continuation = nil
        timeout?.cancel(); poll?.cancel(); web.stopLoading()
        web.navigationDelegate = nil; web.uiDelegate = nil; web.removeFromSuperview()
        continuation.resume(with: result)
    }
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) { poll?.cancel() }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        poll?.cancel()
        poll = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: .milliseconds(1200))
                let custom = SourceRequest.webScript(request)
                if let custom, !custom.isEmpty {
                    let value = try await web.evaluateJavaScript(custom)
                    try Task.checkCancellation()
                    if let text = value as? String, !text.isEmpty { try complete(text); return }
                }
                var previous = "", stable = 0
                for _ in 0..<20 {
                    try Task.checkCancellation()
                    let value = try await web.evaluateJavaScript("document.documentElement ? document.documentElement.outerHTML : ''")
                    let html = value as? String ?? ""
                    guard html.utf8.count <= 8 * 1024 * 1024 else { throw SourceError.message("动态网页超过 8 MB。") }
                    if !html.isEmpty && html == previous { stable += 1 } else { stable = 0 }
                    previous = html
                    if stable >= 3 { try complete(html); return }
                    try await Task.sleep(for: .milliseconds(300))
                }
                guard !previous.isEmpty else { throw SourceError.message("动态网页没有返回可解析内容。") }
                try complete(previous)
            } catch {
                if !Task.isCancelled { finish(.failure(error)) }
            }
        }
    }
    private func complete(_ text: String) throws {
        guard let url = web.url ?? request.url, ["http", "https"].contains(url.scheme?.lowercased() ?? ""), text.utf8.count <= 8 * 1024 * 1024 else { throw SourceError.message("动态网页的地址或内容大小无效。") }
        finish(.success((Data(text.utf8), url)))
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(.failure(error)) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finish(.failure(error)) }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { finish(.failure(SourceError.message("动态网页进程已停止，请重试。"))) }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let allowed = ["http", "https", "about"].contains(navigationAction.request.url?.scheme?.lowercased() ?? "")
        decisionHandler(allowed ? .allow : .cancel)
        if !allowed { finish(.failure(SourceError.message("动态书源尝试打开外部 App，已停止渲染。"))) }
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if navigationResponse.isForMainFrame, let response = navigationResponse.response as? HTTPURLResponse, !(200...299).contains(response.statusCode) {
            decisionHandler(.cancel)
            finish(.failure(SourceError.message("动态网页返回 HTTP \(response.statusCode)，请在网页登录/验证后重试。")))
        } else { decisionHandler(.allow) }
    }
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) { completionHandler() }
    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) { completionHandler(false) }
    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) { completionHandler(nil) }
}
