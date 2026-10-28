import Foundation

/// 書庫由来の表示名で案内の行数や周囲の文字方向を変えさせない(設計書 §7.4)。
enum EntryNameFormatter {
    static func forDisplay(_ name: String, limit: Int) -> String {
        let sanitized = String(name.unicodeScalars.filter {
            !(0x202A...0x202E).contains($0.value) && !(0x2066...0x2069).contains($0.value)
        })
        let prefix = String(sanitized.prefix(max(0, limit)))
        let folded = String(prefix.components(separatedBy: .newlines)
            .joined(separator: " ").prefix(max(0, limit)))
        // 表示本文の上限を守ってから、EPUB 題名と同じ自動方向の隔離を施す(設計書 §2.4、§7.4)。
        return EPUBTitleFormatter.windowTitle(folded, direction: nil)
    }
}
