import Foundation
import SwiftSoup

/// Imports official share links without evaluating scripts or decoding protected responses.
public enum Fanqie {
    public static let sourceID = "moyu:fanqie-official"
    private static let origin = URL(string: "https://fanqienovel.com")!

    public static func isOfficial(_ url: URL) -> Bool {
        guard ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host?.lowercased(), url.user == nil, url.password == nil else { return false }
        return host == "fanqienovel.com" || host.hasSuffix(".fanqienovel.com")
    }

    public static func shareURL(_ input: String) throws -> URL {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.range(of: #"^\d{10,24}$"#, options: .regularExpression) != nil {
            return origin.appendingPathComponent("page/\(text)")
        }
        let detector = try NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let matches = detector.matches(in: text, range: NSRange(text.startIndex..., in: text))
        guard let url = matches.compactMap(\.url).first(where: isOfficial) else {
            throw SourceError.message("请粘贴番茄小说的官方分享链接，或输入数字书籍 ID。可直接粘贴整段分享文案。")
        }
        return url
    }

    public static func bookURL(in url: URL) -> URL? {
        guard isOfficial(url) else { return nil }
        if let match = capture(#"^/page/(\d{10,24})(?:/|$)"#, in: url.path) {
            return origin.appendingPathComponent("page/\(match)")
        }
        if let id = URLComponents(url: url, resolvingAgainstBaseURL: true)?.queryItems?
            .first(where: { ["book_id", "bookId", "novel_id"].contains($0.name) })?.value,
           id.range(of: #"^\d{10,24}$"#, options: .regularExpression) != nil {
            return origin.appendingPathComponent("page/\(id)")
        }
        return nil
    }

    public static func parseCatalog(_ html: String, url: URL, previous: OnlineNovel? = nil) throws -> OnlineNovel {
        guard isOfficial(url) else { throw SourceError.message("分享链接没有跳转到番茄官网，请检查链接。") }
        let doc = try SwiftSoup.parse(html, url.absoluteString)
        let title = try doc.select(".info-name h1, .info-name, h1").first()?.text() ?? ""
        guard !title.isEmpty else { throw SourceError.message("没有获取到番茄书籍信息，请在官方网页确认链接是否有效。") }
        let author = try doc.select(".author-name-text, .author-name").first()?.text() ?? ""
        let intro = try doc.select(".page-abstract-content").first()?.text() ?? ""
        var novel = OnlineNovel(title: title, author: author, intro: intro,
                                url: bookURL(in: url) ?? url, sourceID: sourceID)
        var seen: Set<String> = []
        // Use directory anchors only: the latest-chapter link appears before the directory.
        for anchor in try doc.select(".page-directory-content a[href], .chapter-item a[href]").array() {
            let name = try anchor.text()
            let link = try SourceClient.resolve(anchor.attr("href"), base: url)
            guard isOfficial(link), link.path.hasPrefix("/reader/"), !name.isEmpty,
                  seen.insert(link.absoluteString).inserted else { continue }
            novel.chapters.append(OnlineChapter(title: name, url: link))
            guard novel.chapters.count <= 20000 else { throw SourceError.message("目录超过 20000 章。") }
        }
        guard !novel.chapters.isEmpty else {
            throw SourceError.message("官网没有返回公开章节目录，可能需要在官方网页中查看。")
        }
        novel.chapterIndex = min(max(0, previous?.chapterIndex ?? 0), novel.chapters.count - 1)
        novel.lastReadAt = previous?.lastReadAt
        return novel
    }

    public static func parseChapter(_ html: String) throws -> String {
        let doc = try SwiftSoup.parse(html)
        let body = try HTMLRule.value(".muye-reader-content@html||.reader-content@html", in: doc, body: true)
        guard !body.isEmpty else { throw SourceError.message("官网未返回可提取正文，请使用“官方网页”继续阅读。") }
        if body.unicodeScalars.contains(where: { (0xE000...0xF8FF).contains(Int($0.value)) }) {
            throw SourceError.message("本章采用官方网页字体，原生文本会显示乱码。请点“官方网页”，使用网站原本的字体阅读。")
        }
        return body
    }

    static func bookLinkFromHTML(_ html: String, base: URL) throws -> URL? {
        let doc = try SwiftSoup.parse(html, base.absoluteString)
        for anchor in try doc.select("a[href*='/page/']").array() {
            if let link = try? SourceClient.resolve(anchor.attr("href"), base: base), let book = bookURL(in: link) { return book }
        }
        if let id = capture(#"[\"'](?:bookId|book_id)[\"']\s*:\s*[\"']?(\d{10,24})"#, in: html) {
            return origin.appendingPathComponent("page/\(id)")
        }
        return nil
    }

    private static func capture(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }
}

extension SourceClient {
    public func fanqieShare(_ input: String) async throws -> OnlineNovel {
        let url = try Fanqie.shareURL(input)
        if let canonical = Fanqie.bookURL(in: url) {
            return OnlineNovel(title: "番茄小说", url: canonical, sourceID: Fanqie.sourceID)
        }
        let (data, redirected) = try await fetch(url)
        guard Fanqie.isOfficial(redirected) else { throw SourceError.message("分享链接跳转到了其他网站，请使用番茄官方详情页链接。") }
        let canonical = try Fanqie.bookURL(in: redirected) ?? Fanqie.bookLinkFromHTML(TextParser.decode(data), base: redirected)
        guard let canonical else { throw SourceError.message("未识别到书籍 ID，请从番茄书籍详情页重新复制分享链接。") }
        return OnlineNovel(title: "番茄小说", url: canonical, sourceID: Fanqie.sourceID)
    }

    public func fanqieCatalog(_ novel: OnlineNovel) async throws -> OnlineNovel {
        let (data, finalURL) = try await fetch(novel.url)
        return try Fanqie.parseCatalog(TextParser.decode(data), url: finalURL, previous: novel)
    }

    public func fanqieChapter(_ chapter: OnlineChapter) async throws -> String {
        guard Fanqie.isOfficial(chapter.url) else { throw SourceError.message("章节不是番茄官网链接。") }
        let (data, finalURL) = try await fetch(chapter.url)
        guard Fanqie.isOfficial(finalURL) else { throw SourceError.message("章节链接跳转到了其他网站。") }
        return try Fanqie.parseChapter(TextParser.decode(data))
    }
}
