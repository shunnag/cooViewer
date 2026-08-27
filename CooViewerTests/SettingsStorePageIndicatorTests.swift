import AppKit
import XCTest
@testable import cooViewer

/// ページ番号/ページバーのカスタマイズ設定(仕様書 §3.4, §6.1)
@MainActor
final class SettingsStorePageIndicatorTests: XCTestCase {
    private var defaults: UserDefaults!
    private var store: SettingsStore!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "indicator-test-\(UUID().uuidString)")!
        store = SettingsStore(defaults: defaults)
    }

    func testPositionsDefaultToTopLeftAndClamp() {
        XCTAssertEqual(store.pageNumPosition, 0)
        XCTAssertEqual(store.pageBarPosition, 0)
        defaults.set(9, forKey: "PageNumPosition")
        defaults.set(-1, forKey: "PageBarPosition")
        XCTAssertEqual(store.pageNumPosition, 3)
        XCTAssertEqual(store.pageBarPosition, 0)
    }

    func testPageBarSizeDefaultAndZeroRepair() {
        // 既定 {200,15}。旧実装同様 0 値は補正する(§6.2 自己修復)
        XCTAssertEqual(store.pageBarSize, CGSize(width: 200, height: 15))
        defaults.set(["width": 0, "height": 0], forKey: "PageBarSize")
        XCTAssertEqual(store.pageBarSize, CGSize(width: 200, height: 15))
        defaults.set(["width": 5000, "height": 500], forKey: "PageBarSize")
        XCTAssertEqual(store.pageBarSize, CGSize(width: 1000, height: 40))
        store.pageBarSize = CGSize(width: 300, height: 20)
        XCTAssertEqual(store.pageBarSize, CGSize(width: 300, height: 20))
    }

    func testPageBarShowThumbnailDefaultsOnButHonorsStoredLegacyValue() {
        // 新既定は ON(設計書 §2.4)。旧ドメインに明示保存された 0 は尊重する
        XCTAssertTrue(store.pageBarShowThumbnail)
        defaults.set(0, forKey: "PageBarShowThumbnail")
        XCTAssertFalse(store.pageBarShowThumbnail)
        defaults.set(1, forKey: "PageBarShowThumbnail")
        XCTAssertTrue(store.pageBarShowThumbnail)
    }

    func testColorDefaultsMatchLegacySpec() {
        // 仕様書 §6.1 の既定: 文字=白 / 背景=黒 α0.8 / 既読=白 α0.5
        XCTAssertEqual(store.pageNumTextColor, .white)
        XCTAssertEqual(store.pageNumBackgroundColor.alphaComponent, 0.8, accuracy: 0.001)
        XCTAssertEqual(store.pageBarReadColor.alphaComponent, 0.5, accuracy: 0.001)
    }

    func testColorRoundTripKeepsAlpha() {
        let color = NSColor(srgbRed: 0.2, green: 0.4, blue: 0.6, alpha: 0.3)
        store.pageBarBackgroundColor = color
        let restored = store.pageBarBackgroundColor.usingColorSpace(.sRGB)!
        XCTAssertEqual(restored.redComponent, 0.2, accuracy: 0.001)
        XCTAssertEqual(restored.alphaComponent, 0.3, accuracy: 0.001)
    }

    func testEPUBFolioSuppressedInBottomPositions() {
        // 上配置(0/1)はノンブル両立、下配置(2/3)は抑止(ホスト N/M ラベルと
        // 帯が重なるため)。showNumber=false は全位置 false(cooViewer-de6)
        XCTAssertTrue(ReaderWindowController.epubShowsFolio(
            showNumber: true, pageNumPosition: 0))
        XCTAssertTrue(ReaderWindowController.epubShowsFolio(
            showNumber: true, pageNumPosition: 1))
        XCTAssertFalse(ReaderWindowController.epubShowsFolio(
            showNumber: true, pageNumPosition: 2))
        XCTAssertFalse(ReaderWindowController.epubShowsFolio(
            showNumber: true, pageNumPosition: 3))
        XCTAssertFalse(ReaderWindowController.epubShowsFolio(
            showNumber: false, pageNumPosition: 0))
    }

    func testFontSizeDefaultAndClamp() {
        XCTAssertEqual(store.pageNumFontSize, 11)
        defaults.set(100.0, forKey: "PageNumFontSize")
        XCTAssertEqual(store.pageNumFontSize, 32)
        // ファミリー未指定は等幅数字システムフォント
        XCTAssertEqual(store.pageNumFont.pointSize, 32)
    }
}
