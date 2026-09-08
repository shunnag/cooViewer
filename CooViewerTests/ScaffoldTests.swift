import XCTest
@testable import cooViewer

/// プロジェクト骨組みの疎通テスト。実質的なテストは各マイルストーンで追加する。
final class ScaffoldTests: XCTestCase {
    @MainActor
    func testMainMenuHasStandardTopLevelMenus() {
        // アプリ/ファイル/編集/表示/移動/ウインドウ/ヘルプ の 7 本
        let menu = MainMenuBuilder.build()
        XCTAssertEqual(menu.items.count, 7)
        XCTAssertNotNil(menu.items.first?.submenu)
    }
}
