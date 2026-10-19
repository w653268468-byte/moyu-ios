#if DEBUG
import Foundation

private actor SearchCheckGate {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    var waitingCount: Int { waiters.count }
    func hold() async { await withCheckedContinuation { waiters.append($0) } }
    func release() { let held = waiters; waiters.removeAll(); for waiter in held { waiter.resume() } }
}

@MainActor enum SearchModelCheck {
    private static func waitFor(_ condition: @escaping @MainActor () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !(await condition()) {
            guard ContinuousClock.now < deadline else { throw SourceError.message("搜索状态检查等待超时") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
    static func run() async {
        let gate = SearchCheckGate(), model = SearchViewModel()
        defer { model.cancel(); Task { await gate.release() } }
        let file = URL.documentsDirectory.appendingPathComponent("search-model-check.json")
        do {
            let definitions: [[String: Any]] = ["fast", "slow"].map { name in [
                "bookSourceName": name, "bookSourceUrl": "https://\(name).example",
                "searchUrl": "/result?q={{key}},{\"webView\":true}",
                "ruleSearch": ["bookList": ".book", "name": "a@text", "bookUrl": "a@href"]
            ] }
            let sources = try SourceImport.parse(JSONSerialization.data(withJSONObject: definitions)).sources
            guard sources.count == 2, let fast = sources.first(where: { $0.bookSourceName == "fast" }), let slow = sources.first(where: { $0.bookSourceName == "slow" }) else { throw SourceError.message("搜索检查书源无效") }
            let client = SourceClient(webRenderer: { request, _ in
                guard let url = request.url else { throw SourceError.message("检查请求没有网址") }
                if url.host == "slow.example" { await gate.hold() }
                let keyword = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "q" })?.value ?? ""
                let html = "<div class='book'><a href='/book'>\(keyword)-\(url.host ?? "")</a></div>"
                return (Data(html.utf8), url)
            })
            model.start("保留结果", sources: sources, client: client, concurrency: 2)
            try await waitFor { guard model.completed == 1 else { return false }; return await gate.waitingCount == 1 }
            model.cancel()
            guard model.state.hits.count == 1, model.pendingCount == 1, !model.searching else { throw SourceError.message("停止未保留已完成结果及待处理任务") }
            model.resume(client: client)
            try await waitFor { await gate.waitingCount == 2 }
            await gate.release()
            try await waitFor { !model.searching && model.pendingCount == 0 }
            guard model.state.hits.count == 2, model.completed == 1, model.state.failures.isEmpty else { throw SourceError.message("继续搜索重复处理已完成书源，或旧回调污染新批次") }
            model.start("旧查询", sources: [slow], client: client)
            try await waitFor { await gate.waitingCount == 1 }
            model.start("新查询", sources: [fast], client: client)
            try await waitFor { !model.searching && model.state.hits.count == 1 }
            await gate.release()
            try await Task.sleep(for: .milliseconds(150))
            guard model.keyword == "新查询", model.state.hits.count == 1, model.state.hits.first?.novel.title == "新查询-fast.example", model.pendingCount == 0 else { throw SourceError.message("旧查询返回后污染新查询") }
            let report: [String: Any] = ["status": "passed", "stopPreservesResults": true, "resumeOnlyPending": true, "oldBatchIgnored": true, "oldQueryIgnored": true]
            try JSONSerialization.data(withJSONObject: report).write(to: file, options: .atomic)
        } catch {
            try? JSONSerialization.data(withJSONObject: ["status": "failed", "error": error.localizedDescription]).write(to: file, options: .atomic)
        }
    }
}

@MainActor enum SourceImportCheck {
    static func run() async {
        let root = URL.documentsDirectory.appendingPathComponent("import-check-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let reportURL = URL.documentsDirectory.appendingPathComponent("source-import-check.json")
        do {
            let interpreter = try SourceScript()
            guard let sampleURL = Bundle.main.url(forResource: "verified-sources", withExtension: "json"),
                  try SourceImport.parse(Data(contentsOf: sampleURL)).sources.count == 3 else { throw SourceError.message("打包的实测示例书源无法读取。") }
            let nativeNamespace = "https://native-" + UUID().uuidString.lowercased() + ".example"
            try interpreter.setJSONGlobal("source", json: String(decoding: JSONSerialization.data(withJSONObject: ["bookSourceUrl": nativeNamespace]), as: UTF8.self))
            defer { SourceScriptCache.shared.delete(nativeNamespace, "source:@loginHeader") }
            guard try interpreter.evaluate("const cipher=java.createSymmetricCrypto('AES/CBC/PKCS5Padding','0123456789abcdef','abcdef0123456789');cipher.decryptStr(cipher.encryptBase64('正文验证'))", result: "", baseURL: URL(string: nativeNamespace)!) as? String == "正文验证",
                  try interpreter.evaluate("var imports=new JavaImporter(Packages.java.lang,Packages.java.util);with(imports){String(Base64.getDecoder().decode('R2F2aW4=')).toString()}", result: "", baseURL: URL(string: nativeNamespace)!) as? String == "Gavin",
                  try interpreter.evaluate("java.getString('a@text@js:result+\"规则\"')", result: "<a>嵌套</a>", baseURL: URL(string: nativeNamespace)!) as? String == "嵌套规则",
                  try interpreter.evaluate("source.putLoginHeader('{\"X-Reader\":\"Gavin\"}');source.getLoginHeaderMap().get('X-Reader')", result: "", baseURL: URL(string: nativeNamespace)!) as? String == "Gavin",
                  try interpreter.evaluate("const rsa=java.createAsymmetricCrypto('RSA');rsa.decryptStr(rsa.encryptBase64('正文RSA'),false)", result: "", baseURL: URL(string: nativeNamespace)!, timeout: 15) as? String == "正文RSA" else { throw SourceError.message("原生书源加密、嵌套规则或登录头检查失败") }
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
            var mark = OnlineReadingMark(chapter: chapter, index: 0, offset: 3, text: text)
            mark.note = "保存后重开仍保留的备注"
            try reloaded.saveMark(mark, in: book)
            let restored = OnlineStore(directory: root)
            guard restored.novels.first?.readingMarks?.first == mark else { throw SourceError.message("在线书签或备注未持久化") }
            let report: [String: Any] = ["status": "passed", "redirect": true, "partialFailure": true,
                "pastedJSON": true, "savedAndReloaded": true, "preservedUnknownFields": true,
                "duplicateUpdated": true, "searchCatalogContent": true, "onlineBookmarkAndNote": true,
                "cryptoJSAndAES": true, "nestedRules": true, "sourceLoginKeychain": true, "rsaRoundTrip": true]
            try JSONSerialization.data(withJSONObject: report, options: .prettyPrinted).write(to: reportURL, options: .atomic)
        } catch {
            let report = try? JSONSerialization.data(withJSONObject: ["status": "failed", "error": error.localizedDescription])
            try? report?.write(to: reportURL, options: .atomic)
        }
    }
}
#endif
