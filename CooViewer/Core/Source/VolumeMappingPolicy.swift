import Foundation
import Washi

/// 書庫と EPUB に共通のボリューム安全性判定(cooViewer-oxr.39)。
/// リムーバブル媒体の取り外しやネットワーク切断後のマップ参照は SIGBUS を
/// 招くため、ローカル・非リムーバブル・非取り出し可能と確認できた場合のみ許可する。
enum VolumeMappingPolicy {
    static func isSafeForMemoryMapping(url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [
            .volumeIsLocalKey, .volumeIsRemovableKey, .volumeIsEjectableKey,
        ]) else { return false }
        return isSafeForMemoryMapping(
            volumeIsLocal: values.volumeIsLocal,
            isRemovable: values.volumeIsRemovable,
            isEjectable: values.volumeIsEjectable)
    }

    /// 属性が一つでも不明ならマップを許可しない。
    static func isSafeForMemoryMapping(
        volumeIsLocal: Bool?, isRemovable: Bool?, isEjectable: Bool?
    ) -> Bool {
        volumeIsLocal == true && isRemovable == false && isEjectable == false
    }

    /// 安全性を確認できない EPUB は必ずコピーし、媒体の寿命に読み出しを依存させない。
    static func epubReadStrategy(for url: URL) -> EPUBReadStrategy {
        isSafeForMemoryMapping(url: url) ? .mappedIfSafe : .alwaysCopy
    }
}
