import Foundation
import Washi

/// EPUBReaderView の遅延 callback を現在の本へ永続化してよいかを判定する
/// 純関数群（cooViewer-oxr.23、設計書 §2.4）。
enum EPUBPersistencePolicy {
    static func shouldPersist(
        callbackPublication: EPUBPublication?,
        currentPublication: EPUBPublication?
    ) -> Bool {
        guard let callbackPublication, let currentPublication else { return false }
        return callbackPublication === currentPublication
    }

    /// 通知が途切れない場合でも、最後の成功から 30 秒で保存を確定する。
    /// 失敗後は試行時刻からも間隔を空け、全通知で同期書込を繰り返さない。
    static func shouldSaveNow(
        lastSave: Date?,
        lastAttempt: Date? = nil,
        now: Date,
        maximumLatency: TimeInterval = 30
    ) -> Bool {
        if let lastAttempt, now.timeIntervalSince(lastAttempt) < maximumLatency {
            return false
        }
        guard let lastSave else { return true }
        return now.timeIntervalSince(lastSave) >= maximumLatency
    }
}

/// 一冊の保存周期。失敗した試行を成功と呼ばず、連続通知での再試行も制限する。
struct EPUBSaveSchedule {
    private(set) var lastSuccessfulSaveAt: Date?
    private(set) var lastAttemptAt: Date?

    func shouldSaveNow(at now: Date) -> Bool {
        EPUBPersistencePolicy.shouldSaveNow(
            lastSave: lastSuccessfulSaveAt, lastAttempt: lastAttemptAt, now: now)
    }

    mutating func recordAttempt(at now: Date, succeeded: Bool) {
        lastAttemptAt = now
        if succeeded { lastSuccessfulSaveAt = now }
    }
}
