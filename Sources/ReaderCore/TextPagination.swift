import Foundation
import CoreText
import CoreGraphics

public enum TextPagination {
    /// Paragraph spacing is controlled by the reader, rather than extra empty lines.
    public static func readingText(_ text: String) -> String {
        text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: "\n")
    }

    /// Uses the same CoreText frames rendered on screen. Ranges are UTF-16 offsets.
    public static func ranges(_ text: NSAttributedString, size: CGSize) throws -> [NSRange] {
        guard size.width >= 40, size.height >= 40 else { throw SourceError.message("阅读区域太小，请减小边距。") }
        guard text.length > 0 else { return [NSRange(location: 0, length: 0)] }
        let framesetter = CTFramesetterCreateWithAttributedString(text as CFAttributedString)
        let path = CGPath(rect: CGRect(origin: .zero, size: size), transform: nil)
        var ranges: [NSRange] = []
        var offset = 0
        while offset < text.length {
            try Task.checkCancellation()
            let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: offset, length: 0), path, nil)
            let visible = CTFrameGetVisibleStringRange(frame)
            guard visible.length > 0 else { throw SourceError.message("字号或边距过大，当前屏幕放不下一行文字。") }
            ranges.append(NSRange(location: offset, length: visible.length))
            offset += visible.length
            guard ranges.count <= 20000 else { throw SourceError.message("当前章节分页超过 20000 页。") }
        }
        return ranges
    }
}
