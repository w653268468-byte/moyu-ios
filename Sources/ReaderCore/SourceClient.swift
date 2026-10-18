import Foundation
import SwiftSoup

public actor SourceClient {
    private let session: URLSession
    public init(configuration: URLSessionConfiguration = .ephemeral) {
        let config = configuration
        config.timeoutIntervalForRequest = 25
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
        _ = try Self.resolve(url.absoluteString, base: url)
        var request = URLRequest(url: url)
        request.setValue("MoyuReader/1.0 (iOS)", forHTTPHeaderField: "User-Agent")
        if let header = source?.header, let data = header.data(using: .utf8) {
            let headers = try JSONDecoder().decode([String: String].self, from: data)
            // Credentials are intentionally not forwarded across untrusted redirects.
            for (key, value) in headers where !["cookie", "authorization", "host"].contains(key.lowercased()) {
                request.setValue(value, forHTTPHeaderField: key)
            }
        }
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse, (200...299).contains(response.statusCode) else {
            throw SourceError.message("网站返回错误，可能需要登录、验证或暂时不可用。")
        }
        guard response.expectedContentLength <= Int64(limit) else { throw SourceError.message("网页或书源响应过大。") }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < limit else { throw SourceError.message("网页或书源响应超过大小限制。") }
            data.append(byte)
        }
        return (data, response.url ?? url)
    }

    private func html(_ url: URL, source: BookSource) async throws -> (Document, URL) {
        let (data, finalURL) = try await fetch(url, source: source)
        return (try SwiftSoup.parse(TextParser.decode(data), finalURL.absoluteString), finalURL)
    }

    public func importURL(_ url: URL) async throws -> SourceImport {
        let (data, _) = try await fetch(url, limit: 5 * 1024 * 1024)
        return try SourceImport.parse(data)
    }

    public func search(_ query: String, source: BookSource) async throws -> [OnlineNovel] {
        if let reason = source.incompatibility { throw SourceError.message(reason) }
        guard let template = source.searchUrl, !template.isEmpty, let rule = source.ruleSearch,
              let list = rule.bookList, let name = rule.name, let bookURL = rule.bookUrl else {
            throw SourceError.message("此书源没有完整的搜索规则，可以尝试直接粘贴小说详情页链接。")
        }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        let keyword = query.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        let request = template.replacingOccurrences(of: "{{key}}", with: keyword)
            .replacingOccurrences(of: "{{page}}", with: "1")
            .replacingOccurrences(of: "searchKey", with: keyword)
        guard !request.contains("{{") else { throw SourceError.message("搜索模板包含不支持的变量。") }
        let base = try Self.resolve(source.bookSourceUrl, base: URL(string: "https://example.com")!)
        let (doc, url) = try await html(Self.resolve(request, base: base), source: source)
        var seen: Set<String> = []
        var results: [OnlineNovel] = []
        for element in try HTMLRule.elements(list, in: doc).prefix(100) {
            let title = try HTMLRule.value(name, in: element)
            let link = try HTMLRule.value(bookURL, in: element)
            guard !title.isEmpty, !link.isEmpty else { continue }
            let resolved = try Self.resolve(link, base: url)
            guard seen.insert(resolved.absoluteString).inserted else { continue }
            results.append(OnlineNovel(title: title, author: try HTMLRule.value(rule.author, in: element),
                                       intro: try HTMLRule.value(rule.intro, in: element), url: resolved, sourceID: source.id))
        }
        return results
    }

    public func catalog(_ novel: OnlineNovel, source: BookSource) async throws -> OnlineNovel {
        if let reason = source.incompatibility { throw SourceError.message(reason) }
        var result = novel
        let (detail, detailURL) = try await html(novel.url, source: source)
        if let info = source.ruleBookInfo {
            let title = try HTMLRule.value(info.name, in: detail)
            if !title.isEmpty { result.title = title }
            let author = try HTMLRule.value(info.author, in: detail)
            if !author.isEmpty { result.author = author }
            let intro = try HTMLRule.value(info.intro, in: detail)
            if !intro.isEmpty { result.intro = intro }
        }
        let toc = try HTMLRule.value(source.ruleBookInfo?.tocUrl, in: detail)
        var nextURL = try (toc.isEmpty ? detailURL : Self.resolve(toc, base: detailURL))
        var visited: Set<String> = []
        var seenChapters: Set<String> = []
        var chapters: [OnlineChapter] = []
        guard let rule = source.ruleToc, let list = rule.chapterList else { throw SourceError.message("缺少目录规则。") }
        while visited.insert(nextURL.absoluteString).inserted {
            try Task.checkCancellation()
            guard visited.count <= 30 else { throw SourceError.message("目录超过 30 页，已停止以避免循环请求。") }
            let (doc, pageURL): (Document, URL)
            if nextURL == detailURL { (doc, pageURL) = (detail, detailURL) }
            else { (doc, pageURL) = try await html(nextURL, source: source) }
            for element in try HTMLRule.elements(list, in: doc) {
                let title = try HTMLRule.value(rule.chapterName, in: element)
                let raw = try HTMLRule.value(rule.chapterUrl, in: element)
                guard !title.isEmpty, !raw.isEmpty else { continue }
                let link = try Self.resolve(raw, base: pageURL)
                if seenChapters.insert(link.absoluteString).inserted { chapters.append(OnlineChapter(title: title, url: link)) }
                guard chapters.count <= 20000 else { throw SourceError.message("目录超过 20000 章，暂不支持。") }
            }
            let next = try HTMLRule.value(rule.nextTocUrl, in: doc)
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
            let (doc, pageURL) = try await html(nextURL, source: source)
            let text = try HTMLRule.value(content, in: doc, body: true)
            guard !text.isEmpty else { throw SourceError.message("正文为空，请检查书源规则或网站是否需要验证。") }
            total += text.utf8.count
            guard total <= 4 * 1024 * 1024 else { throw SourceError.message("单章正文超过 4 MB。") }
            texts.append(text)
            let next = try HTMLRule.value(rule.nextContentUrl, in: doc)
            if next.isEmpty { break }
            nextURL = try Self.resolve(next, base: pageURL)
            try await Task.sleep(for: .milliseconds(350))
        }
        return texts.joined(separator: "\n\n")
    }
}
