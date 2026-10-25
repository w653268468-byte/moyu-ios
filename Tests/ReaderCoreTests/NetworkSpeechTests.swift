import Foundation
import XCTest
@testable import ReaderCore

final class NetworkSpeechTests: XCTestCase {
    func testImportPreservesUnknownFieldsDeduplicatesAndReportsPartialErrors() throws {
        let data = Data(#"[{"id":1,"name":"旧音色","url":"https://tts.example/old"},{"id":1,"name":"新音色","url":"https://tts.example/new","extension":{"keep":true},"pauseDuration":99999},{"name":"缺少地址"}]"#.utf8)
        let parsed = try NetworkVoiceImport.parse(data)
        XCTAssertEqual(parsed.engines.count, 1); XCTAssertEqual(parsed.failures.count, 1)
        XCTAssertEqual(parsed.engines[0].name, "新音色"); XCTAssertEqual(parsed.engines[0].pauseDuration, 10000)
        let exported = try JSONSerialization.jsonObject(with: NetworkVoiceImport.export(parsed.engines)) as! [[String: Any]]
        XCTAssertEqual((exported[0]["extension"] as? [String: Bool])?["keep"], true)
        XCTAssertEqual(try NetworkVoiceImport.parse(NetworkVoiceImport.export(parsed.engines)).engines[0].id, 1)
        XCTAssertThrowsError(try NetworkVoiceImport.parse(Data("<html>not JSON</html>".utf8)))
    }
    func testLegadoSpeakTextAndNumericSpeedInPostTemplate() async throws {
        let engine = NetworkSpeechEngine(id: 2, name: "POST", url: ##"https://tts.example/audio,{"method":"POST","body":"tex={{java.encodeURI(java.encodeURI(speakText))}}&spd={{(speakSpeed + 5) / 10 + 4}}"}"##, header: ##"{"X-Speed":"{{speakSpeed}}"}"##)
        let request = try await NetworkSpeechClient().request(engine, text: "你好", speed: 10)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(String(decoding: request.httpBody ?? Data(), as: UTF8.self), "tex=%25E4%25BD%25A0%25E5%25A5%25BD&spd=5.5")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Speed"), "10")
    }
    func testInlineSharedScriptBuildsAbsoluteRequest() async throws {
        let engine = NetworkSpeechEngine(id: 3, name: "Script", url: "@js:voiceURL(speakText, speakSpeed)", jsLib: "function voiceURL(text,speed){return 'https://tts.example/say?q='+java.encodeURI(text)+'&s='+(speed+1)}")
        let request = try await NetworkSpeechClient().request(engine, text: "音色", speed: 15)
        let parts = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
        XCTAssertEqual(parts.host, "tts.example")
        XCTAssertEqual(parts.queryItems?.first(where: { $0.name == "q" })?.value, "音色")
        XCTAssertEqual(parts.queryItems?.first(where: { $0.name == "s" })?.value, "16")
    }
    func testAudioErrorsAreRejectedInsteadOfBeingPlayed() throws {
        XCTAssertThrowsError(try NetworkSpeechClient.validateAudio(Data("<html>needs login</html>".utf8)))
        XCTAssertThrowsError(try NetworkSpeechClient.validateAudio(Data(#"{"code":401,"message":"token expired"}"#.utf8)))
        XCTAssertThrowsError(try NetworkSpeechClient.validateAudio(Data("not audio data at all".utf8)))
        let wave = Data("RIFF1234WAVEfmt ".utf8)
        XCTAssertNoThrow(try NetworkSpeechClient.validateAudio(wave))
        XCTAssertEqual(NetworkSpeechEngine(id: 1, name: "rate", url: "https://tts.example", concurrentRate: "2/1000").minimumInterval, 0.5)
    }
}
