#if DEBUG
import Foundation

@MainActor enum ReadingToolsCheck {
    static func run(directory: URL) async throws {
        let store = ReadingToolsStore(directory: directory)
        let rule = TextReplacementRule(name: "示例净化", pattern: "ORIGINAL", replacement: "CHANGED")
        try store.save(rule)
        let restored = ReadingToolsStore(directory: directory)
        guard restored.rules.count == 1, restored.rules.first?.id == rule.id else { throw SourceError.message("替换规则重开后丢失") }
        let input = "ORIGINAL reader text."
        let transformed = try TransformedReadingText.applying(restored.rules, to: input, book: "示例", origin: "local").normalizedLines()
        guard transformed.text == "CHANGED reader text.", transformed.originalOffset(8) == 9 else { throw SourceError.message("净化文本或阅读位置映射错误") }
        restored.setEnabled(rule, false)
        guard try TransformedReadingText.applying(restored.rules, to: input, book: "示例", origin: "local").text == input else { throw SourceError.message("关闭净化规则后不能恢复原文") }
        let imported = try await ReplacementImport.load("http://127.0.0.1:18765/replace-rules.json")
        guard imported.rules.count == 1, imported.failures.count == 1 else { throw SourceError.message("规则网址获取或部分失败检查未通过") }
        try restored.importRules(imported.rules)
        let again = ReadingToolsStore(directory: directory)
        guard again.rules.count == 2 else { throw SourceError.message("导入覆盖了未选中的规则") }
        try again.importRules(imported.rules)
        guard again.rules.count == 2 else { throw SourceError.message("重复导入生成了重复规则") }
        let exported = try ReplacementImport.export(again.rules)
        guard try ReplacementImport.parse(exported).rules.count == 2 else { throw SourceError.message("净化规则导出后无法重新导入") }
    }
}
#endif
