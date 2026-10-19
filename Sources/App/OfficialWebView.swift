import SwiftUI
import WebKit

@MainActor
enum BrowserSessions {
    static func cookies(for url: URL) async -> [HTTPCookie] {
        let cookies: [HTTPCookie] = await withCheckedContinuation { continuation in
            WKWebsiteDataStore.default().httpCookieStore.getAllCookies { continuation.resume(returning: $0) }
        }
        return cookies.filter { SourceCookies.belongs($0, to: url) }
    }
    static func clearCookies(for url: URL) async {
        let store = WKWebsiteDataStore.default().httpCookieStore
        for cookie in await cookies(for: url) {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                store.delete(cookie) { continuation.resume() }
            }
        }
    }
    static func loginURL(_ source: BookSource) -> URL? {
        guard let base = URL(string: source.bookSourceUrl) else { return nil }
        if let original = source.originalJSON?.data(using: .utf8),
           let fields = try? JSONSerialization.jsonObject(with: original) as? [String: Any],
           let raw = fields["loginUrl"] as? String, let url = try? SourceClient.resolve(raw, base: base) { return url }
        return base
    }

    #if DEBUG
    static func checkCookieSharing(client: SourceClient) async {
        let file = URL.documentsDirectory.appendingPathComponent("cookie-check.json")
        func phase(_ name: String) {
            let value = try? JSONSerialization.data(withJSONObject: ["status": "running", "phase": name])
            try? value?.write(to: file, options: .atomic)
        }
        phase("started")
        let origin = URL(string: "http://127.0.0.1:18765/login")!
        let view = WKWebView(frame: .zero)
        defer { view.stopLoading() }
        do {
            phase("clear_cookies")
            await clearCookies(for: origin)
            await client.replaceCookies([], for: origin)
            phase("web_navigation")
            view.load(URLRequest(url: origin))
            phase("cookie_poll")
            for _ in 0..<100 {
                if await cookies(for: origin).contains(where: { $0.name == "gavin_fixture" }) { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            let received = await cookies(for: origin)
            guard received.contains(where: { $0.name == "gavin_fixture" }) else { throw SourceError.message("浏览器未取得测试 Cookie。") }
            phase("http_request_cookie_received")
            let (data, _) = try await client.fetch(URL(string: "http://127.0.0.1:18765/private")!)
            guard String(data: data, encoding: .utf8) == "GAVIN_AUTHENTICATED_CHAPTER" else { throw SourceError.message("Cookie sharing failed") }
            phase("dynamic_webview_request")
            let source = try JSONDecoder().decode(BookSource.self, from: Data(##"{"bookSourceName":"Dynamic fixture","bookSourceUrl":"http://127.0.0.1:18765","ruleContent":{"content":"#content@text"}}"##.utf8))
            let chapter = OnlineChapter(title: "Dynamic chapter", url: URL(string: "http://127.0.0.1:18765/dynamic")!, requestTemplate: "http://127.0.0.1:18765/dynamic,{'webView':true}")
            let text = try await client.chapter(chapter, source: source)
            guard text == "GAVIN_RENDERED_DYNAMIC_CHAPTER" else { throw SourceError.message("动态网页未执行页面脚本或未复用登录状态。") }
            try Data(#"{"status":"passed"}"#.utf8).write(to: file, options: .atomic)
        } catch {
            let report = try? JSONSerialization.data(withJSONObject: ["status": "failed", "error": error.localizedDescription])
            try? report?.write(to: file, options: .atomic)
        }
    }
    #endif
}

@MainActor
private final class SourceBrowser: NSObject, ObservableObject, WKNavigationDelegate {
    let webView: WKWebView
    @Published var loading = false
    @Published var address = ""
    @Published var error: String?
    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 Version/17.0 Mobile/15E148 Safari/604.1"
    }
    func open(_ url: URL) { if webView.url == nil { webView.load(URLRequest(url: url)) } }
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) { loading = true; error = nil }
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) { address = webView.url?.host ?? "" }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loading = false }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failed(error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { failed(error) }
    private func failed(_ error: Error) {
        loading = false
        if (error as NSError).code != NSURLErrorCancelled { self.error = error.localizedDescription }
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { error = "网页进程已停止，请点击刷新重试。"; loading = false }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let allowed = ["http", "https", "about"].contains(navigationAction.request.url?.scheme?.lowercased() ?? "")
        decisionHandler(allowed ? .allow : .cancel)
        if !allowed { error = "此链接需要外部 App，当前窗口仅支持网页登录。" }
        if allowed, navigationAction.targetFrame == nil { webView.load(navigationAction.request) }
    }
}

private struct SourceWebFrame: UIViewRepresentable {
    let browser: WKWebView
    func makeUIView(context: Context) -> WKWebView { browser }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

@MainActor
struct OfficialWebView: View {
    @EnvironmentObject private var online: OnlineStore
    @Environment(\.dismiss) private var dismiss
    let url: URL
    @StateObject private var browser = SourceBrowser()
    @State private var saving = false
    @State private var confirmClear = false
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if browser.loading { ProgressView().frame(maxWidth: .infinity).padding(5) }
                if let error = browser.error { Text(error).font(.caption).foregroundStyle(.orange).padding(8) }
                SourceWebFrame(browser: browser.webView)
                Text("请在网站中完成登录或验证，点击完成后重新尝试解析。登录状态保存在本机，不写入书源导出或阅读备份。")
                    .font(.caption).foregroundStyle(.secondary).padding(10)
            }.navigationTitle(browser.address.isEmpty ? (url.host ?? "网站") : browser.address)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Menu {
                            Button("后退", systemImage: "chevron.left") { browser.webView.goBack() }
                            Button("刷新", systemImage: "arrow.clockwise") { browser.webView.reload() }
                            Button("清除此网站 Cookie", systemImage: "trash", role: .destructive) { confirmClear = true }
                        } label: { Image(systemName: "ellipsis.circle") }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(saving ? "保存中…" : "完成") {
                            saving = true
                            Task {
                                let cookies = await BrowserSessions.cookies(for: url)
                                await online.client.replaceCookies(cookies, for: url)
                                dismiss()
                            }
                        }.disabled(saving)
                    }
                }
                .confirmationDialog("清除这个网站的 Cookie？", isPresented: $confirmClear, titleVisibility: .visible) {
                    Button("清除", role: .destructive) {
                        Task {
                            await BrowserSessions.clearCookies(for: url)
                            await online.client.replaceCookies([], for: url)
                            browser.webView.reload()
                        }
                    }
                } message: { Text("可能需要重新登录；不会删除书架或章节缓存。") }
                .task { browser.open(url) }
        }
    }
}
