import Foundation

public struct SpeechTextChunk: Equatable, Sendable {
    public let text: String
    public let utf16Offset: Int
}
public enum SpeechText {
    public static func chunks(_ input: String, startingAt offset: Int = 0, maximumCharacters: Int = 1200) -> [SpeechTextChunk] {
        let text = TextPagination.readingText(input) as NSString
        var start = min(max(0, offset), text.length)
        if start < text.length { start = text.rangeOfComposedCharacterSequence(at: start).location }
        var chunks: [SpeechTextChunk] = []
        let tail = text.substring(from: start)
        var current = "", currentStart = start, count = 0
        let maximum = min(4000, max(100, maximumCharacters))
        for character in tail {
            current.append(character); count += 1; start += String(character).utf16.count
            if count >= maximum || (count > 200 && character == "\n") {
                chunks.append(SpeechTextChunk(text: current, utf16Offset: currentStart)); current = ""; currentStart = start; count = 0
            }
        }
        if !current.isEmpty { chunks.append(SpeechTextChunk(text: current, utf16Offset: currentStart)) }
        return chunks
    }
}
