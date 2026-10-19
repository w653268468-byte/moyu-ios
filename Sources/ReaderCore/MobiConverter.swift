import Foundation
import CReaderMobi
import ZIPFoundation

public enum MobiConverter {
    public static let extensions = ["mobi", "azw", "azw3", "prc", "pdb"]
    public static func epub(_ data: Data) throws -> Data {
        try Task.checkCancellation()
        guard data.count <= LocalBookImporter.maximumFileBytes else { throw SourceError.message("MOBI/AZW3 文件超过 100 MB。") }
        var code: Int32 = 0
        let handle = data.withUnsafeBytes { bytes in gavin_mobi_open(bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count, &code) }
        guard let handle else {
            if code == 5 { throw SourceError.message("此电子书正文已加密；DRM 支持已按要求取消。请导入未加密的文件。") }
            if code == 1001 { throw SourceError.message("MOBI/AZW3 解压内容超过大小限制。") }
            throw SourceError.message("MOBI/AZW3 无法解析，文件可能损坏或采用未支持的结构（\(code)）。")
        }
        defer { gavin_mobi_close(handle) }
        try Task.checkCancellation()
        let archive = try Archive(accessMode: .create)
        func add(_ path: String, _ data: Data) throws {
            try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count)) { position, count in data.subdata(in: Int(position)..<(Int(position) + count)) }
        }
        try add("mimetype", Data("application/epub+zip".utf8))
        try add("META-INF/container.xml", Data("<container version='1.0' xmlns='urn:oasis:names:tc:opendocument:xmlns:container'><rootfiles><rootfile full-path='OEBPS/content.opf' media-type='application/oebps-package+xml'/></rootfiles></container>".utf8))
        var names = Set<String>()
        for index in 0..<gavin_mobi_count(handle) {
            try Task.checkCancellation()
            guard let name = gavin_mobi_name(handle, index), let bytes = gavin_mobi_data(handle, index) else { continue }
            let path = String(cString: name)
            guard EPUBPublication.safePath(path), names.insert(path).inserted else { throw SourceError.message("MOBI/AZW3 转换产生重复或无效资源。") }
            try add(path, Data(bytes: bytes, count: gavin_mobi_size(handle, index)))
        }
        guard names.contains("OEBPS/content.opf"), let result = archive.data else { throw SourceError.message("MOBI/AZW3 缺少可重建的阅读目录。") }
        return result
    }
}
