import Foundation
import XCTest
@testable import ReaderCore

final class SourceRSATests: XCTestCase {
    private let base = URL(string: "https://rsa-fixture.example")!
    private func engine() throws -> SourceScript {
        let engine = try SourceScript()
        let url = try XCTUnwrap(Bundle.module.url(forResource: "rsa-public-test-keys", withExtension: "json", subdirectory: "Fixtures"))
        try engine.setJSONGlobal("fixture", json: String(contentsOf: url, encoding: .utf8))
        return engine
    }
    func testImportedPKCS8AndSPKIKeysMatchOpenSSLCiphertexts() throws {
        let script = try engine()
        let values = try script.evaluate("const rsa=java.createAsymmetricCrypto('RSA/ECB/PKCS1Padding').setPrivateKey(fixture.privateKey).setPublicKey(fixture.publicKey); [rsa.decryptStr(fixture.publicCipher,false),rsa.decryptStr(fixture.privateCipher),rsa.encryptBase64(fixture.text,false)===fixture.privateCipher]", result: "", baseURL: base, timeout: 10) as? [Any]
        XCTAssertEqual(values?[0] as? String, "三国演义·复杂书源兼容验证")
        XCTAssertEqual(values?[1] as? String, "三国演义·复杂书源兼容验证")
        XCTAssertEqual(values?[2] as? Bool, true)
        XCTAssertEqual(try script.evaluate("java.createAsymmetricCrypto('RSA').setPrivateKey(fixture.privatePKCS1).decryptStr(fixture.publicCipher,false)", result: "", baseURL: base) as? String, "三国演义·复杂书源兼容验证")
        XCTAssertEqual(try script.evaluate("java.createAsymmetricCrypto('RSA').setPublicKey(fixture.publicPKCS1).decryptStr(fixture.privateCipher,true)", result: "", baseURL: base) as? String, "三国演义·复杂书源兼容验证")
    }
    func testOAEPMatchesOpenSSLAndWrongKeyFails() throws {
        let script = try engine()
        XCTAssertEqual(try script.evaluate("java.createAsymmetricCrypto('RSA/ECB/OAEPWithSHA-256AndMGF1Padding').setPrivateKey(fixture.privateKey).decryptStr(fixture.oaepCipher,false)", result: "", baseURL: base) as? String, "三国演义·复杂书源兼容验证")
        XCTAssertThrowsError(try script.evaluate("java.createAsymmetricCrypto('RSA').decryptStr(fixture.publicCipher,false)", result: "", baseURL: base, timeout: 10))
        XCTAssertThrowsError(try script.evaluate("java.createAsymmetricCrypto('RSA').setPrivateKey('not a key').decryptStr(fixture.publicCipher,false)", result: "", baseURL: base))
    }
    func testSignaturesMatchAllIndependentOpenSSLFixtures() throws {
        let script = try engine()
        for name in ["md5", "sha1", "sha256", "sha384", "sha512"] {
            let result = try script.evaluate("const signer=java.createSign('\(name)withRSA').setPrivateKey(fixture.privateKey).setPublicKey(fixture.publicKey); [signer.signBase64(fixture.text)===fixture.signatures.\(name), signer.verify(fixture.text,fixture.signatures.\(name)),signer.verify('changed',fixture.signatures.\(name))]", result: "", baseURL: base) as? [Bool]
            XCTAssertEqual(result, [true,true,false], name)
        }
    }
    func testGeneratedKeyEncodingAndMultiBlockUnicode() throws {
        let script = try engine()
        XCTAssertEqual(try script.evaluate("const rsa=java.createAsymmetricCrypto('RSA');const text='中文🌸'.repeat(80);const encoded=rsa.encryptBase64(text);const restored=java.createAsymmetricCrypto('RSA').setPrivateKey(rsa.getPrivateKey().getEncoded()).setPublicKey(rsa.getPublicKey().getEncoded());restored.decryptStr(encoded,false)===text", result: "", baseURL: base, timeout: 15) as? Bool, true)
    }
}
