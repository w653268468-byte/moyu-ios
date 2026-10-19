import SwiftUI
import WebKit

private struct EPUBDisplayBook: Sendable {
    var root: URL
    var chapters: [EPUBSpineItem]
    var navigation: [EPUBNavigationItem]
}

struct EPUBReaderLoader: View {
    @EnvironmentObject private var library: LibraryStore
    let book: Book
    @State private var publication: EPUBDisplayBook?
    @State private var document: BookDocument?
    @State private var failure: String?
    var body: some View {
        Group {
            if let publication, let document { EPUBReaderView(book: book, publication: publication, document: document) }
            else if let failure { ContentUnavailableView("无法打开 EPUB", systemImage: "book.closed", description: Text(failure)) }
            else { ProgressView("正在准备 EPUB 图片与原书样式…") }
        }.task {
            let file = library.epubURL(for: book)
            let root = URL.cachesDirectory.appendingPathComponent("GavinEPUB-\(UUID().uuidString)", isDirectory: true)
            do {
                let loader = Task.detached(priority: .userInitiated) {
                    do {
                        let value = try EPUBPublication.load(Data(contentsOf: file, options: .mappedIfSafe))
                        try value.writeResources(to: root)
                        try Task.checkCancellation()
                        return EPUBDisplayBook(root: root, chapters: value.chapters, navigation: value.navigation)
                    } catch { try? FileManager.default.removeItem(at: root); throw error }
                }
                let value = try await withTaskCancellationHandler { try await loader.value } onCancel: { loader.cancel() }
                try Task.checkCancellation()
                document = try await library.document(for: book); publication = value
            } catch {
                try? FileManager.default.removeItem(at: root)
                if !Task.isCancelled { failure = error.localizedDescription }
            }
        }.onDisappear {
            if let publication { try? FileManager.default.removeItem(at: publication.root) }
        }
    }
}

private struct EPUBReaderView: View {
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dismiss) private var dismiss
    let book: Book
    let publication: EPUBDisplayBook
    let document: BookDocument
    @State private var chapter: Int
    @State private var fraction: Double
    @State private var fragment: String?
    @State private var contents = false
    @State private var preferences = false
    @State private var webError: String?
    @State private var command = 0
    @State private var direction = 1
    @AppStorage("reader.epubOriginalStyles") private var originalStyles = true
    private var style = ReadingStyle()
    init(book: Book, publication: EPUBDisplayBook, document: BookDocument) {
        self.book = book; self.publication = publication; self.document = document
        _chapter = State(initialValue: min(max(0, book.epubChapter ?? 0), max(0, publication.chapters.count - 1)))
        _fraction = State(initialValue: min(1, max(0, book.epubProgress ?? 0)))
    }
    var body: some View {
        let item = publication.chapters[chapter]
        let readingChapter = chapter
        VStack(spacing: 0) {
            if let webError { Text(webError).font(.caption).foregroundStyle(.red).padding(8) }
            EPUBWebPage(root: publication.root, item: item, initialProgress: fraction, fragment: fragment,
                originalStyles: originalStyles, style: style,
                appearanceKey: "\(style.fontSize)-\(style.lineSpacing)-\(style.paperName)-\(style.horizontalMargin)-\(style.verticalMargin)-\(style.paragraphSpacing)-\(style.bold)", command: command, direction: direction,
                onProgress: { if chapter == readingChapter { save($0) } }, onNavigate: navigate, onBoundary: { jump(chapter + $0) },
                toggleChrome: { style.fullScreen.toggle() }, onError: { webError = $0 })
                .id(chapter)
            if !style.fullScreen {
                HStack {
                    Button("上一页", systemImage: "chevron.left") { direction = -1; command += 1 }
                    Spacer()
                    Text("\(chapter + 1)/\(publication.chapters.count) 节 · \(Int(fraction * 100))%").font(.caption).monospacedDigit()
                    Spacer()
                    Button("下一页", systemImage: "chevron.right") { direction = 1; command += 1 }
                }.padding(.horizontal).frame(minHeight: 44)
            }
        }.background(style.paper.background)
            .modifier(ReadingAppearance())
            .navigationTitle(book.title).navigationBarTitleDisplayMode(.inline)
            .toolbar(style.fullScreen ? .hidden : .visible, for: .navigationBar).statusBarHidden(style.fullScreen)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button { dismiss() } label: { Image(systemName: "chevron.down") }.accessibilityLabel("返回书架") }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Toggle(isOn: $originalStyles) { Image(systemName: originalStyles ? "doc.richtext" : "textformat") }.accessibilityLabel("保留原书样式")
                    Button { contents = true } label: { Image(systemName: "list.bullet") }.accessibilityLabel("EPUB 目录")
                    Button { preferences = true } label: { Image(systemName: "textformat.size") }.accessibilityLabel("阅读设置")
                }
            }
            .sheet(isPresented: $contents) {
                NavigationStack {
                    List(Array(publication.navigation.enumerated()), id: \.offset) { _, item in
                        Button(item.title) { jump(item.chapter, fragment: item.fragment); contents = false }
                    }.navigationTitle("EPUB 目录")
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { contents = false } } }
                }
            }
            .sheet(isPresented: $preferences) { NavigationStack { ReadingPreferences().toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { preferences = false } } } } }
    }
    private func save(_ value: Double) {
        fraction = min(1, max(0, value))
        let pages = document.pages.filter { $0.chapter == chapter }
        let page = pages.isEmpty ? 0 : pages[min(pages.count - 1, Int(Double(pages.count) * fraction))].id
        library.updateEPUBPosition(bookID: book.id, chapter: chapter, progress: fraction, page: page)
    }
    private func jump(_ target: Int, fragment: String? = nil) {
        guard publication.chapters.indices.contains(target) else { return }
        let same = target == chapter
        let backwards = target < chapter
        self.fragment = fragment; fraction = backwards && fragment == nil ? 1 : 0
        chapter = target; webError = nil
        if same { command += 1; direction = 0 }
    }
    private func navigate(_ url: URL) {
        guard let index = publication.chapters.firstIndex(where: { publication.root.appendingPathComponent($0.path).standardizedFileURL.path == url.standardizedFileURL.path }) else { return }
        jump(index, fragment: url.fragment?.removingPercentEncoding ?? url.fragment)
    }
}

private struct EPUBWebPage: UIViewRepresentable {
    let root: URL
    let item: EPUBSpineItem
    let initialProgress: Double
    let fragment: String?
    let originalStyles: Bool
    let style: ReadingStyle
    let appearanceKey: String
    let command: Int
    let direction: Int
    let onProgress: (Double) -> Void
    let onNavigate: (URL) -> Void
    let onBoundary: (Int) -> Void
    let toggleChrome: () -> Void
    let onError: (String) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.ignoresViewportScaleLimits = true
        let web = OfflineEPUBWebView(frame: .zero, configuration: configuration)
        web.navigationDelegate = context.coordinator; web.scrollView.delegate = context.coordinator
        web.isOpaque = false; web.backgroundColor = UIColor(style.paper.background)
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.doubleTap))
        tap.numberOfTapsRequired = 2; web.addGestureRecognizer(tap)
        context.coordinator.web = web
        web.onResize = { [weak coordinator = context.coordinator] in
            guard let coordinator, coordinator.ready else { return }
            coordinator.restore(coordinator.visibleProgress, fragment: nil)
        }
        // Local books stay offline, including their CSS imports, images and font URLs.
        let rules = #"[{"trigger":{"url-filter":"^https?://"},"action":{"type":"block"}}]"#
        WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "GavinOfflineEPUB", encodedContentRuleList: rules) { rules, error in
            guard let rules else { context.coordinator.parent.onError(error?.localizedDescription ?? "无法开启 EPUB 离线隔离。"); return }
            web.configuration.userContentController.add(rules)
            web.loadFileURL(root.appendingPathComponent(item.path), allowingReadAccessTo: root)
        }
        return web
    }
    func updateUIView(_ web: WKWebView, context: Context) {
        let previous = context.coordinator.parent
        context.coordinator.parent = self
        let changed = previous.originalStyles != originalStyles || previous.appearanceKey != appearanceKey
        if changed && context.coordinator.ready { context.coordinator.applyStyle(progress: context.coordinator.progress()) }
        if context.coordinator.lastCommand != command {
            context.coordinator.lastCommand = command
            guard context.coordinator.ready else { return }
            if direction == 0 { context.coordinator.restore(initialProgress, fragment: fragment) }
            else {
                let scroll = web.scrollView, maximum = max(0, scroll.contentSize.height - scroll.bounds.height)
                let current = scroll.contentOffset.y
                if direction > 0 && current >= maximum - 2 || direction < 0 && current <= 2 { onBoundary(direction) }
                else { scroll.setContentOffset(CGPoint(x: 0, y: min(maximum, max(0, current + CGFloat(direction) * scroll.bounds.height * 0.9))), animated: true) }
            }
        }
    }
    static func dismantleUIView(_ web: WKWebView, coordinator: Coordinator) {
        coordinator.flush(); coordinator.ready = false; coordinator.work?.cancel()
        web.stopLoading(); web.navigationDelegate = nil; web.scrollView.delegate = nil
    }
    final class Coordinator: NSObject, WKNavigationDelegate, UIScrollViewDelegate {
        var parent: EPUBWebPage
        weak var web: WKWebView?
        var ready = false, restoring = false
        var lastCommand: Int
        var visibleProgress: Double
        var work: DispatchWorkItem?
        init(_ parent: EPUBWebPage) { self.parent = parent; lastCommand = parent.command; visibleProgress = parent.initialProgress }
        @objc func doubleTap() { parent.toggleChrome() }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            ready = true; applyStyle(progress: parent.initialProgress, fragment: parent.fragment)
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--ui-epub-check") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak webView] in
                    webView?.evaluateJavaScript("({image:document.getElementById('local-illustration').naturalWidth>0,css:getComputedStyle(document.querySelector('h1')).color==='rgb(30, 100, 80)',scriptsBlocked:!document.documentElement.dataset.bookScriptRan})", in: nil, in: .defaultClient) { result in
                        var report: [String: Any] = ["status":"failed"]
                        switch result {
                        case .success(let value):
                            if let checks = value as? [String: Bool] { report = checks; report["status"] = checks.values.allSatisfy { $0 } ? "passed" : "failed" }
                        case .failure(let error):
                            let detail = error as NSError
                            report["error"] = error.localizedDescription
                            report["scriptError"] = detail.userInfo["WKJavaScriptExceptionMessage"] as? String ?? ""
                            report["line"] = detail.userInfo["WKJavaScriptExceptionLineNumber"] as? Int ?? 0
                        }
                        if let data = try? JSONSerialization.data(withJSONObject: report, options: .prettyPrinted) { try? data.write(to: URL.documentsDirectory.appendingPathComponent("epub-check.json"), options: .atomic) }
                    }
                }
            }
            #endif
        }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { parent.onError(error.localizedDescription) }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { parent.onError(error.localizedDescription) }
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = navigationAction.request.url, url.isFileURL,
                  url.standardizedFileURL.path.hasPrefix(parent.root.standardizedFileURL.path + "/") else { decisionHandler(.cancel); return }
            if navigationAction.navigationType == .linkActivated { parent.onNavigate(url); decisionHandler(.cancel) }
            else { decisionHandler(.allow) }
        }
        func applyStyle(progress: Double, fragment: String? = nil) {
            guard let web else { return }
            restoring = true
            let style = parent.style
            let ink = style.paper.isDark ? "#c2c2c2" : "#2b2b2b"
            let css = parent.originalStyles || parent.item.fixedLayout ? "" : "html,body{background:transparent!important;color:\(ink)!important;font-size:\(style.fontSize)px!important;line-height:1.8!important;}body{padding:\(style.verticalMargin)px \(style.horizontalMargin)px!important;margin:0!important;}p{margin-bottom:\(style.paragraphSpacing)px!important;}img,svg{max-width:100%;height:auto;}"
            let json = String(data: try! JSONSerialization.data(withJSONObject: [css]), encoding: .utf8)!
            let script = "if(document.head){var s=document.getElementById('gavin-reader-style');if(!s){s=document.createElement('style');s.id='gavin-reader-style';document.head.appendChild(s);}s.textContent=\(json)[0];if(!document.querySelector('meta[name=viewport]')){var m=document.createElement('meta');m.name='viewport';m.content='width=device-width, initial-scale=1';document.head.appendChild(m);}}true;"
            web.evaluateJavaScript(script, in: nil, in: .defaultClient) { [weak self] result in
                guard let self else { return }
                if case .failure(let error) = result { self.parent.onError(error.localizedDescription) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in self?.restore(progress, fragment: fragment) }
            }
        }
        func restore(_ value: Double, fragment: String?) {
            guard let web else { return }
            let scroll = web.scrollView
            scroll.setContentOffset(CGPoint(x: 0, y: max(0, scroll.contentSize.height - scroll.bounds.height) * CGFloat(min(1, max(0, value)))), animated: false)
            if let fragment, !fragment.isEmpty, let json = try? JSONSerialization.data(withJSONObject: [fragment]), let string = String(data: json, encoding: .utf8) {
                web.evaluateJavaScript("document.getElementById(\(string)[0])?.scrollIntoView();", in: nil, in: .defaultClient) { [weak self] _ in self?.restoring = false; self?.flush() }
            } else { restoring = false; flush() }
        }
        func progress() -> Double {
            guard let scroll = web?.scrollView else { return parent.initialProgress }
            let maximum = scroll.contentSize.height - scroll.bounds.height
            return maximum > 0 ? min(1, max(0, Double(scroll.contentOffset.y / maximum))) : 0
        }
        func flush() { if ready && !restoring { visibleProgress = progress(); parent.onProgress(visibleProgress) } }
        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            guard ready && !restoring else { return }
            work?.cancel(); let item = DispatchWorkItem { [weak self] in self?.flush() }; work = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: item)
        }
        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { flush() }
        func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) { flush() }
    }
}

private final class OfflineEPUBWebView: WKWebView {
    var onResize: (() -> Void)?
    private var lastSize = CGSize.zero
    override func layoutSubviews() {
        let changed = bounds.size != lastSize && lastSize != .zero
        lastSize = bounds.size
        super.layoutSubviews()
        if changed { DispatchQueue.main.async { [weak self] in self?.onResize?() } }
    }
}
