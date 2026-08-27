import XCTest
@testable import cooViewer

/// PersistedFile.readBytes の三態(absent / unreadable / data)判定。
/// unreadable は実 I/O エラーを注入しづらいため、BookHistoryStore /
/// PasswordVault の破損テストで間接的に検証する(在るのに読めない=潰さない)。
final class PersistedFileTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("persisted-file-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testAbsentForMissingFile() {
        let url = dir.appendingPathComponent("nope.bin")
        guard case .absent = PersistedFile.readBytes(at: url) else {
            return XCTFail("無いファイルは absent")
        }
    }

    func testAbsentForZeroByteFile() throws {
        let url = dir.appendingPathComponent("empty.bin")
        try Data().write(to: url)
        // 0 バイトは absent 扱い(中断作成の残骸で失う中身が無いため新規化を許す)
        guard case .absent = PersistedFile.readBytes(at: url) else {
            return XCTFail("0 バイトは absent")
        }
    }

    func testDataForNonEmptyFile() throws {
        let url = dir.appendingPathComponent("has.bin")
        try Data("hello".utf8).write(to: url)
        guard case .data(let bytes) = PersistedFile.readBytes(at: url) else {
            return XCTFail("非空は data")
        }
        XCTAssertEqual(bytes, Data("hello".utf8))
    }
}
