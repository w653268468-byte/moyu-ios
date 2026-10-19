import Foundation
import XCTest
@testable import ReaderCore

final class ComplexSourceScriptTests: XCTestCase {
    private let base = URL(string: "https://fixture.example/books/1")!
    func testNestedExtractionRestoresOuterResultAndBase() throws {
        let engine = try SourceScript()
        let html = "<a href='/chapter'>故事</a><p>正文</p>"
        let value = try engine.evaluate("const before=result; const extracted=java.getString('a@text@js:result+\"嵌套\"'); [extracted,result===before,baseUrl,java.getString('p@text')]", result: html, baseURL: base) as? [Any]
        XCTAssertEqual(value?[0] as? String, "故事嵌套")
        XCTAssertEqual(value?[1] as? Bool, true)
        XCTAssertEqual(value?[2] as? String, base.absoluteString)
        XCTAssertEqual(value?[3] as? String, "正文")
        XCTAssertEqual(try engine.evaluate("java.getString('$.data@js:JSON.parse(result).name', {data:{name:'JSON故事'}})", result: html, baseURL: base) as? String, "JSON故事")
    }
    func testNestedElementsAndDepthLimitRecover() throws {
        let engine = try SourceScript()
        let rows = try engine.evaluate("java.getElements('a<js>result.toArray().slice(0,1)</js>').map(x=>x.text())", result: "<a>一</a><a>二</a>", baseURL: base) as? [String]
        XCTAssertEqual(rows, ["一"])
        XCTAssertThrowsError(try engine.evaluate("globalThis.recur=()=>java.getString('@js:recur()'); recur()", result: "", baseURL: base))
        XCTAssertEqual(try engine.evaluate("1+1", result: "", baseURL: base) as? Int, 2)
    }
    func testCryptoJSAndSymmetricFacadeMatchNIST() throws {
        let engine = try SourceScript()
        let code = "java.createSymmetricCrypto('AES/CBC/NoPadding',java.hexDecodeToByteArray('2b7e151628aed2a6abf7158809cf4f3c'),java.hexDecodeToByteArray('000102030405060708090a0b0c0d0e0f')).encryptHex(java.hexDecodeToByteArray('6bc1bee22e409f96e93d7e117393172a'))"
        XCTAssertEqual(try engine.evaluate(code, result: "", baseURL: base) as? String, "7649abac8119b246cee98e9b12e9197d")
        XCTAssertEqual(try engine.evaluate("CryptoJS.SHA256('abc').toString()", result: "", baseURL: base) as? String, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(try engine.evaluate("const encrypted=CryptoJS.AES.encrypt('中文正文🌸','passphrase').toString(); CryptoJS.AES.decrypt(encrypted,'passphrase').toString(CryptoJS.enc.Utf8)", result: "", baseURL: base) as? String, "中文正文🌸")
        XCTAssertEqual(try engine.evaluate("const cipher=java.createSymmetricCrypto('AES/CBC/PKCS5Padding','0123456789abcdef','abcdef0123456789');cipher.decryptStr(cipher.encryptBase64('正文🌸'))", result: "", baseURL: base) as? String, "正文🌸")
        XCTAssertThrowsError(try engine.evaluate("java.createSymmetricCrypto('AES/CBC/NoPadding','0123456789abcdef','abcdef0123456789').encrypt('short')", result: "", baseURL: base))
        XCTAssertThrowsError(try engine.evaluate("java.createSymmetricCrypto('AES/CBC/PKCS5Padding','0123456789abcdef','abcdef0123456789').decryptStr('00000000000000000000000000000000')", result: "", baseURL: base))
    }
    func testPersistentSourceCacheIsIsolatedAndExpires() throws {
        let sourceID = "https://cache-" + UUID().uuidString + ".example"
        let json = try String(decoding: JSONSerialization.data(withJSONObject: ["bookSourceUrl": sourceID]), as: UTF8.self)
        let first = try SourceScript(); try first.setJSONGlobal("source", json: json)
        _ = try first.evaluate("cache.put('kept','cache value'); source.setVariable('source value'); source.put('id','42'); cache.put('expires','soon',0.01)", result: "", baseURL: base)
        defer { SourceScriptCache.shared.delete(sourceID, "kept"); SourceScriptCache.shared.delete(sourceID, "expires"); SourceScriptCache.shared.delete(sourceID, "source:@variable"); SourceScriptCache.shared.delete(sourceID, "source:id") }
        Thread.sleep(forTimeInterval: 0.03)
        let second = try SourceScript(); try second.setJSONGlobal("source", json: json)
        let values = try second.evaluate("[cache.get('kept'),source.getVariable(),source.get('id'),source.getKey(),cache.get('expires')]", result: "", baseURL: base) as? [Any]
        XCTAssertEqual(values?[0] as? String, "cache value"); XCTAssertEqual(values?[1] as? String, "source value")
        XCTAssertEqual(values?[2] as? String, "42"); XCTAssertEqual(values?[3] as? String, sourceID); XCTAssertTrue(values?[4] is NSNull)
        try second.setJSONGlobal("source", json: #"{"bookSourceUrl":"https://other.example"}"#)
        XCTAssertTrue(try second.evaluate("cache.get('kept')", result: "", baseURL: base) is NSNull)
    }
    func testJavaStringsAndBookVariablesSurviveSnapshot() throws {
        let engine = try SourceScript()
        try engine.setJSONGlobal("book", json: #"{"bookUrl":"https://fixture.example/book","name":"故事"}"#)
        XCTAssertEqual(try engine.evaluate("book.putVariable('id','42');String(new java.lang.String('中文'.getBytes('GBK'),'GBK'))+'|'+book.getVariable('id')", result: "", baseURL: base) as? String, "中文|42")
        let restored = try SourceScript(); try restored.restoreVariables(engine.snapshotVariables())
        try restored.setJSONGlobal("book", json: #"{"bookUrl":"https://fixture.example/book"}"#)
        XCTAssertEqual(try restored.evaluate("book.getVariable('id')", result: "", baseURL: base) as? String, "42")
        XCTAssertEqual(try restored.evaluate("java.encodeURI('中文 空格','UTF-8')", result: "", baseURL: base) as? String, "%E4%B8%AD%E6%96%87+%E7%A9%BA%E6%A0%BC")
    }
}
