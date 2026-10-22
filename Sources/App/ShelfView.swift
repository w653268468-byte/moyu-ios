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
    @AppStorage("reader.shelfSortRecent") private var sortRecent = true
    @AppStorage("reader.shelfScope") private var shelfScope = "全部"
    @AppStorage("reader.shelfSortUpdated") private var sortUpdated = false
    @State private var showDownloads = false
    @State private var showFindBooks = false
    @State private var onlineReading: OnlineNovel?
    @State private var deletingOnline: OnlineNovel?
    @State private var inspectingOnline: OnlineNovel?
    @StateObject private var organization = ShelfOrganizationStore()
    @AppStorage("reader.shelfGroupFilter") private var groupFilter = "all"
    @AppStorage("reader.shelfLayout") private var shelfLayout = "adaptive"
    @State private var manageGroups = false
    @State private var assignment: ShelfAssignment?
    @State private var batchManaging = false
    private var onlineFiltered: [OnlineNovel] {
        online.novels.filter { organization.matches(ShelfOrganizationStore.key($0), group: groupFilter) && (query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) || $0.author.localizedCaseInsensitiveContains(query)) }.sorted {
            let left = organization.value.pinned.contains(ShelfOrganizationStore.key($0)), right = organization.value.pinned.contains(ShelfOrganizationStore.key($1))
            if left != right { return left }
            if sortUpdated { return ($0.catalogUpdatedAt ?? .distantPast) > ($1.catalogUpdatedAt ?? .distantPast) }
            return sortRecent ? ($0.lastReadAt ?? .distantPast) > ($1.lastReadAt ?? .distantPast) : $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
    }

    private var filtered: [Book] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return library.books.filter { organization.matches(ShelfOrganizationStore.key($0), group: groupFilter) && (term.isEmpty || $0.title.localizedCaseInsensitiveContains(term)) }
            .sorted {
                let left = organization.value.pinned.contains(ShelfOrganizationStore.key($0)), right = organization.value.pinned.contains(ShelfOrganizationStore.key($1))
                if left != right { return left }
                if sortRecent { return ($0.lastReadAt ?? $0.addedAt) > ($1.lastReadAt ?? $1.addedAt) }
                return $0.title.localizedStandardCompare($1.title) == .orderedAscending
            }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ShelfHeader(localCount: library.books.count, onlineCount: online.novels.count, updatedCount: online.novels.filter { !($0.unreadChapterIDs ?? []).isEmpty }.count)

                    Picker("书架类型", selection: $shelfScope) {
                        Text("全部").tag("全部")
                        Text("在线书架").tag("在线")
                        Text("本地书架").tag("本地")
                    }.pickerStyle(.segmented).accessibilityIdentifier("shelf.scope")
                    groupBar
                    if shelfScope != "本地", !online.novels.isEmpty || shelfScope == "在线" { ShelfRefreshStatus() }

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

                    if shelfScope != "在线", query.isEmpty, let recent = library.books.filter({ $0.lastReadAt != nil })
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

                    if shelfScope != "本地", !online.novels.isEmpty || shelfScope == "在线" {
                        VStack(alignment: .leading, spacing: 14) {
                            HStack {
                                Text("在线书架").font(.title3.bold())
                                Text("\(online.novels.count)").font(.subheadline).foregroundStyle(.secondary)
                                Spacer()
                                Button("离线下载", systemImage: "arrow.down.circle") { showDownloads = true }
                                Menu {
                                    Button("最近阅读") { sortRecent = true; sortUpdated = false }
                                    Button("最近更新") { sortUpdated = true }
                                    Button("书名排序") { sortRecent = false; sortUpdated = false }
                                } label: { Image(systemName: "arrow.up.arrow.down").frame(width: 44, height: 44) }.accessibilityLabel("在线书架排序")
                            }
                            if online.novels.isEmpty {
                                HStack(spacing: 14) {
                                    Image(systemName: "globe.asia.australia").font(.title).foregroundStyle(.tint)
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text("在线书架还没有书籍").font(.subheadline.weight(.semibold))
                                        Text("找到喜欢的小说，加入书架追更。").font(.caption).foregroundStyle(.secondary)
                                    }.frame(maxWidth: .infinity, alignment: .leading)
                                    Button("去找书") { showFindBooks = true }.buttonStyle(.bordered)
                                }.padding(16).background(.background, in: RoundedRectangle(cornerRadius: 18))
                            } else {
                                LazyVGrid(columns: shelfLayout == "grid" ? [GridItem(.adaptive(minimum: 140), spacing: 16)] : [GridItem(.flexible())], spacing: 12) {
                                    ForEach(onlineFiltered) { novel in onlineCard(novel) }
                                }
                            }
                        }
                    }

                    if shelfScope != "在线" {
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
                        LazyVGrid(columns: shelfLayout == "list" ? [GridItem(.flexible())] : [GridItem(.adaptive(minimum: 140), spacing: 16)], spacing: 20) {
                            ForEach(filtered) { book in
                                Button { selected = book } label: {
                                    if shelfLayout == "list" { localRow(book) } else { BookCard(book: book) }
                                }
                                    .buttonStyle(.plain)
                                    .contextMenu {
                                        Button("打开阅读", systemImage: "book") { selected = book }
                                        Button("分组与置顶", systemImage: "folder") { assignment = ShelfAssignment(id: ShelfOrganizationStore.key(book), title: book.title) }
                                        Button("删除小说", systemImage: "trash", role: .destructive) { deleting = book }
                                    }
                                    .accessibilityHint("打开阅读，长按可以删除")
                            }
                        }
                    }
                    }
                    Label("你的书架 · 无广告 · 无需注册", systemImage: "leaf")
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity).padding(.top, 12)
                }.padding(.horizontal, 20).padding(.bottom, 30)
            }
            .accessibilityIdentifier("shelf.scroll")
            .background(InterfaceAppearance.background)
            .refreshable { await online.refreshShelf() }
            .scrollBounceBehavior(.always, axes: .vertical)
            .navigationTitle("Gavin").navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: "搜索书架")
            .safeAreaInset(edge: .top, spacing: 0) {
                HStack {
                    Menu {
                        Button("管理分组", systemImage: "folder") { manageGroups = true }
                        Button("批量管理", systemImage: "checklist") { batchManaging = true }
                        Button("列表书架", systemImage: shelfLayout == "list" ? "checkmark" : "list.bullet") { shelfLayout = "list" }
                        Button("网格书架", systemImage: shelfLayout == "grid" ? "checkmark" : "square.grid.2x2") { shelfLayout = "grid" }
                        Button("自动布局") { shelfLayout = "adaptive" }
                        Button("关于Gavin", systemImage: "info.circle") { showAbout = true }
                    } label: { Label("显示与管理", systemImage: "square.grid.2x2").font(.subheadline).frame(minHeight: 44) }.accessibilityLabel("书架显示与管理")
                    Spacer()
                    Button { importing = true } label: {
                        if library.isImporting { ProgressView() } else { Label("导入书籍", systemImage: "plus.circle.fill").font(.subheadline).frame(minHeight: 44) }
                    }.disabled(library.isImporting || library.storageLocked).accessibilityLabel("导入本地书籍")
                }.padding(.horizontal, 20).background(.bar)
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
            .sheet(isPresented: $manageGroups) { ShelfGroupManager(store: organization) }
            .sheet(isPresented: $batchManaging) { ShelfBatchManager(organization: organization) }
            .sheet(item: $assignment) { ShelfAssignmentView(store: organization, assignment: $0) }
            .onAppear { organization.reload(); validateGroupFilter() }
            .onChange(of: organization.value.groups) { _, _ in validateGroupFilter() }
            .sheet(isPresented: $showDownloads) { DownloadsView() }
            .sheet(item: $inspectingOnline) { NovelDetailView(novel: $0) }
            .sheet(isPresented: $showFindBooks) {
                SourceHubView().safeAreaInset(edge: .top) { HStack { Spacer(); Button("关闭找书") { showFindBooks = false }.padding() }.background(.bar) }
            }
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

    @ViewBuilder private func onlineCard(_ novel: OnlineNovel) -> some View {
        if shelfLayout == "grid" {
            VStack(alignment: .leading, spacing: 8) {
                Button { onlineReading = novel } label: {
                    VStack(alignment: .leading, spacing: 10) {
                        NovelCover(title: novel.title, url: novel.coverURL, compact: false).frame(height: 160)
                        onlineBookDetails(novel)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.buttonStyle(.plain)
                HStack { Spacer(); onlineBookMenu(novel) }
            }.padding(12).background(.background, in: RoundedRectangle(cornerRadius: 18))
        } else {
            HStack(spacing: 8) {
                Button { onlineReading = novel } label: {
                    HStack(spacing: 14) {
                        NovelCover(title: novel.title, url: novel.coverURL).frame(width: 56, height: 80)
                        onlineBookDetails(novel)
                        Spacer(minLength: 0)
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain)
                onlineBookMenu(novel)
            }.padding(16).background(.background, in: RoundedRectangle(cornerRadius: 18))
        }
    }
    private func onlineBookDetails(_ novel: OnlineNovel) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(novel.title).font(.headline).foregroundStyle(.primary).lineLimit(2)
            if organization.value.pinned.contains(ShelfOrganizationStore.key(novel)) { Label("置顶", systemImage: "pin.fill").font(.caption2).foregroundStyle(.tint) }
            Text("第 \(novel.chapterIndex + 1) / \(novel.chapters.count) 章" + (novel.author.isEmpty ? "" : " · " + novel.author)).font(.caption).foregroundStyle(.secondary)
            if let latest = novel.lastChapter ?? novel.chapters.last?.title { Text("最新：" + latest).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            if let unread = novel.unreadChapterIDs, !unread.isEmpty {
                Text("新增 \(unread.count) 章").font(.caption2.weight(.semibold)).foregroundStyle(.orange)
                    .padding(.horizontal, 7).padding(.vertical, 3).background(.orange.opacity(0.10), in: Capsule())
            }
            if let state = online.downloadState(novel) {
                Text(state.phase == .completed ? "全书已下载 · 可离线阅读" : "已下载 \(state.completed)/\(state.total) 章").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
    private func onlineBookMenu(_ novel: OnlineNovel) -> some View {
        Menu {
            Button("分组与置顶", systemImage: "folder") { assignment = ShelfAssignment(id: ShelfOrganizationStore.key(novel), title: novel.title) }
            Button("小说详情 / 更新目录", systemImage: "list.bullet") { inspectingOnline = novel }
            Button("离线下载 / 下载管理", systemImage: "arrow.down.circle") { showDownloads = true }
            Button("移出书架", systemImage: "trash", role: .destructive) { deletingOnline = novel }
        } label: { Image(systemName: "ellipsis.circle").frame(width: 44, height: 44) }.accessibilityLabel("在线书籍管理：" + novel.title)
    }
    private func validateGroupFilter() {
        if groupFilter != "all" && groupFilter != "ungrouped" && !organization.value.groups.contains(where: { $0.id == groupFilter }) { groupFilter = "all" }
    }
    private var groupBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                groupChip("全部分组", id: "all")
                groupChip("未分组", id: "ungrouped")
                ForEach(organization.value.groups) { group in groupChip(group.name, id: group.id) }
                Button { manageGroups = true } label: { Image(systemName: "plus").frame(width: 44, height: 44) }.accessibilityLabel("添加书架分组")
            }
        }
    }
    private func groupChip(_ title: String, id: String) -> some View {
        Button { groupFilter = id } label: {
            Text(title).font(.caption.weight(.medium)).padding(.horizontal, 12).frame(minHeight: 44)
                .foregroundStyle(groupFilter == id ? Color.white : Color.primary)
                .background(groupFilter == id ? Color.accentColor : Color(uiColor: .secondarySystemGroupedBackground), in: Capsule())
        }.buttonStyle(.plain).accessibilityIdentifier("shelf.group." + id)
    }
    private func localRow(_ book: Book) -> some View {
        HStack(spacing: 14) {
            NovelCover(title: book.title).frame(width: 52, height: 76)
            VStack(alignment: .leading, spacing: 7) {
                Text(book.title).font(.headline).foregroundStyle(.primary).lineLimit(2)
                if organization.value.pinned.contains(ShelfOrganizationStore.key(book)) { Label("置顶", systemImage: "pin.fill").font(.caption2).foregroundStyle(.tint) }
                Text("\(book.chapterCount) 章 · \(book.wordCount.formatted()) 字").font(.caption).foregroundStyle(.secondary)
                ProgressView(value: book.progress).tint(coverColors[0])
            }
            Spacer(minLength: 0)
        }.padding(14).background(.background, in: RoundedRectangle(cornerRadius: 18))
    }
}

private struct BookCard: View {
    let book: Book
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            NovelCover(title: book.title, compact: false).frame(height: 190)
            Text(book.title).font(.subheadline.weight(.medium)).lineLimit(1)
            Text("\(book.chapterCount) 章 · \(book.wordCount.formatted()) 字")
                .font(.caption).foregroundStyle(.secondary)
            ProgressView(value: book.progress).tint(coverColors[0])
            Text(book.lastReadAt == nil ? "尚未开始" : "已读 \(Int(book.progress * 100))%")
                .font(.caption2).foregroundStyle(.secondary)
        }.padding(12).background(.background, in: RoundedRectangle(cornerRadius: 18))
            .accessibilityElement(children: .combine)
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
                    Text(AppBuildIdentity.label)
                    Text("主程序 MIT / libmobi LGPL-3.0-or-later")
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
