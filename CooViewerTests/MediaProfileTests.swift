import XCTest

@testable import cooViewer

/// メディア速度プロファイル(設計書 キャッシュ節の自動適応)のテスト。
/// 分類の純粋関数・方針表・読み取りゲート・実機プローブの基本動作を確認する。
final class MediaProfileTests: XCTestCase {
    // MARK: - 分類(純粋関数)

    func testNetworkVolumeClassifiesAsNetwork() {
        let profile = MediaProfile.classify(
            isLocalVolume: false, mediumType: .unknown, measuredMBPerSec: nil)
        XCTAssertEqual(profile.mediaClass, .network)
    }

    func testMediumTypeDecidesLocalClass() {
        XCTAssertEqual(MediaProfile.classify(
            isLocalVolume: true, mediumType: .solidState,
            measuredMBPerSec: nil).mediaClass, .fastLocal)
        XCTAssertEqual(MediaProfile.classify(
            isLocalVolume: true, mediumType: .rotational,
            measuredMBPerSec: nil).mediaClass, .slowLocal)
    }

    func testBenchmarkDecidesWhenMediumUnknown() {
        // 速い実測 → fastLocal / 遅い実測 → slowLocal / 中間帯は安全側(slow)
        XCTAssertEqual(MediaProfile.classify(
            isLocalVolume: true, mediumType: .unknown,
            measuredMBPerSec: 900).mediaClass, .fastLocal)
        XCTAssertEqual(MediaProfile.classify(
            isLocalVolume: true, mediumType: .unknown,
            measuredMBPerSec: 40).mediaClass, .slowLocal)
        XCTAssertEqual(MediaProfile.classify(
            isLocalVolume: true, mediumType: .unknown,
            measuredMBPerSec: 120).mediaClass, .slowLocal)
    }

    func testInconclusiveFallsBackToUnknown() {
        let profile = MediaProfile.classify(
            isLocalVolume: true, mediumType: .unknown, measuredMBPerSec: nil)
        XCTAssertEqual(profile.mediaClass, .unknown)
    }

    // MARK: - 方針表

    func testUnknownProfileKeepsLegacyBehavior() {
        // unknown は従来の固定動作と同値であること(判定不能時の回帰防止)
        let profile = MediaProfile.unknown
        XCTAssertEqual(profile.bookPrefetchConcurrency, 4)
        XCTAssertEqual(profile.thumbnailPrefetchConcurrency, 3)
        XCTAssertEqual(profile.defaultPrefetchAhead,
                       SettingsStore.AdvancedDefault.prefetchAhead)
        XCTAssertEqual(profile.defaultPrefetchBehind,
                       SettingsStore.AdvancedDefault.prefetchBehind)
        XCTAssertTrue(profile.shouldSpoolArchive(fileExtension: "zip"))
        XCTAssertTrue(profile.shouldSpoolArchive(fileExtension: "rar"))
    }

    func testFastLocalConcurrencyScalesWithCoresWithinBounds() {
        // 高速ローカルの並列度はコア数連動だが下限 6・上限 12 に収める
        let concurrency = MediaProfile.fastLocalConcurrency
        XCTAssertGreaterThanOrEqual(concurrency, 6)
        XCTAssertLessThanOrEqual(concurrency, 12)
        let profile = MediaProfile(mediaClass: .fastLocal)
        XCTAssertEqual(profile.bookPrefetchConcurrency, concurrency)
        XCTAssertEqual(profile.sourceReadConcurrency, concurrency)
        XCTAssertEqual(profile.thumbnailPrefetchConcurrency, concurrency)
    }

    func testFastLocalSkipsSpoolingForRandomAccessFormats() {
        let profile = MediaProfile(mediaClass: .fastLocal)
        XCTAssertFalse(profile.shouldSpoolArchive(fileExtension: "zip"))
        XCTAssertFalse(profile.shouldSpoolArchive(fileExtension: "cbz"))
        // solid になり得る形式と分割書庫は高速ローカルでもスプールする
        XCTAssertTrue(profile.shouldSpoolArchive(fileExtension: "rar"))
        XCTAssertTrue(profile.shouldSpoolArchive(fileExtension: "7z"))
        XCTAssertTrue(profile.shouldSpoolArchive(fileExtension: "001"))
        // 構造が拡張子に勝つ: エントリ独立と判明した rar/7z はスプール不要
        XCTAssertFalse(profile.shouldSpoolArchive(fileExtension: "rar",
                                                  independentEntries: true))
        XCTAssertFalse(profile.shouldSpoolArchive(fileExtension: "7z",
                                                  independentEntries: true))
        // 分割ボリュームは独立でも常にスプール
        XCTAssertTrue(profile.shouldSpoolArchive(fileExtension: "001",
                                                 independentEntries: true))
    }

    func testSlowMediaSpoolEverythingAndThrottle() {
        for mediaClass in [MediaProfile.MediaClass.slowLocal, .network] {
            let profile = MediaProfile(mediaClass: mediaClass)
            XCTAssertTrue(profile.shouldSpoolArchive(fileExtension: "zip"))
            XCTAssertLessThanOrEqual(profile.sourceReadConcurrency, 3)
            XCTAssertLessThanOrEqual(profile.bookPrefetchConcurrency, 2)
            XCTAssertGreaterThanOrEqual(profile.defaultPrefetchAhead, 16,
                                        "遅い媒体は先読みを深くする")
        }
    }

    func testSpoolOverrideBeatsAutomaticPolicy() {
        // 高度設定の明示(常に/しない)は自動判定より優先されること
        var fast = MediaProfile(mediaClass: .fastLocal)
        fast.spoolOverride = true
        XCTAssertTrue(fast.shouldSpoolArchive(fileExtension: "zip"),
                      "「常に行う」は高速ローカルの zip でも展開する")

        var slow = MediaProfile(mediaClass: .slowLocal)
        slow.spoolOverride = false
        XCTAssertFalse(slow.shouldSpoolArchive(fileExtension: "rar"),
                       "「行わない」は低速媒体の rar でも展開しない")

        var network = MediaProfile(mediaClass: .network)
        network.spoolOverride = nil
        XCTAssertTrue(network.shouldSpoolArchive(fileExtension: "zip"),
                      "nil(自動)はクラスの方針に従う")
    }

    // MARK: - 読み取りゲート

    func testReadGateCapsConcurrency() async {
        let gate = SourceReadGate(limit: 2)
        let counter = ConcurrencyCounter()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<12 {
                group.addTask {
                    await gate.acquire()
                    await counter.enter()
                    try? await Task.sleep(for: .milliseconds(15))
                    await counter.exit()
                    await gate.release()
                }
            }
        }
        let peak = await counter.peak
        XCTAssertLessThanOrEqual(peak, 2, "同時実行がゲート上限を超えないこと")
        let total = await counter.total
        XCTAssertEqual(total, 12, "全読者がいずれ実行されること")
    }

    func testReadGateInteractiveOvertakesBackgroundQueue() async {
        // 表示用(userInitiated)の待ち手は、先に並んでいた背景(utility)の
        // 待ち行列を追い越して先に許可されること
        let gate = SourceReadGate(limit: 1)
        await gate.acquire()  // 埋めておく

        let order = OrderRecorder()
        let background = (0..<3).map { index in
            Task(priority: .utility) {
                await gate.acquire()
                await order.record("bg\(index)")
                await gate.release()
            }
        }
        // 背景の待ち手が並ぶまで少し待つ
        try? await Task.sleep(for: .milliseconds(50))
        let interactive = Task(priority: .userInitiated) {
            await gate.acquire()
            await order.record("interactive")
            await gate.release()
        }
        try? await Task.sleep(for: .milliseconds(50))
        await gate.release()  // 行列が流れ始める

        _ = await interactive.value
        for task in background { _ = await task.value }
        let sequence = await order.sequence
        XCTAssertEqual(sequence.first, "interactive",
                       "表示用の読み込みが背景の行列を追い越すこと")
        XCTAssertEqual(Set(sequence), ["interactive", "bg0", "bg1", "bg2"])
    }

    func testReadGateLimitIncreaseWakesWaiters() async {
        let gate = SourceReadGate(limit: 1)
        await gate.acquire()
        let waiter = Task {
            await gate.acquire()
            await gate.release()
            return true
        }
        // 上限を上げると待ち手が起きる(解放を待たずに)
        try? await Task.sleep(for: .milliseconds(20))
        await gate.setLimit(2)
        let woke = await waiter.value
        XCTAssertTrue(woke)
        await gate.release()
    }

    // MARK: - プローブ(実機スモーク)

    func testProbeClassifiesLocalTempAsNonNetwork() async throws {
        // CI/開発機のテンポラリはローカルボリューム。クラスまでは環境依存の
        // ため「network でない」ことだけを確認する
        let dir = try TestFixtures.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("probe.bin")
        try Data(count: 4 << 20).write(to: file)
        let profile = await MediaSpeedProbe.profile(for: file)
        XCTAssertNotEqual(profile.mediaClass, .network)
    }
}

/// 実行順を記録する計測用 actor
private actor OrderRecorder {
    private(set) var sequence: [String] = []

    func record(_ label: String) {
        sequence.append(label)
    }
}

/// 同時実行数の頂点を数える計測用 actor
private actor ConcurrencyCounter {
    private var active = 0
    private(set) var peak = 0
    private(set) var total = 0

    func enter() {
        active += 1
        total += 1
        peak = max(peak, active)
    }

    func exit() {
        active -= 1
    }
}
