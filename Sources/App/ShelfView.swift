import SwiftUI
import UniformTypeIdentifiers

private let coverColors: [Color] = [
    Color(red: 0.27, green: 0.40, blue: 0.35),
    Color(red: 0.51, green: 0.34, blue: 0.29),
    Color(red: 0.30, green: 0.39, blue: 0.49),
    Color(red: 0.53, green: 0.45, blue: 0.29),
    Color(red: 0.41, green: 0.35, blue: 0.48)
]

struct ShelfView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var online: OnlineStore
    @State private var query = ""
    @State private var importing = false
    @State private var selected: Book?
    @State private var deleting: Book?
    @State private var showAbout = false
    @State private var sortRecent = true
    @State private var onlineReading: OnlineNovel?
    @State private var deletingOnline: OnlineNovel?

    private var filtered: [Book] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return library.books.filter { term.isEmpty || $0.title.localizedCaseInsensitiveContains(term) }
            .sorted {
                if sortRecent { return ($0.lastReadAt ?? $0.addedAt) > ($1.lastReadAt ?? $1.addedAt) }
                return $0.title.localizedStandardCompare($1.title) == .orderedAscending
            }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("GAVIN · 私人的阅读岛屿")
                            .font(.caption.weight(.semibold)).tracking(2).foregroundStyle(.secondary)
                        Text("把日子，读慢一点。")
                            .font(.system(size: 29, weight: .medium, design: .serif))
                        Text("书在这里，故事随身。")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    .padding(.top, 12)

                    if library.isImporting {
                        HStack {
                            ProgressView()
                            Text(library.importProgress).font(.caption)
                            Spacer()
                            Button("取消") { library.cancelImport() }
                        }.padding().background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
                    }

                    if library.storageLocked {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("书架暂时无法读取", systemImage: "externaldrive.badge.exclamationmark")
                            Button("重新读取") { library.reload() }
                        }.padding().frame(maxWidth: .infinity, alignment: .leading)
                            .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 16))
                    }

                    if query.isEmpty, let recent = library.books.filter({ $0.lastReadAt != nil })
                        .max(by: { ($0.lastReadAt ?? .distantPast) < ($1.lastReadAt ?? .distantPast) }) {
                        Button { selected = recent } label: {
                            HStack(spacing: 16) {
                                Image(systemName: "book.pages.fill").font(.largeTitle)
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("继续阅读").font(.caption).opacity(0.75)
                                    Text(recent.title).font(.headline).lineLimit(1)
                                    Text("已读 \(Int(recent.progress * 100))% · 第 \(recent.page + 1) 页")
                                        .font(.caption).opacity(0.8)
                                }
                                Spacer(minLength: 0)
                                Image(systemName: "arrow.right")
                            }.padding(22).foregroundStyle(.white)
                                .background(coverColors[0].gradient, in: RoundedRectangle(cornerRadius: 22))
                        }.buttonStyle(.plain)
                    }

                    if !online.novels.isEmpty {
                        VStack(alignment: .leading, spacing: 14) {
                            Text("在线藏书").font(.title3.bold())
                            ForEach(online.novels.filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) }
                                .sorted { ($0.lastReadAt ?? .distantPast) > ($1.lastReadAt ?? .distantPast) }) { novel in
                                Button { onlineReading = novel } label: {
                                    HStack(spacing: 15) {
                                        Image(systemName: "book.closed.fill").font(.title).foregroundStyle(coverColors[0])
                                        VStack(alignment: .leading, spacing: 5) {
                                            Text(novel.title).font(.headline).foregroundStyle(.primary).lineLimit(1)
                                            Text("第 \(novel.chapterIndex + 1) / \(novel.chapters.count) 章 · \(novel.author)")
                                                .font(.caption).foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        Image(systemName: "chevron.right").font(.caption)
                                    }.padding(16).background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
                                }.buttonStyle(.plain)
                                    .contextMenu {
                                        Button("移出书架", systemImage: "trash", role: .destructive) { deletingOnline = novel }
                                    }
                            }
                        }
                    }

                    HStack {
                        Text("本地书架").font(.title3.bold())
                        Text("\(library.books.count)").font(.subheadline).foregroundStyle(.secondary)
                        Spacer()
                        Menu {
                            Button("最近阅读", systemImage: sortRecent ? "checkmark" : "clock") { sortRecent = true }
                            Button("书名排序", systemImage: !sortRecent ? "checkmark" : "textformat.abc") { sortRecent = false }
                        } label: { Image(systemName: "arrow.up.arrow.down").padding(8) }
                        .accessibilityLabel("书架排序")
                    }

                    if filtered.isEmpty {
                        ContentUnavailableView {
                            Label(query.isEmpty ? "你的下一段故事" : "没有找到这本书", systemImage: "books.vertical")
                        } description: {
                            Text(query.isEmpty ? "导入 TXT、EPUB、PDF 等书籍，开始阅读。" : "试试其他书名。")
                        } actions: {
                            if query.isEmpty { Button("导入小说") { importing = true }.buttonStyle(.borderedProminent) }
                        }
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 22)], spacing: 26) {
                            ForEach(filtered) { book in
                                Button { selected = book } label: { BookCard(book: book) }
                                    .buttonStyle(.plain)
                                    .contextMenu {
                                        Button("打开阅读", systemImage: "book") { selected = book }
                                        Button("删除小说", systemImage: "trash", role: .destructive) { deleting = book }
                                    }
                                    .accessibilityHint("打开阅读，长按可以删除")
                            }
                        }
                    }
                    Label("你的书架 · 无广告 · 无需注册", systemImage: "leaf")
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity).padding(.top, 12)
                }.padding(.horizontal, 24).padding(.bottom, 30)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("Gavin").navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: "搜索书架")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showAbout = true } label: { Image(systemName: "info.circle") }
                        .accessibilityLabel("关于Gavin")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { importing = true } label: {
                        if library.isImporting { ProgressView() } else { Image(systemName: "plus.circle.fill") }
                    }.disabled(library.isImporting || library.storageLocked).accessibilityLabel("导入本地书籍")
                }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.data], allowsMultipleSelection: true) { result in
                switch result {
                case .success(let urls): library.importFiles(urls)
                case .failure(let error): library.errorMessage = error.localizedDescription
                }
            }
            .fullScreenCover(item: $selected) { book in
                NavigationStack { ReaderLoader(book: book) }.environmentObject(library)
            }
            .sheet(isPresented: $showAbout) { AboutView() }
            .fullScreenCover(item: $onlineReading) { OnlineReaderView(novel: $0).environmentObject(online) }
            .confirmationDialog("将这本在线小说移出书架？", isPresented: Binding(
                get: { deletingOnline != nil }, set: { if !$0 { deletingOnline = nil } }
            ), titleVisibility: .visible) {
                Button("移出书架", role: .destructive) {
                    if let novel = deletingOnline { online.remove(novel) }
                    deletingOnline = nil
                }
            }
            .confirmationDialog("删除《\(deleting?.title ?? "")》？", isPresented: Binding(
                get: { deleting != nil }, set: { if !$0 { deleting = nil } }
            ), titleVisibility: .visible) {
                Button("删除小说及阅读记录", role: .destructive) {
                    if let book = deleting { library.delete(book) }
                    deleting = nil
                }
            } message: { Text("原始 TXT 文件不会受影响。") }
        }
    }
}

private struct BookCard: View {
    let book: Book
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 9).fill(coverColors[abs(book.colorIndex % coverColors.count)].gradient)
                Rectangle().fill(.black.opacity(0.12)).frame(width: 8).padding(.leading, 7)
                VStack(alignment: .leading, spacing: 12) {
                    Image(systemName: "water.waves").font(.title2).opacity(0.65)
                    Text(book.title).font(.system(size: 23, weight: .medium, design: .serif)).lineLimit(4)
                    Spacer(minLength: 4)
                    Text("G A V I N").font(.system(size: 9)).tracking(2).opacity(0.65)
                }.foregroundStyle(.white).padding(22)
            }.frame(height: 218)
                .shadow(color: .black.opacity(0.12), radius: 7, y: 4)
            Text(book.title).font(.subheadline.weight(.medium)).lineLimit(1)
            Text("\(book.chapterCount) 章 · \(book.wordCount.formatted()) 字")
                .font(.caption).foregroundStyle(.secondary)
            ProgressView(value: book.progress).tint(coverColors[0])
            Text(book.lastReadAt == nil ? "尚未开始" : "已读 \(Int(book.progress * 100))%")
                .font(.caption2).foregroundStyle(.secondary)
        }.accessibilityElement(children: .combine)
    }
}

private struct AboutView: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label("Gavin", systemImage: "book.pages.fill").font(.title2)
                    Text("把日子，读慢一点。").foregroundStyle(.secondary)
                    Text("版本 2.0.0 · 主程序 MIT / libmobi LGPL-3.0-or-later")
                }
                Section("支持的格式") {
                    Text("TXT、EPUB、PDF、Markdown、HTML、RTF、DOCX、未加密 MOBI/AZW3。单文件 100 MB；TXT 文本 20 MB。")
                    Text("新 EPUB 保留图片与原书样式，MOBI/AZW3 转为 EPUB；DOCX/HTML/RTF 提取文字重排；PDF 按原页提取文字，不保留插图与原版式。扫描 PDF 自动尝试本机 OCR；不处理 DRM 保护正文。")
                }
                Section("数据与隐私") {
                    Text("小说、进度、书源与章节缓存保存在本机，没有账号、广告或统计。使用书源时会直接访问相应网站。删除 App 会删除本地数据。")
                    Text("可以通过“文件 → 我的 iPhone → Gavin”备份 Moyu 和 MoyuOnline 两个文件夹。")
                }
                Section("当前范围") {
                    Text("支持文字书导入、CSS/基础 JSONPath 书源、GET/POST、搜索、目录与章节缓存。新增发现、换源、仿真卷页与 WebDAV 快照同步；完整 Java/Android 脚本接口仍未完成，不等同 Legado 完整版。")
                }
            }.navigationTitle("关于Gavin").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
    }
}
