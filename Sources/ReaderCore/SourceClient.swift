import Foundation
import SwiftSoup
import CryptoKit

public actor SourceClient {
    private let session: URLSession
    private let cookieStorage: HTTPCookieStorage?
    private let cookieProvider: (@Sendable (URL) async -> [HTTPCookie])?
    private let webRenderer: (@Sendable (URLRequest, [HTTPCookie]) async throws -> (Data, URL))?
    private let verificationHandler: SourceVerificationHandler?
    private var scriptEngines: [String: (BookSource, SourceScript)] = [:]
    private var scriptUsers: [String: Int] = [:]
    private var searchWorkers: [String: (BookSource, SourceClient)] = [:]
    private var searchWorkerUsers: [String: Int] = [:]
    private var searchQuery: String?
    private var searchSessionID: UUID?
    private var searchGeneration = UUID()
    private var searchVariables: [String: (BookSource, [String: String])] = [:]
    private var searchVariableBytes = 0

    private static func variableBytes(_ values: [String: String]) -> Int {
        values.reduce(0) { $0 + $1.key.utf8.count + $1.value.utf8.count }
    }

    private func retainScript(_ id: String) { scriptUsers[id, default: 0] += 1 }
    private func releaseScript(_ id: String) {
        if (scriptUsers[id] ?? 0) <= 1 { scriptUsers.removeValue(forKey: id) }
        else { scriptUsers[id, default: 1] -= 1 }
        while scriptEngines.count > 4 {
            guard let idle = scriptEngines.keys.first(where: { scriptUsers[$0] == nil }) else { break }
            scriptEngines.removeValue(forKey: idle)
        }
    }
    public init(configuration: URLSessionConfiguration = .ephemeral, cookieProvider: (@Sendable (URL) async -> [HTTPCookie])? = nil,
                webRenderer: (@Sendable (URLRequest, [HTTPCookie]) async throws -> (Data, URL))? = nil, verificationHandler: SourceVerificationHandler? = nil) {
        let config = configuration
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        config.httpMaximumConnectionsPerHost = 2
        cookieStorage = config.httpCookieStorage
        self.cookieProvider = cookieProvider
        self.webRenderer = webRenderer
        self.verificationHandler = verificationHandler
        session = URLSession(configuration: config)
    }
    deinit { session.invalidateAndCancel() }

    /// Share request configuration and authentication providers, but never mutable JS book/chapter globals.
    public func isolatedWorker() -> SourceClient {
        SourceClient(configuration: session.configuration, cookieProvider: cookieProvider, webRenderer: webRenderer, verificationHandler: verificationHandler)
    }

    public func replaceCookies(_ cookies: [HTTPCookie], for url: URL) {
        for old in cookieStorage?.cookies ?? [] where SourceCookies.belongs(old, to: url) { cookieStorage?.deleteCookie(old) }
        for cookie in cookies where SourceCookies.belongs(cookie, to: url) { cookieStorage?.setCookie(cookie) }
    }

    public func cookies(for url: URL) -> [HTTPCookie] { cookieStorage?.cookies(for: url) ?? [] }

    public static func resolve(_ raw: String, base: URL) throws -> URL {
        guard let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines), relativeTo: base)?.absoluteURL,
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil,
              url.user == nil, url.password == nil else { throw SourceError.message("无效的 HTTP/HTTPS 链接：\(raw)") }
        return url
    }

    public func fetch(_ url: URL, source: BookSource? = nil, limit: Int = 8 * 1024 * 1024) async throws -> (Data, URL) {
        try await fetch(URLRequest(url: url), source: source, limit: limit)
    }

    private func fetch(_ original: URLRequest, source: BookSource? = nil, limit: Int = 8 * 1024 * 1024) async throws -> (Data, URL) {
        if let source { retainScript(source.id) }
        defer { if let source { releaseScript(source.id) } }
        guard let url = original.url else { throw SourceError.message("请求地址为空。") }
        _ = try Self.resolve(url.absoluteString, base: url)
        if let cookieProvider {
            for cookie in await cookieProvider(url) where SourceCookies.belongs(cookie, to: url) { cookieStorage?.setCookie(cookie) }
        }
        var request = original
        if request.value(forHTTPHeaderField: "User-Agent") == nil {
            request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 Version/17.0 Mobile/15E148 Safari/604.1", forHTTPHeaderField: "User-Agent")
        }
        if let source {
            request.setValue(source.bookSourceUrl, forHTTPHeaderField: "Referer")
            if let header = source.header, !header.isEmpty {
                let engine = try scriptEngine(for: source)
                let globals = engine?.requestGlobals() ?? (query: "", page: 1)
                let expanded = try ScriptTemplate.expand(header, using: engine, query: globals.query, base: url, page: globals.page)
                let headers = try SourceHeaders.parse(expanded)
                for (key, value) in headers where key.lowercased() != "host" {
                    request.setValue(value, forHTTPHeaderField: key)
                }
            }
            if let login = SourceScriptCache.shared.get(source.id, "source:@loginHeader") {
                for (key, value) in try SourceHeaders.parse(login) where key.lowercased() != "host" { request.setValue(value, forHTTPHeaderField: key) }
            }
        }
        do {
            if SourceRequest.requiresWebView(request) {
                guard let webRenderer else { throw SourceError.message("当前运行环境没有 WebView 渲染器，无法执行此书源的动态网页请求。") }
                let rendered = try await webRenderer(request, cookieStorage?.cookies(for: url) ?? [])
                guard rendered.0.count <= limit else { throw SourceError.message("WebView 网页超过大小限制。") }
                return rendered
            }
            let (bytes, response) = try await session.bytes(for: request)
            guard let response = response as? HTTPURLResponse else { throw SourceError.message("未收到 HTTP 响应。") }
            guard (200...299).contains(response.statusCode) else {
                throw SourceError.message("网站返回错误 HTTP \(response.statusCode) · \(response.url?.host ?? url.host ?? "")。403/429 通常表示访问限制；404 表示地址失效。")
            }
            guard response.expectedContentLength <= Int64(limit) else { throw SourceError.message("网页或书源响应超过大小限制。") }
            var data = Data()
            for try await byte in bytes {
                try Task.checkCancellation()
                guard data.count < limit else { throw SourceError.message("网页或书源响应超过大小限制。") }
                data.append(byte)
            }
            return (data, response.url ?? url)
        } catch let error as URLError {
            if error.code == .cancelled { throw error }
            throw Self.networkError(error, url: url)
        }
    }

    private static func networkError(_ error: URLError, url: URL) -> SourceError {
            let cause: String
            switch error.code {
            case .timedOut: cause = "连接或响应超时"
            case .cannotFindHost, .dnsLookupFailed: cause = "域名解析失败"
            case .notConnectedToInternet: cause = "手机未连接网络，或此 App 的联网权限已关闭"
            case .cannotConnectToHost: cause = "无法连接网站服务器"
            case .secureConnectionFailed: cause = "HTTPS 加密连接建立失败，可能与网站、网络或代理有关"
            case .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid: cause = "网站 HTTPS 证书验证失败"
            case .networkConnectionLost: cause = "网络连接中断"
            default: cause = error.localizedDescription
            }
            let failedURL = (error as NSError).userInfo[NSURLErrorFailingURLErrorKey] as? URL ?? url
            return SourceError.message("\(failedURL.host ?? url.host ?? "网站")：\(cause)（网络错误 \(error.code.rawValue)）。请用手机 Safari 打开同一网址对比，书源导入与网站正文是不同的请求。")
    }

    private func document(_ request: URLRequest, source: BookSource, globals: [String: String] = [:]) async throws -> (RuleDocument, URL) {
        let (data, finalURL) = try await fetch(request, source: source)
        return (try RuleDocument.parse(data, base: finalURL, source: source, globals: globals, script: scriptEngine(for: source)), finalURL)
    }

    private func scriptEngine(for source: BookSource) throws -> SourceScript? {
        let rules = [source.ruleSearch, source.ruleExplore, source.ruleBookInfo, source.ruleToc, source.ruleContent].compactMap { $0 }.flatMap(\.values) + [source.searchUrl, source.exploreUrl, source.header].compactMap { $0 }
        guard rules.contains(where: { ScriptTemplate.needsScript($0) }) || source.jsLib?.isEmpty == false else { return nil }
        if let cached = scriptEngines[source.id], cached.0 == source { return cached.1 }
        let engine = try SourceScript(configuration: session.configuration, webRenderer: webRenderer, verificationHandler: verificationHandler)
        let json = try source.originalJSON ?? String(decoding: JSONEncoder().encode(source), as: UTF8.self)
        try engine.setJSONGlobal("source", json: json)
        if let library = source.jsLib, !library.isEmpty, let base = URL(string: source.bookSourceUrl) {
            if let urls = try? JSONDecoder().decode([String: String].self, from: Data(library.utf8)) {
                guard urls.count <= 8 else { throw SourceError.message("书源共享脚本最多加载 8 个文件。") }
                let deadline = Date().addingTimeInterval(30)
                for name in urls.keys.sorted() {
                    try Task.checkCancellation()
                    guard Date() < deadline, let value = urls[name] else { throw SourceError.message("共享脚本加载超时。") }
                    let url = try Self.resolve(value, base: base)
                    let escaped = String(decoding: try JSONSerialization.data(withJSONObject: [url.absoluteString]), as: UTF8.self)
                    guard let code = try engine.evaluate("java.ajax(\(escaped)[0])", result: "", baseURL: base) as? String else { throw SourceError.message("共享脚本下载结果不是文本。") }
                    _ = try engine.evaluate(code + "\n;void 0;", result: "", baseURL: base, timeout: 8, persistentDefinitions: true)
                }
            } else { _ = try engine.evaluate(library + "\n;void 0;", result: "", baseURL: base, timeout: 8, persistentDefinitions: true) }
        }
        // A slower source may still need variables created before its HTTP request.
        // Evict only idle engines, never an engine held by an active operation.
        if scriptEngines.count >= 4, let idle = scriptEngines.keys.first(where: { scriptUsers[$0] == nil }) { scriptEngines.removeValue(forKey: idle) }
        scriptEngines[source.id] = (source, engine)
        return engine
    }

    private func document(_ url: URL, source: BookSource) async throws -> (RuleDocument, URL) {
        try await document(URLRequest(url: url), source: source)
    }

    public func importURL(_ url: URL) async throws -> SourceImport {
        try await importURL(url, depth: 0)
    }

    /// Shared by the import screen and native integration checks. A failed link never
    /// discards successfully downloaded sources from other links in the same batch.
    public func importText(_ text: String) async throws -> SourceImport {
        switch try SourceImportInput.detect(text) {
        case .json(let data):
            var result = try SourceImport.parse(data)
            result.diagnostics = ["已识别粘贴的 JSON · \(data.count) 字节 · \(result.sources.count) 个书源"]
            return result
        case .links(let urls):
            var merged = SourceImport(sources: [], failures: [])
            for (index, url) in urls.enumerated() {
                try Task.checkCancellation()
                do {
                    let result = try await importURL(url)
                    merged.diagnostics += result.diagnostics
                    merged.failures += result.failures.map { "链接 \(index + 1)：\($0)" }
                    for source in result.sources {
                        if let old = merged.sources.firstIndex(where: { $0.id == source.id }) { merged.sources[old] = source }
                        else {
                            guard merged.sources.count < 5000 else { throw SourceError.message("合并超过 5000 个书源，请分批导入。") }
                            merged.sources.append(source)
                        }
                    }
                } catch {
                    try Task.checkCancellation()
                    merged.failures.append("链接 \(index + 1)（\(url.absoluteString)）：\(error.localizedDescription)")
                }
            }
            guard !merged.sources.isEmpty else { throw SourceError.message(merged.failures.joined(separator: "\n")) }
            return merged
        }
    }

    private func importURL(_ input: URL, depth: Int) async throws -> SourceImport {
        let url = try SourceSubscription.normalize(input)
        _ = try Self.resolve(url.absoluteString, base: url)
        let data: Data, finalURL: URL
        do {
            (data, finalURL) = try await SourceImportDownload(configuration: session.configuration, limit: SourceImport.maximumBytes).run(url)
        } catch let error as URLError {
            if error.code == .cancelled { throw error }
            throw Self.networkError(error, url: url)
        }
        let trace = "\(input.absoluteString)\n实际地址：\(finalURL.absoluteString) · \(data.count) 字节"
        if let links = try SourceSubscription.links(in: data, base: finalURL) {
            guard depth == 0 else { throw SourceError.message("订阅索引嵌套过深，请直接导入其中的书源 JSON 链接。") }
            var sources: [BookSource] = []
            var failures: [String] = []
            var diagnostics = [trace + " · 订阅索引"]
            for link in links {
                try Task.checkCancellation()
                do {
                    let result = try await importURL(link, depth: depth + 1)
                    for source in result.sources {
                        if let index = sources.firstIndex(where: { $0.id == source.id }) { sources[index] = source }
                        else {
                            guard sources.count < 5000 else { throw SourceError.message("合并书源超过 5000 个，请分批导入。") }
                            sources.append(source)
                        }
                    }
                    failures += result.failures
                    diagnostics += result.diagnostics
                    guard sources.count <= 5000 else { throw SourceError.message("合并书源超过 5000 个，请分批导入。") }
                } catch {
                    if Task.isCancelled { throw error }
                    failures.append("订阅 \(link.host ?? link.absoluteString)：\(error.localizedDescription)")
                }
            }
            guard !sources.isEmpty else { throw SourceError.message("索引已读取，但实际书源下载失败：\n" + failures.joined(separator: "\n")) }
            return SourceImport(sources: sources, failures: failures, diagnostics: diagnostics)
        }
        do {
            var parsed = try SourceImport.parse(data)
            parsed.diagnostics = [trace + " · \(parsed.sources.count) 个书源"]
            guard !parsed.sources.isEmpty else { throw SourceError.message("未读到有效书源：" + parsed.failures.joined(separator: "\n")) }
            return parsed
        }
        catch let error as SourceError { throw SourceError.message(trace + "\n" + error.localizedDescription) }
        catch { throw SourceError.message("书源链接下载成功，但内容不是有效的阅读 JSON。可能返回了网页或验证页。\(error.localizedDescription)") }
    }

    public func search(_ query: String, source: BookSource, page: Int = 1) async throws -> [OnlineNovel] {
        retainScript(source.id); defer { releaseScript(source.id) }
        guard (1...10000).contains(page) else { throw SourceError.message("搜索页码无效。") }
        if let reason = source.searchIncompatibility { throw SourceError.message(reason) }
        let script = try scriptEngine(for: source)
        return try await withTaskCancellationHandler {
            try await searchImpl(query, source: source, page: page)
        } onCancel: { script?.cancel() }
    }

    /// Synchronous java.ajax runs inside its source interpreter. Give each global-
    /// search job its own actor so a slow script cannot block unrelated websites.
    public func searchIndependent(_ query: String, source: BookSource, page: Int = 1, sessionID: UUID? = nil) async throws -> [OnlineNovel] {
        try Task.checkCancellation()
        if searchQuery != query || searchSessionID != sessionID {
            searchSessionID = sessionID
            searchQuery = query; searchGeneration = UUID()
            searchVariables.removeAll(); searchVariableBytes = 0
            for key in Array(searchWorkers.keys) where searchWorkerUsers[key] == nil { searchWorkers.removeValue(forKey: key) }
        }
        let generation = searchGeneration
        let key = generation.uuidString + source.id
        let worker: SourceClient
        if let existing = searchWorkers[key], existing.0 == source { worker = existing.1 }
        else {
            if searchWorkers.count >= 8, let idle = searchWorkers.keys.first(where: { searchWorkerUsers[$0] == nil }) { searchWorkers.removeValue(forKey: idle) }
            worker = SourceClient(configuration: session.configuration, cookieProvider: cookieProvider, webRenderer: webRenderer, verificationHandler: verificationHandler)
            searchWorkers[key] = (source, worker)
        }
        searchWorkerUsers[key, default: 0] += 1
        defer {
            if (searchWorkerUsers[key] ?? 0) <= 1 { searchWorkerUsers.removeValue(forKey: key) }
            else { searchWorkerUsers[key, default: 1] -= 1 }
            while searchWorkers.count > 8 {
                guard let idle = searchWorkers.keys.first(where: { searchWorkerUsers[$0] == nil }) else { break }
                searchWorkers.removeValue(forKey: idle)
            }
        }
        let saved = searchVariables[source.id]
        let variables = saved?.0 == source ? saved?.1 : nil
        let result = try await worker.searchPage(query, source: source, page: page, variables: variables)
        try Task.checkCancellation()
        guard generation == searchGeneration else { throw CancellationError() }
        let bytes = Self.variableBytes(result.1)
        let total = searchVariableBytes - Self.variableBytes(saved?.1 ?? [:]) + bytes
        guard total <= 16 * 1024 * 1024 else { throw SourceError.message("本次搜索的书源变量超过 16 MB，请缩小书源范围后重新搜索。") }
        searchVariableBytes = total
        searchVariables[source.id] = (source, result.1)
        return result.0
    }

    private func searchPage(_ query: String, source: BookSource, page: Int, variables: [String: String]?) async throws -> ([OnlineNovel], [String: String]) {
        if let variables { try scriptEngine(for: source)?.restoreVariables(variables) }
        let novels = try await search(query, source: source, page: page)
        return (novels, try scriptEngine(for: source)?.snapshotVariables() ?? [:])
    }

    private func searchImpl(_ query: String, source: BookSource, page: Int) async throws -> [OnlineNovel] {
        guard let template = source.searchUrl, !template.isEmpty, let rule = source.ruleSearch,
              let list = rule.bookList, let name = rule.name, let bookURL = rule.bookUrl else {
            throw SourceError.message("此书源没有完整的搜索规则，可以尝试直接粘贴小说详情页链接。")
        }
        let base = try Self.resolve(source.bookSourceUrl, base: URL(string: "https://example.com")!)
        let engine = try scriptEngine(for: source)
        try engine?.setJSONGlobal("key", json: String(decoding: JSONEncoder().encode(query), as: UTF8.self))
        try engine?.setJSONGlobal("page", json: String(page))
        let request = try SourceRequest.make(template, query: query, base: base, script: scriptEngine(for: source), page: page)
        let (doc, url) = try await document(request, source: source, globals: ["key": query, "page": String(page)])
        var seen: Set<String> = []
        var results: [OnlineNovel] = []
        for element in try doc.elements(list).prefix(100) {
            for metadata in [rule.wordCount, rule.kind, rule.coverUrl, rule.lastChapter].compactMap({ $0 }) where metadata.contains("@put:") { _ = try element.value(metadata) }
            let title = try element.value(name)
            let link = try element.value(bookURL)
            guard !title.isEmpty, !link.isEmpty else { continue }
            let navigation = try SourceRequest.navigation(link, base: url, script: scriptEngine(for: source))
            let resolved = navigation.url
            guard seen.insert(navigation.template ?? resolved.absoluteString).inserted else { continue }
            var novel = OnlineNovel(title: title, author: try element.optionalValue(rule.author),
                                    intro: try element.optionalValue(rule.intro), url: resolved, sourceID: source.id)
            novel.kind = try? element.optionalValue(rule.kind)
            novel.wordCountLabel = try? element.optionalValue(rule.wordCount)
            novel.lastChapter = try? element.optionalValue(rule.lastChapter)
            let cover = (try? element.optionalValue(rule.coverUrl)) ?? ""
            if !cover.isEmpty { novel.coverURL = try? Self.resolve(cover, base: url) }
            novel.ruleVariables = try scriptEngine(for: source)?.snapshotVariables()
            novel.requestTemplate = navigation.template
            results.append(novel)
        }
        if results.isEmpty, let diagnostic = doc.emptyResultDiagnostic { throw SourceError.message(diagnostic) }
        return results
    }

    public func categories(source: BookSource) throws -> [ExploreCategory] {
        guard source.enabledExplore != false, let raw = source.exploreUrl, !raw.isEmpty,
              let base = URL(string: source.bookSourceUrl) else { return [] }
        let text = try ScriptTemplate.expand(raw, using: scriptEngine(for: source), query: "", base: base)
        return try ExploreCategory.parse(text)
    }

    public func explore(_ category: ExploreCategory, page: Int, source: BookSource) async throws -> [OnlineNovel] {
        retainScript(source.id); defer { releaseScript(source.id) }
        let engine = try scriptEngine(for: source)
        return try await withTaskCancellationHandler { try await exploreImpl(category, page: page, source: source) } onCancel: { engine?.cancel() }
    }
    private func exploreImpl(_ category: ExploreCategory, page: Int, source: BookSource) async throws -> [OnlineNovel] {
        guard !category.isHeading, (1...10000).contains(page), let base = URL(string: source.bookSourceUrl) else { throw SourceError.message("分类网址或页码无效。") }
        if let reason = source.incompatibility { throw SourceError.message(reason) }
        let specific = source.ruleExplore
        let rule = (specific?.bookList?.isEmpty == false) ? specific : source.ruleSearch
        guard let rule, let list = rule.bookList, let name = rule.name, let bookURL = rule.bookUrl else { throw SourceError.message("书源没有完整的发现列表规则。") }
        let request = try SourceRequest.make(category.url, query: "", base: base, script: scriptEngine(for: source), page: page)
        let (doc, url) = try await document(request, source: source, globals: ["page": String(page)])
        var seen = Set<String>()
        var novels: [OnlineNovel] = []
        for element in try doc.elements(list).prefix(100) {
            let title = try element.value(name)
            let raw = try element.value(bookURL)
            guard !title.isEmpty, !raw.isEmpty else { continue }
            let link = try SourceRequest.navigation(raw, base: url, script: scriptEngine(for: source))
            guard seen.insert(link.template ?? link.url.absoluteString).inserted else { continue }
            var novel = OnlineNovel(title: title, author: try element.optionalValue(rule.author), intro: try element.optionalValue(rule.intro), url: link.url, sourceID: source.id)
            novel.kind = try? element.optionalValue(rule.kind); novel.wordCountLabel = try? element.optionalValue(rule.wordCount)
            novel.lastChapter = try? element.optionalValue(rule.lastChapter)
            let cover = (try? element.optionalValue(rule.coverUrl)) ?? ""
            if !cover.isEmpty { novel.coverURL = try? Self.resolve(cover, base: url) }
            novel.requestTemplate = link.template; novel.ruleVariables = try scriptEngine(for: source)?.snapshotVariables()
            novels.append(novel)
        }
        return novels
    }

    public func catalog(_ novel: OnlineNovel, source: BookSource) async throws -> OnlineNovel {
        retainScript(source.id); defer { releaseScript(source.id) }
        let engine = try scriptEngine(for: source)
        return try await withTaskCancellationHandler { try await catalogImpl(novel, source: source) } onCancel: { engine?.cancel() }
    }
    private func catalogImpl(_ novel: OnlineNovel, source: BookSource) async throws -> OnlineNovel {
        if let reason = source.incompatibility { throw SourceError.message(reason) }
        var result = novel
        if let variables = novel.ruleVariables { try scriptEngine(for: source)?.restoreVariables(variables) }
        try installBookContext(result, source: source)
        let detailRequest = try SourceRequest.make(novel.requestTemplate ?? novel.url.absoluteString, query: "", base: novel.url, script: scriptEngine(for: source))
        let (originalDetail, detailURL) = try await document(detailRequest, source: source)
        var detail = originalDetail
        if let initialization = source.ruleBookInfo?.initialization, !initialization.isEmpty {
            let initialized = try detail.value(initialization)
            detail = try RuleDocument.parse(Data(initialized.utf8), base: detailURL, source: source, script: scriptEngine(for: source))
        }
        if let info = source.ruleBookInfo {
            let title = try detail.optionalValue(info.name)
            if !title.isEmpty { result.title = title }
            let author = try detail.optionalValue(info.author)
            if !author.isEmpty { result.author = author }
            let intro = try detail.optionalValue(info.intro)
            if !intro.isEmpty { result.intro = intro }
        }
        let toc = try detail.value(source.ruleBookInfo?.tocUrl)
        try installBookContext(result, source: source)
        var nextRequest = try SourceRequest.make(toc.isEmpty ? detailURL.absoluteString : toc, query: "", base: detailURL, script: scriptEngine(for: source))
        var visited: Set<String> = []
        var seenChapters: Set<String> = []
        var chapters: [OnlineChapter] = []
        guard let rule = source.ruleToc, let list = rule.chapterList else { throw SourceError.message("缺少目录规则。") }
        while visited.insert(requestKey(nextRequest)).inserted {
            try Task.checkCancellation()
            guard visited.count <= 30 else { throw SourceError.message("目录超过 30 页，已停止以避免循环请求。") }
            let (doc, pageURL): (RuleDocument, URL)
            if visited.count == 1 && nextRequest.url == detailURL && toc.isEmpty { (doc, pageURL) = (detail, detailURL) }
            else { (doc, pageURL) = try await document(nextRequest, source: source) }
            for element in try doc.elements(list) {
                let title = try element.value(rule.chapterName)
                let raw = try element.value(rule.chapterUrl)
                guard !title.isEmpty, !raw.isEmpty else { continue }
                let link = try SourceRequest.navigation(raw, base: pageURL, script: scriptEngine(for: source))
                if seenChapters.insert(link.template ?? link.url.absoluteString).inserted {
                    let context: [String: Any] = ["title": title, "url": link.url.absoluteString, "index": chapters.count, "baseUrl": pageURL.absoluteString, "bookUrl": result.url.absoluteString]
                    let json = String(decoding: try JSONSerialization.data(withJSONObject: context), as: UTF8.self)
                    try scriptEngine(for: source)?.putVariable("__gavin:chapter", value: json)
                    chapters.append(OnlineChapter(title: title, url: link.url, ruleVariables: try scriptEngine(for: source)?.snapshotVariables(), requestTemplate: link.template))
                }
                guard chapters.count <= 20000 else { throw SourceError.message("目录超过 20000 章，暂不支持。") }
            }
            let next = try doc.value(rule.nextTocUrl)
            if next.isEmpty { break }
            nextRequest = try SourceRequest.make(next, query: "", base: pageURL, script: scriptEngine(for: source))
            try await Task.sleep(for: .milliseconds(350))
        }
        guard !chapters.isEmpty else { throw SourceError.message("没有解析到章节。请检查目录规则、网站结构或访问限制。") }
        for index in chapters.indices where index + 1 < chapters.count { chapters[index].nextChapterURL = chapters[index + 1].url }
        result.chapters = chapters
        result.chapterIndex = min(max(0, novel.chapterIndex), chapters.count - 1)
        result.ruleVariables = try scriptEngine(for: source)?.snapshotVariables()
        return result
    }

    public func chapter(_ chapter: OnlineChapter, source: BookSource) async throws -> String {
        retainScript(source.id); defer { releaseScript(source.id) }
        let engine = try scriptEngine(for: source)
        return try await withTaskCancellationHandler { try await chapterImpl(chapter, source: source) } onCancel: { engine?.cancel() }
    }
    private func chapterImpl(_ chapter: OnlineChapter, source: BookSource) async throws -> String {
        if let variables = chapter.ruleVariables { try scriptEngine(for: source)?.restoreVariables(variables) }
        if let engine = try scriptEngine(for: source) {
            let savedBook = engine.variable("__gavin:book")
            try engine.setJSONGlobal("book", json: savedBook.isEmpty ? "{}" : savedBook)
            let fallback: [String: Any] = ["title": chapter.title, "url": chapter.url.absoluteString, "index": 0, "baseUrl": chapter.url.absoluteString]
            let saved = engine.variable("__gavin:chapter")
            try engine.setJSONGlobal("chapter", json: saved.isEmpty ? String(decoding: JSONSerialization.data(withJSONObject: fallback), as: UTF8.self) : saved)
        }
        guard let rule = source.ruleContent, let content = rule.content else { throw SourceError.message("缺少正文规则。") }
        var nextRequest = try SourceRequest.make(chapter.requestTemplate ?? chapter.url.absoluteString, query: "", base: chapter.url, script: scriptEngine(for: source))
        var visited: Set<String> = []
        var texts: [String] = []
        var total = 0
        while visited.insert(requestKey(nextRequest)).inserted {
            try Task.checkCancellation()
            guard visited.count <= 20 else { throw SourceError.message("正文分页超过 20 页，已停止请求。") }
            let (doc, pageURL) = try await document(nextRequest, source: source)
            var text = try doc.value(content, body: true)
            if let replacement = rule.replaceRegex, !replacement.isEmpty { text = try RuleReplacement.apply(text, suffix: replacement) }
            guard !text.isEmpty else { throw SourceError.message("正文为空，请检查书源规则或网站是否需要验证。") }
            total += text.utf8.count
            guard total <= 4 * 1024 * 1024 else { throw SourceError.message("单章正文超过 4 MB。") }
            texts.append(text)
            let next = try doc.value(rule.nextContentUrl)
            if next.isEmpty { break }
            let candidate = try SourceRequest.make(next, query: "", base: pageURL, script: scriptEngine(for: source))
            // A source's “next” selector may point to the next chapter rather than
            // the next page of this chapter. Catalog boundaries take precedence.
            if let boundary = chapter.nextChapterURL, boundary != chapter.url, candidate.url == boundary { break }
            nextRequest = candidate
            try await Task.sleep(for: .milliseconds(350))
        }
        return texts.joined(separator: "\n\n")
    }
    private func requestKey(_ request: URLRequest) -> String {
        (request.url?.absoluteString ?? "") + "|" + (request.httpMethod ?? "GET") + "|" + SHA256.hash(data: request.httpBody ?? Data()).map { String(format: "%02x", $0) }.joined()
    }
    private func installBookContext(_ novel: OnlineNovel, source: BookSource) throws {
        let values: [String: Any] = ["name": novel.title, "author": novel.author, "intro": novel.intro, "bookUrl": novel.url.absoluteString, "origin": source.bookSourceUrl, "originName": source.bookSourceName, "durChapterIndex": novel.chapterIndex, "type": 0, "kind": novel.kind ?? "", "coverUrl": novel.coverURL?.absoluteString ?? ""]
        let json = String(decoding: try JSONSerialization.data(withJSONObject: values), as: UTF8.self)
        if let engine = try scriptEngine(for: source) {
            try engine.setJSONGlobal("book", json: json)
            try engine.putVariable("__gavin:book", value: json)
        }
    }
}
