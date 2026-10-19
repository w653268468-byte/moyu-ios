import SwiftUI

struct SearchConfigurationView: View {
    @AppStorage("reader.search.merge") private var merged = true
    @AppStorage("reader.search.exact") private var exact = false
    @AppStorage("reader.search.field") private var fieldRaw = "all"
    @AppStorage("reader.search.sort") private var sortRaw = "relevance"
    @AppStorage("reader.search.concurrency") private var concurrency = 6
    @AppStorage("reader.search.timeout") private var timeout = 15.0
    @AppStorage("reader.search.saveHistory") private var history = true
    @State private var clear = false
    var body: some View {
        Form {
            Section("搜索结果") {
                Toggle("同书名同作者合并", isOn: $merged)
                Toggle("精准匹配书名或作者", isOn: $exact)
                Picker("显示范围", selection: $fieldRaw) { ForEach(BookSearchField.allCases, id: \.rawValue) { Text($0.name).tag($0.rawValue) } }
                Picker("默认排序", selection: $sortRaw) { ForEach(BookSearchSort.allCases, id: \.rawValue) { Text($0.name).tag($0.rawValue) } }
                Text("同名不同作者、作者未知的书保留独立结果；合并后仍可选择各个书源。").font(.caption).foregroundStyle(.secondary)
            }
            Section("速度与等待时间") {
                Picker("同时搜索书源数", selection: $concurrency) { ForEach(1...8, id: \.self) { Text("\($0) 个").tag($0) } }
                Picker("单个书源等待", selection: $timeout) { ForEach([5.0, 10, 15, 30, 60], id: \.self) { Text("\(Int($0)) 秒").tag($0) } }
                Text("下一轮搜索生效。停止后保留已有结果，可继续剩余书源；搜索速度不代表正文一定可用。").font(.caption).foregroundStyle(.secondary)
            }
            Section("隐私") {
                Toggle("保留搜索历史", isOn: $history)
                Button("清空搜索历史", role: .destructive) { clear = true }
                Text("搜索词直接发送到所选书源的网站。").font(.caption).foregroundStyle(.secondary)
            }
        }.navigationTitle("搜索设置").navigationBarTitleDisplayMode(.inline)
            .confirmationDialog("清空搜索历史？", isPresented: $clear, titleVisibility: .visible) { Button("清空", role: .destructive) { UserDefaults.standard.removeObject(forKey: "reader.search.history") } }
    }
}
