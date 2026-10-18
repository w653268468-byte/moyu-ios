import SwiftUI
import UIKit

final class PositionedTextView: UITextView {
    var anchor = (offset: 0, fraction: 0.0)
    var pending: (offset: Int, fraction: Double?)?
    var restoring = false
    private var lastWidth: CGFloat = 0
    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 40 else { return }
        if lastWidth != bounds.width { pending = pending ?? (anchor.offset, anchor.fraction); lastWidth = bounds.width }
        guard let target = pending, textStorage.length > 0 else { return }
        pending = nil; restoring = true
        layoutManager.ensureLayout(for: textContainer)
        let offset = min(max(0, target.offset), textStorage.length - 1)
        let glyph = layoutManager.glyphIndexForCharacter(at: offset)
        let rect = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let y = target.offset == 0 && target.fraction == nil ? 0 : rect.minY + textContainerInset.top + rect.height * min(10, max(-10, target.fraction ?? 0))
        setContentOffset(CGPoint(x: 0, y: min(max(0, y), max(0, contentSize.height - bounds.height))), animated: false)
        anchor = position(); restoring = false
    }
    func position() -> (Int, Double) {
        guard textStorage.length > 0, layoutManager.numberOfGlyphs > 0 else { return (0, 0) }
        let rawY = contentOffset.y - textContainerInset.top
        let y = max(0, rawY)
        let glyph = min(layoutManager.numberOfGlyphs - 1, layoutManager.glyphIndex(for: CGPoint(x: 0, y: y), in: textContainer))
        var range = NSRange()
        let line = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: &range)
        let offset = layoutManager.characterIndexForGlyph(at: range.location)
        let fraction = line.height > 0 ? Double(min(10, max(-10, (rawY - line.minY) / line.height))) : 0
        return (offset, fraction)
    }
}

struct ScrollReadingView: UIViewRepresentable {
    let text: String
    let resumeOffset: Int
    let resumeFraction: Double?
    let onPosition: (Int, Double) -> Void
    let toggleChrome: () -> Void
    private var style = ReadingStyle()
    init(text: String, resumeOffset: Int, resumeFraction: Double?, onPosition: @escaping (Int, Double) -> Void, toggleChrome: @escaping () -> Void) {
        self.text = text; self.resumeOffset = resumeOffset; self.resumeFraction = resumeFraction
        self.onPosition = onPosition; self.toggleChrome = toggleChrome
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: ScrollReadingView
        var revision = ""
        weak var textView: PositionedTextView?
        var save: Task<Void, Never>?
        init(_ parent: ScrollReadingView) {
            self.parent = parent
            super.init()
            NotificationCenter.default.addObserver(self, selector: #selector(appLeaving), name: UIApplication.willResignActiveNotification, object: nil)
        }
        @objc func appLeaving(_ notification: Notification) { flush() }
        @objc func doubleTap() { flush(); parent.toggleChrome() }
        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            guard let textView, !textView.restoring, textView.pending == nil else { return }
            let value = textView.position()
            textView.anchor = (value.0, value.1)
            save?.cancel()
            save = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(350))
                guard !Task.isCancelled else { return }
                self?.flush()
            }
        }
        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { flush() }
        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) { if !decelerate { flush() } }
        func flush() {
            save?.cancel(); save = nil
            guard let textView, !textView.restoring else { return }
            let value = textView.position()
            parent.onPosition(value.0, value.1)
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> UITextView {
        let view = PositionedTextView()
        view.isEditable = false; view.isSelectable = true; view.backgroundColor = .clear
        view.textContainer.lineFragmentPadding = 0
        view.contentInsetAdjustmentBehavior = .never
        view.delegate = context.coordinator
        view.pending = (resumeOffset, resumeFraction)
        view.anchor = (resumeOffset, resumeFraction ?? 0)
        context.coordinator.textView = view
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.doubleTap))
        tap.numberOfTapsRequired = 2
        view.addGestureRecognizer(tap)
        return view
    }
    func updateUIView(_ uiView: UITextView, context: Context) {
        guard let view = uiView as? PositionedTextView else { return }
        context.coordinator.parent = self
        let key = "\(text.hashValue)-\(style.fontSize)-\(style.fontFamily)-\(style.bold)-\(style.letterSpacing)-\(style.lineSpacing)-\(style.paragraphSpacing)-\(style.horizontalMargin)-\(style.verticalMargin)-\(style.indent)-\(style.paperName)"
        guard context.coordinator.revision != key else { return }
        view.restoring = true
        let position: (Int, Double?) = context.coordinator.revision.isEmpty ? (resumeOffset, resumeFraction) : (view.position().0, view.position().1)
        context.coordinator.revision = key
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = style.lineSpacing
        paragraph.paragraphSpacing = style.paragraphSpacing
        paragraph.firstLineHeadIndent = style.indent ? style.fontSize * 2 : 0
        view.attributedText = NSAttributedString(string: TextPagination.readingText(text), attributes: [.font: style.uiFont, .foregroundColor: UIColor(style.paper.ink), .paragraphStyle: paragraph, .kern: style.letterSpacing])
        view.textContainerInset = UIEdgeInsets(top: style.verticalMargin, left: style.horizontalMargin, bottom: style.verticalMargin, right: style.horizontalMargin)
        view.pending = (position.0, position.1)
        view.restoring = false
        view.setNeedsLayout()
    }
    static func dismantleUIView(_ uiView: UITextView, coordinator: Coordinator) { coordinator.flush(); uiView.delegate = nil }

    #if DEBUG
    @MainActor static func checkPositionRecovery() {
        let file = URL.documentsDirectory.appendingPathComponent("scroll-check.json")
        do {
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = 8; paragraph.paragraphSpacing = 16
            let text = NSAttributedString(string: String(repeating: "中文阅读 Gavin 🌸，测试重新打开后恢复同一行和行内位置。\n", count: 200), attributes: [.font: UIFont.systemFont(ofSize: 21), .paragraphStyle: paragraph])
            func viewport(_ target: (Int, Double?)?) -> PositionedTextView {
                let view = PositionedTextView(frame: CGRect(x: 0, y: 0, width: 320, height: 500))
                view.textContainer.lineFragmentPadding = 0
                view.textContainerInset = UIEdgeInsets(top: 24, left: 26, bottom: 24, right: 26)
                view.attributedText = text
                view.pending = target
                view.setNeedsLayout(); view.layoutIfNeeded()
                return view
            }
            let first = viewport((0, nil))
            first.setContentOffset(CGPoint(x: 0, y: 1234.75), animated: false)
            let anchor = first.position()
            let restored = viewport((anchor.0, anchor.1))
            guard anchor.0 > 0, abs(first.contentOffset.y - restored.contentOffset.y) < 1 else {
                throw SourceError.message("滚动位置恢复误差：\(first.contentOffset.y) → \(restored.contentOffset.y)")
            }
            let top = viewport((0, nil))
            let topAnchor = top.position()
            let restoredTop = viewport((topAnchor.0, topAnchor.1))
            guard abs(restoredTop.contentOffset.y) < 1 else { throw SourceError.message("首页边距未正确恢复。") }
            try Data(#"{"status":"passed","roundTripTolerancePoints":1}"#.utf8).write(to: file, options: .atomic)
        } catch {
            let report = try? JSONSerialization.data(withJSONObject: ["status": "failed", "error": error.localizedDescription])
            try? report?.write(to: file, options: .atomic)
        }
    }
    #endif
}
