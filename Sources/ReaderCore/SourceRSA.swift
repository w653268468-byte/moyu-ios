import Foundation
import Security
import CryptoKit

enum SourceRSA {
    private static func bytes(_ value: Any) throws -> Data {
        guard let values = value as? [Int], values.count <= 2 * 1024 * 1024, values.allSatisfy({ (-128...255).contains($0) }) else { throw SourceError.message("RSA 字节数组无效。") }
        return Data(values.map { UInt8(truncatingIfNeeded: $0) })
    }
    private static func decodedKey(_ value: Any) throws -> Data {
        if value is [Int] { let data = try bytes(value); guard data.count <= 65536 else { throw SourceError.message("RSA 密钥过大。") }; return data }
        guard let string = value as? String, string.utf8.count <= 65536 else { throw SourceError.message("RSA 密钥无效或过大。") }
        let cleaned = string.replacingOccurrences(of: "-----[A-Z ]+-----", with: "", options: .regularExpression).components(separatedBy: .whitespacesAndNewlines).joined()
        guard let data = Data(base64Encoded: cleaned), !data.isEmpty else { throw SourceError.message("RSA 密钥不是有效的 PEM/Base64 DER。") }
        return data
    }
    private struct DER { var tag: UInt8; var payload: Data }
    private static func elements(_ data: Data) throws -> [DER] {
        let data = [UInt8](data); var index = 0; var nodes: [DER] = []
        while index < data.count {
            guard index + 2 <= data.count else { throw SourceError.message("RSA DER 长度无效。") }
            let tag = data[index]; var length = Int(data[index+1]); index += 2
            if length >= 128 {
                let count = length & 127
                guard (1...4).contains(count), index + count <= data.count else { throw SourceError.message("RSA DER 长度无效。") }
                length = 0; for _ in 0..<count { length = length * 256 + Int(data[index]); index += 1 }
            }
            guard length <= data.count-index else { throw SourceError.message("RSA DER 内容不完整。") }
            nodes.append(DER(tag: tag, payload: Data(data[index..<(index+length)]))); index += length
        }
        return nodes
    }
    private static func key(_ value: Any, publicKey: Bool) throws -> SecKey {
        var data = try decodedKey(value)
        if publicKey, let certificate = SecCertificateCreateWithData(nil, data as CFData), let key = SecCertificateCopyKey(certificate) { return key }
        let root = try elements(data)
        if root.count == 1, root[0].tag == 0x30 {
            let children = try elements(root[0].payload)
            if publicKey, children.count == 2, children[0].tag == 0x30, children[1].tag == 0x03, children[1].payload.first == 0 {
                data = Data(children[1].payload.dropFirst()) // SubjectPublicKeyInfo → PKCS#1
            } else if !publicKey, children.count >= 3, children[0].tag == 0x02, children[1].tag == 0x30, children[2].tag == 0x04 {
                data = children[2].payload // PKCS#8 → PKCS#1
            }
        }
        var error: Unmanaged<CFError>?
        let attributes: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA, kSecAttrKeyClass as String: publicKey ? kSecAttrKeyClassPublic : kSecAttrKeyClassPrivate]
        guard let result = SecKeyCreateWithData(data as CFData, attributes as CFDictionary, &error) else { throw SourceError.message("RSA 密钥无法导入：\(error?.takeRetainedValue().localizedDescription ?? "格式不支持")") }
        guard (128...1024).contains(SecKeyGetBlockSize(result)) else { throw SourceError.message("RSA 仅支持 1024–8192 位密钥。") }
        return result
    }
    private static func wrapped(_ tag: UInt8, _ payload: Data) -> Data {
        var length = payload.count; var bytes: [UInt8] = []
        if length < 128 { bytes = [UInt8(length)] }
        else { while length > 0 { bytes.insert(UInt8(length & 255), at: 0); length >>= 8 }; bytes.insert(128 | UInt8(bytes.count), at: 0) }
        return Data([tag] + bytes) + payload
    }
    private static func export(_ key: SecKey, publicKey: Bool) throws -> String {
        var error: Unmanaged<CFError>?
        guard let data = SecKeyCopyExternalRepresentation(key, &error) as Data? else { throw SourceError.message("无法导出脚本 RSA 密钥：\(error?.takeRetainedValue().localizedDescription ?? "未知错误")") }
        let identifier = Data([0x30,0x0d,0x06,0x09,0x2a,0x86,0x48,0x86,0xf7,0x0d,0x01,0x01,0x01,0x05,0x00])
        let body = publicKey ? identifier + wrapped(0x03, Data([0]) + data) : Data([0x02,0x01,0x00]) + identifier + wrapped(0x04, data)
        return wrapped(0x30, body).base64EncodedString()
    }
    private static func digestInfo(_ data: Data, algorithm: String) throws -> Data {
        let digest: Data; let prefix: String
        switch algorithm.uppercased().replacingOccurrences(of: "-", with: "") {
        case "MD5WITHRSA": digest = Data(Insecure.MD5.hash(data: data)); prefix = "3020300c06082a864886f70d020505000410"
        case "SHA1WITHRSA": digest = Data(Insecure.SHA1.hash(data: data)); prefix = "3021300906052b0e03021a05000414"
        case "SHA256WITHRSA": digest = Data(SHA256.hash(data: data)); prefix = "3031300d060960864801650304020105000420"
        case "SHA384WITHRSA": digest = Data(SHA384.hash(data: data)); prefix = "3041300d060960864801650304020205000430"
        case "SHA512WITHRSA": digest = Data(SHA512.hash(data: data)); prefix = "3051300d060960864801650304020305000440"
        default: throw SourceError.message("尚未支持的 RSA 签名算法：\(algorithm)")
        }
        let chars = Array(prefix); let header = Data(stride(from: 0, to: chars.count, by: 2).map { UInt8(String(chars[$0...$0+1]), radix: 16)! })
        return header + digest
    }
    static func call(_ method: String, _ args: [Any], cancelled: () -> Bool) throws -> Any {
        if method == "rsaGenerate" {
            var error: Unmanaged<CFError>?
            let attributes: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits as String: 2048]
            guard let secret = SecKeyCreateRandomKey(attributes as CFDictionary, &error), let publicKey = SecKeyCopyPublicKey(secret) else { throw SourceError.message("无法生成 RSA 密钥。") }
            return ["privateKey": try export(secret, publicKey: false), "publicKey": try export(publicKey, publicKey: true)]
        }
        if method == "rsaPublicKey" {
            guard let value = args.first, let publicKey = SecKeyCopyPublicKey(try key(value, publicKey: false)) else { throw SourceError.message("无法取得 RSA 公钥。") }
            return try export(publicKey, publicKey: true)
        }
        guard args.count >= 3, let algorithm = args[0] as? String else { throw SourceError.message("RSA 参数不足。") }
        if method == "rsaSign" || method == "rsaVerify" {
            let payload = try digestInfo(bytes(args[2]), algorithm: algorithm)
            let key = try key(args[1], publicKey: method == "rsaVerify")
            var error: Unmanaged<CFError>?
            if method == "rsaVerify" {
                guard args.count == 4 else { throw SourceError.message("RSA 验签缺少签名。") }
                let valid = SecKeyVerifySignature(key, .rsaSignatureDigestPKCS1v15Raw, payload as CFData, try bytes(args[3]) as CFData, &error)
                if let error { _ = error.takeRetainedValue() }
                return valid
            }
            guard let signature = SecKeyCreateSignature(key, .rsaSignatureDigestPKCS1v15Raw, payload as CFData, &error) as Data? else { throw SourceError.message("RSA 签名失败：\(error?.takeRetainedValue().localizedDescription ?? "未知错误")") }
            return signature.map { Int(Int8(bitPattern: $0)) }
        }
        guard method == "rsaCrypt", args.count == 5, let encrypting = args[1] as? Bool, let publicKey = args[2] as? Bool else { throw SourceError.message("RSA 操作无效。") }
        let parts = algorithm.uppercased().replacingOccurrences(of: "-", with: "").components(separatedBy: "/")
        guard parts.first == "RSA", parts.count == 1 || (parts.count == 3 && ["ECB", "NONE"].contains(parts[1])) else { throw SourceError.message("不支持的 RSA transformation。") }
        let padding = parts.count == 1 ? "PKCS1PADDING" : parts[2]
        let crypto: SecKeyAlgorithm; let overhead: Int
        switch padding {
        case "PKCS1PADDING": crypto = .rsaEncryptionPKCS1; overhead = 11
        case "NOPADDING": crypto = .rsaEncryptionRaw; overhead = 0
        case "OAEPPADDING", "OAEPWITHSHA1ANDMGF1PADDING": crypto = .rsaEncryptionOAEPSHA1; overhead = 42
        case "OAEPWITHSHA256ANDMGF1PADDING": crypto = .rsaEncryptionOAEPSHA256; overhead = 66
        case "OAEPWITHSHA384ANDMGF1PADDING": crypto = .rsaEncryptionOAEPSHA384; overhead = 98
        case "OAEPWITHSHA512ANDMGF1PADDING": crypto = .rsaEncryptionOAEPSHA512; overhead = 130
        default: throw SourceError.message("不支持的 RSA padding：\(padding)")
        }
        let rsaKey = try key(args[3], publicKey: publicKey), data = try bytes(args[4]), block = SecKeyGetBlockSize(rsaKey)
        guard block > overhead else { throw SourceError.message("RSA 密钥过短，无法使用所选填充。") }
        guard encrypting || (!data.isEmpty && data.count.isMultiple(of: block)) else { throw SourceError.message("RSA 密文不是完整分块。") }
        let size = encrypting ? block-overhead : block
        var output = Data()
        let offsets = data.isEmpty ? [0] : Array(stride(from: 0, to: data.count, by: size))
        for offset in offsets {
            guard !cancelled() else { throw SourceError.message("RSA 操作取消或超时。") }
            var chunk = Data(data.dropFirst(offset).prefix(size)); var error: Unmanaged<CFError>?
            let result: Data?
            if encrypting && publicKey {
                if overhead == 0 { chunk = Data(repeating: 0, count: block-chunk.count) + chunk }
                result = SecKeyCreateEncryptedData(rsaKey, crypto, chunk as CFData, &error) as Data?
            } else if !encrypting && !publicKey {
                if padding == "PKCS1PADDING", let raw = SecKeyCreateDecryptedData(rsaKey, .rsaEncryptionRaw, chunk as CFData, &error) as Data? {
                    // Validate the encoded message explicitly: some system providers use
                    // implicit rejection for invalid PKCS#1 v1.5 ciphertexts.
                    let bytes = [UInt8](raw)
                    guard bytes.count == block, bytes[0] == 0, bytes[1] == 2,
                          let end = bytes.dropFirst(2).firstIndex(of: 0), end >= 10 else { throw SourceError.message("RSA 私钥解密填充无效，密钥或密文不匹配。") }
                    result = Data(bytes[(end+1)...])
                } else if padding == "PKCS1PADDING" { result = nil }
                else { result = SecKeyCreateDecryptedData(rsaKey, crypto, chunk as CFData, &error) as Data? }
            } else {
                guard overhead == 0 || padding == "PKCS1PADDING" else { throw SourceError.message("OAEP 仅支持公钥加密、私钥解密。") }
                if encrypting {
                    if overhead == 0 { chunk = Data(repeating: 0, count: block-chunk.count) + chunk }
                    result = SecKeyCreateSignature(rsaKey, overhead == 0 ? .rsaSignatureRaw : .rsaSignatureDigestPKCS1v15Raw, chunk as CFData, &error) as Data?
                } else if let raw = SecKeyCreateEncryptedData(rsaKey, .rsaEncryptionRaw, chunk as CFData, &error) as Data? {
                    let bytes = [UInt8](raw)
                    if overhead == 0 { result = raw }
                    else {
                        guard bytes.count == block, bytes[0] == 0, bytes[1] == 1, let end = bytes.dropFirst(2).firstIndex(of: 0), end >= 10, bytes[2..<end].allSatisfy({ $0 == 255 }) else { throw SourceError.message("RSA 公钥解密填充无效。") }
                        result = Data(bytes[(end+1)...])
                    }
                } else { result = nil }
            }
            guard let result else { throw SourceError.message("RSA 运算失败：\(error?.takeRetainedValue().localizedDescription ?? "未知错误")") }
            output.append(result)
        }
        return output.map { Int(Int8(bitPattern: $0)) }
    }
}
