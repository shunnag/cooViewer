import Foundation
import XCTest

/// XADMaster 撤去後も書庫エンジンの観測契約を保持する(設計書 §2.4)。
struct EngineGolden: Codable, Equatable {
    struct Provenance: Codable, Equatable {
        let capturedOn: String
        let xadMasterCommit: String
        let universalDetectorCommit: String
        let cooViewerCommit: String
    }

    struct Fixture: Codable, Equatable {
        let name: String
        let isEncrypted: Bool
        let entries: [Entry]
    }

    struct Entry: Codable, Equatable {
        let name: String?
        let hasSize: Bool
        let size: Int64
        let isDirectory: Bool
        let isEncrypted: Bool
        let sha256: String?
        let solidGroup: Int32

        private enum CodingKeys: String, CodingKey {
            case name, hasSize, size, isDirectory, isEncrypted, sha256, solidGroup
        }

        /// ディレクトリの SHA や未取得の名前も省略せず null として残す。
        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(name, forKey: .name)
            try container.encode(hasSize, forKey: .hasSize)
            try container.encode(size, forKey: .size)
            try container.encode(isDirectory, forKey: .isDirectory)
            try container.encode(isEncrypted, forKey: .isEncrypted)
            try container.encode(sha256, forKey: .sha256)
            try container.encode(solidGroup, forKey: .solidGroup)
        }
    }

    struct ZipCrypto: Codable, Equatable {
        let archive: Fixture
        let payloadSHA256: String
        let wrongPasswordReturnsEmptyOrNil: Bool
        let correctPasswordMatchesPayload: Bool
    }

    let provenance: Provenance
    let fixtures: [Fixture]
    let zipCrypto: ZipCrypto

    static func load() throws -> Self {
        let url = try XCTUnwrap(
            Bundle(for: ArchiveEngineTests.self).url(
                forResource: "engine-golden", withExtension: "json"),
            "engine-golden.json がテストバンドルにない。開発ガイド §3.6 の手順で採取する")
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
    }

    /// 出自を先頭に置き、各値のキーは辞書順、配列は書庫の列挙順に固定する。
    func encodedJSON() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        func field<T: Encodable>(_ name: String, _ value: T) throws -> String {
            let json = String(decoding: try encoder.encode(value), as: UTF8.self)
                .replacingOccurrences(of: "\n", with: "\n  ")
            return "  \"\(name)\" : \(json)"
        }
        let fields = try [
            field("provenance", provenance),
            field("fixtures", fixtures),
            field("zipCrypto", zipCrypto),
        ]
        return Data(("{\n" + fields.joined(separator: ",\n") + "\n}\n").utf8)
    }

    /// 再現確認では初回採取の出自を維持し、日付や cooViewer の後続コミットだけで
    /// 差分が出ることを避ける。観測元の更新時は既存 JSON を退避して新規採取する。
    /// この採取専用処理も PR 1 の XADMaster 撤去時に削除する。
    static func captureProvenance() throws -> Provenance {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        let xadCommit = try commit(in: root.appendingPathComponent("XADMaster"))
        let detectorCommit = try commit(in: root.appendingPathComponent("UniversalDetector"))
        let existingURL = root.appendingPathComponent("CooViewerTests/Fixtures/engine-golden.json")
        if FileManager.default.fileExists(atPath: existingURL.path) {
            let existing = try JSONDecoder().decode(
                Self.self, from: Data(contentsOf: existingURL)).provenance
            return try XCTUnwrap(
                existing.xadMasterCommit == xadCommit
                    && existing.universalDetectorCommit == detectorCommit ? existing : nil,
                "観測元のコミットが変わっている。既存 JSON を退避して新規採取する")
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return Provenance(
            capturedOn: formatter.string(from: Date()),
            xadMasterCommit: xadCommit,
            universalDetectorCommit: detectorCommit,
            cooViewerCommit: try commit(in: root))
    }

    private static func commit(in directory: URL) throws -> String {
        let output = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", directory.path, "rev-parse", "HEAD"]
        process.standardOutput = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let sha = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return try XCTUnwrap(
            process.terminationStatus == 0 && sha.count == 40
                && sha.allSatisfy(\.isHexDigit) ? sha : nil,
            "\(directory.lastPathComponent) のコミットを取得できない")
    }
}
