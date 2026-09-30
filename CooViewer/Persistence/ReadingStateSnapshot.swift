/// 固定ページの本を閉じる時点の状態(仕様書 §7)。
/// 位置と設定を同じ JSON 更新へ渡し、途中の空状態を永続化しない。
struct ImageBookStateSnapshot {
    let displayName: String
    let pageIndex: Int
    let pagePath: String?
    let settings: SavedBookSettings
}

/// Washi の型を持ち込まずにリフローの保存位置を表す。
struct ReflowReadingPosition {
    let spineIndex: Int
    let progression: Double
    var idref: String? = nil
}

struct ReflowBookmarkSnapshot {
    let name: String
    let position: ReflowReadingPosition
}

struct ReflowCensusSnapshot {
    let metricsKey: String
    let counts: [Int]
    let releaseIdentifier: String?
}

/// 一冊の EPUB の位置・表示設定・しおり・実測を一度に保存する。
/// 合本の子は最近の一覧へ加えず、書込時の復元条件だけを満たす(設計書 §2.4)。
struct ReflowBookStateSnapshot {
    let position: ReflowReadingPosition
    let columnMode: Int
    let bookmarks: [ReflowBookmarkSnapshot]
    let census: ReflowCensusSnapshot?
    var forceRememberBeyondRecents = false
}
