import UIKit
import WebKit

/// A source-requested login/verification pauses only that source's worker.
@MainActor
enum SourceVerificationUI {
    private static var active: UUID?
    private static var controller: VerificationController?
    static func run(_ input: SourceVerificationRequest) async throws -> SourceVerificationResult {
        let id = UUID(), deadline = Date().addingTimeInterval(150)
        while active != nil {
            try Task.checkCancellation()
            guard Date() < deadline else { throw SourceError.message("其他书源正在等待验证，请稍后重试。") }
            try await Task.sleep(for: .milliseconds(100))
        }
        try Task.checkCancellation()
        active = id
        defer { if active == id { active = nil; controller = nil } }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
                guard var presenter = windows.first(where: \.isKeyWindow)?.rootViewController else {
                    continuation.resume(throwing: SourceError.message("App 当前没有可显示验证页面的窗口。")); return
                }
                while let presented = presenter.presentedViewController { presenter = presented }
                let page = VerificationController(input: input) { continuation.resume(with: $0) }
                controller = page
                let navigation = UINavigationController(rootViewController: page)
                navigation.modalPresentationStyle = .pageSheet
                presenter.present(navigation, animated: true)
                navigation.presentationController?.delegate = page
            }
        } onCancel: {
            Task { @MainActor in if active == id { controller?.finish(.failure(CancellationError())) } }
        }
    }
}

@MainActor
private final class VerificationController: UIViewController, WKNavigationDelegate, UIAdaptivePresentationControllerDelegate {
    let input: SourceVerificationRequest
    private var completion: ((Result<SourceVerificationResult, Error>) -> Void)?
    private let web: WKWebView
    private let code = UITextField()
    private let message = UILabel()
    private var loaded = false
    init(input: SourceVerificationRequest, completion: @escaping (Result<SourceVerificationResult, Error>) -> Void) {
        self.input = input; self.completion = completion
        let configuration = WKWebViewConfiguration(); configuration.websiteDataStore = .default()
        web = WKWebView(frame: .zero, configuration: configuration)
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        title = input.title.isEmpty ? "书源登录与验证" : String(input.title.prefix(60))
        navigationItem.leftBarButtonItem = UIBarButtonItem(title: "取消", style: .plain, target: self, action: #selector(cancel))
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "完成", style: .done, target: self, action: #selector(done))
        navigationItem.rightBarButtonItem?.isEnabled = false
        navigationItem.rightBarButtonItem?.accessibilityIdentifier = "source.verification.done"
        navigationItem.leftBarButtonItem?.accessibilityIdentifier = "source.verification.cancel"
        message.text = input.imageCode ? "请查看图片并输入验证码。" : "请在网站内完成登录或验证，再点完成继续解析。"
        message.numberOfLines = 3; message.font = .preferredFont(forTextStyle: .footnote); message.textColor = .secondaryLabel
        code.placeholder = "验证码"; code.borderStyle = .roundedRect; code.autocorrectionType = .no; code.autocapitalizationType = .none
        code.isHidden = !input.imageCode
        code.accessibilityIdentifier = "source.verification.code"
        let stack = UIStackView(arrangedSubviews: [message, web, code]); stack.axis = .vertical; stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            stack.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor, constant: -8),
            code.heightAnchor.constraint(equalToConstant: 44)
        ])
        web.navigationDelegate = self
        web.customUserAgent = input.request.value(forHTTPHeaderField: "User-Agent") ?? "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 Version/17.0 Mobile/15E148 Safari/604.1"
        if let html = input.html, !html.isEmpty { web.loadHTMLString(html, baseURL: input.request.url) }
        else { web.load(input.request) }
    }
    @objc private func cancel() { finish(.failure(CancellationError())) }
    @objc private func done() {
        guard loaded, let url = web.url.flatMap({ ["http", "https"].contains($0.scheme?.lowercased() ?? "") ? $0 : nil }) ?? input.request.url else { return }
        if input.imageCode && code.text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false { message.text = "请输入图片中的验证码。"; return }
        navigationItem.rightBarButtonItem?.isEnabled = false
        Task {
            do {
                let text: String
                if input.imageCode { text = code.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
                else { text = try await web.evaluateJavaScript("document.documentElement ? document.documentElement.outerHTML : ''") as? String ?? "" }
                guard text.utf8.count <= 8 * 1024 * 1024 else { throw SourceError.message("验证页面内容过大。") }
                var cookies = await BrowserSessions.cookies(for: url)
                if let original = input.request.url, original != url { cookies += await BrowserSessions.cookies(for: original) }
                finish(.success(SourceVerificationResult(text: text, url: url, cookies: cookies)))
            } catch { message.text = error.localizedDescription; navigationItem.rightBarButtonItem?.isEnabled = true }
        }
    }
    func finish(_ result: Result<SourceVerificationResult, Error>) {
        guard let callback = completion else { return }; completion = nil
        web.stopLoading(); web.navigationDelegate = nil
        if let navigationController, navigationController.presentingViewController != nil {
            navigationController.dismiss(animated: true) { callback(result) }
        } else { callback(result) }
    }
    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) { finish(.failure(CancellationError())) }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loaded = true; navigationItem.rightBarButtonItem?.isEnabled = true }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { message.text = error.localizedDescription }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let allowed = ["http", "https", "about"].contains(navigationAction.request.url?.scheme?.lowercased() ?? "")
        if allowed, navigationAction.targetFrame == nil { webView.load(navigationAction.request); decisionHandler(.cancel) }
        else { decisionHandler(allowed ? .allow : .cancel) }
    }
}

#if DEBUG
@MainActor
enum SourceVerificationCheck {
    static func run() async -> String {
        do {
            try await Task.sleep(for: .milliseconds(700))
            let engine = try SourceScript(verificationHandler: { input in try await SourceVerificationUI.run(input) })
            let result = try await Task.detached {
                try engine.evaluate("const login=java.startBrowserAwait('/login','书源验证测试',false); const privateBody=java.ajax('/private');const redirect=java.get('/source-start',null).code()===302 && java.connect('/source-start').code()===200;const code=java.getVerificationCode('/login?code'); [login.body().includes('Login complete.'),privateBody==='GAVIN_AUTHENTICATED_CHAPTER',redirect,code==='7319'].every(Boolean)", result: "", baseURL: URL(string: "http://127.0.0.1:18765")!) as? Bool
            }.value
            return result == true ? "passed" : "failed"
        } catch {
            return error is CancellationError || error.localizedDescription.lowercased().contains("cancel") ? "cancelled" : "failed: " + error.localizedDescription
        }
    }
}
#endif
