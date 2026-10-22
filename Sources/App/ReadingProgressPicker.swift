import SwiftUI

/// A preview until the user confirms: dragging must not start chapter requests.
struct ReadingProgressPicker: View {
    @Environment(\.dismiss) private var dismiss
    let titles: [String]
    let current: Int
    let onJump: (Int) -> Void
    @State private var percentage = 0.0
    @State private var chapterNumber = ""
    @FocusState private var enteringChapter: Bool
    private var target: Int { ReadingProgress.chapter(at: percentage / 100, count: titles.count) ?? 0 }
    private var typedTarget: Int? {
        guard let number = Int(chapterNumber), number > 0, number <= titles.count else { return nil }
        return number - 1
    }
    var body: some View {
        NavigationStack {
            Form {
                Section("拖动选择进度") {
                    Text("\(Int(percentage.rounded()))% · 第 \(titles.isEmpty ? 0 : target + 1) / \(titles.count) 章")
                        .monospacedDigit().accessibilityIdentifier("progress.preview")
                    Slider(value: $percentage, in: 0...100).accessibilityLabel("全书章节进度").accessibilityIdentifier("progress.slider")
                    if titles.indices.contains(target) { Text(titles[target]).foregroundStyle(.secondary) }
                    Button("跳转到此进度") { onJump(target); dismiss() }.disabled(titles.isEmpty)
                        .accessibilityIdentifier("progress.confirm")
                    Text("百分比按目录章节估算；确认后跳转到目标章节开头。").font(.caption).foregroundStyle(.secondary)
                }
                Section("输入章节序号") {
                    TextField("1—\(titles.count)", text: $chapterNumber).keyboardType(.numberPad)
                        .focused($enteringChapter)
                        .accessibilityLabel("章节序号").accessibilityIdentifier("progress.chapter")
                    if !chapterNumber.isEmpty && typedTarget == nil { Text("请输入 1—\(titles.count) 的章节序号").font(.caption).foregroundStyle(.secondary) }
                    Button("跳转到指定章节") { if let typedTarget { onJump(typedTarget); dismiss() } }
                        .disabled(typedTarget == nil).accessibilityIdentifier("progress.chapter.confirm")
                }
            }.navigationTitle("进度跳转").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                    ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("收起键盘") { enteringChapter = false } }
                }
                .onAppear {
                    percentage = ReadingProgress.fraction(chapter: current, count: titles.count) * 100
                    chapterNumber = String(min(max(0, current), max(0, titles.count - 1)) + 1)
                }
        }
    }
}
