import Foundation
import PDFKit

// 描画しない周辺型だけを代用し、本番の PDFSource とレンダラーを直接ビルドする(設計書 §7.6)。
protocol BookSource: Sendable {}

struct PageEntry: Sendable {
    let id: Int
    let name: String
    let pathInBook: String
    let fileURL: URL?
    let creationDate: Date?
    let modificationDate: Date?
}

struct ComicInfo: Sendable {
    static func from(pdf: PDFDocument) -> ComicInfo? { nil }
}

enum PasswordCheck: Sendable { case accepted, rejected }

enum BookSourceError: Error {
    case unreadable(URL)
    case temporarilyUnavailable(URL)
    case pageLoadFailed(String)
}

// 表示経路だけを測定する。用途フラグの配線は XCTest で別途検証する(設計書 §7.6)。
enum PageRequestIntent {
    static let isThumbnail = false
}
