import Foundation
import SwiftSoup

public actor SourceClient {
    private let session: URLSession
    public init(configuration: URLSessionConfiguration = .ephemeral) {
        let config = configuration
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        config.httpMaximumConnectionsPerHost = 2
        session = URLSession(configuration: config)
    }

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
        guard let url = original.url else { throw SourceError.message("请求地址为空。") }
        _ = try Self.resolve(url.absoluteString, base: url)
        var request = original
        if request.value(forHTTPHeaderField: "User-Agent") == nil {
            request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 Version/17.0 Mobile/15E148 Safari/604.1", forHTTPHeaderField: "User-Agent")
        }
        if let source {
            request.setValue(source.bookSourceUrl, forHTTPHeaderField: "Referer")
            if let header = source.header, !header.isEmpty, let data = header.data(using: .utf8) {
                let headers = try JSONDecoder().decode([String: String].self, from: data)
                for (key, value) in headers where !["cookie", "authorization", "host"].contains(key.lowercased()) {
                    request.setValue(value, forHTTPHeaderField: key)
                }
            }
        }
        do {
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
            let cause: String
            switch error.code {
            case .timedOut: cause = "连接或响应超时"
            case .cannotFindHost, .dnsLookupFailed: cause = "域名解析失败"
            case .notConnectedToInternet: cause = "手机未连接网络，或此 App 的联网权限已关闭"
            case .cannotConnectToHost: cause = "无法连接网站服务器"
            case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate: cause = "网站 HTTPS 证书验证失败"
            case .networkConnectionLost: cause = "网络连接中断"
            default: cause = error.localizedDescription
            }
            throw SourceError.message("\(url.host ?? "网站")：\(cause)（网络错误 \(error.code.rawValue)）。请用手机 Safari 打开同一网址对比，书源导入与网站正文是不同的请求。")
        }
    }

    private func document(_ request: URLRequest, source: BookSource) async throws -> (RuleDocument, URL) {
        let (data, finalURL) = try await fetch(request, source: source)
        return (try RuleDocument.parse(data, base: finalURL), finalURL)
    }

    private func document(_ url: URL, source: BookSource) async throws -> (RuleDocument, URL) {
        try await document(URLRequest(url: url), source: source)
    }

    public func importURL(_ url: URL) async throws -> SourceImport {
        try await importURL(url, depth: 0)
    }

    private func importURL(_ input: URL, depth: Int) async throws -> SourceImport {
        let url = try SourceSubscription.normalize(input)
        let (data, finalURL) = try await fetch(url, limit: SourceImport.maximumBytes)
        if let links = try SourceSubscription.links(in: data, base: finalURL) {
            guard depth == 0 else { throw SourceError.message("订阅索引嵌套过深，请直接导入其中的书源 JSON 链接。") }
            var sources: [BookSource] = []
            var failures: [String] = []
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
                    guard sources.count <= 5000 else { throw SourceError.message("合并书源超过 5000 个，请分批导入。") }
                } catch {
                    if Task.isCancelled { throw error }
                    failures.append("订阅 \(link.host ?? link.absoluteString)：\(error.localizedDescription)")
                }
            }
            guard !sources.isEmpty else { throw SourceError.message("索引已读取，但实际书源下载失败：\n" + failures.joined(separator: "\n")) }
            return SourceImport(sources: sources, failures: failures)
        }
        do { return try SourceImport.parse(data) }
        catch let error as SourceError { throw error }
        catch { throw SourceError.message("书源链接下载成功，但内容不是有效的阅读 JSON。可能返回了网页或验证页。\(error.localizedDescription)") }
    }

    public func search(_ query: String, source: BookSource) async throws -> [OnlineNovel] {
        if let reason = source.incompatibility { throw SourceError.message(reason) }
        guard let template = source.searchUrl, !template.isEmpty, let rule = source.ruleSearch,
              let list = rule.bookList, let name = rule.name, let bookURL = rule.bookUrl else {
            throw SourceError.message("此书源没有完整的搜索规则，可以尝试直接粘贴小说详情页链接。")
        }
        let base = try Self.resolve(source.bookSourceUrl, base: URL(string: "https://example.com")!)
        let request = try SourceRequest.make(template, query: query, base: base)
        let (doc, url) = try await document(request, source: source)
        var seen: Set<String> = []
        var results: [OnlineNovel] = []
        for element in try doc.elements(list).prefix(100) {
            let title = try element.value(name)
            let link = try element.value(bookURL)
            guard !title.isEmpty, !link.isEmpty else { continue }
            let resolved = try Self.resolve(link, base: url)
            guard seen.insert(resolved.absoluteString).inserted else { continue }
            results.append(OnlineNovel(title: title, author: try element.optionalValue(rule.author),
                                       intro: try element.optionalValue(rule.intro), url: resolved, sourceID: source.id))
        }
        return results
    }

    public func catalog(_ novel: OnlineNovel, source: BookSource) async throws -> OnlineNovel {
        if let reason = source.incompatibility { throw SourceError.message(reason) }
        var result = novel
        let (detail, detailURL) = try await document(novel.url, source: source)
        if let info = source.ruleBookInfo {
            let title = try detail.optionalValue(info.name)
            if !title.isEmpty { result.title = title }
            let author = try detail.optionalValue(info.author)
            if !author.isEmpty { result.author = author }
            let intro = try detail.optionalValue(info.intro)
            if !intro.isEmpty { result.intro = intro }
        }
        let toc = try detail.value(source.ruleBookInfo?.tocUrl)
        var nextURL = try (toc.isEmpty ? detailURL : Self.resolve(toc, base: detailURL))
        var visited: Set<String> = []
        var seenChapters: Set<String> = []
        var chapters: [OnlineChapter] = []
        guard let rule = source.ruleToc, let list = rule.chapterList else { throw SourceError.message("缺少目录规则。") }
        while visited.insert(nextURL.absoluteString).inserted {
            try Task.checkCancellation()
            guard visited.count <= 30 else { throw SourceError.message("目录超过 30 页，已停止以避免循环请求。") }
            let (doc, pageURL): (RuleDocument, URL)
            if nextURL == detailURL { (doc, pageURL) = (detail, detailURL) }
            else { (doc, pageURL) = try await document(nextURL, source: source) }
            for element in try doc.elements(list) {
                let title = try element.value(rule.chapterName)
                let raw = try element.value(rule.chapterUrl)
                guard !title.isEmpty, !raw.isEmpty else { continue }
                let link = try Self.resolve(raw, base: pageURL)
                if seenChapters.insert(link.absoluteString).inserted { chapters.append(OnlineChapter(title: title, url: link)) }
                guard chapters.count <= 20000 else { throw SourceError.message("目录超过 20000 章，暂不支持。") }
            }
            let next = try doc.value(rule.nextTocUrl)
            if next.isEmpty { break }
            nextURL = try Self.resolve(next, base: pageURL)
            try await Task.sleep(for: .milliseconds(350))
        }
        guard !chapters.isEmpty else { throw SourceError.message("没有解析到章节。请检查目录规则、网站结构或访问限制。") }
        result.chapters = chapters
        result.chapterIndex = min(max(0, novel.chapterIndex), chapters.count - 1)
        return result
    }

    public func chapter(_ chapter: OnlineChapter, source: BookSource) async throws -> String {
        guard let rule = source.ruleContent, let content = rule.content else { throw SourceError.message("缺少正文规则。") }
        var nextURL = chapter.url
        var visited: Set<String> = []
        var texts: [String] = []
        var total = 0
        while visited.insert(nextURL.absoluteString).inserted {
            try Task.checkCancellation()
            guard visited.count <= 20 else { throw SourceError.message("正文分页超过 20 页，已停止请求。") }
            let (doc, pageURL) = try await document(nextURL, source: source)
            let text = try doc.value(content, body: true)
            guard !text.isEmpty else { throw SourceError.message("正文为空，请检查书源规则或网站是否需要验证。") }
            total += text.utf8.count
            guard total <= 4 * 1024 * 1024 else { throw SourceError.message("单章正文超过 4 MB。") }
            texts.append(text)
            let next = try doc.value(rule.nextContentUrl)
            if next.isEmpty { break }
            nextURL = try Self.resolve(next, base: pageURL)
            try await Task.sleep(for: .milliseconds(350))
        }
        return texts.joined(separator: "\n\n")
    }
}
