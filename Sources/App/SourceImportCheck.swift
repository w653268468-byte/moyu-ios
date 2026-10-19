#if DEBUG
import Foundation

@MainActor enum SourceImportCheck {
    static func run() async {
        let root = URL.documentsDirectory.appendingPathComponent("import-check-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let reportURL = URL.documentsDirectory.appendingPathComponent("source-import-check.json")
        do {
            let store = OnlineStore(directory: root)
            let result = try await store.client.importText("http://127.0.0.1:18765/broken-sources\nhttp://127.0.0.1:18765/source-start")
            guard result.sources.count == 1, result.failures.count == 1,
                  result.diagnostics.contains(where: { $0.contains("/sources.json") }),
                  result.failures[0].contains("网页") else { throw SourceError.message("重定向或部分失败处理未通过") }
            // The exact same persistence method is used by the preview's confirm button.
            try store.addSources(result.sources)
            let reloaded = OnlineStore(directory: root)
            guard reloaded.sources.count == 1, let source = reloaded.sources.first,
                  source.originalJSON?.contains("customUnknownField") == true else { throw SourceError.message("导入后重新打开未保留书源和原始字段") }
            let pasted = try SourceImport.export(reloaded.sources)
            let pastedResult = try await store.client.importText(String(decoding: pasted, as: UTF8.self))
            guard pastedResult.sources.count == 1 else { throw SourceError.message("完整 JSON 粘贴失败") }
            try reloaded.addSources(pastedResult.sources)
            guard reloaded.sources.count == 1 else { throw SourceError.message("重复导入未更新已有书源") }
            guard let novel = try await reloaded.client.search("公版", source: source).first else { throw SourceError.message("导入后搜索没有结果") }
            let book = try await reloaded.client.catalog(novel, source: source)
            guard let chapter = book.chapters.first else { throw SourceError.message("目录为空") }
            let text = try await reloaded.client.chapter(chapter, source: source)
            guard text.contains("完整链路") else { throw SourceError.message("正文读取失败") }
            let report: [String: Any] = ["status": "passed", "redirect": true, "partialFailure": true,
                "pastedJSON": true, "savedAndReloaded": true, "preservedUnknownFields": true,
                "duplicateUpdated": true, "searchCatalogContent": true]
            try JSONSerialization.data(withJSONObject: report, options: .prettyPrinted).write(to: reportURL, options: .atomic)
        } catch {
            let report = try? JSONSerialization.data(withJSONObject: ["status": "failed", "error": error.localizedDescription])
            try? report?.write(to: reportURL, options: .atomic)
        }
    }
}
#endif
