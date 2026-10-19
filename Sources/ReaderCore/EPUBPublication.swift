import Foundation
import SwiftSoup
import ZIPFoundation

public struct EPUBSpineItem: Codable, Equatable, Sendable {
    public var path: String
    public var title: String
    public var fixedLayout: Bool
}
public struct EPUBNavigationItem: Codable, Equatable, Sendable {
    public var title: String
    public var chapter: Int
    public var fragment: String?
}
public struct EPUBPublication: Sendable {
    public var chapters: [EPUBSpineItem]
    public var navigation: [EPUBNavigationItem]
    public var resources: [String: Data]
    public var rightToLeft: Bool
    public static let maximumExpandedBytes = 200 * 1024 * 1024

    public static func safePath(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("/") && !path.contains("\\") && !path.contains("\0") &&
        !path.components(separatedBy: "/").contains(where: { $0 == ".." || $0 == "." })
    }
    public static func resolve(_ href: String, relativeTo path: String) throws -> (path: String, fragment: String?) {
        let base = URL(fileURLWithPath: "/" + path)
        guard let url = URL(string: href, relativeTo: base)?.absoluteURL, url.isFileURL,
              url.host == nil || url.host == "", url.query == nil else { throw SourceError.message("EPUB 含无效的本地资源地址。") }
        let result = String(url.standardizedFileURL.path.dropFirst())
        guard safePath(result) else { throw SourceError.message("EPUB 资源路径无效。") }
        return (result, url.fragment?.removingPercentEncoding ?? url.fragment)
    }
    public static func load(_ data: Data) throws -> EPUBPublication {
        guard data.count <= LocalBookImporter.maximumFileBytes else { throw SourceError.message("EPUB 超过 100 MB。") }
        let archive = try Archive(data: data, accessMode: .read)
        var resources: [String: Data] = [:], total = 0, files = 0
        for entry in archive {
            try Task.checkCancellation()
            files += 1
            guard files <= 20000 else { throw SourceError.message("EPUB 文件数超过 20000。") }
            guard entry.type != .symlink else { throw SourceError.message("EPUB 不允许符号链接。") }
            if entry.type != .file { continue }
            guard safePath(entry.path), resources[entry.path] == nil else { throw SourceError.message("EPUB 含无效或重复路径。") }
            guard entry.uncompressedSize <= 40 * 1024 * 1024, entry.uncompressedSize <= UInt64(maximumExpandedBytes - total) else { throw SourceError.message("EPUB 解压资源过大。") }
            var content = Data()
            _ = try archive.extract(entry) { chunk in
                try Task.checkCancellation()
                guard chunk.count <= maximumExpandedBytes - total, content.count + chunk.count <= 40 * 1024 * 1024 else { throw SourceError.message("EPUB 解压资源过大。") }
                total += chunk.count; content.append(chunk)
            }
            resources[entry.path] = content
        }
        func resource(_ path: String) throws -> Data {
            guard let content = resources[path] else { throw SourceError.message("EPUB 缺少文件：\(path)") }; return content
        }
        let container = try XMLBookNode.parse(resource("META-INF/container.xml"))
        guard let packagePath = container.descendants("rootfile").first?.attributes["full-path"], safePath(packagePath) else { throw SourceError.message("EPUB 缺少有效内容清单。") }
        if let data = resources["META-INF/encryption.xml"] {
            let encryption = try XMLBookNode.parse(data)
            let protected = encryption.descendants("CipherReference").compactMap { $0.attributes["URI"] }
            if protected.contains(where: { ["xhtml", "html", "htm", "xml"].contains(($0 as NSString).pathExtension.lowercased()) }) { throw SourceError.message("此 EPUB 正文受 DRM 保护，无法导入。") }
        }
        let package = try XMLBookNode.parse(resource(packagePath))
        let items = package.descendants("item")
        let spine = package.descendants("spine").first
        let globalFixed = package.descendants("meta").contains { $0.attributes["property"] == "rendition:layout" && $0.text.trimmingCharacters(in: .whitespacesAndNewlines) == "pre-paginated" }
        var chapters: [EPUBSpineItem] = []
        for ref in spine?.descendants("itemref") ?? [] where ref.attributes["linear"] != "no" {
            guard chapters.count < 10000, let item = items.first(where: { $0.attributes["id"] == ref.attributes["idref"] }),
                  let href = item.attributes["href"] else { throw SourceError.message("EPUB 阅读顺序引用无效。") }
            guard item.attributes["media-type"]?.contains("html") == true || item.attributes["media-type"] == "image/svg+xml" else { continue }
            let path = try resolve(href, relativeTo: packagePath).path
            let html = try SwiftSoup.parse(TextParser.decode(resource(path)))
            let heading = try html.select("h1,h2,h3,title").first()?.text() ?? ""
            let properties = ref.attributes["properties"] ?? ""
            let fixed = properties.contains("rendition:layout-pre-paginated") || (globalFixed && !properties.contains("rendition:layout-reflowable"))
            chapters.append(EPUBSpineItem(path: path, title: heading.isEmpty ? "第 \(chapters.count + 1) 节" : heading, fixedLayout: fixed))
        }
        guard !chapters.isEmpty else { throw SourceError.message("EPUB 没有可阅读的 HTML/SVG 章节。") }
        var navigation: [EPUBNavigationItem] = []
        func add(_ label: String, href: String, base: String) {
            guard !label.isEmpty, let target = try? resolve(href, relativeTo: base), let chapter = chapters.firstIndex(where: { $0.path == target.path }) else { return }
            navigation.append(EPUBNavigationItem(title: label, chapter: chapter, fragment: target.fragment))
        }
        if let item = items.first(where: { ($0.attributes["properties"] ?? "").components(separatedBy: .whitespaces).contains("nav") }), let href = item.attributes["href"] {
            let path = try resolve(href, relativeTo: packagePath).path
            let html = try SwiftSoup.parse(TextParser.decode(resource(path)))
            let navs = try html.select("nav")
            let toc = navs.array().first(where: { (try? $0.attr("epub:type").components(separatedBy: .whitespaces).contains("toc")) == true }) ?? navs.first()
            for link in try toc?.select("a[href]").array() ?? [] { add(try link.text(), href: try link.attr("href"), base: path) }
        } else if let item = items.first(where: { $0.attributes["id"] == spine?.attributes["toc"] || $0.attributes["media-type"] == "application/x-dtbncx+xml" }), let href = item.attributes["href"] {
            let path = try resolve(href, relativeTo: packagePath).path
            let ncx = try XMLBookNode.parse(resource(path))
            for point in ncx.descendants("navPoint") {
                if let href = point.descendants("content").first?.attributes["src"], let label = point.descendants("text").first?.text { add(label, href: href, base: path) }
            }
        }
        if navigation.isEmpty { navigation = chapters.enumerated().map { EPUBNavigationItem(title: $0.element.title, chapter: $0.offset) } }
        return EPUBPublication(chapters: chapters, navigation: navigation, resources: resources, rightToLeft: spine?.attributes["page-progression-direction"] == "rtl")
    }
    public func writeResources(to directory: URL) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        for (path, data) in resources {
            try Task.checkCancellation()
            guard Self.safePath(path) else { throw SourceError.message("EPUB 资源路径无效。") }
            let target = directory.appendingPathComponent(path)
            guard target.standardizedFileURL.path.hasPrefix(directory.standardizedFileURL.path + "/") else { throw SourceError.message("EPUB 资源越界。") }
            try manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: target, options: .atomic)
        }
    }
}
