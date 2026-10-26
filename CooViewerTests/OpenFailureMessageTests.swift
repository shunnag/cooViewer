import XCTest
@testable import cooViewer

final class OpenFailureMessageTests: XCTestCase {
    private let url = URL(fileURLWithPath: "/private/hidden/図面集")

    private func japaneseBundle() throws -> Bundle {
        let path = try XCTUnwrap(Bundle.main.path(forResource: "ja", ofType: "lproj"))
        return try XCTUnwrap(Bundle(path: path))
    }

    private func failure(_ causes: [ReadFailureCause], unchecked: Int = 0,
                         unavailable: Bool = false) -> AssemblyFailure {
        AssemblyFailure(failures: causes.enumerated().map { index, cause in
            ChildReadFailure(relativePath: "/private/subfolder/A-0\(17 + index).zip",
                url: url.appendingPathComponent("hidden.zip"), cause: cause, retryClass: .persistent)
        }, total: causes.count + unchecked, unchecked: unchecked,
            volumeUnavailable: unavailable, sourceURL: url)
    }

    func testChildNameCannotInjectFailureLines() throws {
        let child = ChildReadFailure(relativePath: "dir/巻\n偽案内\u{2028}続き.zip",
            url: url, cause: .accessDenied, retryClass: .persistent)
        let failure = AssemblyFailure(failures: [child], total: 1, unchecked: 0,
            volumeUnavailable: false, sourceURL: url)
        let text = OpenFailureMessage.text(for: failure, bookName: "本", bundle: try japaneseBundle())
        XCTAssertEqual(text.components(separatedBy: .newlines).count, 4)
        XCTAssertTrue(text.contains("巻 偽案内 続き.zip"))
    }

    func testUnreadableMarkerNameCannotInjectLines() {
        let plain = UnreadableVolumeMarker(relativePath: "巻.zip", cause: .accessDenied).message
        let injected = UnreadableVolumeMarker(relativePath: "巻\r\n偽案内\u{2029}.zip", cause: .accessDenied).message
        XCTAssertEqual(injected.components(separatedBy: .newlines).count,
                       plain.components(separatedBy: .newlines).count)
    }

    @MainActor
    func testPasswordPromptNameCannotInjectLines() {
        let text = ReaderWindowController.nestedPasswordMessage(name: "巻\n偽案内\u{2029}.zip")
        XCTAssertEqual(text.components(separatedBy: .newlines).count, 1)
        XCTAssertTrue(text.contains("巻 偽案内 .zip"))
    }

    func testEntryNameFormatterClampsAndPreservesBidiPolicy() {
        XCTAssertEqual(EntryNameFormatter.forDisplay("\u{202E}" + String(repeating: "名", count: 200), limit: 80).count, 80)
        XCTAssertEqual(EntryNameFormatter.forDisplay("\u{202E}名", limit: 120), "\u{202E}名")
        XCTAssertEqual(EntryNameFormatter.forDisplay("名", limit: 0), "")
    }

    func testOneFailure() throws {
        let text = OpenFailureMessage.text(for: failure([.accessDenied]), bookName: "図面集",
                                           bundle: try japaneseBundle())
        XCTAssertEqual(text, "“図面集” を開けませんでした。\n次の 1 冊を読み込めません:\n・A-017.zip — アクセス権がありません\nページが欠けた状態では表示しません。")
    }

    func testTwoFailuresWithSharedCauseEachHaveOneReadableLine() throws {
        let text = OpenFailureMessage.text(for: failure([.connectionLost, .connectionLost]),
                                           bookName: "図面集", bundle: try japaneseBundle())
        XCTAssertTrue(text.contains("次の 2 冊を読み込めません:\n・A-017.zip — 接続が切れています\n・A-018.zip — 接続が切れています\n"))
        XCTAssertEqual(text.components(separatedBy: "接続が切れています").count - 1, 2)
        XCTAssertFalse(text.contains("ほか"))
    }

    func testTwoFailuresWithMixedCauses() throws {
        let text = OpenFailureMessage.text(for: failure([.accessDenied, .diskFull]),
                                           bookName: "図面集", bundle: try japaneseBundle())
        XCTAssertTrue(text.contains("次の 2 冊を読み込めません:\n・A-017.zip — アクセス権がありません\n・A-018.zip — ディスクの空きが足りません\n"))
    }

    func testFiveFailuresLimitNamesToThreeLines() throws {
        let text = OpenFailureMessage.text(for: failure(Array(repeating: .fileChanged, count: 5)),
                                           bookName: "図面集", bundle: try japaneseBundle())
        XCTAssertTrue(text.contains("次の 5 冊を読み込めません:\n・A-017.zip — 読み込み中にファイルが変わりました\n・A-018.zip — 読み込み中にファイルが変わりました\n・A-019.zip — 読み込み中にファイルが変わりました\n・ほか 2 冊\n"))
        XCTAssertFalse(text.contains("A-020"))
    }

    func testFiveMixedFailuresAndUncheckedNeverExposeParentOrAbsolutePaths() throws {
        let text = OpenFailureMessage.text(for: failure([.notFound, .repeatedFailure, .diskFull,
            .accessDenied, .fileChanged], unchecked: 2), bookName: "図面集", bundle: try japaneseBundle())
        XCTAssertTrue(text.contains("・A-017.zip — ファイルが見つかりません(移動・削除された可能性)\n・A-018.zip — 繰り返し読み込みに失敗しました\n・A-019.zip — ディスクの空きが足りません\n・ほか 2 冊\n"))
        XCTAssertTrue(text.contains("さらに 2 冊は確認できませんでした。"))
        for path in ["private", "hidden", "subfolder", "A-020"] { XCTAssertFalse(text.contains(path)) }
    }

    func testVolumeUnavailableReplacesList() throws {
        let text = OpenFailureMessage.text(for: failure([.connectionLost], unchecked: 2, unavailable: true),
                                           bookName: "図面集", bundle: try japaneseBundle())
        XCTAssertEqual(text, "“図面集” を開けませんでした。\n保存先に接続できません。再接続(マウント)かスリープ解除のときに自動で読み直します。\n2 冊は確認できませんでした。\nページが欠けた状態では表示しません。")
    }

    func testBookNotFoundAndDisconnectedVariants() throws {
        let bundle = try japaneseBundle()
        let missing = OpenFailureMessage.textForNotFound(bookName: "図面集", bundle: bundle)
        XCTAssertTrue(missing.hasPrefix("“図面集” が見つかりません"))
        XCTAssertTrue(missing.contains("移動・削除された可能性があります"))
        XCTAssertFalse(missing.contains("ページが欠けた状態"))
        let disconnected = OpenFailureMessage.textForNotFound(bookName: "図面集",
            volumeUnavailable: true, bundle: bundle)
        XCTAssertTrue(disconnected.contains("保存先に接続できません"))
        XCTAssertFalse(disconnected.contains("見つかりません"))
        XCTAssertFalse(disconnected.contains("ページが欠けた状態"))
    }

    func testUncheckedWithoutAnyNamedFailuresHasNoAdditionalPrefix() throws {
        let text = OpenFailureMessage.text(for: failure([], unchecked: 2),
            bookName: "図面集", bundle: try japaneseBundle())
        XCTAssertTrue(text.contains("\n2 冊は確認できませんでした。\n"))
        XCTAssertFalse(text.contains("さらに"))
    }

    func testUnavailableMessageOnlyPromisesAutomaticRetryWhileArmed() throws {
        let bundle = try japaneseBundle()
        let text = OpenFailureMessage.text(for: failure([.connectionLost], unavailable: true),
            bookName: "図面集", automaticRetryArmed: false, bundle: bundle)
        XCTAssertTrue(text.contains("接続が戻ったら「もう一度読み込む」を選んでください。"))
        XCTAssertFalse(text.contains("自動で読み直します"))
        let missing = OpenFailureMessage.textForNotFound(bookName: "図面集", volumeUnavailable: true,
            automaticRetryArmed: false, bundle: bundle)
        XCTAssertTrue(missing.contains("接続が戻ったら「もう一度読み込む」を選んでください。"))
        XCTAssertFalse(missing.contains("自動で読み直します"))
        XCTAssertEqual(text.components(separatedBy: "図面集").count - 1, 1)
    }

    func testSnapshotFixtureShowsThreeSeparateVolumesAndUncheckedCount() throws {
        let text = OpenFailureMessage.text(for: failure([.accessDenied, .notFound, .diskFull], unchecked: 2),
            bookName: "図面集", bundle: try japaneseBundle())
        XCTAssertEqual(text, "“図面集” を開けませんでした。\n次の 3 冊を読み込めません:\n・A-017.zip — アクセス権がありません\n・A-018.zip — ファイルが見つかりません(移動・削除された可能性)\n・A-019.zip — ディスクの空きが足りません\nさらに 2 冊は確認できませんでした。\nページが欠けた状態では表示しません。")
    }

    func testEnglishCountMessagesHaveSingularAndPluralForms() throws {
        let path = try XCTUnwrap(Bundle.main.path(forResource: "en", ofType: "lproj"))
        let bundle = try XCTUnwrap(Bundle(path: path))
        for count in [1, 2] {
            let word = count == 1 ? "book" : "books"
            let listed = OpenFailureMessage.text(for: failure(Array(repeating: .diskFull, count: count), unchecked: count),
                bookName: "Plans", bundle: bundle, locale: Locale(identifier: "en"))
            XCTAssertTrue(listed.contains("Could not read the following \(count) \(word):"))
            XCTAssertTrue(listed.contains("Could not check \(count) additional \(word)."))
            let unlisted = OpenFailureMessage.text(for: failure([], unchecked: count), bookName: "Plans",
                bundle: bundle, locale: Locale(identifier: "en"))
            XCTAssertTrue(unlisted.contains("Could not check \(count) \(word)."))
            let remainder = OpenFailureMessage.text(for: failure(Array(repeating: .diskFull, count: count + 3)),
                bookName: "Plans", bundle: bundle, locale: Locale(identifier: "en"))
            XCTAssertTrue(remainder.contains("• \(count) more \(word)"))
        }
    }
}
