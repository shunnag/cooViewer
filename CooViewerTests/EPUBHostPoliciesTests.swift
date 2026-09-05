import AppKit
import XCTest
import Washi

@testable import cooViewer

final class EPUBHostPoliciesTests: XCTestCase {
    func testFootnotePolicyAcceptsNoteReferencesAndBacklinksOnlyWhenEnabled() {
        XCTAssertTrue(EPUBFootnotePolicy.shouldPopover(
            link: link(isNoteReference: true), isEnabled: true))
        XCTAssertTrue(EPUBFootnotePolicy.shouldPopover(
            link: link(hasBacklink: true), isEnabled: true))
        XCTAssertFalse(EPUBFootnotePolicy.shouldPopover(
            link: link(isNoteReference: true), isEnabled: false))
        XCTAssertFalse(EPUBFootnotePolicy.shouldPopover(
            link: link(), isEnabled: true))
    }

    func testFootnotePlacementUsesAnchorAndChoosesRoomyVerticalEdge() {
        let bounds = CGRect(x: 0, y: 0, width: 600, height: 400)
        let upper = CGRect(x: 40, y: 320, width: 20, height: 20)
        let lower = CGRect(x: 40, y: 40, width: 20, height: 20)

        let upperPlacement = EPUBFootnotePopoverGeometry.placement(
            anchorRect: upper, lastClickLocation: nil, in: bounds)
        let lowerPlacement = EPUBFootnotePopoverGeometry.placement(
            anchorRect: lower, lastClickLocation: nil, in: bounds)

        XCTAssertEqual(upperPlacement.anchorRect, upper)
        XCTAssertEqual(upperPlacement.preferredEdge, .minY)
        XCTAssertEqual(lowerPlacement.anchorRect, lower)
        XCTAssertEqual(lowerPlacement.preferredEdge, .maxY)
    }

    func testFootnotePlacementFallsBackToLastClickThenViewCenter() {
        let bounds = CGRect(x: 10, y: 20, width: 300, height: 200)
        let click = CGPoint(x: 72, y: 81)

        let clicked = EPUBFootnotePopoverGeometry.placement(
            anchorRect: nil, lastClickLocation: click, in: bounds)
        let centered = EPUBFootnotePopoverGeometry.placement(
            anchorRect: nil, lastClickLocation: nil, in: bounds)

        XCTAssertEqual(clicked.anchorRect.origin, click)
        XCTAssertEqual(clicked.anchorRect.size, CGSize(width: 1, height: 1))
        XCTAssertEqual(centered.anchorRect.origin,
                       CGPoint(x: bounds.midX, y: bounds.midY))
    }

    func testPageJumpResolverPrefersValidGlobalPage() {
        XCTAssertEqual(EPUBPageJumpResolver.resolve(
            input: " 12 ", printLabels: ["xii", "12"], totalPages: 40),
            .global(12))
    }

    func testPageJumpResolverFallsBackToExactPrintLabel() {
        XCTAssertEqual(EPUBPageJumpResolver.resolve(
            input: " xii\n", printLabels: ["x", "xii"], totalPages: 40),
            .printPage("xii"))
        XCTAssertEqual(EPUBPageJumpResolver.resolve(
            input: "41", printLabels: ["41"], totalPages: 40),
            .printPage("41"))
        XCTAssertEqual(EPUBPageJumpResolver.resolve(
            input: "12", printLabels: ["12"], totalPages: 0),
            .printPage("12"))
    }

    func testPageJumpResolverRejectsInvalidOrOutOfRangeInput() {
        XCTAssertEqual(EPUBPageJumpResolver.resolve(
            input: "41", printLabels: [], totalPages: 40), .invalid)
        XCTAssertEqual(EPUBPageJumpResolver.resolve(
            input: "missing", printLabels: ["xii"], totalPages: 40), .invalid)
        XCTAssertEqual(EPUBPageJumpResolver.resolve(
            input: "1", printLabels: [], totalPages: 0), .invalid)
    }

    func testContextMenuDecisionSuppressesOnlyForResolvedBinding() {
        XCTAssertTrue(EPUBContextMenuDecision.shouldSuppressMenu(
            hasResolvedAction: true))
        XCTAssertFalse(EPUBContextMenuDecision.shouldSuppressMenu(
            hasResolvedAction: false))
    }

    func testSelectionSearchTermTrimsCollapsesWhitespaceAndNormalizesUnicode() {
        XCTAssertEqual(EPUBSelectionSearchTerm.term(
            from: " \n cafe\u{301}\t au   lait \r"), "café au lait")
        XCTAssertNil(EPUBSelectionSearchTerm.term(from: " \n\t "))
        XCTAssertNil(EPUBSelectionSearchTerm.term(from: nil))
    }

    func testSettingsMapperMapsTypographyFootnotesPrintPagesAndContextMenu() throws {
        let mapped = EPUBSettingsMapper.readerSettings(from: settingsValues(
            lineHeightScale: 1.5,
            letterSpacing: 2,
            paragraphSpacing: 1,
            forceFont: true,
            hidesRuby: true))

        XCTAssertEqual(mapped.lineHeightScale, 1.5)
        XCTAssertEqual(try XCTUnwrap(mapped.letterSpacingEm), 0.1, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(mapped.paragraphSpacingEm), 0.5, accuracy: 0.0001)
        XCTAssertEqual(mapped.defaultFontFamily, "Hiragino Mincho ProN")
        XCTAssertEqual(mapped.fontFamilyOverride, "Hiragino Mincho ProN")
        XCTAssertTrue(mapped.hidesRuby)
        XCTAssertTrue(mapped.hidesFootnoteAsides)
        XCTAssertTrue(mapped.showsPrintPageInFurniture)
        XCTAssertEqual(mapped.contextMenuPolicy, .readingDefault)
        XCTAssertTrue(mapped.announcesPageChanges)
    }

    func testSettingsMapperUsesBookTypographyForSafeDefaults() {
        let mapped = EPUBSettingsMapper.readerSettings(from: settingsValues(
            defaultFontFamily: "   ",
            lineHeightScale: 0,
            letterSpacing: 0,
            paragraphSpacing: 0,
            forceFont: true,
            hidesRuby: false))

        XCTAssertNil(mapped.defaultFontFamily)
        XCTAssertNil(mapped.fontFamilyOverride)
        XCTAssertNil(mapped.lineHeightScale)
        XCTAssertNil(mapped.letterSpacingEm)
        XCTAssertNil(mapped.paragraphSpacingEm)
        XCTAssertFalse(mapped.hidesRuby)
    }

    private func link(
        isNoteReference: Bool = false,
        hasBacklink: Bool = false
    ) -> EPUBInternalLink {
        EPUBInternalLink(
            href: "note.xhtml#n1", containerPath: "OPS/note.xhtml",
            fragment: "n1", targetSpineIndex: 1, epubType: nil, role: nil,
            isNoteReference: isNoteReference, hasBacklink: hasBacklink,
            targetEpubType: nil, anchorRect: nil)
    }

    private func settingsValues(
        defaultFontFamily: String = "Hiragino Mincho ProN",
        lineHeightScale: Double,
        letterSpacing: Int,
        paragraphSpacing: Int,
        forceFont: Bool,
        hidesRuby: Bool
    ) -> EPUBSettingsValues {
        EPUBSettingsValues(
            pageTurnStyle: .slide,
            fontScale: 1.2,
            pinchAdjustsFontScale: true,
            showsPageFurniture: true,
            insets: EPUBReaderInsets(top: 10, left: 20, bottom: 30, right: 40),
            defaultFontFamily: defaultFontFamily,
            theme: .dark,
            forcesReadableColors: true,
            horizontalWheelTurnsPages: true,
            reversesHorizontalWheelTurn: false,
            hidesFootnoteAsides: true,
            lineHeightScale: lineHeightScale,
            letterSpacing: letterSpacing,
            paragraphSpacing: paragraphSpacing,
            forceFont: forceFont,
            hidesRuby: hidesRuby,
            showsPrintPageInFurniture: true)
    }
}
