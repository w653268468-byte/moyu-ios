import Foundation
import XCTest
@testable import ReaderCore

private final class ScriptThreadResult: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Result<String, Error>?
    func store(_ value: Result<String, Error>) { lock.lock(); self.value = value; lock.unlock() }
    func load() -> Result<String, Error>? { lock.lock(); defer { lock.unlock() }; return value }
}

final class SourceScriptTests: XCTestCase {
    let base = URL(string: "https://books.example/book/1")!
    func testDigestAndHMacKnownVectors() throws {
        let engine = try SourceScript()
        XCTAssertEqual(try engine.evaluate("java.digestHex('abc','SHA-1')", result: "", baseURL: base) as? String, "a9993e364706816aba3e25717850c26c9cd0d89d")
        XCTAssertEqual(try engine.evaluate("java.digestBase64Str('abc','SHA-256')", result: "", baseURL: base) as? String, "ungWv48Bz+pBQUDeXa4iI7ADYaOWF3qctBD/YfIAFa0=")
        XCTAssertEqual(try engine.evaluate("java.md5Encode16('abc')", result: "", baseURL: base) as? String, "3cd24fb0d6963f7d")
        XCTAssertEqual(try engine.evaluate("java.HMacHex('The quick brown fox jumps over the lazy dog','HmacSHA256','key')", result: "", baseURL: base) as? String, "f7bc83f430538424b13298e6aa6fb143ef4d59a14946175997479dbc2d1a3cd8")
        let encoded = try engine.evaluate("java.HMacBase64('The quick brown fox jumps over the lazy dog','HmacSHA256','key')", result: "", baseURL: base) as? String ?? ""
        XCTAssertEqual(Data(base64Encoded: encoded)?.map { String(format: "%02x", $0) }.joined(), "f7bc83f430538424b13298e6aa6fb143ef4d59a14946175997479dbc2d1a3cd8")
        XCTAssertThrowsError(try engine.evaluate("java.digestHex('abc','not-an-algorithm')", result: "", baseURL: base))
        XCTAssertThrowsError(try engine.evaluate("java.HMacHex('abc','SHA256','key')", result: "", baseURL: base))
    }
    func testBase64BinaryPreservesJavaSignedBytes() throws {
        let engine = try SourceScript()
        XCTAssertEqual(try engine.evaluate("java.base64DecodeToByteArray('AP+A')", result: "", baseURL: base) as? [Int], [0, -1, -128])
        XCTAssertThrowsError(try engine.evaluate("java.base64Decode('AP+A')", result: "", baseURL: base))
    }
    func testEverySupportedDigestAndHMacAlgorithmAgainstIndependentVectors() throws {
        let vectors = [
            ("MD5", "900150983cd24fb0d6963f7d28e17f72", "d2fe98063f876b03193afb49b4979591"),
            ("SHA1", "a9993e364706816aba3e25717850c26c9cd0d89d", "4fd0b215276ef12f2b3e4c8ecac2811498b656fc"),
            ("SHA256", "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", "9c196e32dc0175f86f4b1cb89289d6619de6bee699e4c378e68309ed97a1a6ab"),
            ("SHA384", "cb00753f45a35e8bb5a03d699ac65007272c32ab0eded1631a8b605a43ff5bed8086072ba1e7cc2358baeca134c825a7", "30ddb9c8f347cffbfb44e519d814f074cf4047a55d6f563324f1c6a33920e5edfb2a34bac60bdc96cd33a95623d7d638"),
            ("SHA512", "ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f", "3926a207c8c42b0c41792cbd3e1a1aaaf5f7a25704f62dfc939c4987dd7ce060009c5bb1c2447355b3216f10b537e9afa7b64a4e5391b0d631172d07939e087a")
        ]
        let engine = try SourceScript()
        for (name, digest, mac) in vectors {
            XCTAssertEqual(try engine.evaluate("java.digestHex('abc','\(name)')", result: "", baseURL: base) as? String, digest, name)
            XCTAssertEqual(try engine.evaluate("java.HMacHex('abc','Hmac\(name)','key')", result: "", baseURL: base) as? String, mac, name)
        }
    }
    func testRulesHaveFreshLexicalBindingsWhileLibrariesAndPutRemainShared() throws {
        let engine = try SourceScript()
        _ = try engine.evaluate("function sharedName(value) { return value + '共享'; }; void 0", result: "", baseURL: base, persistentDefinitions: true)
        for value in ["第一页", "第二页"] {
            XCTAssertEqual(try engine.evaluate("let title = result; const suffix = '结果'; java.put('last', title); sharedName(title + suffix)", result: value, baseURL: base) as? String, value + "结果共享")
        }
        XCTAssertEqual(try engine.evaluate("java.get('last')", result: "", baseURL: base) as? String, "第二页")
    }
    func testCompatibleContentSelectionAndCommonUtilityHelpers() throws {
        let engine = try SourceScript()
        let html = "<a href='/next'>下一章</a><div id='content'>第一段<br><br>第二段</div>"
        XCTAssertEqual(try engine.evaluate("java.getString('a@href',null,true)", result: html, baseURL: base) as? String, "https://books.example/next")
        XCTAssertEqual(try engine.evaluate("java.setContent({data:{name:'故事'}}); java.getString('$.data.name')", result: "", baseURL: base) as? String, "故事")
        XCTAssertEqual(try engine.evaluate("java.setContent('<p>公版</p>'); let e=java.getElement('p'); java.setContent(e); java.getString('text')", result: "", baseURL: base) as? String, "公版")
        XCTAssertEqual(try engine.evaluate("java.timeFormatUTC(0,'yyyy-MM-dd HH:mm:ss',8)", result: "", baseURL: base) as? String, "1970-01-01 08:00:00")
        XCTAssertEqual(try engine.evaluate("java.hexDecodeToString(java.hexEncodeToString('中文🌸'))", result: "", baseURL: base) as? String, "中文🌸")
        XCTAssertEqual(try engine.evaluate("java.t2s('繁體小說')", result: "", baseURL: base) as? String, "繁体小说")
        XCTAssertEqual(try engine.evaluate("java.s2t('繁体小说')", result: "", baseURL: base) as? String, "繁體小說")
        let uuid = try engine.evaluate("java.randomUUID()", result: "", baseURL: base) as? String ?? ""
        XCTAssertNotNil(UUID(uuidString: uuid))
        XCTAssertThrowsError(try engine.evaluate("java.hexDecodeToString('xy')", result: "", baseURL: base))
    }
    func testCachedEngineWorksAfterMovingToAnotherOSThread() throws {
        let engine = try SourceScript(), result = ScriptThreadResult()
        let url = base, finished = DispatchSemaphore(value: 0)
        _ = try engine.evaluate("java.put('kept','cross-thread')", result: "", baseURL: url)
        let thread = Thread {
            do {
                let value = try engine.evaluate("java.get('kept')", result: "", baseURL: url)
                result.store(.success(value as? String ?? "missing"))
            } catch { result.store(.failure(error)) }
            finished.signal()
        }
        thread.start()
        guard finished.wait(timeout: .now() + 10) == .success else { return XCTFail("Script thread did not finish") }
        XCTAssertEqual(try XCTUnwrap(result.load()).get(), "cross-thread")
        XCTAssertThrowsError(try engine.evaluate("function recurse(){java.md5Encode('x');return recurse()} recurse()", result: "", baseURL: url, timeout: 0.5))
        XCTAssertEqual(try engine.evaluate("1+1", result: "", baseURL: url) as? Int, 2)
    }
    func testModernJavaScriptAndStructuredOutput() throws {
        let engine = try SourceScript()
        let value = try engine.evaluate("JSON.parse(result).books.filter(b => b.free).map(({name}) => name)", result: #"{"books":[{"name":"三国","free":true},{"name":"Other","free":false}]}"#, baseURL: base)
        XCTAssertEqual(value as? [String], ["三国"])
    }
    func testHTMLAndJavaLikeCollections() throws {
        let engine = try SourceScript()
        let html = "<div class='book'><a href='/a'>三国</a></div><div class='book'><a href='/b'>水浒</a></div>"
        let value = try engine.evaluate("java.getElements('.book').toArray().map(o => o.select('a').first().text())", result: html, baseURL: base)
        XCTAssertEqual(value as? [String], ["三国", "水浒"])
        XCTAssertEqual(try engine.evaluate("java.getString('a@href')", result: html, baseURL: base) as? String, "/a\n/b")
        XCTAssertEqual(try engine.evaluate("org.jsoup.Jsoup.parse(result).select('a').last().attr('href')", result: html, baseURL: base) as? String, "/b")
    }
    func testEncodingHashesAndVariables() throws {
        let engine = try SourceScript()
        XCTAssertEqual(try engine.evaluate("java.base64Decode(java.base64Encode(result))", result: "中文🌸", baseURL: base) as? String, "中文🌸")
        XCTAssertEqual(try engine.evaluate("java.md5Encode(result)", result: "abc", baseURL: base) as? String, "900150983cd24fb0d6963f7d28e17f72")
        _ = try engine.evaluate("java.put('chapter', '第一章')", result: "", baseURL: base)
        XCTAssertEqual(try engine.evaluate("java.get('chapter')", result: "", baseURL: base) as? String, "第一章")
        XCTAssertEqual(try engine.evaluate("java.resolve('../toc')", result: "", baseURL: base) as? String, "https://books.example/toc")
    }
    func testRuleDocumentPipelinesPreserveElementsAndScope() throws {
        let doc = try RuleDocument.parse(Data("<div class='book'><a href='/a'>三国</a></div><div class='book'><a href='/b'>水浒</a></div>".utf8), base: base)
        let rows = try doc.elements(".book<js>result.toArray().slice(0,1)</js>")
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(try rows[0].value("a@text@js:result + '演义'"), "三国演义")
        XCTAssertEqual(try rows[0].value("a@href"), "/a")
        _ = try doc.value("@js:java.put('shared','kept')")
        XCTAssertEqual(try rows[0].value("@js:java.get('shared')"), "kept")
        let json = try RuleDocument.parse(Data(#"{"books":[{"name":"A"},{"name":"B"}]}"#.utf8), base: base)
        XCTAssertEqual(try json.value("$.books@js:JSON.parse(result).map(b => b.name).join(',')"), "A,B")
        let single = try RuleDocument.parse(Data(#"{"books":[{"name":"A"}]}"#.utf8), base: base)
        XCTAssertEqual(try single.value("$.books[*]@js:JSON.parse(result).map(b => b.name).join(',')"), "A")
    }
    func testScriptURLAndInlineTemplates() throws {
        let script = try SourceScript()
        let request = try SourceRequest.make("@js:'/search?q=' + encodeURIComponent(key) + '&page=' + page", query: "中文 空格", base: base, script: script, page: 3)
        XCTAssertEqual(URLComponents(url: request.url!, resolvingAgainstBaseURL: true)?.queryItems?.first?.value, "中文 空格")
        XCTAssertTrue(request.url!.absoluteString.hasSuffix("page=3"))
        let inline = try SourceRequest.make("/search?q={{encodeURIComponent(key)}}&n={{({a:2}).a}}", query: "a&b", base: base, script: script)
        XCTAssertTrue(inline.url!.absoluteString.contains("q=a%26b&n=2"))
        let quotes = try ScriptTemplate.expand("{{'x}}y'}}", using: script, query: "", base: base)
        XCTAssertEqual(quotes, "x}}y")
        XCTAssertThrowsError(try ScriptTemplate.expand("/{{key + 'broken'}", using: script, query: "", base: base))
    }
    func testInfiniteLoopIsInterruptedAndUnknownBridgeIsVisible() throws {
        let engine = try SourceScript()
        let began = Date()
        XCTAssertThrowsError(try engine.evaluate("while (true) {}", result: "", baseURL: base, timeout: 0.05)) { error in
            XCTAssertTrue(error.localizedDescription.contains("时间限制"))
        }
        XCTAssertLessThan(Date().timeIntervalSince(began), 5)
        XCTAssertThrowsError(try engine.evaluate("java.unimplementedInterface()", result: "", baseURL: base)) { error in
            XCTAssertTrue(error.localizedDescription.contains("java.unimplementedInterface"))
        }
        XCTAssertEqual(try engine.evaluate("[typeof std, typeof os, typeof Worker].join(',')", result: "", baseURL: base) as? String, "undefined,undefined,undefined")
    }
}
