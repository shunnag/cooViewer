import Foundation
import XCTest

/// 旧エンジン撤去後も書庫エンジンの観測契約を保持する(設計書 §2.4)。
struct EngineGolden: Decodable, Equatable {
    struct Provenance: Decodable, Equatable {
        let capturedOn: String
        let xadMasterCommit: String
        let universalDetectorCommit: String
        let cooViewerCommit: String
    }

    struct Fixture: Decodable, Equatable {
        let name: String
        let isEncrypted: Bool
        let entries: [Entry]
    }

    struct Entry: Decodable, Equatable {
        let name: String?
        let hasSize: Bool
        let size: Int64
        let isDirectory: Bool
        let isEncrypted: Bool
        let sha256: String?
        let solidGroup: Int32
    }

    struct ZipCrypto: Decodable, Equatable {
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
            "engine-golden.json がテストバンドルにない。固定資産。旧エンジン撤去後は再採取不可")
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
    }
}
