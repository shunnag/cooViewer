import Foundation
import os
import XCTest

@testable import cooViewer

/// ボリュームごとのプローブキュー(設計書 §7.3)。マウントテーブルは注入し、
/// 実マウントにも実ネットワークボリュームにも依存しない。
final class VolumeProbeQueuesTests: XCTestCase {
    private let table = MountTable(mountPoints: [
        "/", "/System/Volumes/Data", "/Volumes/NAS", "/Volumes/NAS/sub", "/Volumes/Local",
    ])

    private func makeQueues(width: Int, table: MountTable? = nil,
                            maximumVolumeQueues: Int = 16) -> VolumeProbeQueues {
        let table = table ?? self.table
        return VolumeProbeQueues(
            label: "test.cooViewer.volumes", width: width,
            mountTable: MountTableCache(read: { table }, refreshInterval: .zero),
            maximumVolumeQueues: maximumVolumeQueues)
    }

    // MARK: - ボリュームの選択

    func testLongestPrefixWins() {
        XCTAssertEqual(table.mountPoint(forPath: "/Volumes/NAS/book.zip"), "/Volumes/NAS")
        XCTAssertEqual(table.mountPoint(forPath: "/Volumes/NAS/sub/deeper/book.zip"),
                       "/Volumes/NAS/sub")
        XCTAssertEqual(table.mountPoint(forPath: "/Volumes/NAS/sub"), "/Volumes/NAS/sub",
                       "マウントポイントそのもの")
        XCTAssertEqual(table.mountPoint(forPath: "/Users/x/Comics/a.zip"), "/")
        XCTAssertEqual(table.mountPoint(forPath: "/System/Volumes/Data/Users/x/a.zip"),
                       "/System/Volumes/Data")
    }

    func testPrefixMatchRespectsComponentBoundaries() {
        XCTAssertEqual(table.mountPoint(forPath: "/Volumes/NAS2/book.zip"), "/",
                       "/Volumes/NAS2 は /Volumes/NAS の配下ではない")
        XCTAssertEqual(table.mountPoint(forPath: "/Volumes/NAS/subway/book.zip"), "/Volumes/NAS",
                       "/Volumes/NAS/subway は /Volumes/NAS/sub の配下ではない")
        XCTAssertEqual(table.mountPoint(forPath: "/Volumes/LocalDisk/a"), "/")
    }

    func testUnknownAndRelativePathsGoToRoot() {
        XCTAssertEqual(table.mountPoint(forPath: "/Volumes/Gone/book.zip"), "/")
        XCTAssertEqual(table.mountPoint(forPath: "relative/book.zip"), "/")
        XCTAssertEqual(table.mountPoint(forPath: ""), "/")
        XCTAssertEqual(MountTable(mountPoints: []).mountPoint(forPath: "/Volumes/NAS/a"), "/",
                       "空のテーブルでもルートは常にある")
    }

    func testLexicalNormalizationWithoutTouchingTheFileSystem() {
        XCTAssertEqual(table.mountPoint(forPath: "/Volumes//NAS/./book.zip"), "/Volumes/NAS")
        XCTAssertEqual(table.mountPoint(forPath: "/Volumes/NAS/../Local/book.zip"), "/Volumes/Local")
        XCTAssertEqual(table.mountPoint(forPath: "/Volumes/NAS/"), "/Volumes/NAS")
        XCTAssertEqual(MountTable(mountPoints: ["/Volumes/NAS/", "//"]).mountPoints,
                       ["/Volumes/NAS", "/"], "マウントポイント側も正規化し、重複は落とす")
    }

    /// 塞がらない `getmntinfo_r_np` の FFI 経路(バッファの受け取りと文字列化)だけを
    /// 通す煙テスト。実テーブルの内容については何も主張しない(ルートは常にある)
    func testCurrentMountTableIsReadableAndContainsRoot() {
        let current = MountTable.readCurrent()
        XCTAssertTrue(current.mountPoints.contains("/"))
        XCTAssertEqual(current.mountPoint(forPath: "/"), "/")
    }

    func testCacheRereadsOnlyAfterTheInterval() {
        let reads = OSAllocatedUnfairLock(initialState: 0)
        let cache = MountTableCache(read: {
            reads.withLock { $0 += 1 }
            return MountTable(mountPoints: ["/Volumes/A"])
        }, refreshInterval: .seconds(60))
        XCTAssertEqual(cache.current().mountPoints, ["/Volumes/A", "/"])
        _ = cache.current()
        _ = cache.current()
        XCTAssertEqual(reads.withLock { $0 }, 1, "間隔内は写しを使い回す")
    }

    // MARK: - キューの振り分け・寿命・上限

    func testQueuesAreKeyedByVolumeAndFallBackToRoot() {
        let queues = makeQueues(width: 1)
        let root = queues.queue(forPath: "/Users/x/a.zip")
        XCTAssertEqual(queues.queue(for: URL(fileURLWithPath: "/Volumes/Gone/a.zip")).label,
                       root.label, "一致しないパスはルートのキュー")
        XCTAssertEqual(queues.queue(forPath: "/Volumes/NAS/a.zip").label,
                       queues.queue(forPath: "/Volumes/NAS/b/c.zip").label)
        XCTAssertNotEqual(queues.queue(forPath: "/Volumes/NAS/a.zip").label,
                          queues.queue(forPath: "/Volumes/NAS/sub/a.zip").label)
        XCTAssertNotEqual(queues.queue(forPath: "/Volumes/NAS/a.zip").label, root.label)
        XCTAssertEqual(queues.mountPoints, ["/", "/Volumes/NAS", "/Volumes/NAS/sub"],
                       "キューは要求されたボリュームにだけ作る")
    }

    func testVolumesBeyondTheBoundEvictAnIdleQueue() {
        let queues = makeQueues(width: 1, maximumVolumeQueues: 2)
        let root = queues.queue(forPath: "/Users/x").label
        let nas = queues.queue(forPath: "/Volumes/NAS/a").label
        let sub = queues.queue(forPath: "/Volumes/NAS/sub/a").label
        XCTAssertNotEqual(nas, root)
        XCTAssertNotEqual(sub, root)
        let local = queues.queue(forPath: "/Volumes/Local/a").label
        XCTAssertNotEqual(local, root, "暇なキューを 1 本捨てて新顔に自分のキューを与える")
        XCTAssertEqual(queues.mountPoints.count, 3)
        XCTAssertTrue(queues.mountPoints.contains("/Volumes/Local"))
    }

    func testVolumesBeyondTheBoundShareRootOnlyWhenEveryQueueIsBusy() async {
        let queues = makeQueues(width: 1, maximumVolumeQueues: 2)
        let release = DispatchSemaphore(value: 0)
        defer { for _ in 0..<2 { release.signal() } }
        let entered = expectation(description: "2 本のボリュームキューが塞がった")
        entered.expectedFulfillmentCount = 2
        let busy = ["/Volumes/NAS/a", "/Volumes/NAS/sub/a"].map { path in
            Task {
                await queues.queue(forPath: path).run { () -> Bool in
                    entered.fulfill()
                    release.wait()
                    return true
                }
            }
        }
        await fulfillment(of: [entered], timeout: 5)

        let root = queues.queue(forPath: "/Users/x").label
        XCTAssertEqual(queues.queue(forPath: "/Volumes/Local/a").label, root,
                       "全部塞がっているときだけルートを共有する")
        XCTAssertEqual(queues.mountPoints, ["/", "/Volumes/NAS", "/Volumes/NAS/sub"])

        for _ in 0..<2 { release.signal() }
        for task in busy { _ = await task.value }
    }

    func testUnmountedIdleQueuesArePrunedWhenTheTableChanges() async {
        let current = OSAllocatedUnfairLock(initialState: table)
        let queues = VolumeProbeQueues(
            label: "test.cooViewer.prune", width: 1,
            mountTable: MountTableCache(read: { current.withLock { $0 } }, refreshInterval: .zero))
        _ = queues.queue(forPath: "/Volumes/NAS/a")
        _ = queues.queue(forPath: "/Volumes/Local/a")
        XCTAssertEqual(queues.mountPoints, ["/", "/Volumes/NAS", "/Volumes/Local"])

        // NAS が外れ、暇なキューは次の要求で捨てられる。以後そのパスはルートへ
        current.withLock { $0 = MountTable(mountPoints: ["/", "/Volumes/Local"]) }
        let root = queues.queue(forPath: "/Users/x").label
        XCTAssertEqual(queues.mountPoints, ["/", "/Volumes/Local"])
        XCTAssertEqual(queues.queue(forPath: "/Volumes/NAS/a").label, root)

        // 操作が残っているキューは、ボリュームが外れても結果を届けるまで残す
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let entered = expectation(description: "Local のキューで塞がった")
        let busy = Task {
            await queues.queue(forPath: "/Volumes/Local/a").run { () -> Int in
                entered.fulfill()
                release.wait()
                return 1
            }
        }
        await fulfillment(of: [entered], timeout: 5)
        current.withLock { $0 = MountTable(mountPoints: ["/"]) }
        _ = queues.queue(forPath: "/Users/x")
        XCTAssertEqual(queues.mountPoints, ["/", "/Volumes/Local"], "進行中のキューは残る")
        release.signal()
        let value = await busy.value
        XCTAssertEqual(value, 1)
    }

    /// 死んだボリュームのキューが幅ぶん塞がっていても、別ボリュームの呼び出しはすぐ戻り、
    /// 死んだボリュームへの追加の呼び出しだけが(スレッドを持たずに)待つ
    func testBlockedVolumeDoesNotDelayOtherVolumes() async {
        let width = 2
        let queues = makeQueues(width: width)
        let release = DispatchSemaphore(value: 0)
        // 失敗しても塞がったスレッドを残さない
        defer { for _ in 0..<(width + 1) { release.signal() } }

        let entered = expectation(description: "死んだボリュームの幅ぶんが塞がった")
        entered.expectedFulfillmentCount = width
        let hung = (0..<width).map { index in
            Task {
                await queues.queue(forPath: "/Volumes/NAS/dead-\(index).zip").run { () -> Int in
                    entered.fulfill()
                    release.wait()
                    return index
                }
            }
        }
        await fulfillment(of: [entered], timeout: 5)

        let extraFinished = expectation(description: "死んだボリュームへの追加の呼び出しが戻った")
        extraFinished.isInverted = true
        let extra = Task {
            let value = await queues.queue(forPath: "/Volumes/NAS/extra.zip").run { () -> Int in
                release.wait()
                return 99
            }
            extraFinished.fulfill()
            return value
        }

        let liveFinished = expectation(description: "別ボリュームの呼び出しが戻った")
        let live = Task {
            let value = await queues.queue(forPath: "/Volumes/Local/book.zip").run { 7 }
            liveFinished.fulfill()
            return value
        }
        let rootFinished = expectation(description: "ルートの呼び出しが戻った")
        let root = Task {
            let value = await queues.queue(forPath: "/Users/x/book.zip").run { 8 }
            rootFinished.fulfill()
            return value
        }
        await fulfillment(of: [liveFinished, rootFinished], timeout: 5)
        await fulfillment(of: [extraFinished], timeout: 0.3)
        let liveValue = await live.value
        let rootValue = await root.value
        XCTAssertEqual(liveValue, 7)
        XCTAssertEqual(rootValue, 8)

        for _ in 0..<(width + 1) { release.signal() }
        var hungValues: [Int] = []
        for task in hung { hungValues.append(await task.value) }
        XCTAssertEqual(hungValues, Array(0..<width), "解放後は塞がっていた結果も届く")
        let extraValue = await extra.value
        XCTAssertEqual(extraValue, 99)
    }
}
