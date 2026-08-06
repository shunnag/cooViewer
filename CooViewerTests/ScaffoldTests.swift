import XCTest
@testable import cooViewer

/// プロジェクト骨組みの疎通テスト。実質的なテストは各マイルストーンで追加する。
final class ScaffoldTests: XCTestCase {
    @MainActor
    func testMainMenuHasStandardTopLevelMenus() {
        let menu = MainMenuBuilder.build()
        XCTAssertEqual(menu.items.count, 5)
        XCTAssertNotNil(menu.items.first?.submenu)
    }
}
