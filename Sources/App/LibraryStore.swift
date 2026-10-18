import Foundation
import SwiftUI

@MainActor
final class LibraryStore: ObservableObject {
    @Published private(set) var books: [Book] = []
    @Published var errorMessage: String?
    @Published private(set) var isImporting = false
    @Published private(set) var importProgress = ""
    private var importTask: Task<Void, Never>?
    private var parseTask: Task<BookDocument, Error>?
    @Published private(set) var storageLocked = false
    private let directory: URL
    private var manifest: URL { directory.appendingPathComponent("library.json") }
    private var backup: URL { directory.appendingPathComponent("library.backup.json") }

    init() {
        directory = URL.documentsDirectory.appendingPathComponent("Moyu", isDirectory: true)
        reload()
    }

    func reload() {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: manifest.path) {
                do {
                    books = try JSONDecoder().decode([Book].self, from: Data(contentsOf: manifest))
                } catch {
                    books = try JSONDecoder().decode([Book].self, from: Data(contentsOf: backup))
                    try JSONEncoder().encode(books).write(to: manifest, options: .atomic)
                    errorMessage = "书架索引异常，已从上一次备份恢复。小说文件未被删除。"
                }
            } else {
                // Persist the empty shelf first, so deleting the sample never re-adds it.
                books = []
                try persist()
                let document = try TextParser.parse(Self.sample)
                try add(title: "山海来信", document: document)
            }
            storageLocked = false
        } catch {
            storageLocked = true
            errorMessage = "无法读取书架：\(error.localizedDescription)\n为保护现有文件，已暂停写入。请重试，或先通过“文件”App 备份Gavin文件夹。"
        }
    }

    private func persist() throws {
        let data = try JSONEncoder().encode(books)
        if FileManager.default.fileExists(atPath: manifest.path) {
            try Data(contentsOf: manifest).write(to: backup, options: .atomic)
        }
        try data.write(to: manifest, options: .atomic)
    }

    private func documentURL(_ id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).json")
    }

    func document(for book: Book) async throws -> BookDocument {
        let url = documentURL(book.id)
        return try await Task.detached(priority: .userInitiated) {
            let document = try JSONDecoder().decode(BookDocument.self, from: Data(contentsOf: url))
            guard !document.pages.isEmpty,
                  document.pages.allSatisfy({ document.chapters.indices.contains($0.chapter) }) else {
                throw TextImportError.empty
            }
            return document
        }.value
    }

    private func add(title: String, document: BookDocument) throws {
        guard !storageLocked else { return }
        let book = Book(title: title, document: document, colorIndex: books.count % 5)
        let url = documentURL(book.id)
        try JSONEncoder().encode(document).write(to: url, options: .atomic)
        books.insert(book, at: 0)
        do { try persist() }
        catch {
            books.removeAll { $0.id == book.id }
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    func importFiles(_ urls: [URL]) {
        guard !isImporting, !storageLocked else { return }
        isImporting = true
        importTask = Task {
            defer { isImporting = false; importProgress = ""; parseTask = nil; importTask = nil }
            var failures: [String] = []
            for url in urls {
                if Task.isCancelled { break }
                importProgress = "正在导入 \(url.lastPathComponent)"
                do {
                    let parser = Task.detached(priority: .userInitiated) { [weak self] in
                        let access = url.startAccessingSecurityScopedResource()
                        defer { if access { url.stopAccessingSecurityScopedResource() } }
                        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                        guard size <= LocalBookImporter.maximumFileBytes else { throw SourceError.message("单本文件不能超过 100 MB。") }
                        let data = try Data(contentsOf: url, options: .mappedIfSafe)
                        return try LocalBookImporter.parse(data, filename: url.lastPathComponent) { [weak self] completed, total in
                            Task { @MainActor [weak self] in self?.importProgress = "\(url.lastPathComponent) · PDF / OCR \(completed)/\(total) 页" }
                        }
                    }
                    parseTask = parser
                    let document = try await parser.value
                    try Task.checkCancellation()
                    try add(title: url.deletingPathExtension().lastPathComponent, document: document)
                } catch {
                    if Task.isCancelled { break }
                    failures.append("\(url.lastPathComponent)：\(error.localizedDescription)")
                }
            }
            if !failures.isEmpty { errorMessage = failures.joined(separator: "\n") }
        }
    }

    func cancelImport() { parseTask?.cancel(); importTask?.cancel() }

    func updatePosition(bookID: UUID, page: Int, textOffset: Int? = nil) {
        update(bookID) {
            $0.page = min(max(0, page), max(0, $0.pageCount - 1))
            $0.lastReadAt = Date()
            $0.textOffset = textOffset
        }
    }

    func toggleBookmark(bookID: UUID, page: ReadingPage) {
        update(bookID) { book in
            if book.bookmarks.contains(where: { $0.page == page.id }) {
                book.bookmarks.removeAll { $0.page == page.id }
            } else {
                book.bookmarks.append(Bookmark(page: page.id, excerpt: String(page.text.prefix(65))))
                book.bookmarks.sort { $0.page < $1.page }
            }
        }
    }

    private func update(_ id: UUID, mutation: (inout Book) -> Void) {
        guard !storageLocked, let index = books.firstIndex(where: { $0.id == id }) else { return }
        let old = books[index]
        mutation(&books[index])
        do { try persist() }
        catch {
            books[index] = old
            errorMessage = "保存失败：\(error.localizedDescription)"
        }
    }

    func delete(_ book: Book) {
        guard !storageLocked else { return }
        let old = books
        books.removeAll { $0.id == book.id }
        do {
            try persist()
            // Keep the prior index coherent with deletion; orphan files are harmless if removal fails.
            try? JSONEncoder().encode(books).write(to: backup, options: .atomic)
            try? FileManager.default.removeItem(at: documentURL(book.id))
        } catch {
            books = old
            errorMessage = "删除失败：\(error.localizedDescription)"
        }
    }

    private static let sample = """
    山海来信
    Gavin · 原创演示短篇

    第一章 风从海边来
    林屿回到小镇的那一天，渡口刚下过雨。青石板上留着浅浅的水光，远处的灯塔在雾里，像一枚没有寄出的邮票。
    她背着旧帆布包，沿着海岸走。街角的书店还在，门口挂着一块木牌，上面写着：今日有风，适宜读书。
    “你终于回来了。”柜台后的老人抬起头。他没有问她这些年去了哪里，只把一封信推到她面前。
    信封上没有邮戳。收信人的名字是她，字迹却来自十年前。
    她拆开信，里面只有一行字：如果你还记得山顶那棵树，明天日出之前，来找我。
    那一夜，潮声很轻。她把信放在枕边，听见窗外的风一页一页翻动旧日时光。

    第二章 山上的邮局
    通往山顶的小路被青草遮住了一半。林屿提着灯，经过废弃的候车亭，看见墙上还留着小时候画的星星。
    山顶并没有人，只有那棵老树。树下多了一只木箱，箱盖上刻着“山海邮局”四个字。
    箱子里装满了信。有写给未来的自己，有写给远行的朋友，也有写给一只再也没有回来的猫。每一封都被小心地折好，等着有人读到。
    最下面是一本薄薄的记录册。最后一页写着：邮局不负责让愿望成真，只负责提醒你，曾经认真地希望过。
    林屿坐下来，天边露出一线金色。她终于想起，这个邮局是自己和朋友们一起建的。他们约好，不管走多远，十年后都回来看看。
    她从包里找出笔，在空白的一页上写道：我回来了。虽然比约定晚了一点。

    第三章 把日子读慢一点
    后来，林屿留在了小镇。她帮老人整理书店，把积灰的窗户擦亮，在靠海的一面摆了两把椅子。
    每逢晴天，她就把山上的信带下来，放在书店门口。渐渐地，有人认出了自己的笔迹，有人读着读着笑了，也有人安静地坐了一个下午。
    那封最早的信是谁写的，始终没有答案。老人说，也许是从前的你，写给现在的你。
    春天快结束时，林屿收到一张明信片。照片上是一片陌生的海，背面写着：听说你回去了。等夏天，我也回去。
    她把明信片夹进正在读的书，翻开下一页。窗外的海风吹过来，带着盐和阳光的气味。
    日子没有突然变得不同。只是从那以后，她不再急着把每一页翻过去。

    后记
    欢迎来到Gavin。这是一款将书留在自己手里的阅读工具。
    回到书架，点击右上角加号，就能从“文件”导入你自己的 TXT 小说。阅读时可切换纸张、调整字号、添加书签，也可以通过目录和搜索跳转。
    本演示短篇随软件以 MIT 许可提供，你可以自由修改和使用。
    """
}
