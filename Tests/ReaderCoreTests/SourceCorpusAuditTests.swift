import Foundation
import XCTest
@testable import ReaderCore

private struct SourceAuditCase: Sendable { var source: BookSource; var collection: String; var scripted: Bool; var requiresPersonalLogin: Bool }
private struct SourceAuditResult: Codable, Sendable {
    var name: String; var source: String; var collection: String; var scripted: Bool
    var status = "failed"; var stage = "search"; var keyword = "三国演义"
    var title: String?; var chapters: Int?; var characters: Int?; var error: String?; var category: String?
    var usedWebView = false
    var chapterIndex: Int?; var chapterTitle: String?
}
private actor SourceAuditProgress {
    var value: SourceAuditResult
    init(_ item: SourceAuditCase) { value = SourceAuditResult(name: item.source.bookSourceName, source: item.source.bookSourceUrl, collection: item.collection, scripted: item.scripted) }
    func update(_ stage: String, keyword: String? = nil, title: String? = nil, chapters: Int? = nil) {
        value.stage = stage
        if let keyword { value.keyword = keyword }; if let title { value.title = title }; if let chapters { value.chapters = chapters }
    }
    func usedWebView() { value.usedWebView = true }
    func chapter(_ index: Int, title: String, characters: Int? = nil) { value.chapterIndex = index; value.chapterTitle = title; value.characters = characters }
    func passed(_ report: SourceValidationResult) -> SourceAuditResult {
        var result = value; result.status = "passed"; result.stage = "content"
        result.keyword = report.keyword; result.title = report.title; result.chapters = report.chapters
        result.chapterIndex = report.chapterIndex; result.chapterTitle = report.chapterTitle; result.characters = report.characters
        return result
    }
    func result(error: String? = nil) -> SourceAuditResult {
        var result = value
        if let error {
            result.error = error
            let lower = error.lowercased()
            if lower.contains("没有 webview 渲染器") { result.status = "requires_webview"; result.category = "runtime_environment" }
            else if lower.contains("没有交互式书源验证窗口") { result.status = "requires_login"; result.category = "runtime_environment" }
            else if ["域名停放", "广告跳转", "脚本跳转页", "网站返回 html 页面"].contains(where: lower.contains) { result.category = "unexpected_website_response" }
            else if lower.contains("正文不足") { result.category = "short_or_placeholder_body" }
            else if ["http 401", "http 403", "http 429", "验证", "验证码", "登录", "captcha"].contains(where: lower.contains) { result.category = "authentication_or_rate_limit" }
            else if ["http 404", "http 410", "http 5", "域名", "dns", "超时", "超过 45", "timeout", "network", "网络", "https"].contains(where: lower.contains) { result.category = "network_or_dead_endpoint" }
            else { result.category = "rule_or_bridge" }
        }
        return result
    }
}

final class SourceCorpusAuditTests: XCTestCase {
    func testPublicCollectionsThroughSearchCatalogAndBody() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["GAVIN_SOURCE_AUDIT"] == "1" else { throw XCTSkip("Public-source corpus audit is opt-in") }
        let root = URL(fileURLWithPath: environment["GAVIN_AUDIT_DIRECTORY"] ?? ".build/source-audit", isDirectory: true)
        let data = try Data(contentsOf: root.appendingPathComponent("corpus.json"))
        let objects = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        var candidates: [SourceAuditCase] = []
        for object in objects {
            guard let source = object["source"] as? [String: Any], let collection = object["collection"] as? String,
                  let parsed = try? SourceImport.parse(JSONSerialization.data(withJSONObject: source)).sources.first else { continue }
            candidates.append(SourceAuditCase(source: parsed, collection: collection, scripted: object["scripted"] as? Bool ?? false, requiresPersonalLogin: object["requiresPersonalLogin"] as? Bool ?? false))
        }
        let limit = min(60, max(1, Int(environment["GAVIN_AUDIT_LIMIT"] ?? "32") ?? 32))
        var selected: [SourceAuditCase] = [], hosts = Set<String>()
        // Round-robin across independent collections and script/static styles.
        let buckets = Dictionary(grouping: candidates, by: { $0.collection + "|" + String($0.scripted) }).sorted { $0.key < $1.key }.map(\.value)
        for index in 0..<(buckets.map(\.count).max() ?? 0) {
            for bucket in buckets where bucket.indices.contains(index) {
                let item = bucket[index]
                guard let host = URL(string: item.source.bookSourceUrl)?.host, hosts.insert(host).inserted else { continue }
                selected.append(item); if selected.count == limit { break }
            }
            if selected.count == limit { break }
        }
        XCTAssertFalse(selected.isEmpty)
        var results: [SourceAuditResult] = []
        await withTaskGroup(of: SourceAuditResult.self) { group in
            var next = 0
            for _ in 0..<min(3, selected.count) { let item = selected[next]; next += 1; group.addTask { await Self.audit(item) } }
            while let result = await group.next() {
                results.append(result)
                print("SOURCE AUDIT: \(result.status) · \(result.stage) · \(result.name) · \(result.error ?? "")")
                if next < selected.count { let item = selected[next]; next += 1; group.addTask { await Self.audit(item) } }
            }
        }
        let report = try JSONEncoder().encode(results.sorted { $0.source < $1.source })
        try report.write(to: root.appendingPathComponent("report.json"), options: .atomic)
        print("SOURCE AUDIT SUMMARY: \(results.filter { $0.status == "passed" }.count)/\(results.count) complete search → catalog → content. A completed audit is not a claim that all sources passed.")
        XCTAssertEqual(results.count, selected.count)
    }
    private static func audit(_ item: SourceAuditCase) async -> SourceAuditResult {
        let progress = SourceAuditProgress(item)
        if item.requiresPersonalLogin {
            var result = await progress.result(error: "公开规则含共享会话，审计未使用；需本人网页登录后验证")
            result.status = "requires_login"; result.stage = "login"; result.category = "authentication_or_rate_limit"
            return result
        }
        do {
            #if os(macOS)
            let client = SourceClient(cookieProvider: { await CorpusWebRenderer.cookies($0) }, webRenderer: { request, cookies in
                await progress.usedWebView(); return try await CorpusWebRenderer.render(request, cookies: cookies)
            })
            #else
            let client = SourceClient()
            #endif
            let report = try await SourceValidator.validate(item.source, client: client) { update in
                await progress.update(update.stage, keyword: update.keyword, title: update.title, chapters: update.chapters)
                if let index = update.chapterIndex, let title = update.chapterTitle { await progress.chapter(index, title: title, characters: update.characters) }
            }
            return await progress.passed(report)
        } catch { return await progress.result(error: error.localizedDescription) }
    }
}
