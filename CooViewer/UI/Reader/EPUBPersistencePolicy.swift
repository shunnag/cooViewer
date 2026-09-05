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
    static func shouldSaveNow(
        lastSave: Date?,
        now: Date,
        maximumLatency: TimeInterval = 30
    ) -> Bool {
        guard let lastSave else { return true }
        return now.timeIntervalSince(lastSave) >= maximumLatency
    }
}
