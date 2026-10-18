import SwiftUI
import UIKit

final class PositionedTextView: UITextView {
    var anchor = (offset: 0, fraction: 0.0)
    var pending: (offset: Int, fraction: Double)?
    var restoring = false
    private var lastWidth: CGFloat = 0
    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 40 else { return }
        if lastWidth != bounds.width { pending = pending ?? anchor; lastWidth = bounds.width }
        guard let target = pending, textStorage.length > 0 else { return }
        pending = nil; restoring = true
        layoutManager.ensureLayout(for: textContainer)
        let offset = min(max(0, target.offset), textStorage.length - 1)
        let glyph = layoutManager.glyphIndexForCharacter(at: offset)
        let rect = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let y = rect.minY + textContainerInset.top + rect.height * min(1, max(0, target.fraction))
        setContentOffset(CGPoint(x: 0, y: min(max(0, y), max(0, contentSize.height - bounds.height))), animated: false)
        anchor = target; restoring = false
    }
    func position() -> (Int, Double) {
        guard textStorage.length > 0, layoutManager.numberOfGlyphs > 0 else { return (0, 0) }
        let y = max(0, contentOffset.y - textContainerInset.top)
        let glyph = min(layoutManager.numberOfGlyphs - 1, layoutManager.glyphIndex(for: CGPoint(x: 0, y: y), in: textContainer))
        var range = NSRange()
        let line = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: &range)
        let offset = layoutManager.characterIndexForGlyph(at: range.location)
        let fraction = line.height > 0 ? Double(min(1, max(0, (y - line.minY) / line.height))) : 0
        return (offset, fraction)
    }
}

struct ScrollReadingView: UIViewRepresentable {
    let text: String
    let resumeOffset: Int
    let resumeFraction: Double
    let onPosition: (Int, Double) -> Void
    let toggleChrome: () -> Void
    private var style = ReadingStyle()
    init(text: String, resumeOffset: Int, resumeFraction: Double, onPosition: @escaping (Int, Double) -> Void, toggleChrome: @escaping () -> Void) {
        self.text = text; self.resumeOffset = resumeOffset; self.resumeFraction = resumeFraction
        self.onPosition = onPosition; self.toggleChrome = toggleChrome
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: ScrollReadingView
        var revision = ""
        weak var textView: PositionedTextView?
        var save: Task<Void, Never>?
        init(_ parent: ScrollReadingView) { self.parent = parent }
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
        view.anchor = (resumeOffset, resumeFraction)
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
        let position = context.coordinator.revision.isEmpty ? (resumeOffset, resumeFraction) : view.position()
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
}
