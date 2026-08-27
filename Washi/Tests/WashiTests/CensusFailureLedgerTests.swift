import XCTest
@testable import Washi

/// census 失敗台帳(2-strike + TTL)の検証。now を注入して完全決定論(sleep 不要)。
final class CensusFailureLedgerTests: XCTestCase {
    func testTwoStrikesThenSkip() {
        var ledger = CensusFailureLedger(ttl: .seconds(300))
        let t0 = ContinuousClock.now
        XCTAssertFalse(ledger.shouldSkip("k", now: t0))  // 未記録
        ledger.recordFailure("k", now: t0)
        XCTAssertFalse(ledger.shouldSkip("k", now: t0))  // 1 回では止めない
        ledger.recordFailure("k", now: t0)
        XCTAssertTrue(ledger.shouldSkip("k", now: t0))   // 2 回で恒久記録
    }

    func testForgivenAfterTTL() {
        var ledger = CensusFailureLedger(ttl: .seconds(300))
        let t0 = ContinuousClock.now
        ledger.recordFailure("k", now: t0)
        ledger.recordFailure("k", now: t0)
        XCTAssertTrue(ledger.shouldSkip("k", now: t0))
        // TTL 経過で赦す
        let later = t0.advanced(by: .seconds(301))
        XCTAssertFalse(ledger.shouldSkip("k", now: later))
        // 勘定リセット後は 1 回失敗しても再 skip しない
        ledger.recordFailure("k", now: later)
        XCTAssertFalse(ledger.shouldSkip("k", now: later))
    }

    func testClearResets() {
        var ledger = CensusFailureLedger(ttl: .seconds(300))
        let t0 = ContinuousClock.now
        ledger.recordFailure("k", now: t0)
        ledger.recordFailure("k", now: t0)
        XCTAssertTrue(ledger.shouldSkip("k", now: t0))
        ledger.clear()
        XCTAssertFalse(ledger.shouldSkip("k", now: t0))
    }
}
