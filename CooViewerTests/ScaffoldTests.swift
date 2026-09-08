import XCTest
@testable import cooViewer

/// プロジェクト骨組みの疎通テスト。実質的なテストは各マイルストーンで追加する。
final class ScaffoldTests: XCTestCase {
    @MainActor
    func testMainMenuHasStandardTopLevelMenus() {
        // Release は標準 7 本、Debug は移行診断メニューを加えた 8 本
        let menu = MainMenuBuilder.build()
#if DEBUG
        XCTAssertEqual(menu.items.count, 8)
        XCTAssertTrue(menu.items.compactMap(\.submenu).flatMap(\.items).contains {
            $0.action == #selector(AppDelegate.showArchiveEngineStatus(_:))
        })
#else
        XCTAssertEqual(menu.items.count, 7)
#endif
        XCTAssertNotNil(menu.items.first?.submenu)
    }
}
