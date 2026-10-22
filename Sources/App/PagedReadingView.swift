import SwiftUI
import CoreText
import UIKit

private struct PageDrawing: UIViewRepresentable {
    let text: NSAttributedString
    let range: NSRange
    let ink: UIColor
    func makeUIView(context: Context) -> CoreTextPage {
        let page = CoreTextPage()
        page.backgroundColor = .clear
        page.isOpaque = false
        return page
    }
    func updateUIView(_ view: CoreTextPage, context: Context) {
        view.text = text; view.range = range; view.setNeedsDisplay()
        view.isAccessibilityElement = true
        view.accessibilityIdentifier = "reader.pageText"
        view.accessibilityLabel = text.attributedSubstring(from: range).string
    }
}

final class CoreTextPage: UIView {
    private var framesetter = CTFramesetterCreateWithAttributedString(NSAttributedString(string: "") as CFAttributedString)
    var text = NSAttributedString(string: "") {
        didSet {
            if oldValue !== text { framesetter = CTFramesetterCreateWithAttributedString(text as CFAttributedString) }
        }
    }
    var range = NSRange(location: 0, length: 0)
    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext(), text.length > 0 else { return }
        context.saveGState()
        context.textMatrix = .identity
        context.translateBy(x: 0, y: bounds.height)
        context.scaleBy(x: 1, y: -1)
        let path = CGPath(rect: bounds, transform: nil)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: range.location, length: range.length), path, nil)
        CTFrameDraw(frame, context)
        context.restoreGState()
    }
}

struct PagedReadingView: View {
    let text: String
    let title: String
    let resumeOffset: Int
    let onOffset: (Int) -> Void
    let previousChapter: () -> Void
    let nextChapter: () -> Void
    let toggleChrome: () -> Void
    private var style = ReadingStyle()
    @State private var pages: [NSRange] = []
    @State private var attributed = NSAttributedString(string: "")
    @State private var page = 0
    @State private var failure: String?
    @State private var anchor: Int?
    @State private var forward = true
    @State private var layoutID = UUID()

    init(text: String, title: String, resumeOffset: Int, onOffset: @escaping (Int) -> Void,
         previousChapter: @escaping () -> Void, nextChapter: @escaping () -> Void, toggleChrome: @escaping () -> Void) {
        self.text = text; self.title = title; self.resumeOffset = resumeOffset; self.onOffset = onOffset
        self.previousChapter = previousChapter; self.nextChapter = nextChapter; self.toggleChrome = toggleChrome
    }

    var body: some View {
        GeometryReader { geometry in
            let showTitle = style.showChapterTitle && !text.hasPrefix(title)
            // Ignoring the container safe area makes the paper full screen. Some hosting
            // configurations then report zero local insets; keep text clear of the window's
            // island/home indicator as well, including the side inset after rotation.
            let windowInsets = style.fullScreen ? (UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first { $0.isKeyWindow }?.safeAreaInsets ?? .zero) : .zero
            let safeSide = max(geometry.safeAreaInsets.leading, geometry.safeAreaInsets.trailing, windowInsets.left, windowInsets.right)
            let width = max(40, min(760, geometry.size.width) - (style.horizontalMargin + safeSide) * 2)
            let top = style.verticalMargin + max(geometry.safeAreaInsets.top, windowInsets.top)
            let bottom = style.verticalMargin + max(geometry.safeAreaInsets.bottom, windowInsets.bottom)
            let height = max(40, geometry.size.height - top - bottom - 26 - (showTitle ? 28 : 0))
            let side = (geometry.size.width - width) / 2
            ZStack {
                    if let failure { Text(failure).font(.callout) }
                    else if style.pageAnimation == "curl", !pages.isEmpty {
                        CurlReadingView(text: attributed, ranges: pages, page: page, paper: UIColor(style.paper.background),
                            onPage: selectPage, previousChapter: previousChapter, nextChapter: nextChapter,
                            toggleChrome: toggleChrome,
                            contentInsets: UIEdgeInsets(top: top + (showTitle ? 28 : 0), left: side, bottom: bottom + 26, right: side),
                            title: showTitle ? title : nil, ink: UIColor(style.paper.ink)).id(layoutID)
                    } else if pages.indices.contains(page) {
                        VStack(spacing: 0) {
                            if showTitle { Text(title).font(.caption).lineLimit(1).opacity(0.6).frame(height: 28, alignment: .topLeading).frame(maxWidth: .infinity, alignment: .leading) }
                            PageDrawing(text: attributed, range: pages[page], ink: UIColor(style.paper.ink)).frame(width: width, height: height)
                            Text("\(page + 1) / \(pages.count)").font(.caption2).monospacedDigit().opacity(0.6).frame(height: 26, alignment: .bottom)
                                .accessibilityIdentifier("reader.pageIndicator")
                        }.padding(.top, top).padding(.bottom, bottom).padding(.horizontal, side)
                            .frame(width: geometry.size.width, height: geometry.size.height)
                            .background(style.paper.background)
                            .id(page)
                            .transition(.asymmetric(insertion: .move(edge: forward ? .trailing : .leading), removal: .move(edge: forward ? .leading : .trailing)))
                    } else { ProgressView("正在分页…") }
                }.frame(width: geometry.size.width, height: geometry.size.height).background(style.paper.background).clipped()
                    .accessibilityIdentifier("reader.pageCanvas")
                    .gesture(DragGesture(minimumDistance: 25).onEnded { value in
                        guard style.pageAnimation != "curl" else { return }
                        guard abs(value.translation.width) > abs(value.translation.height) else { return }
                        move(value.translation.width < 0 ? 1 : -1)
                    }, including: style.pageAnimation == "curl" ? .none : .all)
                .contentShape(Rectangle())
                .simultaneousGesture(LongPressGesture(minimumDuration: 0.5).exclusively(before: SpatialTapGesture()).onEnded { value in
                    switch value {
                    case .first: toggleChrome()
                    case .second(let tap):
                        switch style.tapMap.action(x: tap.location.x, y: tap.location.y, width: geometry.size.width, height: geometry.size.height) {
                        case .previous: move(-1)
                        case .next: move(1)
                        case .menu: toggleChrome()
                        case .none: break
                        }
                    }
                })
                .accessibilityAction(named: "下一页") { move(1) }
                .accessibilityAction(named: "上一页") { move(-1) }
                .accessibilityAction(named: "阅读菜单") { toggleChrome() }
                .task(id: "\(width)-\(height)-\(style.fontSize)-\(style.fontFamily)-\(style.bold)-\(style.letterSpacing)-\(style.lineSpacing)-\(style.paragraphSpacing)-\(style.indent)-\(style.paperName)") {
                    await repaginate(size: CGSize(width: width, height: height))
                }
        }
    }

    @MainActor private func repaginate(size: CGSize) async {
        let offset = anchor ?? max(0, resumeOffset)
        do {
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = style.lineSpacing
            paragraph.paragraphSpacing = style.paragraphSpacing
            paragraph.firstLineHeadIndent = style.indent ? style.fontSize * 2 : 0
            paragraph.lineBreakMode = .byWordWrapping
            let font = CTFontCreateWithName(style.uiFont.fontName as CFString, style.fontSize, nil)
            let value = NSAttributedString(string: TextPagination.readingText(text), attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): UIColor(style.paper.ink).cgColor,
                .paragraphStyle: paragraph, .kern: style.letterSpacing
            ])
            let layout = try await Task.detached(priority: .userInitiated) { try TextPagination.ranges(value, size: size) }.value
            try Task.checkCancellation()
            attributed = value; pages = layout; layoutID = UUID()
            page = layout.lastIndex(where: { $0.location <= offset }) ?? 0
            failure = nil
            anchor = layout[page].location
            onOffset(layout[page].location)
        } catch { if !Task.isCancelled { failure = error.localizedDescription } }
    }

    private func move(_ delta: Int) {
        guard !pages.isEmpty else { return }
        let target = page + delta
        if target < 0 { previousChapter(); return }
        if target >= pages.count { nextChapter(); return }
        forward = delta > 0
        withAnimation(.easeOut(duration: 0.18)) { page = target }
        anchor = pages[target].location
        onOffset(pages[target].location)
    }
    private func selectPage(_ target: Int) {
        guard pages.indices.contains(target) else { return }
        page = target; anchor = pages[target].location; onOffset(pages[target].location)
    }
}
