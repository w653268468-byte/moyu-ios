import SwiftUI
import UIKit
import AVFoundation

enum Paper: String, CaseIterable, Identifiable {
    case cream, white, green, sand, rose, gray, night, black
    var id: String { rawValue }
    var name: String {
        switch self {
        case .cream: return "纸白"; case .white: return "纯白"; case .green: return "青瓷"
        case .sand: return "羊皮"; case .rose: return "胭脂"; case .gray: return "雾灰"
        case .night: return "夜读"; case .black: return "纯黑"
        }
    }
    var isDark: Bool { self == .night || self == .black }
    var background: Color {
        switch self {
        case .cream: return Color(red: 0.96, green: 0.94, blue: 0.88)
        case .white: return .white
        case .green: return Color(red: 0.87, green: 0.93, blue: 0.87)
        case .sand: return Color(red: 0.88, green: 0.82, blue: 0.69)
        case .rose: return Color(red: 0.96, green: 0.89, blue: 0.88)
        case .gray: return Color(white: 0.86)
        case .night: return Color(red: 0.10, green: 0.12, blue: 0.13)
        case .black: return .black
        }
    }
    var ink: Color { isDark ? Color(white: 0.76) : Color(white: 0.17) }
}

struct ReadingStyle: DynamicProperty {
    @AppStorage("reader.fontSize") var fontSize = 21.0
    @AppStorage("reader.lineSpacing") var lineSpacing = 10.0
    @AppStorage("reader.paper") var paperName = Paper.cream.rawValue
    @AppStorage("reader.serif") var serif = true
    @AppStorage("reader.fontFamily") var fontFamily = "宋体"
    @AppStorage("reader.bold") var bold = false
    @AppStorage("reader.letterSpacing") var letterSpacing = 0.0
    @AppStorage("reader.paragraphSpacing") var paragraphSpacing = 18.0
    @AppStorage("reader.horizontalMargin") var horizontalMargin = 26.0
    @AppStorage("reader.verticalMargin") var verticalMargin = 24.0
    @AppStorage("reader.indent") var indent = true
    @AppStorage("reader.showChapterTitle") var showChapterTitle = true
    @AppStorage("reader.keepAwake") var keepAwake = false
    @AppStorage("reader.brightness") var brightness = 1.0
    @AppStorage("reader.speechRate") var speechRate = 0.5
    @AppStorage("reader.paged") var paged = true
    @AppStorage("reader.fullScreen") var fullScreen = false
    @AppStorage("reader.autoChangeSource") var autoChangeSource = false
    var paper: Paper { Paper(rawValue: paperName) ?? .cream }
    var font: Font {
        let size = min(44, max(12, fontSize))
        let design: Font.Design
        switch fontFamily { case "宋体": design = .serif; case "圆体": design = .rounded; case "等宽": design = .monospaced; default: design = .default }
        return .system(size: size, weight: bold ? .semibold : .regular, design: design)
    }
    var uiFont: UIFont {
        let base = UIFont.systemFont(ofSize: min(44, max(12, fontSize)), weight: bold ? .semibold : .regular)
        let design: UIFontDescriptor.SystemDesign
        switch fontFamily { case "宋体": design = .serif; case "圆体": design = .rounded; case "等宽": design = .monospaced; default: design = .default }
        return UIFont(descriptor: base.fontDescriptor.withDesign(design) ?? base.fontDescriptor, size: min(44, max(12, fontSize)))
    }
    func reset() {
        fontSize = 21; lineSpacing = 10; paperName = Paper.cream.rawValue; serif = true
        fontFamily = "宋体"; bold = false; letterSpacing = 0; paragraphSpacing = 18
        horizontalMargin = 26; verticalMargin = 24; indent = true; showChapterTitle = true
        keepAwake = false; brightness = 1; speechRate = 0.5; paged = true; fullScreen = false
        autoChangeSource = false
    }
}

struct ReadingParagraphs: View {
    let text: String
    private var style = ReadingStyle()
    init(text: String) { self.text = text }
    private var paragraphs: [String] { text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
    var body: some View {
        LazyVStack(alignment: .leading, spacing: style.paragraphSpacing) {
            ForEach(Array(paragraphs.enumerated()), id: \.offset) { _, paragraph in
                Text((style.indent ? "　　" : "") + paragraph)
                    .font(style.font).kerning(style.letterSpacing).lineSpacing(style.lineSpacing)
                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

struct ReadingAppearance: ViewModifier {
    private var style = ReadingStyle()
    @State private var previousIdleSetting = false
    func body(content: Content) -> some View {
        content.overlay { Color.black.opacity(1 - min(1, max(0.35, style.brightness))).allowsHitTesting(false) }
            .onAppear { previousIdleSetting = UIApplication.shared.isIdleTimerDisabled; UIApplication.shared.isIdleTimerDisabled = style.keepAwake }
            .onChange(of: style.keepAwake) { _, value in UIApplication.shared.isIdleTimerDisabled = value }
            .onDisappear { UIApplication.shared.isIdleTimerDisabled = previousIdleSetting }
    }
}

struct ReadingPreferences: View {
    private var style = ReadingStyle()
    @State private var resetting = false
    var body: some View {
        Form {
            Section("实时预览") {
                VStack(alignment: .leading, spacing: 14) {
                    if style.showChapterTitle { Text("第一章 · 风从海边来").font(.headline) }
                    ReadingParagraphs(text: "日子没有突然变得不同。只是从那以后，她不再急着把每一页翻过去。\n窗外的海风吹过来，带着盐和阳光的气味。")
                }.padding(.horizontal, min(30, style.horizontalMargin)).padding(.vertical, min(30, style.verticalMargin))
                    .foregroundStyle(style.paper.ink).background(style.paper.background, in: RoundedRectangle(cornerRadius: 12))
            }
            Section("主题") {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 62))], spacing: 12) {
                    ForEach(Paper.allCases) { paper in
                        Button { style.paperName = paper.rawValue } label: {
                            VStack(spacing: 6) {
                                Circle().fill(paper.background).overlay { Circle().stroke(style.paperName == paper.rawValue ? Color.accentColor : .gray.opacity(0.3), lineWidth: style.paperName == paper.rawValue ? 3 : 1) }.frame(width: 38, height: 38)
                                Text(paper.name).font(.caption).foregroundStyle(.primary)
                            }
                        }.buttonStyle(.plain).accessibilityLabel("\(paper.name)主题")
                    }
                }.padding(.vertical, 5)
            }
            Section("字体与排版") {
                Picker("字体", selection: Binding(get: { style.fontFamily }, set: { style.fontFamily = $0 })) {
                    ForEach(["系统", "宋体", "圆体", "等宽"], id: \.self) { Text($0).tag($0) }
                }
                control("字号", value: Binding(get: { style.fontSize }, set: { style.fontSize = $0 }), range: 12...44)
                Toggle("加粗", isOn: Binding(get: { style.bold }, set: { style.bold = $0 }))
                control("字距", value: Binding(get: { style.letterSpacing }, set: { style.letterSpacing = $0 }), range: 0...6, step: 0.5)
                control("行距", value: Binding(get: { style.lineSpacing }, set: { style.lineSpacing = $0 }), range: 0...30)
                control("段距", value: Binding(get: { style.paragraphSpacing }, set: { style.paragraphSpacing = $0 }), range: 0...40)
                Toggle("首行缩进两字", isOn: Binding(get: { style.indent }, set: { style.indent = $0 }))
                Toggle("显示章节标题", isOn: Binding(get: { style.showChapterTitle }, set: { style.showChapterTitle = $0 }))
            }
            Section("页面") {
                Toggle("左右翻页", isOn: Binding(get: { style.paged }, set: { style.paged = $0 }))
                Toggle("全屏阅读", isOn: Binding(get: { style.fullScreen }, set: { style.fullScreen = $0 }))
                Toggle("正文失败时自动换源", isOn: Binding(get: { style.autoChangeSource }, set: { style.autoChangeSource = $0 }))
                Text("自动换源只接受同书名、同作者且能匹配当前章节的结果；信息不足时请手动选择。").font(.caption).foregroundStyle(.secondary)
                Text("左右滑动或点击两侧翻页，点击正文中间显示菜单。关闭左右翻页后上下滚动，双击正文显示菜单。")
                    .font(.caption).foregroundStyle(.secondary)
                control("左右边距", value: Binding(get: { style.horizontalMargin }, set: { style.horizontalMargin = $0 }), range: 10...55)
                control("上下边距", value: Binding(get: { style.verticalMargin }, set: { style.verticalMargin = $0 }), range: 8...60)
                control("页面亮度", value: Binding(get: { style.brightness }, set: { style.brightness = $0 }), range: 0.35...1, step: 0.05)
                Toggle("阅读时保持屏幕常亮", isOn: Binding(get: { style.keepAwake }, set: { style.keepAwake = $0 }))
                Text("亮度仅作用于阅读页面，退出后恢复。排版设置在本地与在线阅读中共用。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("听书") {
                control("语速", value: Binding(get: { style.speechRate }, set: { style.speechRate = $0 }), range: 0.25...0.65, step: 0.05)
                Text("使用 iPhone 系统中文语音，朗读当前分段或当前章节；切换章节会停止朗读。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Button("恢复默认阅读设置", role: .destructive) { resetting = true }
            }
        }.navigationTitle("阅读设置").navigationBarTitleDisplayMode(.inline)
            .confirmationDialog("恢复默认排版和主题？", isPresented: $resetting, titleVisibility: .visible) {
                Button("恢复默认", role: .destructive) { style.reset() }
            }
    }
    private func control(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double = 1) -> some View {
        VStack(alignment: .leading) {
            HStack { Text(title); Spacer(); Text(value.wrappedValue.formatted(.number.precision(.fractionLength(0...2)))).monospacedDigit().foregroundStyle(.secondary) }
            Slider(value: value, in: range, step: step).accessibilityLabel(title)
        }
    }
}

@MainActor
final class ReaderSpeech: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    @Published private(set) var active = false
    @Published private(set) var paused = false
    @Published var message: String?
    private let synthesizer = AVSpeechSynthesizer()
    override init() { super.init(); synthesizer.delegate = self }
    func play(_ text: String, rate: Double) {
        if active {
            if paused { synthesizer.continueSpeaking(); paused = false }
            else { synthesizer.pauseSpeaking(at: .word); paused = true }
            return
        }
        guard text.count <= 100000 else { message = "本章超过 10 万字，请选择较短章节再朗读。"; return }
        guard !text.isEmpty else { return }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "zh-CN")
        utterance.rate = Float(min(0.65, max(0.25, rate)))
        active = true; paused = false
        synthesizer.speak(utterance)
    }
    func stop() { synthesizer.stopSpeaking(at: .immediate); active = false; paused = false }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.active = false; self.paused = false }
    }
}
