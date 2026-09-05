import XCTest

@testable import cooViewer

final class EPUBSettingsChangeTests: XCTestCase {
    func testUnchangedEPUBSettingsDoNotRequestHighlightTeardown() {
        let settings = fingerprint()

        XCTAssertFalse(ReaderWindowController.epubSettingsActuallyChanged(
            previous: settings, current: settings))
    }

    func testChangedEPUBSettingsRequestHighlightTeardown() {
        XCTAssertTrue(ReaderWindowController.epubSettingsActuallyChanged(
            previous: fingerprint(), current: fingerprint(theme: 2)))
    }

    func testFirstEPUBSettingsApplicationCountsAsChanged() {
        XCTAssertTrue(ReaderWindowController.epubSettingsActuallyChanged(
            previous: nil, current: fingerprint()))
    }

    func testInteractionOnlyChangeDoesNotRebuildEPUBThumbnails() {
        XCTAssertFalse(ReaderWindowController.epubThumbnailSettingsActuallyChanged(
            previous: fingerprint(),
            current: fingerprint(pageTurnAnimation: 2)))
    }

    func testThemeChangeRebuildsEPUBThumbnails() {
        XCTAssertTrue(ReaderWindowController.epubThumbnailSettingsActuallyChanged(
            previous: fingerprint(), current: fingerprint(theme: 2)))
    }

    func testTypographyChangeRebuildsEPUBThumbnails() {
        XCTAssertTrue(ReaderWindowController.epubThumbnailSettingsActuallyChanged(
            previous: fingerprint(), current: fingerprint(lineHeightScale: 1.5)))
    }

    private func fingerprint(
        pageTurnAnimation: Int = 0,
        theme: Int = 0,
        lineHeightScale: Double = 0
    ) -> EPUBSettingsFingerprint {
        EPUBSettingsFingerprint(
            pageTurnAnimation: pageTurnAnimation,
            fontScale: 1,
            pinchAdjustsFontScale: true,
            showsPageFurniture: true,
            pageMargins: 1,
            defaultFontFamily: "",
            theme: theme,
            forcesReadableColors: true,
            footnotePopover: true,
            hidesFootnoteAsides: false,
            lineHeightScale: lineHeightScale,
            letterSpacing: 0,
            paragraphSpacing: 0,
            forceFont: false,
            hidesRuby: false,
            showsPrintPage: false,
            horizontalWheelTurnsPages: true,
            flipSwipeDirection: true)
    }
}
