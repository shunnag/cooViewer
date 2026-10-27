import Foundation

/// 書庫由来の表示名で案内の行数やレイアウトを増やさない(設計書 §7.4)。
enum EntryNameFormatter {
    static func forDisplay(_ name: String, limit: Int) -> String {
        let prefix = String(name.prefix(max(0, limit)))
        return String(prefix.components(separatedBy: .newlines).joined(separator: " ").prefix(max(0, limit)))
    }
}
